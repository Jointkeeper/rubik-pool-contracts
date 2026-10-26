// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {toNextCalendarWeek} from "./CalendarWeek.sol";
import {PoolLedger, PoolLedgerBase, PoolLedgerViews, PoolLedgerMonday, PoolLedgerProj, PoolLedgerEmergency, PoolLedgerBook} from "../src/PoolLedger.sol";

/// @notice Создание бухгалтерии ВНЕШНИМ вызовом: `vm.expectRevert` перед `new` в теле теста forge исполняет как чит-код
/// `deployCode`, и отказ конструктора завершает весь тест «успехом» — следующие строки не исполнялись (замер 18.10, трасса).
contract LedgerFactory {
    function make(PoolLedger.Init memory p) external returns (PoolLedger) {
        return new PoolLedger(p);
    }
}

/// @notice Правило `_split` в двух путях: быстрый (`_splitInto`, ассемблер, суммы в uint128 — его судят фикстуры) и широкий
/// (`_splitWide`, через `_mulDiv`; в бухгалтерии сумм вне uint128 нет, и фикстуры его не исполняют). Их равенство на одних
/// входах — судья широкого пути.
contract SplitHarness is PoolLedgerBase {
    function both(int256 need, int256[] memory w, int256[] memory cap)
        external
        pure
        returns (int256[] memory g1, uint256[] memory i1, int256 r1, int256[] memory g2, uint256[] memory i2, int256 r2)
    {
        uint256 m = w.length;
        uint256 n1;
        uint256 n2;
        g1 = new int256[](m);
        i1 = new uint256[](m);
        (n1, r1) = _splitInto(need, w, cap, m, g1, i1, new int256[](m));
        g2 = new int256[](m);
        i2 = new uint256[](m);
        (n2, r2) = _splitWide(need, w, cap, m, g2, i2, new int256[](m));
        assembly {
            mstore(i1, n1)
            mstore(i2, n2)
        }
    }
}

