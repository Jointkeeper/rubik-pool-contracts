// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {toNextCalendarWeek} from "./CalendarWeek.sol";
import {PoolLedger, PoolLedgerBase, PoolLedgerViews, PoolLedgerMonday, PoolLedgerProj, PoolLedgerEmergency, PoolLedgerBook} from "../src/PoolLedger.sol";

/// @notice Ред. 9.4 — замороженный пул на стороне бухгалтерии: то, чего фикстуры эталона не видят по построению (эталон
/// считает недельный расчёт атомарным и замораживает одной операцией). Правило E и снимок вне расчёта судит дифференциал
/// (фикстуры 236-239, 260, 261); здесь — заморозка ПОСРЕДИ расчёта пачками (MS_SNAP: снимок обязан быть снимком «до monday»),
/// замок неизменности на шагах расчёта, проход итогов пачками и прямой вызов реализации.
contract PoolLedgerEmergencyTest is Test {
    address internal constant T = address(0xfee);
    address internal constant A = address(0x1);
    address internal constant B = address(0x2);
    address internal constant C = address(0x3);
    address internal constant R1 = address(0x51); // рефералы-неинвесторы: держатели только вознаграждения (`known`)
    address internal constant R2 = address(0x52);
    uint8 internal constant NONE = 0;
    uint8 internal constant PAYOUT = 2;
    uint8 internal constant EVM = 1;

    function _fresh() internal returns (PoolLedger M) {
        M = new PoolLedger(PoolLedger.Init(
            T, 1000, 5000, 2000, 3500, 200, 52, 0, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()),
            address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0
        ));
    }

    function _v(PoolLedger M) internal pure returns (PoolLedgerViews) {
        return PoolLedgerViews(address(M));
    }

    /// @dev Неделя 1: прибыль двух поколений — комиссия в котёл, вознаграждения рефералам (этап реферальных долей), у C
    /// режим выплат — прибыль уходит заявкой. Неделя 2 (`two`): после расчёта недели 1 — убыток сверх денег адресов
    /// (должники, раздел, дыра пула) в одном поколении и прибыль в другом.
    function _scenario(PoolLedger M, bool two) internal {
        M.deposit(A, 1000e6, R1, NONE, EVM, bytes32(0));
        M.deposit(B, 3000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(C, 500e6, R2, PAYOUT, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("x", 8000e6);
        M.fillOrder("x");
        M.markPosition("x", -100e6); // веса следующего снимка другие — второе поколение
        M.sizeOrder("p", 2000e6);
        M.fillOrder("p");
        M.closePosition("p", 900e6);
        M.withdraw(C, 100e6, false); // у C «к получению» на начало недели 1 — его копия MS_SNAP не ноль
        if (!two) return;
        _steps(M); // неделя 1 пачками: копия MS_SNAP этой недели остаётся в памяти — неделя 2 обязана её переписать
        M.mondayEnd();
        M.claim(C); // «к получению» C -> 0: копия недели 2 обязана записать ноль поверх недели 1
        M.withdraw(A, 300e6, false); // у A денег меньше его веса в снимке «x» — убыток сделает его должником
        M.claim(A);
        M.sizeOrder("q", 1000e6);
        M.fillOrder("q");
        M.closePosition("q", 400e6);
        M.closePosition("x", -5200e6);
    }

    /// @dev Ход расчёта пачками: сколько вызовов `mondayStep(1)` до этапа «осталось mondayEnd» и старший пройденный этап.
    function _steps(PoolLedger M) internal returns (uint256 n, uint256 top) {
        toNextCalendarWeek();
        M.mondayBegin();
        while (true) {
            (uint256 stage,,,) = _v(M).mondayProgress();
            if (stage == 7) return (n, top);
            if (stage > top) top = stage;
            M.mondayStep(1);
            n++;
        }
    }

    function _snap(PoolLedger M) internal {
        M.emergencyFreeze();
        if (_v(M).emergencyTotals()[0] == 1) M.emergencySnapStep(type(uint256).max);
        assertEq(_v(M).emergencyTotals()[0], 2, "snapshot ready");
    }

    function _assertSameShares(PoolLedger X, PoolLedger Y, string memory what) internal view {
        assertEq(keccak256(abi.encode(_v(X).emergencyDump())), keccak256(abi.encode(_v(Y).emergencyDump())), what);
        int256[9] memory t = _v(X).emergencyTotals();
        uint256 E = uint256(t[6]);
        uint256[6] memory grid = [uint256(0), E / 3, uint256(t[4]), E, E + uint256(t[4]), 3 * E + 7];
        address[6] memory who = [A, B, C, R1, R2, T];
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = 0; j < 6; j++) {
                assertEq(_v(X).emergencyDue(who[i], grid[j]), _v(Y).emergencyDue(who[i], grid[j]), what);
            }
        }
    }

    /// @dev ЗАМОРОЗКА ПОСРЕДИ РАСЧЁТА = ЗАМОРОЗКА ДО НЕГО (эталон: расчёт атомарен, снимок — состояние ДО `monday`). На каждом
    /// шаге расчёта пачками по одной единице (после `mondayBegin`, после каждой строки, каждого этапа фазы 2, перед
    /// `mondayEnd`) снимок и доли на сетке M совпадают со снимком двойника, замороженного до `mondayBegin`. Строки и фаза 2
    /// переписывают капитал, котёл (комиссия), вознаграждения и долг пула — без копии MS_SNAP доли были бы «полуразнесены».
    function _midMondayEqualsBefore(bool two) internal {
        PoolLedger ref = _fresh();
        _scenario(ref, two);
        _snap(ref);
        PoolLedger probe = _fresh();
        _scenario(probe, two);
        (uint256 n, uint256 top) = _steps(probe);
        assertGt(n, 2, "the settlement takes several batches");
        // неделя 1 — строки и реферальные доли; неделя 2 — должники: раздел соучастников (3) и дальше
        assertGe(top, two ? 3 : 1, "phase 2 of the settlement is exercised");
        for (uint256 j = 0; j <= n; j++) {
            PoolLedger M = _fresh();
            _scenario(M, two);
            toNextCalendarWeek();
            M.mondayBegin();
            for (uint256 s = 0; s < j; s++) {
                M.mondayStep(1);
            }
            _snap(M);
            _assertSameShares(ref, M, string.concat("mid-monday snapshot after step ", vm.toString(j)));
            assertEq(_v(M).emergencyTotals()[1], 1, "mid-monday freeze reads the MS_SNAP copy");
            vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "frozen"));
            M.mondayStep(1);
            vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "frozen"));
            M.mondayEnd();
        }
    }

    function test_rev94_mid_monday_freeze_equals_freeze_before_monday_week1() public {
        _midMondayEqualsBefore(false);
    }

    function test_rev94_mid_monday_freeze_equals_freeze_before_monday_week2() public {
        _midMondayEqualsBefore(true);
    }

    /// @dev Копия MS_SNAP переписывается КАЖДУЮ неделю, нулём тоже: реферал R1, у которого на начало недели 2 было
    /// вознаграждение, к неделе 3 вывел и забрал всё (f = s = 0). Заморозка посреди недели 3 обязана видеть его ноль, а не
    /// копию недели 2.
    function test_rev94_ms_snap_overwrites_an_emptied_holder() public {
        PoolLedger[2] memory twins = [_fresh(), _fresh()];
        for (uint256 i = 0; i < 2; i++) {
            PoolLedger M = twins[i];
            _scenario(M, false);
            _steps(M); // неделя 1: R1 получает вознаграждение
            M.mondayEnd();
            _steps(M); // неделя 2: копия MS_SNAP записывает f(R1) != 0
            M.mondayEnd();
            int256 rw = _v(M).referrerView(R1)[0];
            assertGt(rw, 0, "R1 holds a reward");
            M.withdraw(R1, uint256(rw), true);
            M.claim(R1);
        }
        _snap(twins[0]); // неделя 3: заморозка до расчёта
        toNextCalendarWeek();
        twins[1].mondayBegin();
        twins[1].mondayStep(1);
        _snap(twins[1]); // посреди расчёта недели 3 — из копии
        _assertSameShares(twins[0], twins[1], "week-3 copy after an emptied holder");
        (int256 f0, int256 s0,) = _v(twins[1]).emergencyPlanes(R1);
        assertEq(f0 + s0, 0, "the emptied referrer has nothing in the copy");
    }

    /// @dev Снимок вне расчёта — живые плоскости, и неделя расчёта их действительно меняла (иначе стенд выше ничего не судит).
    function test_rev94_monday_moves_the_planes_it_copies() public {
        PoolLedger before = _fresh();
        _scenario(before, true);
        _snap(before);
        PoolLedger after_ = _fresh();
        _scenario(after_, true);
        toNextCalendarWeek();
        after_.monday();
        _snap(after_);
        assertEq(_v(after_).emergencyTotals()[1], 0, "outside monday the frozen planes are read live");
        assertTrue(
            keccak256(abi.encode(_v(before).emergencyDump())) != keccak256(abi.encode(_v(after_).emergencyDump())),
            "a settled week changes the snapshot"
        );
        int256[9] memory b = _v(before).emergencyTotals();
        int256[9] memory a = _v(after_).emergencyTotals();
        assertTrue(b[4] != a[4] || b[5] != a[5], "the week moves the pot or the pool hole");
    }

    /// @dev Неизменность: после заморозки каждая изменяющая операция — отказ «frozen» (`initPartner` — «init closed»), повторная
    /// заморозка тоже; состояние бит в бит. MX1: `refundRef` с ref незачтённого Send — отказ, ref не сгорает.
    function test_rev94_frozen_ledger_rejects_every_mutation() public {
        PoolLedger M = _fresh();
        _scenario(M, false);
        M.sizeOrder("open", 500e6);
        M.fillOrder("open");
        M.sizeOrder("sized", 500e6);
        _snap(M);
        bytes32 h = keccak256(abi.encode(_v(M).dump(), _v(M).emergencyDump()));
        bytes memory fz = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "frozen");
        bytes[28] memory calls = [
            abi.encodeCall(PoolLedger.deposit, (A, 10e6, address(0), NONE, EVM, bytes32(0))),
            abi.encodeCall(PoolLedger.withdraw, (A, 1, false)),
            abi.encodeCall(PoolLedger.claim, (A)),
            abi.encodeCall(PoolLedger.sizeOrder, ("new", 1e6)),
            abi.encodeCall(PoolLedger.fillOrder, ("sized")),
            abi.encodeCall(PoolLedger.cancelOrder, ("sized")),
            abi.encodeCall(PoolLedger.markPosition, ("open", 1)),
            abi.encodeCall(PoolLedger.closePosition, ("open", 1)),
            abi.encodeCall(PoolLedger.reducePosition, ("open", 1, 1e6, 0)),
            abi.encodeCall(PoolLedger.setWithdrawable, (0)),
            abi.encodeCall(PoolLedger.sweepToPerp, ()),
            abi.encodeCall(PoolLedger.payQueue, ()),
            abi.encodeCall(PoolLedger.treasuryPayout, ()),
            abi.encodeCall(PoolLedger.setPayoutMode, (A, true)),
            abi.encodeCall(PoolLedger.setPartner, (R1, 1)),
            abi.encodeCall(PoolLedger.coverShortfall, (1, EVM, bytes32(0))),
            abi.encodeCall(PoolLedger.refundRef, (bytes32("send-1"))),
            abi.encodeCall(PoolLedger.raiseMaxInvestors, (43)),
            abi.encodeWithSignature("monday()"),
            abi.encodeWithSignature("mondayBegin()"),
            abi.encodeCall(PoolLedger.mondayStep, (1)),
            abi.encodeCall(PoolLedger.mondayEnd, ()),
            abi.encodeCall(PoolLedger.emergencyFreeze, ()),
            abi.encodeCall(PoolLedger.emergencySnapStep, (1)),
            // ред. 9.5: внеочередной и явный календарный расчёт — тот же замок
            abi.encodeWithSignature("monday(bool)", false),
            abi.encodeWithSignature("monday(bool)", true),
            abi.encodeWithSignature("mondayBegin(bool)", false),
            abi.encodeWithSignature("mondayBegin(bool)", true)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory why) = address(M).call(calls[i]);
            assertFalse(ok, string.concat("mutation accepted on a frozen ledger: call ", vm.toString(i)));
            if (i != 23) assertEq(why, fz, string.concat("rejected by the freeze lock: call ", vm.toString(i)));
        }
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "init closed"));
        M.initPartner(address(0x77));
        assertEq(keccak256(abi.encode(_v(M).dump(), _v(M).emergencyDump())), h, "frozen state bit for bit");
    }

    /// @dev Проход итогов пачками по одному держателю = за один вызов; правило E закрыто до готовности снимка; k = 0 — отказ.
    function test_rev94_snapshot_pass_in_batches() public {
        PoolLedger X = _fresh();
        _scenario(X, true);
        _snap(X);
        PoolLedger Y = _fresh();
        _scenario(Y, true);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "emergency: no snapshot"));
        _v(Y).emergencyDue(A, 1);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "emergency: no pass"));
        Y.emergencySnapStep(1);
        Y.emergencyFreeze();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "emergency: no snapshot"));
        _v(Y).emergencyDue(A, 1);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "emergencySnapStep: k == 0"));
        Y.emergencySnapStep(0);
        uint256 steps;
        while (Y.emergencySnapStep(1) != 0) steps++;
        assertEq(steps + 1, 3 + 3, "one holder per batch: A, B, C, then known R1, treasury, R2");
        _assertSameShares(X, Y, "batched snapshot pass");
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "zero address"));
        _v(Y).emergencyDue(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "uint128"));
        _v(Y).emergencyDue(A, uint256(type(uint128).max) + 1);
        assertEq(_v(Y).emergencyDue(address(0xdead), 1e18), 0, "outsider gets nothing");
    }

    /// @dev MX2 (стык 9.3.1.1 и 9.4, спека 8.14; числа — эталон, стенд MX2): часть +200 ордера {A, B} при комиссии 50 % —
    /// после понедельника она капитал, а её комиссия отложена (резерв `fee_due` Н2). Снимок резерв не читает: капитал A 1 100,
    /// котёл 0; при деньгах = плоскостям A получает 1 100, котёл 0 (обычный путь дал бы A 1 050, котлу 100 — названная цена).
    function test_rev94_mx2_part_is_capital_deferred_fee_not_taken() public {
        PoolLedger M = _fresh();
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("p", 1000e6);
        M.fillOrder("p");
        M.reducePosition("p", 200e6, 500e6, 0);
        M.setWithdrawable(uint256(_v(M).status()[9]) + 200e6);
        toNextCalendarWeek();
        M.monday();
        _snap(M);
        (, int256 s,) = _v(M).emergencyPlanes(A);
        int256[9] memory t = _v(M).emergencyTotals();
        assertEq(s, 1100e6, "the settled part is capital");
        assertEq(t[4], 0, "the pot holds no deferred fee");
        uint256 edge = uint256(t[4] > t[5] ? t[4] - t[5] : int256(0)) + uint256(t[6]);
        assertEq(_v(M).emergencyDue(A, edge), 1100e6);
        assertEq(_v(M).emergencyDue(T, edge), 0);
    }

    /// @dev MX3 (эталон, стенд MX3): минимум депозита 10, капитал A после убытка 7 — доля 7 при деньгах = плоскостям; депозит
    /// после заморозки отклоняет заморозка, а не минимум.
    function test_rev94_mx3_no_minimum_in_emergency() public {
        PoolLedger M = new PoolLedger(PoolLedger.Init(
            T, 1000, 5000, 2000, 3500, 200, 52, 10e6, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()),
            address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0
        ));
        M.deposit(A, 10e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 100e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("p", 110e6);
        M.fillOrder("p");
        M.closePosition("p", -33e6);
        toNextCalendarWeek();
        M.monday();
        _snap(M);
        (, int256 s,) = _v(M).emergencyPlanes(A);
        assertEq(s, 7e6, "A's capital after the loss is below the minimum");
        assertEq(_v(M).emergencyDue(A, uint256(_v(M).emergencyTotals()[6])), 7e6, "paid in full, no minimum");
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "frozen"));
        M.deposit(A, 10e6, address(0), NONE, EVM, bytes32(0));
    }

    /// @dev Реализация без памяти бухгалтерии: прямой вызов отклоняется `onlyOwner` (владелец её собственной памяти — ноль).
    function test_rev94_direct_call_to_emergency_impl_reverts() public {
        PoolLedgerEmergency e = new PoolLedgerEmergency();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "owner"));
        e.emergencyFreeze();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "owner"));
        e.mondayBegin();
    }

    /// @dev В7′: старейшая заявка ИНВЕСТОРА в очереди бухгалтерии (reward-заявки не судятся — эталон `serve_starved`).
    function test_rev94_oldest_investor_queue_entry() public {
        PoolLedger M = _fresh();
        assertEq(_v(M).oldestQueued(), -1, "empty queue");
        _scenario(M, false);
        M.setWithdrawable(0);
        toNextCalendarWeek();
        M.monday(); // C в режиме выплат: прибыль — заявкой; ликвидности нет — заявка ждёт
        int256 q = _v(M).oldestQueued();
        assertGe(q, 0, "payout-mode profit waits in the queue");
        M.setWithdrawable(0);
        M.withdraw(B, 10e6, false);
        assertEq(_v(M).oldestQueued(), q, "a newer entry does not move the oldest");
    }
}
