// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";

/// Минимальный ERC-20 интерфейс — только то, что нужно bridgeToCore (pull от владельца)
/// и sweep (вывод остатка). Не тянем OpenZeppelin ради нескольких вызовов: держим probe
/// самодостаточным.
interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// Research-probe для R1-R6 (e96) и R8/R10/S1/S2/UCT (e103/e104, v2). НЕ вольт: нет долей, нет комиссий,
/// один владелец. v2 только ДОБАВЛЯЕТ функции: прежние сигнатуры зовёт e96 и они не меняются.
contract VaultProbe {
    error NotOwner();
    error ZeroOwner();
    error TransferFromFailed();
    error TransferFailed();
    error NativeTransferFailed();

    address public immutable owner;
    event Action(string what, bytes data);

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroOwner();
        owner = owner_;
    }

    // R5 кладёт bridgeToEvm(...) HYPE НАПРЯМУЮ на EVM-баланс probe (нативный перевод,
    // не ERC-20) — без receive() он бы отверг перевод и завис на полпути моста.
    receive() external payable {}

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // R2/R3: CoreWriter action 9 — add API wallet (через библиотеку, не руками).
    function addApiWallet(address agent, string calldata name) external onlyOwner {
        CoreWriterLib.addApiWallet(agent, name);
        emit Action("addApiWallet", abi.encode(agent, name));
    }

    // R1: EVM -> Core (ERC-20 на системный адрес токена).
    // ⚠ Библиотечный CoreWriterLib.bridgeToCore(uint64,uint256) мостит БАЛАНС САМОГО
    // контракта (approve+deposit / safeTransfer от address(this)) — своего ERC-20 у probe
    // нет. Поэтому внешняя сигнатура (нужна драйверу как есть, cast зовёт её по имени)
    // несёт address usdc ДОПОЛНИТЕЛЬНО к tokenIndex: им мы сначала подтягиваем amount от
    // владельца (transferFrom), а уже потом мостим из своего баланса. Владелец обязан
    // ЗАРАНЕЕ approve(probe, amount) на ERC-20 USDC — операционный шаг вне этого контракта.
    function bridgeToCore(address usdc, uint64 tokenIndex, uint256 amount) external onlyOwner {
        if (!IERC20Min(usdc).transferFrom(msg.sender, address(this), amount)) revert TransferFromFailed();
        CoreWriterLib.bridgeToCore(tokenIndex, amount);
        emit Action("bridgeToCore", abi.encode(tokenIndex, amount));
    }

    // R2/R5: spot <-> perp (action 7). Внешняя сигнатура == внутренняя один в один.
    function usdClassTransfer(uint64 ntl, bool toPerp) external onlyOwner {
        CoreWriterLib.transferUsdClass(ntl, toPerp);
        emit Action("usdClassTransfer", abi.encode(ntl, toPerp));
    }

    // R5: Core -> EVM. weiAmount — величина в CORE-wei (не EVM decimals): библиотечный
    // bridgeToEvm(uint64,uint256,bool) принимает amount как core-wei при isEvmAmount=false —
    // это и есть режим, который R5 измеряет (сетка округления bridge_grid_probe).
    function bridgeToEvm(uint64 tokenIndex, uint64 weiAmount) external onlyOwner {
        CoreWriterLib.bridgeToEvm(tokenIndex, uint256(weiAmount), false);
        emit Action("bridgeToEvm", abi.encode(tokenIndex, weiAmount));
    }

    // R4: признак «плоско». ⚠ Реальная сигнатура библиотеки — accountMarginSummary(uint32
    // perpDexIndex, address user), порядок аргументов ОБРАТНЫЙ тому, что предполагал план;
    // возвращаемая структура (int64 accountValue, uint64 marginUsed, uint64 ntlPos, int64
    // rawUsd) совпадает с внешней ABI-формой один в один.
    function marginSummary() public view returns (PrecompileLib.AccountMarginSummary memory) {
        return PrecompileLib.accountMarginSummary(0, address(this));
    }

    function coreUserExists() external view returns (bool) {
        return PrecompileLib.coreUserExists(address(this));
    }

    // R4 (rev4 спеки): ликвидность эпохи — withdrawable precompile (0x…0803), сырое uint64 Core.
    function withdrawableRaw() external view returns (uint64) {
        return PrecompileLib.withdrawable(address(this));
    }

    // Единственный путь вывода средств у probe: bridgeToEvm (R5) кладёт токен/HYPE на
    // EVM-баланс САМОГО контракта, и без sweep он там и остался бы навсегда.
    function sweep(address token, address to) external onlyOwner {
        uint256 bal = IERC20Min(token).balanceOf(address(this));
        if (!IERC20Min(token).transfer(to, bal)) revert TransferFailed();
        emit Action("sweep", abi.encode(token, to, bal));
    }

    // R8 (контракт #2): spot-перевод с Core-счёта САМОГО контракта на Core-адрес человека
    // (CoreWriter action 6) — тот же путь, которым PoolVault платит `claim`. Перевод себе
    // библиотека отклоняет (`CoreWriterLib__CannotSelfTransfer`): на Core он всегда отказ.
    function spotSend(address to, uint64 token, uint64 weiAmount) external onlyOwner {
        CoreWriterLib.spotSend(to, token, weiAmount);
        emit Action("spotSend", abi.encode(to, token, weiAmount));
    }

    // R8/S1: spot-баланс ЛЮБОГО адреса (total/hold/entryNtl, сырые Core-wei) — прекомпайл 0x…0801.
    function spotBalanceOf(address user, uint64 token) external view returns (PrecompileLib.SpotBalance memory) {
        return PrecompileLib.spotBalance(user, token);
    }

    // R10: маржа ЧУЖОГО адреса (ноги), как её читает PoolVault.reconcile — прекомпайл 0x…080F, dex 0.
    function marginOf(address user) external view returns (PrecompileLib.AccountMarginSummary memory) {
        return PrecompileLib.accountMarginSummary(0, user);
    }

    // R10: позиция ЧУЖОГО адреса по perp-индексу — прекомпайл position2 (0x…0813).
    function positionOf(address user, uint32 perp) external view returns (PrecompileLib.Position memory) {
        return PrecompileLib.position(user, perp);
    }

    function sweepNative(address payable to) external onlyOwner {
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert NativeTransferFailed();
        emit Action("sweepNative", abi.encode(to, bal));
    }
}
