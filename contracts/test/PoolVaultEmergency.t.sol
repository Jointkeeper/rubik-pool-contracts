// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HyperCore} from "hyper-evm-sim/HyperCore.sol";
import {CoreSimulatorLib} from "hyper-evm-sim/CoreSimulatorLib.sol";
import {CoreWriterSim} from "hyper-evm-sim/CoreWriterSim.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {PoolLedger, PoolLedgerBase, PoolLedgerViews} from "../src/PoolLedger.sol";
import {PoolVault} from "../src/PoolVault.sol";
import {PoolVaultEmergency, P_EMERGENCY, EmergencyClock} from "../src/PoolVaultEmergency.sol";
import {PoolDeployHarness} from "./PoolVault.t.sol";

/// @dev Стенды стыков ред. 9.4 с хранилищем для беты (rev9: доля ног, заявки «всё», газ заявок, предел адресов, лимит TVL).

/// @notice Ред. 9.4 — аварийный выход хранилища (модуль `PoolVaultEmergency`) на симуляторе HyperCore: триггеры (кто и когда
/// вправе заморозить), замок хранилища после заморозки (MX1), деньги раздачи (U_s, M_cum с исправлением В4, деньги в пути,
/// поздний приход с ног) и правило E на настоящих выплатах. Правило E своим счётом судит дифференциал (фикстуры 236-239,
/// 260, 261), снимок посреди расчёта — `PoolLedgerEmergencyTest`.
contract PoolVaultEmergencyTest is Test {
    HyperCore internal core;
    PoolVault internal V;
    PoolDeployHarness internal H;
    address internal constant T = address(0xfee);
    address internal constant CW = 0x3333333333333333333333333333333333333333;
    address internal K = makeAddr("keeper");
    address internal G = makeAddr("guardian");
    address internal A = makeAddr("investorA");
    address internal B = makeAddr("investorB");
    address internal C = makeAddr("investorC");
    address internal D = makeAddr("investorD");
    address internal X = makeAddr("stranger");
    uint64 internal constant USDC = 0;
    uint256 internal constant DELAY = 1 days; // нижняя граница таймлока (ревью-2, #5): каждый срок ниже >= 2·DELAY
    // сроки триггеров стенда — разные, чтобы каждый судился отдельно (боевые — параметры деплоя)
    uint256 internal constant STUCK = 3 days;
    uint256 internal constant DEAD = 5 days;
    uint256 internal constant NOMONDAY = 15 days;
    uint256 internal constant SERVE = 4 days;
    uint256 internal constant QUEUE_MAX = 7 days; // В7′ (ревью 20.10): больше T_dead — стенды держат keeper живым

    function _vault(uint256 delay_, PoolVaultEmergency em) internal returns (PoolVault v) {
        return _vaultShare(delay_, em, 5000, true); // прежние стенды аварии — раздача пополам (C7)
    }

    /// @dev Хранилище с долей ноги A `bps`; `activateB = false` — нога B не на Core (бета на одной ноге: ей ничего не шлют).
    function _vaultShare(uint256 delay_, PoolVaultEmergency em, uint256 bps, bool activateB) internal returns (PoolVault v) {
        address at = vm.computeCreateAddress(address(H), vm.getNonce(address(H)) + 8);
        PoolVault.VaultInit memory p;
        (p.ledger, p.legA, p.legB) = H.parts(at, at, at);
        (p.admin, p.keeper, p.guardian, p.delay, p.tvlCap, p.legShareBps, p.emergency) =
            (address(this), K, G, delay_, type(uint256).max, bps, em);
        v = H.vault(p);
        core.forceAccountActivation(address(v));
        core.forceAccountActivation(address(v.legA()));
        if (activateB) core.forceAccountActivation(address(v.legB()));
    }

    function _module() internal returns (PoolVaultEmergency) {
        return new PoolVaultEmergency(STUCK, DEAD, NOMONDAY, SERVE, QUEUE_MAX);
    }

    function setUp() public {
        core = CoreSimulatorLib.init();
        CoreSimulatorLib.setOfflineMode(true);
        H = new PoolDeployHarness();
        V = _vault(DELAY, _module());
        address[5] memory who = [A, B, C, D, T];
        for (uint256 i = 0; i < 5; i++) {
            core.forceAccountActivation(who[i]);
            CoreSimulatorLib.forceSpotBalance(who[i], USDC, 5000e8);
        }
    }

    // --- помощники -------------------------------------------------------------------------------------------------- //
    function E() internal view returns (PoolVaultEmergency) {
        return PoolVaultEmergency(address(V)); // модуль — через fallback хранилища, на его памяти
    }

    function _lv() internal view returns (PoolLedgerViews) {
        return PoolLedgerViews(address(V.ledger()));
    }

    function _send(address from, address to, uint64 usdcWei) internal {
        vm.prank(from);
        (bool ok,) = CW.call(
            abi.encodeWithSignature(
                "sendRawAction(bytes)",
                abi.encodePacked(uint8(1), HLConstants.SPOT_SEND_ACTION, abi.encode(to, USDC, usdcWei))
            )
        );
        require(ok, "send");
        CoreSimulatorLib.nextBlock();
    }

    function _spot(address a) internal view returns (uint64) {
        return PrecompileLib.spotBalance(a, USDC).total;
    }

    function _deposit(address who, uint64 usd, bytes32 ref) internal {
        _send(who, address(V), usd * 100);
        vm.prank(K);
        V.creditDeposit(who, uint256(usd), ref);
    }

    function _sweep() internal {
        vm.prank(K);
        V.sweepToLegs();
        CoreSimulatorLib.nextBlock();
        V.confirmSweep();
    }

    /// @dev Операция keeper'а, которая ничего не меняет: держит `T_dead` в покое.
    function _ping() internal {
        vm.prank(K);
        V.payQueue();
    }

    function _warp(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
    }

    /// @dev Заморозка по смерти keeper'а и проход итогов снимка одним вызовом (любой вызывающий).
    function _freezeDead() internal {
        _warp(DEAD);
        vm.prank(X);
        assertEq(E().emergencyFreeze(), 2, "trigger: dead keeper");
        vm.prank(X);
        assertEq(E().emergencySnapStep(type(uint256).max), 0, "snapshot ready");
    }

    function _paidTotal() internal view returns (uint256 p) {
        (,,,, p) = E().emergencyState();
    }

    // --- триггеры ------------------------------------------------------------------------------------------------- //
    /// @dev Нет триггера — нет заморозки; `T_dead` — от последней УСПЕШНОЙ операции keeper'а; пул без денег бездействием не
    /// замораживается.
    function test_rev94_dead_keeper_trigger() public {
        _warp(DEAD + 1);
        assertEq(E().emergencyTrigger(), 0, "a pool that never had money is not frozen by inactivity");
        vm.expectRevert(PoolVaultEmergency.NoTrigger.selector);
        E().emergencyFreeze();
        _deposit(A, 1000e6, "a1");
        _warp(DEAD - 1);
        assertEq(E().emergencyTrigger(), 0);
        _ping();
        _warp(DEAD - 1);
        assertEq(E().emergencyTrigger(), 0, "any keeper operation restarts T_dead");
        _warp(1);
        assertEq(E().emergencyTrigger(), 2);
        vm.prank(X);
        assertEq(E().emergencyFreeze(), 2);
        vm.expectRevert(PoolVaultEmergency.Frozen.selector);
        E().emergencyFreeze();
    }

    /// @dev `T_stuck`: открытый расчёт пачками старше срока — и только он (закрытый расчёт триггер снимает).
    function test_rev94_stuck_monday_trigger() public {
        _deposit(A, 1000e6, "a1");
        vm.prank(K);
        V.mondayBegin();
        _warp(STUCK - 1);
        assertEq(E().emergencyTrigger(), 0);
        _warp(1);
        assertEq(E().emergencyTrigger(), 1, "monday open for T_stuck");
        uint256 snap = vm.snapshotState();
        vm.startPrank(K);
        while (V.mondayStep(1000) != 0) {}
        V.mondayEnd();
        vm.stopPrank();
        assertEq(E().emergencyTrigger(), 0, "closed monday is not stuck");
        // заморозка посреди расчёта: снимок — копия MS_SNAP, готов сразу (проход итогов не нужен), раздача открыта
        vm.revertToState(snap);
        vm.prank(X);
        assertEq(E().emergencyFreeze(), 1);
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "emergency: no pass"));
        E().emergencySnapStep(1);
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 1000e6, "A takes its pre-monday capital");
    }

    /// @dev Ревью 20.10, R6: расчёт (атомарный и пачками) и его открытие ДО первого зачисленного депозита часов аварии не
    /// запускают — пул без денег не замораживается ни по `T_dead`, ни по `T_nomonday`, ни по `T_stuck`; часы идут с депозита.
    function test_review_monday_before_first_deposit_starts_no_clock() public {
        vm.prank(K);
        V.monday();
        _warp(NOMONDAY);
        assertEq(E().emergencyTrigger(), 0, "a settled week of an empty pool starts no clock");
        vm.prank(X);
        vm.expectRevert(PoolVaultEmergency.NoTrigger.selector);
        E().emergencyFreeze();
        vm.prank(K);
        V.mondayBegin();
        _warp(STUCK);
        assertEq(E().emergencyTrigger(), 0, "an open settlement of an empty pool is not stuck");
        vm.startPrank(K);
        while (V.mondayStep(1000) != 0) {}
        V.mondayEnd();
        vm.stopPrank();
        _warp(NOMONDAY);
        assertEq(E().emergencyTrigger(), 0, "nor after a paged settlement");
        _deposit(A, 100e6, "a1");
        uint256 t0 = block.timestamp;
        vm.warp(t0 + DEAD - 1);
        assertEq(E().emergencyTrigger(), 0);
        vm.warp(t0 + DEAD);
        assertEq(E().emergencyTrigger(), 2, "the clocks start with the first credited deposit");
    }

    /// @dev `T_nomonday`: отсчёт от первого депозита, затем от последнего закрытого расчёта; keeper жив (T_dead молчит).
    function test_rev94_no_monday_trigger() public {
        _deposit(A, 1000e6, "a1");
        for (uint256 i = 0; i < 3; i++) {
            _warp(4 days);
            _ping();
        }
        _warp(NOMONDAY - 12 days - 1);
        _ping();
        assertEq(E().emergencyTrigger(), 0);
        _warp(1);
        assertEq(E().emergencyTrigger(), 3, "no settled week for T_nomonday since the first deposit");
        vm.prank(K);
        V.monday();
        assertEq(E().emergencyTrigger(), 0, "a settled week restarts the clock");
    }

    /// @dev `T_serve` по заявке хранилища: keeper жив, но заявку не исполняет.
    function test_rev94_unserved_intent_trigger() public {
        _deposit(A, 1000e6, "a1");
        vm.prank(A);
        V.requestWithdraw(100e6, false, false);
        _warp(3 days);
        _ping();
        _warp(SERVE - 3 days - 1);
        assertEq(E().emergencyTrigger(), 0);
        _warp(1);
        assertEq(E().emergencyTrigger(), 4, "the oldest unprocessed intent is older than T_serve");
        vm.prank(K);
        V.processWithdrawals(1);
        assertEq(E().emergencyTrigger(), 0, "processed intent stops the trigger");
    }

    /// @dev Заявка A 500 в очереди бухгалтерии (keeper держит `withdrawable` 0 при 900 на ногах); ответ — время, с которого
    /// считается её возраст (операция keeper'а, проведшая её в очередь).
    function _queuedRequest() internal returns (uint256 t0) {
        _deposit(A, 1000e6, "a1");
        _sweep(); // 900 на ногах (по 450), withdrawable бухгалтерии 900
        vm.prank(K);
        V.setWithdrawable(0);
        vm.prank(A);
        V.requestWithdraw(500e6, false, false);
        vm.prank(K);
        V.processWithdrawals(1);
        assertGe(_lv().oldestQueued(), 0, "the request waits in the ledger queue");
        t0 = block.timestamp;
    }

    /// @dev В7′ (ревью 20.10): старейшая заявка инвестора в очереди бухгалтерии старше `T_queue_max` — триггер, и ТОЛЬКО
    /// возраст: на секунду раньше — нет; выставить физически доступное мало, снимает триггер лишь оплата очереди.
    function test_rev94_ledger_queue_age_trigger() public {
        uint256 t0 = _queuedRequest();
        _warp(QUEUE_MAX / 2);
        _ping(); // keeper жив: T_dead молчит
        vm.warp(t0 + QUEUE_MAX - 1);
        _ping();
        assertEq(E().emergencyTrigger(), 0, "a request younger than T_queue_max is not a trigger");
        _warp(1);
        assertEq(E().emergencyTrigger(), 5, "queue entry older than T_queue_max");
        uint256 snap = vm.snapshotState();
        vm.prank(K);
        V.setWithdrawable(900e6);
        assertEq(E().emergencyTrigger(), 5, "liquidity set but the queue not paid: still a trigger");
        vm.prank(K);
        V.legSendToVault(0, 400e6); // деньги очереди — с ноги на хранилище, затем оплата
        CoreSimulatorLib.nextBlock();
        V.confirmLegSend(0);
        vm.prank(K);
        V.payQueue();
        assertEq(_lv().oldestQueued(), -1, "the queue is paid");
        assertEq(E().emergencyTrigger(), 0, "a served queue stops the trigger");
        vm.revertToState(snap);
        vm.prank(X);
        assertEq(E().emergencyFreeze(), 5);
    }

    /// @dev Ревью 20.10, R1/R1b/F1: посторонний шлёт 1 микро на ногу при честном keeper'е (`withdrawable` = физическому; G2
    /// выше не даёт). Прежняя форма В7′ (`withdrawable` < физического) взводилась и замораживала пул навсегда; теперь донат
    /// не взводит НИЧЕГО — ни до срока, ни на нём (заявку держит удержание открытой позиции, а не keeper).
    function test_review_donation_on_leg_arms_nothing() public {
        _deposit(A, 1000e6, "a1");
        _sweep(); // 900 на ногах, withdrawable 900
        vm.startPrank(K);
        V.sizeOrder("W", 3000e6); // удержание 35 % нотионала > капитала: заявка ждёт закрытия позиции
        V.fillOrder("W");
        vm.stopPrank();
        vm.prank(A);
        V.requestWithdraw(500e6, false, false);
        vm.prank(K);
        V.processWithdrawals(1);
        uint256 t0 = block.timestamp;
        assertEq(uint256(_lv().status()[10]), V.physicalWithdrawable(), "honest keeper: withdrawable == physical");
        vm.warp(t0 + SERVE);
        _ping();
        core.forceAccountActivation(X);
        CoreSimulatorLib.forceSpotBalance(X, USDC, 1e8);
        _send(X, address(V.legA()), 100); // 1 микро-USDC
        assertEq(V.physicalWithdrawable(), 900e6 + 1, "the donation is physical");
        assertEq(E().emergencyTrigger(), 0, "the donation arms nothing");
        vm.prank(X);
        vm.expectRevert(PoolVaultEmergency.NoTrigger.selector);
        E().emergencyFreeze();
        vm.warp(t0 + QUEUE_MAX - 1);
        _ping();
        assertEq(E().emergencyTrigger(), 0, "nor right before T_queue_max");
    }

    /// @dev Ревью 20.10, R3: злой keeper с agent-ключом держит физически выводимое нулём (вся касса ног в `hold` — спот-заявки;
    /// семантика hold HL — мок прекомпайла) и делает расчёты каждые 4 суток. Прежняя форма молчала вечно (~80 суток в
    /// репро); теперь триггер срабатывает ровно в `T_queue_max` от проведения заявки в очередь.
    function test_review_hold_zeroed_physical_still_fires_by_age() public {
        uint256 t0 = _queuedRequest();
        address la = address(V.legA());
        address lb = address(V.legB());
        uint64 ta = _spot(la);
        uint64 tb = _spot(lb);
        vm.mockCall(address(0x801), abi.encode(la, uint64(0)), abi.encode(PrecompileLib.SpotBalance(ta, ta, 0)));
        vm.mockCall(address(0x801), abi.encode(lb, uint64(0)), abi.encode(PrecompileLib.SpotBalance(tb, tb, 0)));
        assertEq(V.physicalWithdrawable(), 0, "physical zero");
        bool fired;
        for (uint256 w = 0; w < 20 && !fired; w++) {
            _warp(4 days - 1); // < T_dead; расчёт каждые 4 суток < T_nomonday
            uint8 why = E().emergencyTrigger();
            assertEq(why, block.timestamp >= t0 + QUEUE_MAX ? 5 : 0, "exactly by age");
            fired = why == 5;
            if (!fired) {
                vm.prank(K);
                V.monday();
            }
        }
        assertTrue(fired, "fired by T_queue_max");
        vm.prank(X);
        assertEq(E().emergencyFreeze(), 5);
    }

    /// @dev Объявление admin'а — общий таймлок: до `eta` нет, guardian отменяет в окне, после `eta` — заморозка любым.
    function test_rev94_announcement_through_timelock_guardian_cancels() public {
        vm.prank(X);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeEmergency();
        V.proposeEmergency();
        _warp(DELAY - 1);
        assertEq(E().emergencyTrigger(), 0, "not before eta");
        vm.prank(G);
        V.cancel(P_EMERGENCY);
        _warp(1);
        assertEq(E().emergencyTrigger(), 0, "cancelled by the guardian");
        V.proposeEmergency();
        _warp(DELAY);
        assertEq(E().emergencyTrigger(), 6);
        vm.prank(X);
        E().emergencyFreeze();
    }

    /// @dev Ревью 20.10, R5: созревшее объявление (`eta` прошёл) может только исполниться — guardian и admin его не снимают,
    /// admin не перевзводит (перезапись сдвинула бы срок на `DELAY`); заморозку по нему исполняет любой. До `eta` перезапись
    /// законна (сдвигает срок), отмена — тоже.
    function test_review_matured_announcement_only_freezes() public {
        V.proposeEmergency();
        _warp(DELAY - 1);
        V.proposeEmergency(); // до eta: перезапись сдвигает срок
        (, uint256 eta) = V.proposals(P_EMERGENCY);
        assertEq(eta, block.timestamp + DELAY);
        vm.warp(eta);
        assertEq(E().emergencyTrigger(), 6, "matured");
        bytes memory matured = abi.encodeWithSelector(PoolVault.Matured.selector, eta);
        vm.prank(G);
        vm.expectRevert(matured);
        V.cancel(P_EMERGENCY);
        vm.expectRevert(matured);
        V.cancel(P_EMERGENCY); // admin тоже
        vm.expectRevert(matured);
        V.proposeEmergency();
        _warp(1 days);
        vm.prank(G);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.Matured.selector, eta));
        V.cancel(P_EMERGENCY);
        assertEq(E().emergencyTrigger(), 6, "still matured");
        vm.prank(X);
        assertEq(E().emergencyFreeze(), 6);
    }

    /// @dev Таймлок: ОДНО пространство видов на всё хранилище (README «Таймлок: виды предложений»). Все восемь предложений
    /// висят разом и не затирают друг друга; номера 5 и 6 — те, что читает сторож (`vault_watch.PROPOSAL_KIND`), авария — 7;
    /// отмена guardian'ом одного вида не снимает другой, исполнение одного не исполняет другой.
    function test_timelock_kinds_unique() public {
        assertEq(P_EMERGENCY, 7, "emergency announcement is kind 7");
        address nk = makeAddr("newKeeper");
        address ng = makeAddr("newGuardian");
        address na = makeAddr("newAdmin");
        V.proposeAdmin(na);
        V.proposeKeeper(nk);
        V.proposeGuardian(ng);
        V.proposeAgent(0, makeAddr("agentA"), "bot");
        V.proposeAgent(1, makeAddr("agentB"), "bot");
        V.proposeLegShare(10_000);
        V.proposeMaxInvestors(50);
        V.proposeEmergency();
        bytes32[8] memory want = [
            keccak256(abi.encode(na)),
            keccak256(abi.encode(nk)),
            keccak256(abi.encode(ng)),
            keccak256(abi.encode(makeAddr("agentA"), "bot")),
            keccak256(abi.encode(makeAddr("agentB"), "bot")),
            keccak256(abi.encode(uint256(10_000))),
            keccak256(abi.encode(uint256(50))),
            keccak256("rubik.pool.vault.emergency.announce")
        ];
        for (uint256 k = 0; k < 8; k++) {
            (bytes32 h,) = V.proposals(k);
            assertEq(h, want[k], string.concat("kind ", vm.toString(k), " holds its own action"));
            for (uint256 j = 0; j < k; j++) {
                assertTrue(want[j] != want[k], "distinct actions");
            }
        }
        vm.prank(G);
        V.cancel(7); // guardian снимает объявление аварии — доля и предел висят
        (bytes32 h5,) = V.proposals(5);
        (bytes32 h6,) = V.proposals(6);
        (bytes32 h7,) = V.proposals(7);
        assertEq(h5, want[5]);
        assertEq(h6, want[6]);
        assertEq(h7, bytes32(0));
        _warp(DELAY);
        V.applyLegShare(10_000);
        assertEq(V.legShareBps(), 10_000);
        (h6,) = V.proposals(6);
        assertEq(h6, want[6], "applying the share does not consume the investor-limit proposal");
        assertEq(E().emergencyTrigger(), 0, "cancelled announcement: no freeze by kind 7");
        V.proposeEmergency();
        vm.prank(G);
        V.cancel(5 + 1); // отмена предела не трогает объявление
        (h7,) = V.proposals(7);
        assertEq(h7, want[7]);
        _warp(DELAY);
        assertEq(E().emergencyTrigger(), 6, "the announcement matured under kind 7");
    }

    // --- после заморозки ---------------------------------------------------------------------------------------- //
    /// @dev Хранилище после заморозки: keeper, admin (В8) и вход денег закрыты замком; MX1 — возврат незачтённого Send
    /// отклонён, ref НЕ сгорает (бухгалтерия бит в бит), его деньги — в U_s; выплата — только правилом E.
    /// Стыки rev9: заявка (точная и «всё»), доля ног и предел адресов (предложения созрели ДО заморозки — исполнение всё
    /// равно отказ, предложения и доля не тронуты), раздача с долей. MX3: депозит сверх лимита TVL до заморозки отклоняет
    /// лимит, после — заморозка (вход закрыт ею, а не лимитом).
    function test_rev94_frozen_vault_rejects_everything_mx1() public {
        _deposit(A, 1000e6, "a1");
        _send(B, address(V), 5e8); // Send, который keeper не зачёл: он чужой держателям
        V.setTvlCap(1000e6);
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TvlCapExceeded.selector, 1005e6, 1000e6));
        V.creditDeposit(B, 5e6, "b-send");
        V.proposeLegShare(10_000);
        V.proposeMaxInvestors(50);
        _freezeDead(); // DEAD > DELAY: оба предложения созрели
        bytes32 h = keccak256(abi.encode(_lv().dump()));
        (, , , uint256 foreign,) = E().emergencyState();
        assertEq(foreign, 5e8, "U_s = the uncredited Send exactly");
        bytes4 fz = PoolVault.Frozen.selector;
        vm.startPrank(K);
        vm.expectRevert(fz);
        V.refundDeposit(B, 5e8, "b-send", 1);
        vm.expectRevert(fz);
        V.creditDeposit(B, 5e6, "b-send");
        vm.expectRevert(fz);
        V.coverShortfall(1, "b-send");
        vm.expectRevert(fz);
        V.sweepToLegs();
        vm.expectRevert(fz);
        V.legSendToVault(0, 1);
        vm.expectRevert(fz);
        V.processWithdrawals(1);
        vm.expectRevert(fz);
        V.vaultToSpot(1);
        vm.stopPrank();
        vm.prank(A);
        vm.expectRevert(fz);
        V.requestWithdraw(1, false, false);
        vm.prank(A);
        vm.expectRevert(fz);
        V.requestWithdraw(0, false, true);
        vm.prank(C);
        vm.expectRevert(fz);
        V.register(address(0), false);
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "frozen"));
        V.claim();
        vm.expectRevert(fz);
        V.proposeKeeper(X);
        vm.expectRevert(fz);
        V.setTvlCap(1);
        vm.expectRevert(fz);
        V.setPartner(X, 1);
        vm.expectRevert(fz);
        V.proposeEmergency();
        vm.expectRevert(fz);
        V.proposeLegShare(0);
        vm.expectRevert(fz);
        V.applyLegShare(10_000);
        vm.expectRevert(fz);
        V.proposeMaxInvestors(50);
        vm.expectRevert(fz);
        V.applyMaxInvestors(50);
        assertEq(V.legShareBps(), 5000, "share untouched");
        (bytes32 h5,) = V.proposals(5);
        (bytes32 h6,) = V.proposals(6);
        assertEq(h5, keccak256(abi.encode(uint256(10_000))), "matured share proposal not consumed");
        assertEq(h6, keccak256(abi.encode(uint256(50))), "matured limit proposal not consumed");
        assertEq(V.tvlCap(), 1000e6);
        vm.prank(X);
        vm.expectRevert(fz);
        V.acceptAdmin();
        assertEq(keccak256(abi.encode(_lv().dump())), h, "ledger bit for bit: the refund ref is not burned");
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 1000e6, "A takes its capital, MX3: no minimum");
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(address(V)), 5e8, "the foreign Send stays on the vault (returned only through U_s)");
    }

    /// @dev В4 (стенд E-8 плана, AV5): ПЯТЬ забираний в ОДНОМ блоке при убытке (на хранилище 800 из 1000) — каждому ровно
    /// due(800), сумма не больше денег; тот же итог при другом порядке и раздаче по блокам; повторное забирание — 0.
    function test_rev94_five_claims_in_one_block_and_order_independence() public {
        _deposit(A, 100e6, "a1");
        _deposit(B, 200e6, "b1");
        _deposit(C, 300e6, "c1");
        _deposit(D, 400e6, "d1");
        _freezeDead();
        CoreSimulatorLib.forceSpotBalance(address(V), USDC, 800e8); // убыток недели: денег на хранилище 800
        uint256 snap = vm.snapshotState();
        address[5] memory who = [A, B, C, D, T];
        uint256[5] memory want = [uint256(80e6), 160e6, 240e6, 320e6, 0];
        uint64[5] memory was;
        for (uint256 i = 0; i < 5; i++) {
            was[i] = _spot(who[i]);
            vm.prank(X);
            assertEq(E().emergencyClaim(who[i]), want[i], "due(800) in one block");
        }
        assertEq(_paidTotal(), 800e6, "paid exactly the money");
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(address(V)), 0, "every send executed: nothing paid twice");
        for (uint256 i = 0; i < 5; i++) {
            assertEq(_spot(who[i]) - was[i], want[i] * 100, "money reached the holder's own Core address");
        }
        for (uint256 i = 0; i < 5; i++) {
            assertEq(E().emergencyClaim(who[i]), 0, "nothing more");
        }
        vm.revertToState(snap);
        for (uint256 i = 5; i > 0; i--) {
            vm.prank(X);
            assertEq(E().emergencyClaim(who[i - 1]), want[i - 1], "reverse order, one per block");
            CoreSimulatorLib.nextBlock();
        }
        assertEq(_paidTotal(), 800e6);
        assertEq(_spot(address(V)), 0);
    }

    /// @dev Деньги в пути (M5): перевод с ноги прежнего блока, не подтверждённый до заморозки, — деньги держателей (заморозка
    /// его подтверждает, U_s его не берёт); перевод того же блока ещё в пути — придёт и поднимет M_cum.
    function test_rev94_money_in_flight_belongs_to_holders() public {
        _deposit(A, 1000e6, "a1");
        _sweep();
        vm.prank(K);
        V.legSendToVault(0, 300e6); // касса ноги после раздачи — spot (450)
        CoreSimulatorLib.nextBlock(); // пришло, но не подтверждено
        V.proposeEmergency();
        _warp(DELAY);
        vm.prank(K);
        V.legSendToVault(1, 200e6); // в блоке заморозки: ещё в пути
        vm.prank(X);
        assertEq(E().emergencyFreeze(), 6);
        E().emergencySnapStep(type(uint256).max);
        (, , , uint256 foreign,) = E().emergencyState();
        assertEq(foreign, 0, "arrived leg money is not foreign");
        (uint256 m, uint256 due,) = E().emergencyStatus(A);
        assertEq(m, 400e6, "vault 100 + arrived 300; the in-flight 200 is not there yet");
        assertEq(due, 400e6);
        CoreSimulatorLib.nextBlock();
        (m, due,) = E().emergencyStatus(A);
        assertEq(m, 600e6, "the in-flight send arrived and raises M_cum");
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 600e6);
    }

    /// @dev Поздний остаток с ног: `emergencyCollect` (любой) сводит кассу ног на хранилище; каждый дотягивает разницу.
    function test_rev94_collect_legs_and_top_up() public {
        _deposit(A, 1000e6, "a1");
        _deposit(B, 1000e6, "b1");
        _sweep(); // на хранилище 200, на ногах 1 800
        _freezeDead();
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 100e6, "only the vault cash so far: 200 of E 2000");
        vm.expectRevert(abi.encodeWithSelector(PoolVaultEmergency.BadLeg.selector, 2));
        E().emergencyCollect(2);
        vm.startPrank(X);
        E().emergencyCollect(0);
        E().emergencyCollect(1);
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(address(V.legA())) + _spot(address(V.legB())), 0, "legs emptied");
        vm.startPrank(X);
        assertEq(E().emergencyClaim(A), 900e6, "A tops up to its 1000");
        assertEq(E().emergencyClaim(B), 1000e6);
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(address(V)), 0);
    }

    /// @dev Забирание: только Core-пользователю (иначе комиссия активации — на хранилище); до заморозки модуль закрыт.
    function test_rev94_claim_rules() public {
        _deposit(A, 1000e6, "a1");
        vm.expectRevert(PoolVaultEmergency.NotFrozen.selector);
        E().emergencyClaim(A);
        vm.expectRevert(PoolVaultEmergency.NotFrozen.selector);
        E().emergencySnapStep(1);
        vm.expectRevert(PoolVaultEmergency.NotFrozen.selector);
        E().emergencyCollect(0);
        _warp(DEAD);
        E().emergencyFreeze();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "emergency: no snapshot"));
        E().emergencyClaim(A);
        E().emergencySnapStep(1);
        address fresh = makeAddr("not-on-core");
        vm.expectRevert(abi.encodeWithSelector(PoolVaultEmergency.NotActivated.selector, fresh));
        E().emergencyClaim(fresh);
        assertEq(E().emergencyClaim(T), 0, "treasury with no pot: nothing");
    }

    /// @dev Ревью 20.10, F3: нога A рефералом копила вознаграждение, `emergencyClaim(legA)` слал деньги на ногу, а
    /// `emergencyCollect` возвращал их хранилищу — M_cum считал их дважды, и сумма выплат превышала деньги. Теперь набор
    /// `poolSink` (хранилище, ноги, бухгалтерия, системные адреса токенов Core) не бывает ни рефералом, ни получателем
    /// возврата, ни получателем аварийной выплаты; treasury рефералом законна (её доля — в котёл, эталон).
    function test_review_pool_sinks_never_referrer_nor_recipient() public {
        address[8] memory sinks = [
            address(V),
            address(V.legA()),
            address(V.legB()),
            address(V.ledger()),
            address(0x2000000000000000000000000000000000000000), // USDC (индекс 0)
            address(0x2000000000000000000000000000000000000123),
            address(0x200000000000000000000000ffFFFFFffFffFfff), // последний индекс uint64
            address(0x2222222222222222222222222222222222222222) // HYPE
        ];
        for (uint256 i = 0; i < sinks.length; i++) {
            vm.prank(C);
            vm.expectRevert(abi.encodeWithSelector(PoolVault.BadRecipient.selector, sinks[i]));
            V.register(sinks[i], false);
        }
        vm.prank(C);
        V.register(T, false); // treasury — законный реферал
        vm.prank(D);
        V.register(address(0x2000000000000000000000010000000000000000), false); // вне диапазона системных — обычный адрес
        _deposit(A, 1000e6, "a1");
        _send(B, address(V), 50e8);
        for (uint256 i = 3; i < sinks.length; i++) {
            vm.prank(K);
            vm.expectRevert(abi.encodeWithSelector(PoolVault.BadRecipient.selector, sinks[i]));
            V.refundDeposit(sinks[i], 50e8, "rb", 1);
        }
        _freezeDead();
        for (uint256 i = 0; i < sinks.length; i++) {
            vm.prank(X);
            vm.expectRevert(abi.encodeWithSelector(PoolVaultEmergency.BadRecipient.selector, sinks[i]));
            E().emergencyClaim(sinks[i]);
        }
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 1000e6);
    }

    /// @dev Модуль без хранилища: прямой вызов отклоняется (своих бухгалтерии и ног у него нет). Конструктор хранилища:
    /// модуль без кода и модуль со сроком короче двух таймлоков (ревью-2, #5) — отказ.
    function test_rev94_module_linking() public {
        PoolVaultEmergency em = _module();
        vm.expectRevert();
        em.emergencyFreeze();
        vm.expectRevert();
        em.emergencyClaim(A);
        PoolVaultEmergency short_ = new PoolVaultEmergency(STUCK, 2 * DELAY - 1, NOMONDAY, SERVE, QUEUE_MAX);
        address at = vm.computeCreateAddress(address(H), vm.getNonce(address(H)) + 8);
        PoolVault.VaultInit memory p;
        (p.ledger, p.legA, p.legB) = H.parts(at, at, at);
        (p.admin, p.keeper, p.guardian, p.delay, p.tvlCap, p.legShareBps, p.emergency) =
            (address(this), K, G, DELAY, 1, 5000, short_);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(short_)));
        H.vault(p);
        // В7′: `T_queue_max` короче 2·DELAY — тоже отказ (замена keeper'а обязана успеть до срока очереди с запасом)
        short_ = new PoolVaultEmergency(STUCK, DEAD, NOMONDAY, SERVE, 2 * DELAY - 1);
        p.emergency = short_;
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(short_)));
        H.vault(p);
        vm.expectRevert(PoolVaultEmergency.ZeroTerm.selector);
        new PoolVaultEmergency(STUCK, DEAD, 0, SERVE, QUEUE_MAX);
        vm.expectRevert(PoolVaultEmergency.ZeroTerm.selector);
        new PoolVaultEmergency(STUCK, DEAD, NOMONDAY, SERVE, 0);
    }

    // --- стыки с хранилищем для беты (rev9) ------------------------------------------------------------------------ //
    /// @dev Бета на одной ноге (доля 10000/0): нога B не получала денег и не на Core. `emergencyCollect(1)` — пустой проход
    /// (выводимого и кассы нет, отправок нет), без отказа; сбор с ноги A приносит всё, держатель забирает капитал.
    function test_mx_collect_one_leg_share_leg_b_not_activated() public {
        V = _vaultShare(DELAY, _module(), 10_000, false);
        _deposit(A, 1000e6, "a1");
        _sweep(); // 900 — ноге A, ноге B — ничего
        assertFalse(PrecompileLib.coreUserExists(address(V.legB())), "leg B never activated");
        assertEq(_spot(address(V.legA())), 900e8);
        _freezeDead();
        vm.startPrank(X);
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVaultEmergency.EmergencyCollected(1, 0, 0);
        E().emergencyCollect(1);
        E().emergencyCollect(0);
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(address(V.legA())), 0, "leg A emptied");
        assertFalse(PrecompileLib.coreUserExists(address(V.legB())), "nothing sent to leg B");
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 1000e6);
    }

    /// @dev Ревью 20.10, R7: бета на одной ноге (10000/0), нога B не на Core, и её прекомпайлы ОТКАТЫВАЮТСЯ (семантика HL на
    /// неактивированном адресе не описана — мок). Ни триггеры (очередь, объявление), ни заморозка, ни G2 (`setWithdrawable`,
    /// `mondayBegin`), ни сбор с ноги B их не читают: триггер очереди не читает прекомпайлов вовсе, G2 и сбор пропускают ногу
    /// без активации.
    function test_review_unactivated_leg_b_precompiles_never_read() public {
        V = _vaultShare(DELAY, _module(), 10_000, false);
        address lb = address(V.legB());
        vm.mockCallRevert(address(0x803), abi.encode(lb), "no user");
        vm.mockCallRevert(address(0x801), abi.encode(lb, uint64(0)), "no user");
        uint256 t0 = _queuedRequest(); // G2 (`setWithdrawable`) — с откатывающимися прекомпайлами ноги B
        assertEq(V.physicalWithdrawable(), 900e6, "leg B skipped");
        vm.prank(K);
        V.mondayBegin();
        vm.startPrank(K);
        while (V.mondayStep(1000) != 0) {}
        V.mondayEnd();
        vm.stopPrank();
        V.proposeEmergency();
        vm.warp(t0 + DELAY);
        _ping();
        assertEq(E().emergencyTrigger(), 6, "the matured announcement is readable");
        vm.warp(t0 + QUEUE_MAX);
        _ping();
        assertEq(E().emergencyTrigger(), 5, "the queue trigger reads no precompile");
        vm.prank(X);
        assertEq(E().emergencyFreeze(), 5);
        E().emergencySnapStep(type(uint256).max);
        vm.startPrank(X);
        E().emergencyCollect(1); // пустой проход без прекомпайлов ноги B
        E().emergencyCollect(0);
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 1000e6);
    }

    /// @dev Заявка «всё», которую keeper не проводит, и газ заявок: голодный вызов откатывает транзакцию целиком (бухгалтерия
    /// зовётся без `try`),
    /// `nextIntent` на месте — значит, и `T_serve` считает от подачи (keeper не сбросит его нехваткой газа). Заморозка по
    /// `T_serve`: заявка хранилища — капитал (её деньги — в `s` снимка), держатель забирает всё; `openIntent` остаётся, но
    /// новая заявка — отказ заморозки.
    function test_mx_starved_withdraw_all_intent_keeps_t_serve_and_is_capital() public {
        _deposit(A, 1000e6, "a1");
        _deposit(B, 500e6, "b1");
        vm.prank(A);
        V.requestWithdraw(0, false, true);
        bool caught;
        for (uint256 gas = 40_000; gas <= 400_000 && !caught; gas += 10_000) {
            vm.prank(K);
            try V.processWithdrawals{gas: gas}(1) {
                revert("processed: the gas grid must starve first");
            } catch {
                caught = true;
            }
        }
        assertTrue(caught, "a starved call reverted whole");
        assertEq(V.nextIntent(), 0, "intent not eaten");
        _warp(SERVE - 1);
        _ping(); // keeper жив: T_dead молчит
        assertEq(E().emergencyTrigger(), 0);
        _warp(1);
        assertEq(E().emergencyTrigger(), 4, "unserved ALL intent older than T_serve");
        vm.prank(X);
        E().emergencyFreeze();
        E().emergencySnapStep(type(uint256).max);
        assertTrue(V.openIntent(A), "the open flag stays, harmless");
        vm.startPrank(X);
        assertEq(E().emergencyClaim(A), 1000e6, "the ALL intent is capital");
        assertEq(E().emergencyClaim(B), 500e6);
        vm.stopPrank();
        vm.prank(A);
        vm.expectRevert(PoolVault.Frozen.selector);
        V.requestWithdraw(0, false, true);
    }

    /// @dev Журнал В7′ (`qStamps`) после пакета A (вывод без `try`): заявки бухгалтерии (`nextQid`) рождаются ТОЛЬКО в операциях
    /// keeper'а — их хвост `_keeperDone` и пишет журнал. Входы не-keeper'а, доходящие до бухгалтерии (`setPayoutMode`,
    /// заявка хранилища точная и «всё»), очереди не рождают; бизнес-отказ бухгалтерии КОДОМ (сумма больше свободной доли) —
    /// тоже: `_enqueue` стоит после проверок `withdraw`, журнал не пишется. Исполненная заявка рождает ровно одну запись с
    /// первым id и временем операции.
    function test_qstamps_queue_born_only_in_keeper_ops() public {
        _deposit(A, 1000e6, "a1");
        _deposit(B, 1000e6, "b1");
        _sweep();
        vm.prank(K);
        V.setWithdrawable(0); // выводимое встаёт в очередь бухгалтерии целиком
        (,,, uint256 n0) = V.emergencyClock();
        int256 q0 = _lv().status()[6];
        vm.prank(A);
        V.setPayoutMode(true);
        vm.prank(A);
        V.requestWithdraw(400e6, false, false);
        vm.prank(B);
        V.requestWithdraw(0, false, true);
        assertEq(_lv().status()[6], q0, "investor entries create no ledger queue entry");
        vm.startPrank(K);
        V.sizeOrder("p", 1800e6);
        V.fillOrder("p");
        V.closePosition("p", -1500e6); // свободная доля каждого — 250: точная заявка A (400) отклоняется кодом
        vm.stopPrank();
        (,,, uint256 n1) = V.emergencyClock();
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.WithdrawRejected(0, abi.encodeWithSignature("Revert(string)", "withdraw: amount"));
        vm.prank(K);
        V.processWithdrawals(1);
        assertEq(_lv().status()[6], q0, "a business rejection by code enqueues nothing");
        (,,, uint256 n2) = V.emergencyClock();
        assertEq(n2, n1, "and writes no journal entry");
        assertEq(n1, n0, "trading ops created no queue entry either");
        _warp(1);
        vm.prank(K);
        V.processWithdrawals(1); // «всё» B: 250 в очередь
        assertEq(_lv().status()[6], q0 + 1, "one queue entry");
        (,,, uint256 n3) = V.emergencyClock();
        assertEq(n3, n2 + 1, "exactly one journal entry");
        assertEq(V.qStamps(n3 - 1), (uint256(q0) << 64) | block.timestamp, "first id and time of the keeper operation");
        assertEq(_lv().oldestQueued(), q0);
    }

    // --- газ ------------------------------------------------------------------------------------------------------ //
    /// @dev Граница адресов 43 (у каждого свой реферал) и G = 60 живых поколений: заморозка, проход итогов, забирание —
    /// каждое <= 25 млн газа. Меряется вызов из стенда (без базы транзакции и calldata).
    function test_rev94_emergency_gas_at_bound() public {
        uint256 n = 43; // `MAX_INVESTORS_BOUND`
        for (uint256 i = 0; i < n; i++) {
            address a = address(uint160(0x1000 + i));
            core.forceAccountActivation(a);
            CoreSimulatorLib.forceSpotBalance(a, USDC, 2000e8);
            vm.prank(a);
            V.register(address(uint160(0x9000 + i)), false);
            _deposit(a, 1000e6, bytes32(i + 1));
        }
        _sweep();
        vm.startPrank(K); // неделя с прибылью: комиссия в котёл, вознаграждение каждому рефералу — держателей 101
        V.sizeOrder("w", n * 500e6);
        V.fillOrder("w");
        V.closePosition("w", int256(n * 100e6));
        V.monday();
        vm.stopPrank();
        vm.startPrank(K);
        for (uint256 j = 0; j < 60; j++) {
            bytes32 pid = bytes32(abi.encodePacked("g", vm.toString(j)));
            V.sizeOrder(pid, n * 700e6 / 60);
            V.fillOrder(pid);
            V.markPosition(pid, -int256((j + 1) * 1e6));
        }
        vm.stopPrank();
        assertEq(_lv().status()[2], 61, "60 live generations after the closed week-1 generation");
        _warp(DEAD);
        uint256 g = gasleft();
        E().emergencyFreeze();
        uint256 gf = g - gasleft();
        g = gasleft();
        E().emergencySnapStep(type(uint256).max);
        uint256 gs = g - gasleft();
        uint256 gc;
        for (uint256 i = 0; i < n; i++) {
            g = gasleft();
            E().emergencyClaim(address(uint160(0x1000 + i)));
            uint256 used = g - gasleft();
            if (used > gc) gc = used;
        }
        emit log_named_uint("9.4 emergencyFreeze (n = 43, G = 60)", gf);
        emit log_named_uint("9.4 emergencySnapStep, all holders in one call", gs);
        emit log_named_uint("9.4 emergencyClaim max", gc);
        assertLe(gf, 25_000_000);
        assertLe(gs, 25_000_000);
        assertLe(gc, 25_000_000);
    }

    // --- ревью-2, #1: расчёт чаще недели ------------------------------------------------------------------------------ //
    /// @dev Keeper проводит расчёт раньше недели, когда газ шага приближается к лимиту блока (`liveGenCount`). Три расчёта за
    /// одну календарную неделю (атомарный, пачками, атомарный): каждый принят; неделя бухгалтерии +1 на КАЖДЫЙ расчёт (это
    /// счётчик расчётов, а не календарь — партнёрский срок `partnerTermWeeks` считается в нём же, README «Ревью-2»);
    /// `mondayEndAt` = время расчёта, триггеров нет; живые поколения уходят ровно с закрытием их ордеров. Часы аварии от
    /// частоты не «отмываются»: заявка в очереди бухгалтерии стареет от РОЖДЕНИЯ (`T_queue_max` сработает через срок, сколько
    /// бы расчётов ни прошло), `T_nomonday` — от последнего расчёта.
    function test_review2_three_settlements_in_one_week() public {
        // ревью-3b: календарный расчёт — один за неделю; расчёты 2 и 3 той же недели — ВНЕОЧЕРЕДНЫЕ, право — половина предела
        // поколений (предел 2: одно новое поколение с расчёта)
        H.setMaxGens(2);
        V = _vault(DELAY, _module());
        _deposit(A, 1000e6, "a1");
        _deposit(B, 1000e6, "b1");
        _sweep();
        PoolLedgerViews L = _lv();
        uint256 t0 = block.timestamp;
        int256 w0 = L.status()[1];
        vm.startPrank(K);
        V.sizeOrder("P1", 500e6);
        V.fillOrder("P1");
        V.sizeOrder("Q1", 300e6); // то же поколение (те же веса)
        V.fillOrder("Q1");
        V.closePosition("Q1", 100e6);
        V.setWithdrawable(0);
        vm.stopPrank();
        assertEq(L.liveGenCount(), 1);
        // заявка A уходит в очередь бухгалтерии (ликвидности нет): её срок — от рождения
        vm.prank(A);
        V.requestWithdraw(50e6, false, false);
        vm.prank(K);
        V.processWithdrawals(1);
        int256 qid = L.oldestQueued();
        assertGe(qid, 0, "queued in the ledger");
        uint256 born = block.timestamp;
        // расчёт 1 (сутки 1): атомарный
        _warp(1 days);
        vm.prank(K);
        V.monday();
        _settledCheck(L, w0 + 1, 1);
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday: calendar week already settled"));
        V.monday(); // второй календарный той же недели
        // расчёт 2 (сутки 3): новый ордер — новое поколение, закрыт с убытком; пачками, внеочередной
        _warp(2 days);
        vm.startPrank(K);
        V.markPosition("P1", -20e6);
        V.sizeOrder("R1", 200e6);
        V.fillOrder("R1");
        V.closePosition("R1", -50e6);
        vm.stopPrank();
        assertEq(L.liveGenCount(), 2, "P1's generation and R1's");
        vm.startPrank(K);
        V.mondayBegin(false);
        while (V.mondayStep(1) != 0) {}
        V.mondayEnd();
        vm.stopPrank();
        assertEq(_clock().mondayBeganAt, block.timestamp, "paged settlement stamps its start");
        _settledCheck(L, w0 + 1, 1); // поколение R1 закрыто целиком — ушло; P1 живо; внеочередной неделю не сдвигает
        // расчёт 3 (сутки 5): новое поколение (вход и отмена), P1 закрыт, атомарный внеочередной
        _warp(2 days);
        vm.startPrank(K);
        V.sizeOrder("S1", 100e6);
        V.cancelOrder("S1");
        V.closePosition("P1", 30e6);
        V.monday(false);
        vm.stopPrank();
        _settledCheck(L, w0 + 1, 0);
        assertLt(block.timestamp, t0 + 7 days, "three settlements inside one calendar week");
        assertEq(L.oldestQueued(), qid, "settlements neither pay nor re-stamp the queued request");
        // часы: очередь — от рождения заявки (расчёты её не молодят), T_nomonday — от последнего расчёта
        uint256 snap = vm.snapshotState();
        vm.warp(born + QUEUE_MAX - 1);
        _ping();
        assertEq(E().emergencyTrigger(), 0);
        vm.warp(born + QUEUE_MAX);
        _ping();
        assertEq(E().emergencyTrigger(), 5, "queue age counts from birth, not from the latest settlement");
        vm.revertToState(snap);
        // оплатить очередь (деньги с ноги, ликвидность) — и `T_nomonday` судится от расчёта 3
        vm.prank(K);
        V.legSendToVault(0, 100e6);
        CoreSimulatorLib.nextBlock();
        V.confirmLegSend(0);
        vm.startPrank(K);
        V.setWithdrawable(100e6);
        V.payQueue();
        vm.stopPrank();
        assertEq(L.oldestQueued(), -1);
        uint256 t3 = _clock().mondayEndAt; // время расчёта 3 (перевод с ноги сдвинул блок и часы)
        for (uint256 d = 4 days; d < NOMONDAY; d += 4 days) {
            vm.warp(t3 + d);
            _ping();
        }
        vm.warp(t3 + NOMONDAY - 1);
        _ping();
        assertEq(E().emergencyTrigger(), 0);
        vm.warp(t3 + NOMONDAY);
        _ping();
        assertEq(E().emergencyTrigger(), 3, "T_nomonday from the latest settlement");
    }

    function _clock() internal view returns (EmergencyClock memory c) {
        (c,,,) = V.emergencyClock();
    }

    /// @dev После расчёта: неделя бухгалтерии, расчёт закрыт, `mondayEndAt` = сейчас, триггеров нет, живых поколений `gens`.
    function _settledCheck(PoolLedgerViews L, int256 week, uint256 gens) internal view {
        int256[13] memory s = L.status();
        assertEq(s[1], week, "one ledger week per settlement");
        assertEq(s[11], 0, "settlement closed");
        assertEq(_clock().mondayEndAt, block.timestamp, "T_nomonday restarts at each settlement");
        assertEq(E().emergencyTrigger(), 0);
        assertEq(L.liveGenCount(), gens);
    }

    // --- ревью-3: agent-ключи ног после заморозки (R3-A), сверка keeper'а без ноги не на Core (R3-B) ------------------ //
    address internal BOT3 = makeAddr("bot3");
    address internal BOT4 = makeAddr("bot4");
    uint256 internal constant P_AGENT_A = 3; // `P_AGENT + 0`

    function _addApi(address leg, address agent, string memory name) internal {
        vm.expectEmit(true, false, false, true, CW);
        emit CoreWriterSim.RawAction(
            leg, abi.encodePacked(uint8(1), HLConstants.ADD_API_WALLET_ACTION, abi.encode(agent, name))
        );
    }

    function _bot3() internal {
        V.proposeAgent(0, BOT3, "bot");
        _warp(DELAY);
        V.applyAgent(0, BOT3, "bot");
    }

    /// @dev Ни один денежный путь хранилища после заморозки не открыт: keeper, инвестор и прочие admin-действия — `Frozen`.
    function _frozenMoneyPathsShut() internal {
        bytes4 fz = PoolVault.Frozen.selector;
        vm.startPrank(K);
        vm.expectRevert(fz);
        V.creditDeposit(A, 1, "x");
        vm.expectRevert(fz);
        V.sweepToLegs();
        vm.expectRevert(fz);
        V.legSendToVault(0, 1);
        vm.expectRevert(fz);
        V.legToSpot(0, 1);
        vm.expectRevert(fz);
        V.processWithdrawals(1);
        vm.expectRevert(fz);
        V.vaultToSpot(1);
        vm.expectRevert(fz);
        V.refundDeposit(B, 1, "x", 1);
        vm.stopPrank();
        vm.prank(A);
        vm.expectRevert(fz);
        V.requestWithdraw(0, false, true);
        vm.expectRevert(fz);
        V.setTvlCap(1);
        vm.expectRevert(fz);
        V.proposeKeeper(X);
        vm.expectRevert(fz);
        V.proposeLegShare(0);
    }

    /// @dev R3-A: после заморозки guardian отзывает ключ ноги (`onlyPauser` замка не имеет), а admin возвращает РОВНО
    /// отозванный — сразу, как и до заморозки. Посторонний и guardian вернуть не могут. Денег хранилища возврат не двигает:
    /// бухгалтерия бит в бит, деньги хранилища и ног на месте, держатель забирает ровно своё.
    function test_review3_frozen_agent_revoke_is_reversible() public {
        address la = address(V.legA());
        _bot3();
        _deposit(A, 1000e6, "a1");
        _freezeDead();
        bytes32 h = keccak256(abi.encode(_lv().dump()));
        (uint64 vs, uint64 ls) = (_spot(address(V)), _spot(la));
        vm.prank(G);
        V.revokeAgent(0, "bot", keccak256("r3-salt")); // отзыв после заморозки открыт
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.restoreAgent(0, "bot");
        vm.prank(X);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.restoreAgent(0, "bot");
        _addApi(la, BOT3, "bot");
        V.restoreAgent(0, "bot");
        (address ag, bool rv) = V.agents(keccak256(abi.encode(uint256(0), "bot")));
        assertEq(ag, BOT3, "exactly the revoked key");
        assertFalse(rv, "restored after freeze");
        vm.expectRevert(PoolVault.NothingToChange.selector);
        V.restoreAgent(0, "bot"); // не отозван — возвращать нечего
        _frozenMoneyPathsShut();
        assertEq(keccak256(abi.encode(_lv().dump())), h, "ledger bit for bit");
        assertEq(_spot(address(V)), vs, "vault money untouched");
        assertEq(_spot(la), ls, "leg money untouched");
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 1000e6, "the holder takes exactly its own");
    }

    /// @dev R3-A′: ключ отозван ДО заморозки (законная реакция на кражу), замена таймлоком не успела — после заморозки admin
    /// всё равно возвращает ровно его.
    function test_review3_revoked_before_freeze_restorable_after() public {
        address la = address(V.legA());
        _bot3();
        _deposit(A, 1000e6, "a1");
        vm.prank(G);
        V.revokeAgent(0, "bot", keccak256("r3-salt"));
        _freezeDead();
        _addApi(la, BOT3, "bot");
        V.restoreAgent(0, "bot");
        (, bool rv) = V.agents(keccak256(abi.encode(uint256(0), "bot")));
        assertFalse(rv);
    }

    /// @dev R3-A: новый ключ ноги после заморозки — только таймлоком (`DELAY`), предложение снимает guardian (`cancel` замка не
    /// имеет); guardian и посторонний не предлагают и не применяют. Денежные пути хранилища остаются закрыты.
    function test_review3_frozen_new_agent_only_through_timelock() public {
        address la = address(V.legA());
        _deposit(A, 1000e6, "a1");
        _freezeDead();
        bytes32 h = keccak256(abi.encode(_lv().dump()));
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeAgent(0, BOT4, "bot2");
        vm.prank(X);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeAgent(0, BOT4, "bot2");
        V.proposeAgent(0, BOT4, "bot2");
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, block.timestamp + DELAY));
        V.applyAgent(0, BOT4, "bot2");
        vm.prank(G);
        V.cancel(P_AGENT_A); // вето guardian'а после заморозки на месте
        _warp(DELAY);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyAgent(0, BOT4, "bot2");
        V.proposeAgent(0, BOT4, "bot2");
        _warp(DELAY);
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.applyAgent(0, BOT4, "bot2");
        vm.prank(X);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.applyAgent(0, BOT4, "bot2");
        _addApi(la, BOT4, "bot2");
        V.applyAgent(0, BOT4, "bot2");
        (address ag, bool rv) = V.agents(keccak256(abi.encode(uint256(0), "bot2")));
        assertEq(ag, BOT4);
        assertFalse(rv);
        _frozenMoneyPathsShut();
        assertEq(keccak256(abi.encode(_lv().dump())), h, "ledger bit for bit");
        vm.prank(X);
        assertEq(E().emergencyClaim(A), 1000e6);
    }

    /// @dev R3-B: сверка keeper'а на бете (вся раздача ноге A, нога B не на Core) прекомпайлов ноги B не читает — они
    /// откатывают; стоимость ног — perp + spot ноги A.
    function test_review3_reconcile_skips_leg_not_on_core() public {
        V = _vaultShare(DELAY, _module(), 10_000, false);
        _deposit(A, 1000e6, "a1");
        _sweep();
        vm.prank(K);
        V.legToPerp(0, 400e6);
        CoreSimulatorLib.nextBlock();
        address lb = address(V.legB());
        vm.mockCallRevert(address(0x801), abi.encode(lb, uint64(0)), "no user");
        vm.mockCallRevert(address(0x80F), abi.encode(uint32(0), lb), "no user");
        (uint256 vaultMicro, uint256 heldMicro, int256 legsMicro) = V.reconcile();
        assertEq(vaultMicro, 100e6, "buffer on the vault");
        assertEq(heldMicro, 100e6, "ledger spot+evm after the sweep");
        assertEq(V.legA().accountValue(), 400e6, "perp of leg A is counted");
        assertEq(legsMicro, 900e6, "perp + spot of leg A");
    }

    /// @dev R3-B: на двух ногах сверка суммирует perp и spot обеих; spot — в wei суммой, а на микро делится один раз (остаток
    /// wei двух ног не теряется).
    function test_review3_reconcile_two_legs() public {
        _deposit(A, 1000e6, "a1");
        _sweep();
        vm.startPrank(K);
        V.legToPerp(0, 100e6);
        V.legToPerp(1, 200e6);
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        (address la, address lb) = (address(V.legA()), address(V.legB()));
        CoreSimulatorLib.forceSpotBalance(la, USDC, _spot(la) + 50);
        CoreSimulatorLib.forceSpotBalance(lb, USDC, _spot(lb) + 50);
        (,, int256 legsMicro) = V.reconcile();
        assertEq(legsMicro, 900e6 + 1, "both legs, perp and spot, 100 wei of remainders = 1 micro");
    }
}