/// @notice Свойства, которые дифференциал с эталоном не видит по построению: фикстуры не перемежают недельный расчёт
/// пачками с другими операциями. Бухгалтерию судит `contracts/diff/pool_ledger_diff.pytxt`, здесь — оболочка и короткие
/// сценарии правил ред. 9 (доплата соучастника, возврат, дыра пула); числа в них посчитаны эталоном.
contract PoolLedgerTest is Test {
    PoolLedger internal L;
    address internal constant T = address(0xfee);
    address internal constant A = address(0x1);
    address internal constant B = address(0x2);
    address internal constant C = address(0x3);
    uint8 internal constant NONE = 0;
    uint8 internal constant EVM = 1;

    function setUp() public {
        L = new PoolLedger(PoolLedger.Init(
            T, 1000, 5000, 2000, 3500, 200, 52, 0, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0
        ));
        L.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        L.deposit(B, 2000e6, address(0), NONE, EVM, bytes32(0));
        L.sweepToPerp();
        L.sizeOrder("x", 3000e6);
        L.fillOrder("x");
        L.closePosition("x", 300e6);
    }

    function test_monday_paged_blocks_every_other_change() public {
        toNextCalendarWeek();
        L.mondayBegin();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        L.deposit(C, 100e6, address(0), NONE, EVM, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        L.sizeOrder("y", 100e6);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        L.payQueue();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        L.monday();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        L.mondayBegin();
    }

    function test_monday_end_requires_everyone_settled() public {
        toNextCalendarWeek();
        L.mondayBegin();
        assertEq(L.mondayStep(1), 1, "one investor left");
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday: not all settled"));
        L.mondayEnd();
        assertEq(L.mondayStep(5), 0, "step past the end clamps");
        L.mondayEnd();
        assertEq(PoolLedgerViews(address(L)).status()[11], 0, "monday closed");
        L.deposit(C, 100e6, address(0), NONE, EVM, bytes32(0)); // открыт снова
    }

    /// @dev Пачка без единиц стояла бы на месте молча (на этапах 0-3, 5 отвечала «осталось > 0», на этапе 4 всё равно
    /// двигала расчёт) — отказ на любом этапе.
    function test_monday_step_zero_reverts() public {
        toNextCalendarWeek();
        L.mondayBegin();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "mondayStep: k == 0"));
        L.mondayStep(0);
        L.mondayStep(2);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "mondayStep: k == 0"));
        L.mondayStep(0);
        L.mondayEnd();
    }

    function test_monday_steps_need_open_monday() public {
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday not open"));
        L.mondayStep(1);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday not open"));
        L.mondayEnd();
    }

    function test_paged_equals_atomic() public {
        PoolLedger M = new PoolLedger(PoolLedger.Init(
            T, 1000, 5000, 2000, 3500, 200, 52, 0, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0
        ));
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 2000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("x", 3000e6);
        M.fillOrder("x");
        M.closePosition("x", 300e6);
        toNextCalendarWeek();
        L.mondayBegin();
        L.mondayStep(1);
        L.mondayStep(1);
        L.mondayEnd();
        toNextCalendarWeek();
        M.monday();
        assertEq(
            keccak256(abi.encode(PoolLedgerViews(address(L)).dump())),
            keccak256(abi.encode(PoolLedgerViews(address(M)).dump())),
            "paged state != atomic state"
        );
    }

    /// @dev Пакет A ревью: бизнес-отказ `withdraw` — КОДОМ при успешном вызове, а не отказом (хранилище зовёт бухгалтерию без
    /// `try`, и отказ транзакции остановил бы очередь), и состояние не тронуто. Коды — `W_AMOUNT` (1: ноль, сверх свободной
    /// доли, не держатель) и `W_RANGE` (2: вне uint128, в том числе «отрицательная» после приведения к int256). Дифференциал
    /// отказ кодом и отказ транзакции не различает (оба — «не принят»), поэтому форму исхода судит этот стенд.
    function test_withdraw_business_rejection_is_a_code_not_a_revert() public {
        PoolLedgerViews V = PoolLedgerViews(address(L));
        uint256 f = uint256(V.freeStake(A, false));
        bytes32 before = keccak256(abi.encode(V.dump()));
        uint256[5] memory amt = [f + 1, 0, uint256(1) << 128, (uint256(1) << 255) + 1, 1];
        address[5] memory who = [A, A, A, A, C];
        uint8[5] memory want = [uint8(1), 1, 2, 2, 1];
        for (uint256 i = 0; i < 5; i++) {
            (uint8 st, int256 paid, int256 queued) = L.withdraw(who[i], amt[i], false);
            assertEq(st, want[i], string.concat("status of case ", vm.toString(i)));
            assertEq(paid, 0);
            assertEq(queued, 0);
            assertEq(keccak256(abi.encode(V.dump())), before, "rejection by code leaves the state untouched");
        }
        (uint8 ok, int256 p, int256 q) = L.withdraw(A, f, false);
        assertEq(ok, 0, "exactly the free stake is executed");
        assertEq(p + q, int256(f));
    }

    function test_views_reach_ledger_storage() public {
        (address owner_, address treasury_,,,,,,) = PoolLedgerViews(address(L)).params();
        assertEq(owner_, address(this));
        assertEq(treasury_, T);
        assertEq(PoolLedgerViews(address(L)).sizingCapital(), 3000e6, "views read ledger storage via delegatecall");
    }

    function test_only_owner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "owner"));
        L.monday();
    }

    // --- редакция 9: доплата, возврат, дыра ------------------------------------------------------------------- //
    address internal constant POOL = address(0);

    function _fresh() internal returns (PoolLedger M) {
        M = new PoolLedger(PoolLedger.Init(
            T, 1000, 5000, 2000, 3500, 200, 52, 0, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0
        ));
    }

    function _dump(PoolLedger M) internal view returns (int256[] memory) {
        return PoolLedgerViews(address(M)).dump();
    }

    /// @dev Поле инвестора i из выгрузки: 10 счётчиков, число инвесторов, затем по 14 слов (1 — stake, 8 — cumPnl, 13 — uncovered).
    function _inv(int256[] memory d, uint256 i, uint256 field) internal pure returns (int256) {
        return d[11 + 14 * i + field];
    }

    /// @dev Хвост выгрузки — книга доплативших: число троек и тройки (должник, доплативший, сумма).
    function _assertBook(int256[] memory d, address[] memory debtor, address[] memory creditor, int256[] memory amt)
        internal
        pure
    {
        uint256 k = debtor.length;
        uint256 base = d.length - 3 * k;
        assertEq(d[base - 1], int256(k), "book size");
        for (uint256 i = 0; i < k; i++) {
            assertEq(d[base + 3 * i], int256(uint256(uint160(debtor[i]))), "book debtor");
            assertEq(d[base + 3 * i + 1], int256(uint256(uint160(creditor[i]))), "book creditor");
            assertEq(d[base + 3 * i + 2], amt[i], "book amount");
        }
    }

    /// @dev A 1000 и B 3000 в ордере 8000; A вывел и забрал 300; закрытие −3200: доля A −800 при 700 своих -> недостача 100,
    /// её доплачивает B (единственный соучастник). Числа — из эталона `GenLedger` на тех же вызовах.
    function _coverScenario(PoolLedger M, bool paged) internal {
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 3000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("x", 8000e6);
        M.fillOrder("x");
        M.withdraw(A, 300e6, false);
        M.claim(A);
        M.closePosition("x", -3200e6);
        PoolLedgerViews V = PoolLedgerViews(address(M));
        assertEq(V.weight(B), 500e6 - 3, "B weight minus the upper bound of his cover (hold 100 + dust 3)");
        assertEq(V.freeStake(B, false), 500e6 - 3, "B free minus hold");
        assertEq(V.projectedShortfall(), 100e6, "rev 9.1: gate counts the whole projected shortfall");
        if (paged) {
            toNextCalendarWeek();
            M.mondayBegin();
            while (M.mondayStep(1) != 0) {}
            M.mondayEnd();
        } else {
            toNextCalendarWeek();
            M.monday();
        }
    }

    function test_rev9_comate_covers_then_debtor_profit_pays_back() public {
        PoolLedger M = _fresh();
        _coverScenario(M, false);
        int256[] memory d = _dump(M);
        assertEq(_inv(d, 0, 1), 0, "A stake");
        assertEq(_inv(d, 0, 8), -700e6, "A cum_pnl: own loss 800, the 100 he did not carry");
        assertEq(_inv(d, 0, 13), 100e6, "A owes 100");
        assertEq(_inv(d, 1, 1), 500e6, "B stake after own loss and cover");
        assertEq(_inv(d, 1, 8), -2500e6, "B cum_pnl includes the cover");
        address[] memory deb = new address[](1);
        address[] memory cr = new address[](1);
        int256[] memory am = new int256[](1);
        (deb[0], cr[0], am[0]) = (A, B, 100e6);
        _assertBook(d, deb, cr, am);
        // депозит должника принят и долг не гасит; прибыль A по новому ордеру сначала возвращает B его 100
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        assertEq(_inv(_dump(M), 0, 13), 100e6, "deposit does not repay the debt");
        M.sweepToPerp();
        M.sizeOrder("y", 2000e6);
        M.fillOrder("y");
        M.closePosition("y", 300e6);
        toNextCalendarWeek();
        M.monday();
        d = _dump(M);
        assertEq(_inv(d, 0, 1), 1100e6, "A stake: 1000 + 200 - 100 back");
        assertEq(_inv(d, 0, 13), 0, "A debt repaid");
        assertEq(_inv(d, 1, 1), 700e6, "B stake: 500 + 100 profit + 100 back");
        assertEq(_inv(d, 1, 8), -2300e6, "B cum_pnl grows back");
        _assertBook(d, new address[](0), new address[](0), new int256[](0));
    }

    function test_rev9_paged_monday_equals_atomic_with_cover() public {
        PoolLedger M = _fresh();
        PoolLedger N = _fresh();
        _coverScenario(M, false);
        _coverScenario(N, true);
        assertEq(keccak256(abi.encode(_dump(M))), keccak256(abi.encode(_dump(N))), "paged state != atomic state");
    }

    /// @dev Скриптовая фикстура `scenario_204`: деньги кончились у всех, сделка съела ещё и лежащую в торговле комиссию ->
    /// дыра 150 (долг A и B по 75 перед ПУЛОМ); депозит новичка закрыт, пока дыра не погашена.
    function test_rev9_pool_hole_closes_deposits_until_repaid() public {
        PoolLedger M = _fresh();
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("W", 1000e6);
        M.fillOrder("W");
        M.closePosition("W", 1000e6);
        M.setWithdrawable(2800e6);
        toNextCalendarWeek();
        M.monday();
        M.sweepToPerp();
        M.sizeOrder("P", 2500e6);
        M.fillOrder("P");
        M.sizeOrder("Q", 500e6);
        M.fillOrder("Q");
        M.setWithdrawable(2800e6);
        M.withdraw(A, 1250e6, false);
        M.withdraw(B, 1250e6, false);
        M.claim(A);
        M.claim(B);
        M.closePosition("P", -1200e6);
        M.setWithdrawable(350e6);
        toNextCalendarWeek();
        M.monday();
        assertEq(PoolLedgerViews(address(M)).status()[5], 150e6, "shortfall = hole");
        address[] memory deb = new address[](2);
        address[] memory cr = new address[](2);
        int256[] memory am = new int256[](2);
        (deb[0], cr[0], am[0]) = (A, POOL, 75e6);
        (deb[1], cr[1], am[1]) = (B, POOL, 75e6);
        _assertBook(_dump(M), deb, cr, am);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "deposit: pool debt"));
        M.deposit(C, 500e6, address(0), NONE, EVM, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "cover_shortfall: amount"));
        M.coverShortfall(150e6 + 1, EVM, bytes32(0));
        assertEq(M.coverShortfall(50e6, EVM, bytes32(0)), 100e6);
        M.closePosition("Q", 400e6);
        M.setWithdrawable(750e6);
        toNextCalendarWeek();
        M.monday();
        assertEq(PoolLedgerViews(address(M)).status()[5], 0, "profit of the debtors repays the pool account");
        _assertBook(_dump(M), new address[](0), new address[](0), new int256[](0));
        M.deposit(C, 500e6, address(0), NONE, EVM, bytes32(0)); // открыт снова
    }

    function test_rev9_treasury_is_not_an_investor() public {
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "deposit: treasury is not an investor"));
        L.deposit(T, 100e6, address(0), NONE, EVM, bytes32(0));
    }

    function test_monday_impl_rejects_direct_calls() public {
        PoolLedgerMonday impl = new PoolLedgerMonday();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "owner"));
        impl.monday();
    }

    /// @dev Вознаграждение адреса из выгрузки: раздел `known` (адрес, claimable, claimable_reward, reward_cash, withdrawn_reward).
    function _rewardCash(int256[] memory d, address a) internal pure returns (int256) {
        uint256 base = 11 + 14 * uint256(d[10]);
        for (uint256 i = 0; i < uint256(d[base]); i++) {
            if (d[base + 1 + 5 * i] == int256(uint256(uint160(a)))) return d[base + 1 + 5 * i + 3];
        }
        return 0;
    }

    /// @dev Пыль закрытого поколения уходит в котёл ЦЕЛИКОМ и долг пула НЕ гасит (ред. 9: котёл — treasury). Дыра 204 с
    /// результатом −1200.000001: доли по −600.000001, пыль +1 микро. Числа — эталон.
    function test_rev9_pot_does_not_repay_pool_debt() public {
        PoolLedger M = _fresh();
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("W", 1000e6);
        M.fillOrder("W");
        M.closePosition("W", 1000e6);
        M.setWithdrawable(2800e6);
        toNextCalendarWeek();
        M.monday();
        M.sweepToPerp();
        M.sizeOrder("P", 2500e6);
        M.fillOrder("P");
        M.setWithdrawable(2800e6);
        M.withdraw(A, 1250e6, false);
        M.withdraw(B, 1250e6, false);
        M.claim(A);
        M.claim(B);
        M.closePosition("P", -1200e6 - 1);
        M.setWithdrawable(174999999);
        toNextCalendarWeek();
        M.monday();
        int256[] memory d = _dump(M);
        assertEq(PoolLedgerViews(address(M)).status()[5], 325000002, "shortfall");
        assertEq(_rewardCash(d, T), 500000001, "dust of the closed generation goes to the pot");
        address[] memory deb = new address[](2);
        address[] memory cr = new address[](2);
        int256[] memory am = new int256[](2);
        (deb[0], cr[0], am[0]) = (A, POOL, 162500001);
        (deb[1], cr[1], am[1]) = (B, POOL, 162500001);
        _assertBook(d, deb, cr, am);
    }

    /// @dev Стенд эталона R6 (находка CR-1): приглашённый B зарегистрирован РАНЬШЕ реферала-должника A. Реферальная доля A
    /// зачисляется после всех строк — его убыток её не съедает, недостачу A доплачивает B. Числа — эталон.
    function test_rev9_referral_share_after_all_rows() public {
        PoolLedger M = _fresh();
        M.initPartner(A);
        M.deposit(B, 1, A, NONE, EVM, bytes32(0));
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("G1", 1500e6);
        M.fillOrder("G1");
        M.deposit(B, 10_000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("G2", 3000e6);
        M.fillOrder("G2");
        M.setWithdrawable(9900000001);
        M.withdraw(A, 1000e6, false);
        M.claim(A);
        M.closePosition("G1", -1400e6);
        M.closePosition("G2", 1100e6);
        M.setWithdrawable(9600000001);
        toNextCalendarWeek();
        M.monday();
        int256[] memory d = _dump(M);
        assertEq(_rewardCash(d, A), 99999999, "referral share is A's money, his loss did not eat it");
        assertEq(_rewardCash(d, T), 400000002, "pot");
        assertEq(_inv(d, 1, 13), 679545454, "A owes B");
        assertEq(_inv(d, 0, 1), 9820454546, "B stake");
        address[] memory deb = new address[](1);
        address[] memory cr = new address[](1);
        int256[] memory am = new int256[](1);
        (deb[0], cr[0], am[0]) = (A, B, 679545454);
        _assertBook(d, deb, cr, am);
    }

    /// @dev Эталон `_addr`: нулевой адрес — ключ «долг перед пулом» во внешнем виде книги и «нет реферала»; участником он
    /// не бывает ни в одной операции с адресом участника.
    function test_zero_address_is_never_a_participant() public {
        bytes memory z = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "zero address");
        vm.expectRevert(z);
        L.deposit(address(0), 100e6, address(0), NONE, EVM, bytes32(0));
        vm.expectRevert(z);
        L.withdraw(address(0), 1, false);
        vm.expectRevert(z);
        L.withdraw(address(0), 1, true);
        vm.expectRevert(z);
        L.claim(address(0));
        vm.expectRevert(z);
        L.setPayoutMode(address(0), true);
        vm.expectRevert(z);
        L.setPartner(address(0), 1);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        vm.expectRevert(z);
        V.freeStake(address(0), false);
        vm.expectRevert(z);
        V.investorView(address(0));
        vm.expectRevert(z);
        V.referrerView(address(0));
        PoolLedger M = _fresh();
        vm.expectRevert(z);
        M.initPartner(address(0));
        PoolLedgerViews vi = new PoolLedgerViews();
        PoolLedgerMonday mi = new PoolLedgerMonday();
        PoolLedgerProj pj = new PoolLedgerProj();
        address em = address(new PoolLedgerEmergency());
        address bk = address(new PoolLedgerBook());
        LedgerFactory f = new LedgerFactory();
        vm.expectRevert(z);
        f.make(PoolLedger.Init(address(0), 1000, 5000, 2000, 3500, 200, 52, 0, 43, address(vi), address(mi), address(pj), em, address(this), bk, 0));
        // КЕ10: владелец — аргумент конструктора (вычисленный адрес хранилища); нулевой — отказ, а не бесхозная бухгалтерия
        vm.expectRevert(z);
        f.make(PoolLedger.Init(T, 1000, 5000, 2000, 3500, 200, 52, 0, 43, address(vi), address(mi), address(pj), em, address(0), bk, 0));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "proj: no code"));
        f.make(PoolLedger.Init(T, 1000, 5000, 2000, 3500, 200, 52, 0, 43, address(vi), address(mi), address(0xbeef), em, address(this), bk, 0));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "emergency: no code"));
        f.make(PoolLedger.Init(T, 1000, 5000, 2000, 3500, 200, 52, 0, 43, address(vi), address(mi), address(pj), address(0xbeef), address(this), bk, 0));
    }

    /// @dev Пакет безопасности (П2/П3): предел адресов обязателен и не выше границы из замера газа, минимум — в uint128,
    /// оба видны витриной `limits()`; `refundRef` сжигает ref в общем пространстве депозитов и `coverShortfall` и, как
    /// любая изменяющая операция, отклоняется, пока открыт недельный расчёт пачками (`_start`).
    function test_safety_pack_limits_and_refund_ref() public {
        address vi = address(new PoolLedgerViews());
        address mi = address(new PoolLedgerMonday());
        address pj = address(new PoolLedgerProj());
        address em = address(new PoolLedgerEmergency());
        address bk = address(new PoolLedgerBook());
        LedgerFactory f = new LedgerFactory();
        bytes memory bad = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "max_investors");
        vm.expectRevert(bad);
        f.make(PoolLedger.Init(T, 1000, 5000, 2000, 3500, 200, 52, 0, 0, vi, mi, pj, em, address(this), bk, 0));
        vm.expectRevert(bad);
        f.make(PoolLedger.Init(T, 1000, 5000, 2000, 3500, 200, 52, 0, type(uint256).max, vi, mi, pj, em, address(this), bk, 0));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "uint128"));
        f.make(PoolLedger.Init(T, 1000, 5000, 2000, 3500, 200, 52, 1 << 128, 3, vi, mi, pj, em, address(this), bk, 0));
        PoolLedger M = f.make(PoolLedger.Init(T, 1000, 5000, 2000, 3500, 200, 52, 10e6, 3, vi, mi, pj, em, address(this), bk, 0));
        (int256 md, uint256 mx) = PoolLedgerViews(address(M)).limits();
        assertEq(md, 10e6);
        assertEq(mx, 3);
        bytes memory used = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "ledger_ref used");
        M.refundRef("r1");
        vm.expectRevert(used);
        M.refundRef("r1");
        vm.expectRevert(used);
        M.deposit(A, 100e6, address(0), NONE, 0, "r1");
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "id32"));
        M.refundRef(bytes32(0));
        M.deposit(A, 100e6, address(0), NONE, 0, "r2");
        vm.expectRevert(used);
        M.refundRef("r2");
        toNextCalendarWeek();
        M.mondayBegin();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        M.refundRef("r3");
        M.mondayStep(10);
        M.mondayEnd();
        M.refundRef("r3");
    }

    /// @dev A9: предел адресов поднимается только владельцем, только вверх и не выше `MAX_INVESTORS_BOUND` (43); новый
    /// предел сразу действует в П2. `totalStake` — капитал под управлением (мера лимита TVL хранилища, A10).
    function test_raise_max_investors_up_only_to_bound_and_total_stake() public {
        LedgerFactory f = new LedgerFactory();
        PoolLedger M = f.make(PoolLedger.Init(T, 1000, 5000, 2000, 3500, 200, 52, 0, 2,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()),
            address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0));
        PoolLedgerViews V = PoolLedgerViews(address(M));
        M.deposit(A, 100e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 250e6, address(0), NONE, EVM, bytes32(0));
        assertEq(V.totalStake(), 350e6);
        bytes memory lim = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "deposit: investor limit");
        vm.expectRevert(lim);
        M.deposit(C, 100e6, address(0), NONE, EVM, bytes32(0));
        bytes memory bad = abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "max_investors");
        vm.expectRevert(bad);
        M.raiseMaxInvestors(2); // без изменения
        vm.expectRevert(bad);
        M.raiseMaxInvestors(1); // вниз
        vm.expectRevert(bad);
        M.raiseMaxInvestors(44); // выше границы газа
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "owner"));
        M.raiseMaxInvestors(3);
        M.raiseMaxInvestors(3);
        (, uint256 mx) = V.limits();
        assertEq(mx, 3);
        M.deposit(C, 100e6, address(0), NONE, EVM, bytes32(0));
        vm.expectRevert(lim);
        M.deposit(address(0x4), 100e6, address(0), NONE, EVM, bytes32(0));
        M.raiseMaxInvestors(43); // ровно граница
        M.withdraw(B, 50e6, false);
        assertEq(V.totalStake(), 400e6, "withdrawal leaves the capital");
        // A9 × 9.4: замороженная бухгалтерия неизменна целиком — подъём предела тоже отказ «frozen»
        vm.expectRevert(bad);
        M.raiseMaxInvestors(43); // без изменения — до заморозки «max_investors»
        M.emergencyFreeze();
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "frozen"));
        M.raiseMaxInvestors(43);
    }

    /// @dev Быстрый и широкий пути `_split` дают одно и то же (доли, порядок ключей, остаток) на случайных входах, где широкий
    /// путь достижим (need > 0): веса бывают нулевыми и отрицательными (кандидат исключён), вместимость упирается, пыль
    /// доливается по порядку.
    function testFuzz_split_fast_equals_wide(uint256 seed) public {
        SplitHarness h = new SplitHarness();
        uint256 m = 1 + seed % 12;
        int256[] memory w = new int256[](m);
        int256[] memory cap = new int256[](m);
        for (uint256 k = 0; k < m; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            w[k] = int256(r % 1000) - 100;
            cap[k] = int256((r >> 64) % 500);
        }
        int256 need = 1 + int256(uint256(keccak256(abi.encode(seed, "need"))) % 3000);
        int256 W;
        for (uint256 k = 0; k < m; k++) {
            if (w[k] > 0) W += w[k];
        }
        vm.assume(W > 0);
        (int256[] memory g1, uint256[] memory i1, int256 r1, int256[] memory g2, uint256[] memory i2, int256 r2) =
            h.both(need, w, cap);
        assertEq(r1, r2, "rest");
        assertEq(g1, g2, "give");
        assertEq(i1, i2, "insertion order");
    }

    /// @dev Контекст `hold` считает ТОЛЬКО PoolLedgerProj: бухгалтерия отдаёт `holdCtx()` проекциям через fallback на своей
    /// памяти (проектный убыток есть — контекст обходит обоих участников); прямой вызов реализации читает пустую память.
    function test_proj_impl_computes_hold_context_on_ledger_memory() public {
        PoolLedgerBase.HoldCtx memory c = PoolLedgerProj(address(L)).holdCtx();
        assertFalse(c.swept, "closed profit: no projected loss");
        L.sizeOrder("y", 3000e6);
        L.fillOrder("y");
        L.markPosition("y", -2900e6);
        c = PoolLedgerProj(address(L)).holdCtx();
        assertTrue(c.swept, "paper loss: context swept");
        assertEq(c.cap.length, 2, "both investors");
        assertGt(c.weight[1], 0, "weight of B");
        c = new PoolLedgerProj().holdCtx();
        assertFalse(c.swept, "direct call reads empty memory");
    }

    /// @dev Фаза 2 пачками: пока раздел недостачи не закончен, любая другая операция отклоняется, а `mondayEnd` — до этапа
    /// DONE. Сценарий `_coverScenario`: A — должник, B доплачивает.
    function test_phase2_steps_block_everything_until_done() public {
        PoolLedger M = _fresh();
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(B, 3000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("x", 8000e6);
        M.fillOrder("x");
        M.withdraw(A, 300e6, false);
        M.claim(A);
        M.closePosition("x", -3200e6);
        PoolLedgerViews V = PoolLedgerViews(address(M));
        toNextCalendarWeek();
        M.mondayBegin();
        // ред. 9.5: единицы строк — две строки адресов и ОДНО поколение строки должника A (его убыток по поколениям — пачками)
        assertEq(M.mondayStep(3), 1, "rows done: one debtor left for the co-participants stage");
        (uint256 stage, uint256 done, uint256 left, bool open) = V.mondayProgress();
        assertEq(stage, 3, "co-participants stage");
        assertEq(done, 0);
        assertEq(left, 1);
        assertTrue(open);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        M.deposit(C, 100e6, address(0), NONE, EVM, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        M.withdraw(B, 1, false);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday in progress"));
        M.claim(B);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday: not all settled"));
        M.mondayEnd();
        uint256 left2 = M.mondayStep(1);
        (stage,,,) = V.mondayProgress();
        assertEq(stage, 4, "pool stage is one call");
        assertEq(left2, 1);
        assertEq(M.mondayStep(1), 1, "nothing left for the pool: B covered all; one debtor's share waits for the book");
        (stage,,,) = V.mondayProgress();
        assertEq(stage, 6, "rev 9.2: netting stage writes the shares into the book");
        assertEq(M.mondayStep(1), 0, "A -> B written, B owes no investor: no cycle to search");
        (stage,,,) = V.mondayProgress();
        assertEq(stage, 7, "done");
        M.mondayEnd();
        (,,, open) = V.mondayProgress();
        assertFalse(open);
        assertEq(_inv(_dump(M), 0, 13), 100e6, "A owes 100 to B, as atomically");
    }

    // --- редакция 9.2: зачёт циклов книги ------------------------------------------------------------------------- //
    address internal constant RA = address(0xc1);
    address internal constant RB = address(0xc2);
    uint256 internal constant LIMIT = 25_000_000;

    /// @dev Недельный расчёт пачками по ОДНОЙ единице каждого этапа; каждая пачка <= 25 млн газа. Возвращает число пачек
    /// этапа возвратов (2) — работ очереди возвратов этого расчёта.
    function _mondayK1(PoolLedger M) internal returns (uint256 repayBatches, uint256 batches) {
        PoolLedgerViews V = PoolLedgerViews(address(M));
        toNextCalendarWeek();
        M.mondayBegin();
        while (true) {
            (uint256 stage,,,) = V.mondayProgress();
            if (stage == 7) break;
            uint256 g = gasleft();
            M.mondayStep(1);
            assertLe(g - gasleft(), LIMIT, "one batch of the weekly settlement <= 25M gas");
            batches++;
            if (stage == 2) repayBatches++;
            assertLe(batches, 100, "weekly settlement finishes in a bounded number of batches");
        }
        M.mondayEnd();
    }

    /// @dev Сценарий ревьюера (фикстура `scenario_221`, долларовая шкала). Неделя 1: B доплатил недостачу A — A должен B 50.
    /// Неделя 2: A внёс 5000 (долг депозит не гасит) и доплатил недостачу B 75.7 — запись B -> A замыкает цикл, зачёт на 50:
    /// книга B -> A 25.7. Неделя 3: прибыль A 1 микро — у A долга нет, она уходит в его капитал. До ред. 9.2 этот микро
    /// ходил A -> B -> A и за круг гасил по микро из каждого долга: 2·50·10^6 = 10^8 работ этапа возвратов, расчёт не кончался
    /// ни атомарно, ни пачками. Теперь каждый расчёт — конечное число пачек <= 25 млн. Числа — трасса эталона.
    function test_rev92_reviewer_cycle_settles_in_bounded_batches() public {
        PoolLedger M = new PoolLedger(PoolLedger.Init(
            T, 1000, 5000, 2000, 3500, 200, 3, 0, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0
        ));
        M.initPartner(A);
        M.deposit(RA, 100e6, address(0), NONE, EVM, bytes32(0));
        M.deposit(RB, 2000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("o1", 2100e6);
        M.fillOrder("o1");
        M.withdraw(RA, 100e6, false);
        M.setWithdrawable(1890e6);
        M.payQueue();
        M.claim(RA);
        M.closePosition("o1", -1785e6);
        M.setWithdrawable(105e6);
        _mondayK1(M);
        address[] memory deb = new address[](1);
        address[] memory cr = new address[](1);
        int256[] memory am = new int256[](1);
        (deb[0], cr[0], am[0]) = (RA, RB, 50e6);
        _assertBook(_dump(M), deb, cr, am);
        M.deposit(RA, 5000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("o2", 5250e6);
        M.fillOrder("o2");
        M.withdraw(RB, 250e6, false);
        M.setWithdrawable(4725e6);
        M.payQueue();
        M.claim(RB);
        M.closePosition("o2", -3427.2e6);
        M.setWithdrawable(1297.8e6);
        _mondayK1(M);
        int256[] memory d = _dump(M);
        (deb[0], cr[0], am[0]) = (RB, RA, 25.7e6);
        _assertBook(d, deb, cr, am);
        assertEq(_inv(d, 0, 13), 0, "A's debt netted against B's");
        assertEq(_inv(d, 1, 13), 25.7e6, "B owes A the rest of the cycle");
        assertEq(_inv(d, 0, 1), 1660.3e6, "A stake");
        M.sweepToPerp();
        M.sizeOrder("o3", 100e6);
        M.fillOrder("o3");
        M.closePosition("o3", 1);
        M.setWithdrawable(1494270001);
        (uint256 repay, uint256 batches) = _mondayK1(M);
        assertEq(repay, 0, "A owes nobody: no repayment work at all (rev 9.1: 1e8 works around the cycle)");
        assertLe(batches, 10, "bounded");
        d = _dump(M);
        _assertBook(d, deb, cr, am);
        assertEq(_inv(d, 0, 1), 1660300001, "the micro of profit goes to A's capital");
    }

    // --- ред. 9.3 / 9.3.1 / 9.3.1.1: частичное закрытие, `partR`, резерв (числа — эталон `vault_accounting.pytxt`) ---------- //
    function _ledgerWith(uint256 bufferBps, uint256 holdBps) internal returns (PoolLedger M) {
        M = new PoolLedger(PoolLedger.Init(
            T, bufferBps, 5000, 2000, holdBps, 200, 52, 0, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0
        ));
    }

    /// @dev (нотионал, марк, partR) ордера `pid` из выгрузки: слова ордера — pid, gen, state, notional, upnl, sized_week, partR.
    function _orderOf(PoolLedger M, bytes32 pid) internal view returns (int256 notional, int256 upnl, int256 partR) {
        int256[] memory d = PoolLedgerViews(address(M)).dump();
        uint256 o = d.length - 7;
        while (d[o] != int256(uint256(pid))) o--;
        return (d[o + 3], d[o + 4], d[o + 6]);
    }

    /// @dev Требование переноса (спека 8.12.1, ревью 9.3.1 п. 5): `partR` — int256. Две части по −(2^127 − 1) на ОДНОМ ордере
    /// с закрытием другого ордера поколения в +(2^127 − 1) между ними эталон принимает: границы судят `upnl + partR` (−X) и
    /// `R − P_g` (X), а сумма частей — −(2^128 − 2). Резерв комиссии читает −доля(partR): s·|p| = 2^255 − 2^128 — в uint256.
    /// Эталон: свободное A = 1, partR = −(2^128 − 2).
    function test_rev931_part_sum_beyond_int128_is_accepted() public {
        PoolLedger M = _ledgerWith(0, 3500);
        int256 X = type(int128).max;
        M.deposit(A, uint256(1) << 127, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("p", 2e6);
        M.fillOrder("p");
        M.sizeOrder("q", 1e6);
        M.fillOrder("q");
        M.reducePosition("p", -X, 1e6, 0);
        M.closePosition("q", X);
        M.reducePosition("p", -X, 0.5e6, X);
        (int256 n, int256 u, int256 part) = _orderOf(M, "p");
        assertEq(n, 0.5e6, "notional of the rest");
        assertEq(u, X, "mark of the rest");
        assertEq(part, -2 * X, "sum of parts is below int128");
        assertEq(PoolLedgerViews(address(M)).freeStake(A, false), 1, "free stake (reference)");
    }

    /// @dev R931-2 эталона: границы сделки целиком. q закрыт в −X, у p часть +X: марк X проходит у сделки (R + марки = X), но
    /// марк с результатом частей 2X — отказ, как и вторая часть +X; марк 10 принят, partR = X.
    function test_rev931_part_bounds() public {
        PoolLedger M = _ledgerWith(0, 3500);
        int256 X = type(int128).max - 10;
        M.deposit(A, uint256(1) << 127, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("p", 1e6);
        M.fillOrder("p");
        M.sizeOrder("q", 1e6);
        M.fillOrder("q");
        M.reducePosition("p", X, 0.5e6, 0);
        M.closePosition("q", -X);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "int128"));
        M.markPosition("p", X);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "int128"));
        M.reducePosition("p", X, 0.25e6, 0);
        M.markPosition("p", 10);
        (int256 n, int256 u, int256 part) = _orderOf(M, "p");
        assertEq(n, 0.5e6, "notional");
        assertEq(u, 10, "mark");
        assertEq(part, X, "partR");
    }

    /// @dev R931-3 эталона (ред. 9.3.1.1, Н2): резерв не завышен. A 1000, удержания нет; p 500 — часть +200, остаток 250 с марком
    /// −200 (итог сделки 0); q 500 — марк +300; понедельник. Комиссия к удержанию — 0, свободное 1200 (формула 9.3.1 клала
    /// остаток p в общий бумажный `min` с маркой q: комиссия 100, свободное 1100).
    function test_rev9311_reserve_not_inflated() public {
        PoolLedger M = _ledgerWith(1000, 0);
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("p", 500e6);
        M.fillOrder("p");
        M.sizeOrder("q", 500e6);
        M.fillOrder("q");
        M.reducePosition("p", 200e6, 250e6, -200e6);
        M.markPosition("q", 300e6);
        M.setWithdrawable(1200e6);
        toNextCalendarWeek();
        M.monday();
        assertEq(PoolLedgerViews(address(M)).freeStake(A, false), 1200e6, "free stake: reserve 0 (9.3.1 formula: 1100)");
    }

    /// @dev R931-1 эталона (худший порядок закрытий): A 1000; p 1000 — часть +200 (остаток 500, марк 0), q 1000 — часть −100
    /// (остаток 500, марк +150); понедельник. Закрыть p, оставив q, — база +200: резерв комиссии 100 (часть q −100 вне базы
    /// поднимает её, её бумажный u + p = +50 гасит только прочий убыток), свободное 1000. Без −доли(p) части в минус резерв
    /// был бы 50 и свободное 1050.
    function test_rev931_reserve_worst_order() public {
        PoolLedger M = _ledgerWith(1000, 3500);
        M.deposit(A, 1000e6, address(0), NONE, EVM, bytes32(0));
        M.sweepToPerp();
        M.sizeOrder("p", 1000e6);
        M.fillOrder("p");
        M.sizeOrder("q", 1000e6);
        M.fillOrder("q");
        M.reducePosition("p", 200e6, 500e6, 0);
        M.reducePosition("q", -100e6, 500e6, 150e6);
        M.setWithdrawable(1150e6);
        toNextCalendarWeek();
        M.monday();
        assertEq(PoolLedgerViews(address(M)).freeStake(A, false), 1000e6, "free stake: reserve 100 (reference)");
    }
}
