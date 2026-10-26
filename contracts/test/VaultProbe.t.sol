// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultProbe} from "../src/VaultProbe.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {HyperCore} from "hyper-evm-sim/HyperCore.sol";
import {CoreSimulatorLib} from "hyper-evm-sim/CoreSimulatorLib.sol";

/// forge-lint: disable-next-line(mixed-case-function)
contract VaultProbeTest is Test {
    VaultProbe probe;

    function setUp() public {
        probe = new VaultProbe(address(this));
    }

    function test_onlyOwnerCanAddAgent() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(VaultProbe.NotOwner.selector);
        probe.addApiWallet(address(0xA6E7), "vaultagent");
    }

    // marginSummary() зовёт ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS (0x...080F) через
    // staticcall. В голом unit-тесте (без vm.createSelectFork на живой RPC) этого адреса
    // не существует — библиотека несёт свой BaseSimulatorTest/CoreSimulatorLib именно для
    // этого, но он требует createSelectFork на mainnet RPC (сетевая зависимость теста).
    // Для формы возврата достаточно детерминированного мока precompile-адреса (одобрено
    // планом задачи как fallback) — без сети, без форка.
    function test_flatPredicateShape() public {
        vm.mockCall(
            0x000000000000000000000000000000000000080F,
            abi.encode(uint32(0), address(probe)),
            abi.encode(int64(0), uint64(0), uint64(0), int64(0))
        );
        PrecompileLib.AccountMarginSummary memory s = probe.marginSummary();
        assertEq(s.ntlPos, 0);
    }

    function test_withdrawableRawShape() public {
        vm.mockCall(
            0x0000000000000000000000000000000000000803, abi.encode(address(probe)), abi.encode(uint64(123_456_789))
        );
        assertEq(probe.withdrawableRaw(), 123_456_789);
    }

    function test_constructorRevertsForZeroOwner() public {
        vm.expectRevert(VaultProbe.ZeroOwner.selector);
        new VaultProbe(address(0));
    }

    // sweep() — единственный путь вывода ERC-20 остатка после bridgeToEvm (R5). Токен
    // не деплоим — vm.mockCall перехватывает calldata на произвольном адресе, живого
    // байткода не требуется (тот же приём, что у marginSummary-стенда).
    function test_sweepTransfersFullBalanceToOwnerChoice() public {
        address token = address(0xC0FFEE);
        address to = address(0xCAFE);
        vm.mockCall(token, abi.encodeWithSignature("balanceOf(address)", address(probe)), abi.encode(uint256(500)));
        vm.mockCall(token, abi.encodeWithSignature("transfer(address,uint256)", to, uint256(500)), abi.encode(true));
        probe.sweep(token, to);
    }

    function test_sweepRevertsForNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(VaultProbe.NotOwner.selector);
        probe.sweep(address(0xC0FFEE), address(0xCAFE));
    }

    // sweepNative() — вывод HYPE, дошедшего на EVM-баланс probe нативным переводом
    // (bridgeToEvm/receive). vm.deal кладёт баланс без моков — это встроенный ETH-счётчик EVM.
    function test_sweepNativeTransfersFullBalanceToOwnerChoice() public {
        address payable to = payable(address(0xCAFE));
        vm.deal(address(probe), 3 ether);
        probe.sweepNative(to);
        assertEq(to.balance, 3 ether);
        assertEq(address(probe).balance, 0);
    }

    function test_sweepNativeRevertsForNonOwner() public {
        vm.deal(address(probe), 1 ether);
        vm.prank(address(0xBEEF));
        vm.expectRevert(VaultProbe.NotOwner.selector);
        probe.sweepNative(payable(address(0xCAFE)));
    }
}

/// @notice VaultProbe v2 (R8/R10, e103/e104) на симуляторе HyperCore (офлайн, без сети). Имя содержит
/// `VaultProbeTest`, чтобы `--match-contract VaultProbeTest` гонял оба набора.
contract VaultProbeTestSim is Test {
    HyperCore internal core;
    VaultProbe internal probe;
    address internal H = makeAddr("human");
    address internal L = makeAddr("leg");
    uint64 internal constant USDC = 0;

    function setUp() public {
        core = CoreSimulatorLib.init();
        CoreSimulatorLib.setOfflineMode(true);
        probe = new VaultProbe(address(this));
        core.forceAccountActivation(address(probe));
        core.forceAccountActivation(H);
        CoreSimulatorLib.forceSpotBalance(address(probe), USDC, 10e8);
    }

    // R8: spotSend контракт -> человек доходит РОВНО на сумму и списывается с контракта ровно на неё же.
    function test_spotSendReachesHumanExactly() public {
        uint64 hBefore = probe.spotBalanceOf(H, USDC).total;
        probe.spotSend(H, USDC, 3e8);
        CoreSimulatorLib.nextBlock();
        assertEq(probe.spotBalanceOf(H, USDC).total - hBefore, 3e8);
        assertEq(probe.spotBalanceOf(address(probe), USDC).total, 7e8);
    }

    function test_spotSendRevertsForNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(VaultProbe.NotOwner.selector);
        probe.spotSend(H, USDC, 1e8);
    }

    // Перевод себе на Core — всегда отказ; библиотека отклоняет его ещё на EVM, до CoreWriter.
    function test_spotSendToSelfReverts() public {
        vm.expectRevert(CoreWriterLib.CoreWriterLib__CannotSelfTransfer.selector);
        probe.spotSend(address(probe), USDC, 1e8);
    }

    // Чтение ЧУЖОГО адреса: отдаётся баланс того, кого спросили, а не самого контракта.
    function test_spotBalanceOfReadsForeignAddress() public {
        CoreSimulatorLib.forceSpotBalance(L, USDC, 1234);
        assertEq(probe.spotBalanceOf(L, USDC).total, 1234);
        assertEq(probe.spotBalanceOf(address(probe), USDC).total, 10e8);
    }

    // R10: маржа чужого адреса (ноги) — то, что его perp-баланс задал, а у самого probe — ноль.
    function test_marginOfReadsForeignAddress() public {
        CoreSimulatorLib.forcePerpBalance(L, 500e6);
        assertEq(probe.marginOf(L).accountValue, int64(500e6));
        assertEq(probe.marginOf(address(probe)).accountValue, int64(0));
    }

    // R10: позиция чужого адреса по perp-индексу (симулятор позволяет задать плечо, не размер).
    function test_positionOfReadsForeignAddress() public {
        CoreSimulatorLib.forcePerpLeverage(L, 3, 7);
        assertEq(probe.positionOf(L, 3).leverage, 7);
        assertEq(probe.positionOf(address(probe), 3).leverage, 0);
    }

    // R10: аргументы уходят в прекомпайл position2 в порядке (user, perp), размер декодируется со знаком.
    function test_positionOfPassesUserAndPerpToPrecompile() public {
        vm.mockCall(
            0x0000000000000000000000000000000000000813,
            abi.encode(L, uint32(5)),
            abi.encode(int64(-42), uint64(1000), int64(0), uint32(3), false)
        );
        PrecompileLib.Position memory p = probe.positionOf(L, 5);
        assertEq(p.szi, int64(-42));
        assertEq(p.entryNtl, 1000);
        assertEq(p.leverage, 3);
    }
}
