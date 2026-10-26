// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {toNextCalendarWeek} from "./CalendarWeek.sol";
import {PoolLedger, PoolLedgerBase, PoolLedgerViews, PoolLedgerMonday, PoolLedgerProj, PoolLedgerEmergency, PoolLedgerBook} from "../src/PoolLedger.sol";

/// @notice Ред. 9.5 (спека 8.15) — то, чего дифференциал не видит по построению: у фикстур эталона внеочередной расчёт —
/// политика keeper'а, а не бухгалтерии (`maxGens == 0` у всех, кроме 266, и там условие выполнено). Здесь: ПРАВО на
/// внеочередной расчёт (предел поколений или должник по маркам, иначе отказ), граница `maxGens` конструктора, неделя
/// замороженного посреди внеочередного расчёта пула и газ операций книги, не растущий с числом окончательных поколений.
contract PoolLedgerGensTest is Test {
    address internal constant T = address(0xfee);
    address internal constant A = address(0x1);
    address internal constant B = address(0x2);
    uint8 internal constant NONE = 0;
    uint8 internal constant EVM = 1;
    bytes internal constant NOT_ALLOWED = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday: extra settle not allowed");

    function _init(uint256 maxGens) internal returns (PoolLedger.Init memory) {
        return PoolLedger.Init(
            T, 1000, 5000, 2000, 3500, 200, 52, 0, 43, address(new PoolLedgerViews()), address(new PoolLedgerMonday()),
            address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()),
            maxGens
        );
    }

    function _fresh(uint256 maxGens) internal returns (PoolLedger) {
        return new PoolLedger(_init(maxGens));
    }

    function _v(PoolLedger M) internal pure returns (PoolLedgerViews) {
        return PoolLedgerViews(address(M));
    }

    function _since(PoolLedger M) internal view returns (uint256 s) {
        (, s,) = _v(M).genLimits();
    }

    /// @dev Два инвестора, ордер `o1` исполнен и под марком (веса следующего снимка другие): одно поколение с расчёта.
    function _twoGens(PoolLedger M, bool second) internal {
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 500e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("o1", 300e6);
        M.fillOrder("o1");
        M.markPosition("o1", -10e6);
        if (second) M.sizeOrder("o2", 300e6);
    }

    /// @dev Предел 4: внеочередной расчёт принят, только когда с расчёта открыто ⌊4/2⌋ = 2 поколения (без должника по маркам);
    /// неделя не сдвигается, счёт поколений обнуляется; календарный — без условия, неделя + 1.
    function test_r95_extra_settle_needs_half_of_max_gens() public {
        PoolLedger M = _fresh(4);
        _twoGens(M, false);
        assertEq(_since(M), 1);
        assertEq(_v(M).projectedShortfall(), 0, "no debtor by marks");
        vm.expectRevert(NOT_ALLOWED);
        M.monday(false);
        vm.expectRevert(NOT_ALLOWED);
        M.mondayBegin(false);
        M.sizeOrder("o2", 300e6);
        assertEq(_since(M), 2);
        int256 w0 = _v(M).status()[1];
        M.monday(false);
        assertEq(_v(M).status()[1], w0, "extra settle keeps the calendar week");
        assertEq(_since(M), 0, "extra settle resets generations since settle");
        vm.expectRevert(NOT_ALLOWED);
        M.monday(false); // ноль поколений с расчёта — снова нельзя
        toNextCalendarWeek();
        M.monday(true);
        assertEq(_v(M).status()[1], w0 + 1, "calendar settle moves the week by one");
        toNextCalendarWeek();
        M.monday();
        assertEq(_v(M).status()[1], w0 + 2);
    }

    /// @dev То же пачками: `mondayBegin(false)` судится тем же условием и неделю не сдвигает.
    function test_r95_extra_settle_paged() public {
        PoolLedger M = _fresh(4);
        _twoGens(M, true);
        int256 w0 = _v(M).status()[1];
        M.mondayBegin(false);
        while (true) {
            (uint256 stage,,,) = _v(M).mondayProgress();
            if (stage == 7) break;
            M.mondayStep(1);
        }
        M.mondayEnd();
        assertEq(_v(M).status()[1], w0);
        assertEq(_since(M), 0);
    }

    /// @dev Должник по маркам даёт право на внеочередной расчёт при любом числе поколений: {A 100, B 100} в ордере на 1000,
    /// B вносит ещё 1000 (в снимке его нет), марк −300 — доля A 150 при капитале 100 (сценарий фикстуры 267).
    function test_r95_extra_settle_on_debtor_by_marks() public {
        PoolLedger M = _fresh(100);
        M.deposit(A, 100e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 100e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("gap", 1000e6);
        M.fillOrder("gap");
        M.deposit(B, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        vm.expectRevert(NOT_ALLOWED);
        M.monday(false); // одно поколение из 100 и должника нет
        M.markPosition("gap", -300e6);
        assertGt(_v(M).projectedShortfall(), 0, "A is a debtor by marks");
        assertEq(_since(M), 1);
        int256 w0 = _v(M).status()[1];
        M.monday(false);
        assertEq(_v(M).status()[1], w0);
    }

    /// @dev Предел 2: третье НОВОЕ поколение — отказ; ордер при тех же весах встаёт в текущее и пределом не режется; после
    /// внеочередного расчёта — принят.
    function test_r95_max_gens_refuses_only_new_generation() public {
        PoolLedger M = _fresh(2);
        _twoGens(M, true);
        M.sizeOrder("same", 100e6); // те же веса — текущее поколение
        assertEq(_v(M).status()[2], 2, "same weights, same generation");
        M.fillOrder("o2");
        M.markPosition("o2", -20e6);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "size_order: max_gens"));
        M.sizeOrder("o3", 300e6);
        M.monday(false);
        M.sizeOrder("o3", 300e6);
        assertEq(_v(M).status()[2], 3);
        (uint256 mg, uint256 since, uint256 live) = _v(M).genLimits();
        assertEq(mg, 2);
        assertEq(since, 1);
        assertEq(live, 3, "o1, o2 and the current generation of o3 are live");
    }

    /// @dev Граница конструктора: предел выше MAX_GENS_BOUND и книга без кода — отказ.
    function test_r95_ctor_bounds() public {
        Factory f = new Factory();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "max_gens"));
        f.make(_init(1001));
        PoolLedger.Init memory p = _init(10);
        p.bookImpl = address(0xbeef);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "book: no code"));
        f.make(p);
        f.make(_init(1000));
    }

    /// @dev Заморозка посреди ВНЕОЧЕРЕДНОГО расчёта пачками: неделя снимка — текущая (внеочередной её не сдвигал); посреди
    /// календарного — неделя до него.
    function test_r95_freeze_mid_extra_settle_week() public {
        for (uint256 cal = 0; cal < 2; cal++) {
            PoolLedger M = _fresh(2);
            _twoGens(M, true);
            int256 w0 = _v(M).status()[1];
            toNextCalendarWeek();
            M.mondayBegin(cal == 1);
            M.mondayStep(1);
            M.emergencyFreeze();
            assertEq(_v(M).emergencyTotals()[3], w0, "snapshot week = week before the settle");
        }
    }

    /// @dev Газ операций книги не растёт с числом ОКОНЧАТЕЛЬНЫХ поколений (ред. 9.5): M неисполненных входов (каждый — своё
    /// поколение, отменён) до замера марка, закрытия и депозита. Разница между M = 20 и M = 400 — шум холодных слов, а не
    /// O(поколений) (до амортизации — ~7.3 тыс. газа на поколение в КАЖДОМ из трёх вызовов).
    function test_r95_book_gas_flat_in_dead_generations() public {
        uint256[3] memory few = _bookGas(20);
        uint256[3] memory many = _bookGas(400);
        for (uint256 i = 0; i < 3; i++) {
            assertLt(many[i], few[i] + 30_000, "book call grows with dead generations");
        }
    }

    function _bookGas(uint256 m) internal returns (uint256[3] memory g) {
        PoolLedger M = _fresh(0);
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("anchor", 200e6);
        M.fillOrder("anchor");
        for (uint256 j = 0; j < m; j++) {
            M.markPosition("anchor", -int256((j % 50 + 1) * 1e6));
            bytes32 pid = bytes32(abi.encodePacked("o", vm.toString(j)));
            M.sizeOrder(pid, 10e6);
            M.cancelOrder(pid);
        }
        (,, uint256 live) = _v(M).genLimits();
        assertEq(live, 2, "dead generations left the live list");
        assertEq(_v(M).liveGenCount(), m + 1, "but stay in the snapshots until the settle");
        M.sizeOrder("probe", 10e6);
        M.fillOrder("probe");
        vm.cool(address(M));
        uint256 g0 = gasleft();
        M.markPosition("probe", -1e6);
        g[0] = g0 - gasleft();
        vm.cool(address(M));
        g0 = gasleft();
        M.closePosition("probe", -1e6);
        g[1] = g0 - gasleft();
        vm.cool(address(M));
        g0 = gasleft();
        M.deposit(A, 10e6, address(0), NONE, EVM, bytes32(0));
        g[2] = g0 - gasleft();
        toNextCalendarWeek();
        M.monday();
        assertEq(_v(M).liveGenCount(), 1, "settle closes every dead generation");
    }

    /// @dev Потолок суммы капиталов (эталон `_stake_ceiling`) — ведущаяся `growSum`: закрытая прибыль поколения входит в оценку
    /// сразу (депозит сверх потолка с ней — отказ), а после расчёта, закрывшего поколение, выходит из неё (прибыль уже в
    /// капитале — второй раз её не считать: тот же депозит принят).
    function test_r95_stake_ceiling_follows_generation_result() public {
        PoolLedger M = _fresh(0);
        M.deposit(A, 1 << 127, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("big", 1e6);
        M.fillOrder("big");
        M.closePosition("big", int256(1 << 126));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "stake ceiling"));
        M.deposit(B, (1 << 126) + 1, address(0), NONE, EVM, bytes32(0)); // 2^127 + 2^126 (R) + 2^126 + 1 > 2^128 − 1
        toNextCalendarWeek();
        M.monday(); // половина прибыли — комиссия в котёл, капитал A = 2^127 + 2^125; поколение закрыто
        M.deposit(B, 1 << 126, address(0), NONE, EVM, bytes32(0)); // 2^127 + 2^125 + 2^126 < 2^128
    }

    // --- ревью-3b: календарный расчёт — не чаще одного за календарную неделю; право внеочередного — после замков ---------- //
    bytes internal constant CAL_SETTLED =
        abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday: calendar week already settled");
    address internal constant PARTNER = address(0x77);
    uint256 internal constant MON_0400 = 4 days + 4 hours; // 1970-01-05 04:00 UTC — понедельник, время расписания keeper'а

    function _pot(PoolLedger M) internal view returns (int256) {
        int256[6] memory r = _v(M).referrerView(T);
        return r[0] + r[1] + r[2];
    }

    /// @dev Репро ревьюера (`test_rv3b_calendar_bypasses_extra_gate`): внеочередной отклонён — календарный в ТОМ ЖЕ блоке
    /// принимается ОДИН раз, второй и третий — отказ; неделя +1, а не +3. Все три формы календарного судятся одним замком.
    function test_rv3b_second_calendar_in_a_week_refused() public {
        PoolLedger M = _fresh(1000);
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("o1", 300e6);
        M.fillOrder("o1");
        M.closePosition("o1", 200e6);
        vm.expectRevert(NOT_ALLOWED);
        M.monday(false);
        int256 w0 = _v(M).status()[1];
        M.monday(true);
        vm.expectRevert(CAL_SETTLED);
        M.monday();
        vm.expectRevert(CAL_SETTLED);
        M.monday(true);
        vm.expectRevert(CAL_SETTLED);
        M.mondayBegin();
        vm.expectRevert(CAL_SETTLED);
        M.mondayBegin(true);
        assertEq(_v(M).status()[1], w0 + 1, "one calendar week per calendar week");
        toNextCalendarWeek();
        M.mondayBegin(true); // следующая неделя — пачками
        while (M.mondayStep(1) != 0) {}
        M.mondayEnd();
        assertEq(_v(M).status()[1], w0 + 2);
    }

    /// @dev Репро ревьюера (`test_rv3b_peak_fee_via_calendar`): путь +200 / −200 внутри недели. Календарный расчёт на пике той
    /// же недели — отказ; один расчёт в конце — комиссии нет на обоих путях (фиксации на пике нет).
    function test_rv3b_peak_fee_via_calendar_refused() public {
        int256[2] memory fee;
        for (uint256 v = 0; v < 2; v++) {
            PoolLedger M = _fresh(1000);
            M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
            M.sweepToPerp();
            M.monday(); // календарный расчёт этой недели проведён
            M.sizeOrder("o1", 300e6);
            M.fillOrder("o1");
            M.closePosition("o1", 200e6);
            if (v == 1) {
                vm.expectRevert(CAL_SETTLED);
                M.monday(true); // фиксация на пике той же недели
            }
            M.sizeOrder("o2", 300e6);
            M.fillOrder("o2");
            M.closePosition("o2", -200e6);
            toNextCalendarWeek();
            M.monday(true);
            fee[v] = _pot(M);
        }
        assertEq(fee[0], 0, "no profit over the week - no fee");
        assertEq(fee[1], 0, "the peak is not crystallized");
    }

    /// @dev Репро ревьюера (`test_rv3b_partner_term_burned_in_one_block`): 53 календарных расчёта в одном блоке — принят один,
    /// неделя +1; срок партнёра (52 недели) не сжигается.
    function test_rv3b_partner_term_not_burned_in_one_block() public {
        PoolLedger M = _fresh(1000);
        M.setPartner(PARTNER, 1);
        M.deposit(A, 1000e6, PARTNER, NONE, EVM, bytes32(0));
        M.sweepToPerp();
        int256 w0 = _v(M).status()[1];
        M.monday();
        for (uint256 i = 0; i < 52; i++) {
            vm.expectRevert(CAL_SETTLED);
            M.monday();
        }
        assertEq(_v(M).status()[1], w0 + 1, "one calendar week in one block");
    }

    /// @dev Недельный ритм keeper'а (`SETTLEMENT_UTC` — понедельник 04:00 UTC) проходит каждую неделю; пропущенный понедельник
    /// догоняется позже в ТУ ЖЕ неделю (вторник) — один раз; граница недели — понедельник 00:00 UTC: воскресенье 23:59:59 — та
    /// же неделя, секундой позже — новая. Внеочередной расчёт по праву календарь не трогает: календарный той же недели после
    /// него проходит.
    function test_rv3b_weekly_rhythm_passes() public {
        PoolLedger M = _fresh(4);
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        int256 w0 = _v(M).status()[1];
        for (uint256 k = 0; k < 8; k++) {
            vm.warp(MON_0400 + k * 7 days); // недели 1..8
            M.monday();
        }
        assertEq(_v(M).status()[1], w0 + 8, "every Monday 04:00 UTC settles");
        vm.warp(MON_0400 + 8 * 7 days + 1 days); // неделя 9: понедельник пропущен — вторник
        M.monday();
        vm.expectRevert(CAL_SETTLED);
        M.monday();
        uint256 mon10 = 10 * 7 days - 3 days; // понедельник 00:00 UTC недели 10
        vm.warp(mon10 - 1); // воскресенье 23:59:59 — ещё неделя 9
        vm.expectRevert(CAL_SETTLED);
        M.monday();
        vm.warp(mon10);
        _twoGens(M, true); // два новых поколения: право на внеочередной (предел 4)
        M.monday(false);
        assertEq(_v(M).status()[1], w0 + 9, "extra settle keeps the week");
        M.monday(); // календарный той же недели — проходит: внеочередной календарь не трогает
        vm.expectRevert(CAL_SETTLED);
        M.monday();
        assertEq(_v(M).status()[1], w0 + 10);
    }

    /// @dev Ревью-3b (LOW): право на внеочередной расчёт судится ПОСЛЕ замков — на открытом расчёте отказ «monday in
    /// progress», на замороженном пуле — «frozen», а не «extra settle not allowed».
    function test_rv3b_extra_settle_reasons_after_locks() public {
        PoolLedger M = _fresh(1000);
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.mondayBegin();
        bytes memory open_ = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress");
        vm.expectRevert(open_);
        M.monday(false);
        vm.expectRevert(open_);
        M.mondayBegin(false);
        while (M.mondayStep(1) != 0) {}
        M.mondayEnd();
        M.emergencyFreeze();
        bytes memory frozen = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "frozen");
        vm.expectRevert(frozen);
        M.monday(false);
        vm.expectRevert(frozen);
        M.mondayBegin(false);
    }
}

contract Factory {
    function make(PoolLedger.Init memory p) external returns (PoolLedger) {
        return new PoolLedger(p);
    }
}
