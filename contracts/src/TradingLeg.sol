// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";

/// @title TradingLeg — торговая нога пула: свой Core-счёт, agent-ключ бота, переводы только с хранилищем.
/// @notice Пул держит ДВЕ ноги 50/50: на одном счёте Hyperliquid неттит встречные позиции по одной монете (спека rev7 §2).
/// Нога не знает бухгалтерии: она исполняет переводы, которые велит хранилище, и отдаёт свою стоимость прекомпайлом.
/// ⚠ Действия CoreWriter АСИНХРОННЫ: HyperCore исполняет их после блока и об отказе контракту не сообщает. Сверка
/// идёт по прекомпайлам (`accountValue`, `withdrawableUsd`), а последовательность шагов ведёт keeper.
contract TradingLeg {
    uint64 internal constant USDC = 0;

    address public immutable vault;

    error NotVault();
    error ZeroVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @param vault_ хранилище, которое ещё не развёрнуто (КЕ10): его вычисленный адрес. Конструктор `PoolVault` сверяет,
    /// что `vault == address(this)`; до развёртывания хранилища по этому адресу нет ни кода, ни ключа.
    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroVault();
        vault = vault_;
    }

    /// @notice Ключ бота: торгует от имени ноги и НЕ умеет переводить средства (проверено прогоном #0, R2/R3).
    /// Повторный вызов с тем же именем заменяет прежний ключ (R3).
    function addApiWallet(address agent, string calldata name) external onlyVault {
        CoreWriterLib.addApiWallet(agent, name);
    }

    /// @notice Отмена заявок ноги по oid (CoreWriter, действие 10). Заявки agent'а — заявки этого счёта.
    function cancelOrders(uint32[] calldata assets, uint64[] calldata oids) external onlyVault {
        for (uint256 i = 0; i < oids.length; i++) {
            CoreWriterLib.cancelOrderByOrderId(assets[i], oids[i]);
        }
    }

    /// @param usd микро-USDC (единицы perp на Core совпадают с единицами бухгалтерии).
    function toPerp(uint64 usd) external onlyVault {
        CoreWriterLib.transferUsdClass(usd, true);
    }

    function toSpot(uint64 usd) external onlyVault {
        CoreWriterLib.transferUsdClass(usd, false);
    }

    /// @param usdcWei единицы spot USDC на Core (1e8 на доллар).
    function sendToVault(uint64 usdcWei) external onlyVault {
        CoreWriterLib.spotSend(vault, USDC, usdcWei);
    }

    /// @notice Стоимость perp-счёта ноги, микро-USDC (может быть отрицательной по формату венью).
    function accountValue() external view returns (int64) {
        return PrecompileLib.accountMarginSummary(0, address(this)).accountValue;
    }

    function withdrawableUsd() external view returns (uint64) {
        return PrecompileLib.withdrawable(address(this));
    }

    function spotUsdcWei() external view returns (uint64) {
        return PrecompileLib.spotBalance(address(this), USDC).total;
    }
}
