// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {toNextCalendarWeek} from "./CalendarWeek.sol";
import {PoolLedger, PoolLedgerViews, PoolLedgerMonday, PoolLedgerProj, PoolLedgerEmergency, PoolLedgerBook} from "../src/PoolLedger.sol";
import {LedgerFactory} from "./PoolLedger.t.sol";
import {PoolDeployHarness} from "./PoolVault.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {HyperCore} from "hyper-evm-sim/HyperCore.sol";
import {CoreSimulatorLib} from "hyper-evm-sim/CoreSimulatorLib.sol";
import {PoolVault} from "../src/PoolVault.sol";
import {PoolVaultEmergency} from "../src/PoolVaultEmergency.sol";
import {TradingLeg} from "../src/TradingLeg.sol";

/// @notice Стенды ревьюера фазы 2 (находки M1, M2): ни одна транзакция недельного расчёта не дороже 25 млн газа, когда
/// очередь длинная (m заявок на держателя) и когда поколение — на каждый ордер. Keeper берёт пачку по витрине
/// `mondayProgress`: этап — и под него `k`. Сборка состояния идёт без учёта газа (`pauseGasMetering`); меряется каждый
/// вызов расчёта. Бухгалтерию здесь не судят (её судит дифференциал) — только газ и то, что расчёт доходит до конца.
contract PoolLedgerGasTest is Test {
    uint256 internal constant LIMIT = 25_000_000;
    uint256 internal constant TX = 21_000 + 16 * 36; // база транзакции и calldata вызова keeper'а — их стенд не видит
    address internal constant T = address(0xfee);
    uint8 internal constant NONE = 0;
    uint8 internal constant EVM = 1;
    uint256 internal constant USD = 1e6;

    PoolLedger internal L;
    uint256 internal worst; //   наибольший газ одной транзакции расчёта
    string internal worstAt;

    function _addr(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    /// @dev Ред. 9.5: предел поколений стендов — граница контракта (`MAX_GENS_BOUND`); хранилище без предела не связывается.
    uint256 internal constant GENS = 1000;

    function _ledger(uint256 bufferBps) internal returns (PoolLedger) {
        return _ledgerG(bufferBps, GENS);
    }

    /// @dev Бухгалтерия стенда с пределом поколений `maxGens` (0 — без предела: неделя в тысячи поколений без расчёта).
    function _ledgerG(uint256 bufferBps, uint256 maxGens) internal returns (PoolLedger) {
        return new PoolLedger(PoolLedger.Init(
            T, bufferBps, 5000, 2000, 3500, 200, 52, 0, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()),
            address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), maxGens
        ));
    }

    /// @dev Пачка этапа по витрине: копия MS_SNAP (ред. 9.4, этап 8), строки и реферальные доли — `kRows`, тяжёлые этапы фазы 2 —
    /// по одной единице.
    function _k(uint256 stage, uint256 kRows) internal pure returns (uint256) {
        return stage <= 1 || stage == 8 ? kRows : 1;
    }


    /// @dev Недельный расчёт пачками, как keeper: `mondayStep(k)` до этапа 7 (DONE), затем `mondayEnd`; каждый вызов меряется.
    function _mondayPaged(uint256 kRows) internal {
        vm.resumeGasMetering();
        uint256 g = gasleft();
        toNextCalendarWeek();
        L.mondayBegin();
        _note(g - gasleft(), "mondayBegin");
        if (g - gasleft() + TX > worstBegin) worstBegin = g - gasleft() + TX; // ред. 9.4: в нём копия MS_SNAP
        while (true) {
            (uint256 stage,,,) = PoolLedgerViews(address(L)).mondayProgress();
            if (stage == 7) break;
            g = gasleft();
            L.mondayStep(_k(stage, kRows));
            _note(g - gasleft(), string.concat("mondayStep[", vm.toString(stage), "]"));
        }
        g = gasleft();
        L.mondayEnd();
        _note(g - gasleft(), "mondayEnd");
        vm.pauseGasMetering();
    }

    function _note(uint256 used, string memory what) internal {
        used += TX;
        if (used > worst) (worst, worstAt) = (used, what);
        assertLe(used, LIMIT, what);
    }

    /// @dev M1: один должник (адрес 0) и 199 держателей, у каждого по `m` заявок в 1 микро, поданных ПО КРУГУ (id
    /// перемешаны); заявки держит удержание большого открытого ордера. Убыток другого ордера даёт должнику недостачу —
    /// её доплачивают все держатели (каждое снятие доплаты раньше обходило всю очередь, находка M1). Затем большой ордер
    /// закрывается в ноль, и очередь платится при ликвидности на половину заявок (упор посреди потока) и на всё.
    function _queueStand(uint256 m) internal {
        vm.pauseGasMetering();
        uint256 n = BOUND;
        L = _ledger(0);
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        L.sizeOrder("loss", n * 1000 * USD);
        L.fillOrder("loss");
        L.setWithdrawable(600 * USD);
        L.withdraw(_addr(0), 600 * USD, false);
        L.claim(_addr(0));
        L.setWithdrawable(0);
        L.sizeOrder("big", n * 3000 * USD);
        L.fillOrder("big");
        for (uint256 r = 0; r < m; r++) {
            for (uint256 i = 1; i < n; i++) {
                L.withdraw(_addr(i), 1, false);
            }
        }
        L.closePosition("loss", -int256(n * 600 * USD));
        L.setWithdrawable(n * 100 * USD);
        _mondayPaged(50);
        int256[13] memory st = PoolLedgerViews(address(L)).status();
        assertEq(st[11], 0, "monday closed");
        L.closePosition("big", 0);
        L.setWithdrawable((n - 1) * m / 2);
        vm.resumeGasMetering();
        uint256 g = gasleft();
        L.payQueue();
        uint256 used = g - gasleft();
        vm.pauseGasMetering();
        if (m != 0) _note(used, "payQueue (cut mid-stream)");
        L.setWithdrawable(n * 100 * USD);
        vm.resumeGasMetering();
        g = gasleft();
        L.payQueue();
        used = g - gasleft();
        vm.pauseGasMetering();
        _note(used, "payQueue");
        _mondayPaged(50);
        emit log_named_uint(string.concat("M1 m=", vm.toString(m), ": max gas, ", worstAt), worst);
    }

    function test_m1_queue_m200_every_tx_under_25m() public {
        _queueStand(200);
    }

    /// @dev M2: 200 участников, `G` ордеров, каждый в СВОЁМ поколении (метка в минус меняет веса следующего снимка);
    /// каждый 10-й выводит почти всё; закрытие первой половины с убытком 0.85 капитала — 20 должников, у каждого убыток в
    /// G/2 поколениях (раздел соучастников — по единице (должник, поколение)). Второй расчёт закрывает G/2 мёртвых поколений.
    function _gensStand(uint256 G) internal {
        vm.pauseGasMetering();
        uint256 n = BOUND;
        L = _ledger(1000);
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        uint256 nj = n * 1500 * USD / G;
        for (uint256 j = 0; j < G; j++) {
            bytes32 pid = bytes32(abi.encodePacked("g", vm.toString(j)));
            L.sizeOrder(pid, nj);
            L.fillOrder(pid);
            L.markPosition(pid, -int256((j + 1) * USD));
            if (parts) _reduceMeasured(pid, -int256((j + 1) * USD / 2), nj / 2, -int256((j + 1) * USD / 2));
        }
        assertEq(PoolLedgerViews(address(L)).status()[2], int256(G), "one generation per order");
        L.setWithdrawable(n * 800 * USD);
        for (uint256 i = 0; i < n; i += 10) {
            L.withdraw(_addr(i), 475 * USD, false);
            L.claim(_addr(i));
        }
        uint256 half = G / 2;
        for (uint256 j = 0; j < half; j++) {
            L.closePosition(bytes32(abi.encodePacked("g", vm.toString(j))), -int256(n * 850 * USD / half));
        }
        _mondayPaged(20);
        for (uint256 j = half; j < G; j++) {
            L.closePosition(bytes32(abi.encodePacked("g", vm.toString(j))), 0);
        }
        _mondayPaged(20);
        int256[] memory d = PoolLedgerViews(address(L)).dump();
        assertEq(d[11 + 14 * uint256(d[10]) + 1 + 5 * _holders(d)], 0, "no live generations after the second monday");
        emit log_named_uint(string.concat("M2 G=", vm.toString(G), ": max gas, ", worstAt), worst);
        if (parts) emit log_named_uint("  reducePosition max", worstReduce);
    }

    /// @dev Число держателей плоскостей в выгрузке (раздел после инвесторов).
    function _holders(int256[] memory d) internal pure returns (uint256) {
        return uint256(d[11 + 14 * uint256(d[10])]);
    }

    function test_m2_gens60_every_tx_under_25m() public {
        _gensStand(60);
    }

    function test_m2_gens20_every_tx_under_25m() public {
        _gensStand(20);
    }

    /// @dev Ред. 9.3: часть (`reducePosition`) меряется как любой вызов keeper'а — на тех же худших входах.
    function _reduceMeasured(bytes32 pid, int256 realized, uint256 notional, int256 upnl) internal {
        vm.resumeGasMetering();
        uint256 g = gasleft();
        L.reducePosition(pid, realized, notional, upnl);
        uint256 used = g - gasleft();
        vm.pauseGasMetering();
        if (used + TX > worstReduce) worstReduce = used + TX;
        if (strict) _note(used, "reducePosition");
        else _rec(used, "reducePosition");
    }

    /// @dev Ред. 9.3/9.3.1: тот же стенд M2, у ордера КАЖДОГО поколения — часть в минус (половина нотионала): база комиссии
    /// каждой строки расчёта видит D и U с частями во всех G поколениях, закрытия первой половины — ордера с частью.
    function test_rev93_m2_gens60_parts_every_tx_under_25m() public {
        parts = true;
        _gensStand(60);
    }

    function test_rev93_m2_gens20_parts_every_tx_under_25m() public {
        parts = true;
        _gensStand(20);
    }

    /// @dev Ред. 9.2, худший достижимый поиск пути зачёта при N=200: книга — цепочка A_0 -> A_1 -> … -> A_199 (звено i:
    /// ордер только на A_i и A_{i+1}, A_i выводит всё, кроме 10, его недостачу доплачивает A_{i+1}). Неделя замыкания: A_0
    /// вносит 1000, A_199 «выходит» до убытка, его недостачу доплачивает A_0: запись A_199 -> A_0 замыкает цикл через ВЕСЬ
    /// пул — поиск открывает все 200 вершин, путь длины 199, минимум снимается с 200 рёбер одной единицей этапа зачёта.
    /// Следующая неделя — прибыль по оставшейся ацикличной книге. Каждая транзакция расчёта <= 25 млн.
    function test_rev92_cycle_through_whole_pool_every_tx_under_25m() public {
        vm.pauseGasMetering();
        uint256 n = BOUND;
        L = new PoolLedger(PoolLedger.Init(T, 0, 5000, 2000, 0, 200, 52, 0, 43,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0));
        PoolLedgerViews V = PoolLedgerViews(address(L));
        L.deposit(_addr(0), 100 * USD, address(0), NONE, EVM, bytes32(0));
        L.deposit(_addr(1), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        for (uint256 i = 0; i < n - 1; i++) {
            if (i != 0) L.deposit(_addr(i + 1), 1000 * USD, address(0), NONE, EVM, bytes32(0));
            L.sweepToPerp();
            _closeWeek(V, _addr(i), bytes32(abi.encodePacked("c", vm.toString(i))));
            toNextCalendarWeek();
            L.monday();
        }
        int256[] memory d = V.dump();
        assertEq(d[d.length - 1 - 3 * (n - 1)], int256(n - 1), "book is a chain of n-1 links");
        L.deposit(_addr(0), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        L.sweepToPerp();
        _closeWeek(V, _addr(n - 1), "ring");
        _mondayPaged(50);
        d = V.dump();
        assertEq(d[11 + 13], 0, "A_0 owes nobody: the cycle through the whole pool is netted on its smallest edge");
        assertGt(d[11 + 14 * (n - 1) + 13], 0, "A_199 still owes A_0 the rest of the ring edge");
        L.sweepToPerp();
        uint256 cap = uint256(V.freeStake(_addr(0), false) + V.freeStake(_addr(n - 1), false));
        L.sizeOrder("win", 2 * cap);
        L.fillOrder("win");
        L.closePosition("win", int256(cap));
        _mondayPaged(50);
        emit log_named_uint(string.concat("rev 9.2 cycle of n=", vm.toString(n), ": max gas, ", worstAt), worst);
    }

    /// @dev Неделя звена: ордер 3x (капитал «выходящего» + 1000), он выводит всё, кроме 10, убыток 0.6 — его недостача.
    function _closeWeek(PoolLedgerViews V, address out, bytes32 pid) internal {
        uint256 s = uint256(V.freeStake(out, false));
        uint256 nt = 3 * (s + 1000 * USD);
        L.sizeOrder(pid, nt);
        L.fillOrder(pid);
        L.setWithdrawable(s);
        L.withdraw(out, s - 10 * USD, false);
        L.claim(out);
        L.closePosition(pid, -int256(nt / 5));
        L.setWithdrawable(0);
    }

    // --- ред. 9.2.1 / 9.2.2: проекция фазы 2 — вес и гейты видят возврат того же расчёта -------------------------------- //

    bool internal strict = true; // false — замер без отказа (скан по n печатает газ и за границей)
    uint256 internal worstReduce; // наибольший газ `reducePosition` стенда (печатается в итоге стенда)
    bool internal parts; //          ред. 9.3: у ордеров стенда — части (`reducePosition`), база комиссии с частями
    uint256 internal worstBegin; //  ред. 9.4: наибольший газ `mondayBegin` (копия MS_SNAP)
    uint256 internal constant BOUND = 43; // MAX_INVESTORS_BOUND контракта (README «Газ ред. 9.2.1»)

    function _rec(uint256 used, string memory what) internal {
        used += TX;
        if (used > worst) (worst, worstAt) = (used, what);
        emit log_named_uint(what, used);
        if (strict) assertLe(used, LIMIT, what);
    }

    function _free(PoolLedgerViews V, address a) internal view returns (uint256) {
        int256 s = V.freeStake(a, false);
        return s > 0 ? uint256(s) : 0;
    }

    /// @dev Состояние «обратного треугольника» (`_triangle`) без замеров: книга, `G` поколений с бумажным убытком, прибыль
    /// недели. Ледгер `L`, владелец — стенд.
    function _triangleBook(uint256 n, uint256 G) internal {
        vm.pauseGasMetering();
        worst = 0;
        L = _ledger(0);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        L.deposit(_addr(0), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        for (uint256 k = 1; k < n; k++) {
            L.deposit(_addr(k), 1000 * USD, address(0), NONE, EVM, bytes32(0));
            L.sweepToPerp();
            uint256 nt = uint256(V.sizingCapital()) / 10;
            bytes32 pid = bytes32(abi.encodePacked("t", vm.toString(k)));
            L.sizeOrder(pid, nt);
            L.fillOrder(pid);
            uint256 free = _free(V, _addr(k));
            L.setWithdrawable(free);
            L.withdraw(_addr(k), free, false);
            L.claim(_addr(k));
            L.closePosition(pid, -int256(nt * 99 / 100));
            L.setWithdrawable(0);
            toNextCalendarWeek();
            L.monday();
            for (uint256 j = 0; j <= k; j++) {
                uint256 s = _free(V, _addr(j));
                if (s < 1000 * USD) L.deposit(_addr(j), 1000 * USD - s, address(0), NONE, EVM, bytes32(0));
            }
        }
        int256[] memory d = V.dump();
        uint256 e = (n - 1) * n / 2;
        assertEq(uint256(d[d.length - 1 - 3 * e]), e, "inverse triangle: i owes every j < i");
        L.sweepToPerp();
        for (uint256 j = 0; j < G; j++) {
            bytes32 pid = bytes32(abi.encodePacked("g", vm.toString(j)));
            L.sizeOrder(pid, n * 10 * USD);
            L.fillOrder(pid);
            L.markPosition(pid, -int256((j + 1) * USD));
            if (parts) _reduceMeasured(pid, -int256((j + 1) * USD / 2), n * 5 * USD, -int256((j + 1) * USD / 2));
        }
        L.sizeOrder("win", n * 100 * USD);
        L.fillOrder("win");
        // ред. 9.3: прибыль недели — частью (ордер открыт, часть в плюс: резерв комиссии и D у каждого адреса)
        if (parts) _reduceMeasured("win", int256(n * USD), n * 50 * USD, 0);
        else L.closePosition("win", int256(n * USD));
    }

    /// @dev Худший проверенный вход проекции фазы 2 (спека 8.11.1, «обратный треугольник»; та же конструкция — сценарий
    /// дифференциала `triangle_012`). Неделя k: входит A_k, ордер на десятую часть капитала, A_k выводит свободное до
    /// закрытия, убыток 99 % — его недостачу 64 USD доплачивают ВСЕ прежние соучастники поколения, и A_k должен каждому;
    /// затем все пополняют капитал до 1000 (A_k — тоже держатель, его долг остаётся). Итог — книга «i должен всем j < i»,
    /// n(n − 1)/2 рёбер. Неделя замера: `G` живых поколений с бумажным убытком (контекст `hold` гейтов считается), ордер
    /// `win` с прибылью по 1 USD на адрес — каждый должник гасит 1 USD из 64, возврат идёт доплатившим, а они сами должники:
    /// возврат идёт дальше по цепочке волнами (эталон: ~3.1·n² кандидатов `_split`, ~8n работ). Меряются транзакции,
    /// которые считают проекцию: `sizeOrder` (вес), `withdraw`, `claim` и `payQueue` (контекст `hold`), `deposit`, и расчёт.
    function _triangle(uint256 n, uint256 G) internal returns (uint256) {
        _triangleBook(n, G);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        vm.resumeGasMetering();
        uint256 g = gasleft();
        L.sizeOrder("probe", n * USD);
        _rec(g - gasleft(), "sizeOrder (weights: phase-2 projection)");
        vm.pauseGasMetering();
        L.setWithdrawable(n * 100 * USD);
        // заявка «вывести всё» хранилища: `freeStake`, затем `withdraw` на всю долю — две проекции в одной транзакции.
        // Только печать (в границу 25 млн не входит: её судят отдельные вызовы); состояние откатывается.
        uint256 snap = vm.snapshotState();
        vm.resumeGasMetering();
        g = gasleft();
        L.withdraw(_addr(1), _free(V, _addr(1)), false);
        uint256 allGas = g - gasleft() + TX;
        vm.pauseGasMetering();
        emit log_named_uint("withdraw ALL (freeStake + withdraw, as PoolVault)", allGas);
        vm.revertToState(snap);
        vm.resumeGasMetering();
        g = gasleft();
        L.withdraw(_addr(1), 10 * USD, false);
        _rec(g - gasleft(), "withdraw (hold context)");
        g = gasleft();
        L.claim(_addr(1));
        _rec(g - gasleft(), "claim (hold context)");
        g = gasleft();
        L.deposit(_addr(1), 10 * USD, address(0), NONE, EVM, bytes32(0));
        _rec(g - gasleft(), "deposit");
        g = gasleft();
        L.payQueue();
        _rec(g - gasleft(), "payQueue (hold context)");
        if (parts) {
            g = gasleft();
            L.markPosition("g0", -int256(USD));
            _rec(g - gasleft(), "markPosition (order with a part)");
            g = gasleft();
            L.closePosition("win", 0);
            _rec(g - gasleft(), "closePosition (order with a part)");
            vm.pauseGasMetering();
            L.setWithdrawable(n * 100 * USD);
            _mondayPaged(50);
            vm.resumeGasMetering();
        }
        vm.pauseGasMetering();
        emit log_named_uint(string.concat("9.2.1 triangle n=", vm.toString(n), " G=", vm.toString(G), parts ? " parts" : "",
            ": max gas, ", worstAt), worst);
        if (parts) emit log_named_uint("  reducePosition max", worstReduce);
        return worst;
    }

    /// @dev Граница `MAX_INVESTORS_BOUND`: на худшем проверенном входе при n = BOUND каждая транзакция, считающая проекцию,
    /// <= 25 млн (замер 18.10: N_MAX = 56 при G = 3; граница 43 — заявка «вывести всё» хранилища, README «Газ заявок»); адрес BOUND + 1
    /// бухгалтерия не принимает, предел конструктора выше границы — отказ.
    function test_rev921_triangle_at_bound_every_tx_under_25m() public {
        _triangle(BOUND, 3);
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "deposit: investor limit"));
        L.deposit(_addr(BOUND), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        LedgerFactory f = new LedgerFactory();
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "max_investors"));
        f.make(PoolLedger.Init(T, 0, 5000, 2000, 3500, 200, 52, 0, BOUND + 1,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0));
    }

    /// @dev Цепочка при n = BOUND (книга той же формы, что у стенда цикла: A_i должен A_{i+1}): прибыль всех — возврат
    /// идёт по всем звеньям; вес `sizeOrder` и контекст `hold` (поколение с бумажным убытком рядом) видят его.
    /// @dev Ред. 9.3/9.3.1 на худшем входе проекции: тот же треугольник при n = BOUND, у G = 3 поколений с бумажным убытком —
    /// части в минус, прибыль недели — частью ордера `win` (часть в плюс, ордер открыт): каждый адрес несёт D, U и резерв
    /// с частями во всех живых поколениях. Каждая транзакция (часть, вес, гейты, марк, закрытие, расчёт) <= 25 млн.
    function test_rev93_triangle_parts_at_bound_every_tx_under_25m() public {
        parts = true;
        _triangle(BOUND, 3);
    }

    function test_rev921_chain_projection_every_tx_under_25m() public {
        vm.pauseGasMetering();
        worst = 0;
        uint256 n = BOUND;
        L = new PoolLedger(PoolLedger.Init(T, 0, 5000, 2000, 0, 200, 52, 0, BOUND,
            address(new PoolLedgerViews()), address(new PoolLedgerMonday()), address(new PoolLedgerProj()), address(new PoolLedgerEmergency()), address(this), address(new PoolLedgerBook()), 0));
        PoolLedgerViews V = PoolLedgerViews(address(L));
        L.deposit(_addr(0), 100 * USD, address(0), NONE, EVM, bytes32(0));
        L.deposit(_addr(1), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        for (uint256 i = 0; i < n - 1; i++) {
            if (i != 0) L.deposit(_addr(i + 1), 1000 * USD, address(0), NONE, EVM, bytes32(0));
            L.sweepToPerp();
            _closeWeek(V, _addr(i), bytes32(abi.encodePacked("c", vm.toString(i))));
            toNextCalendarWeek();
            L.monday();
        }
        for (uint256 i = 0; i < n - 1; i++) {
            L.deposit(_addr(i), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        L.sizeOrder("loss", n * 10 * USD);
        L.fillOrder("loss");
        L.markPosition("loss", -int256(USD));
        L.sizeOrder("win", n * 100 * USD);
        L.fillOrder("win");
        L.closePosition("win", int256(n * 50 * USD));
        vm.resumeGasMetering();
        uint256 g = gasleft();
        L.sizeOrder("probe", n * USD);
        _rec(g - gasleft(), "chain: sizeOrder (weights: phase-2 projection)");
        vm.pauseGasMetering();
        L.setWithdrawable(n * 10 * USD);
        vm.resumeGasMetering();
        g = gasleft();
        L.withdraw(_addr(1), 10 * USD, false);
        _rec(g - gasleft(), "chain: withdraw (hold context)");
        g = gasleft();
        L.claim(_addr(1));
        _rec(g - gasleft(), "chain: claim (hold context)");
        vm.pauseGasMetering();
        emit log_named_uint(string.concat("9.2.1 chain n=", vm.toString(n), ": max gas, ", worstAt), worst);
    }

    /// @dev Ред. 9.4 — ЗАМОРОЖЕННЫЙ ПУЛ на границе адресов: BOUND инвесторов, у каждого СВОЙ реферал-неинвестор (держателей 2·BOUND + 1 с
    /// treasury), G = 60 живых поколений. Меряются: `mondayBegin` с копией MS_SNAP (первая неделя — запись в пустые слоты,
    /// вторая — после комиссии и вознаграждений), заморозка (Σ весов по G поколениям), проход итогов одним вызовом и
    /// по одному держателю, правило E в худшей ветке «капитала нет» (S = 0: все вывели всё, поколения ещё живы — p по G).
    function test_rev94_emergency_at_bound_every_tx_under_25m() public {
        vm.pauseGasMetering();
        uint256 n = BOUND;
        uint256 G = 60;
        L = _ledger(1000);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(uint160(0x9000 + i)), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        L.sizeOrder("w", n * 500 * USD);
        L.fillOrder("w");
        L.closePosition("w", int256(n * 100 * USD)); // прибыль: комиссия в котёл, вознаграждение каждому рефералу
        _mondayPaged(50); // MS_SNAP первой недели — пустые слоты
        uint256 nj = n * 900 * USD / G;
        for (uint256 j = 0; j < G; j++) {
            bytes32 pid = bytes32(abi.encodePacked("g", vm.toString(j)));
            L.sizeOrder(pid, nj);
            L.fillOrder(pid);
            L.markPosition(pid, -int256((j + 1) * USD));
        }
        assertEq(V.status()[2], int256(G + 1), "one generation per order");
        for (uint256 j = 0; j < G; j++) {
            L.closePosition(bytes32(abi.encodePacked("g", vm.toString(j))), 0); // поколения живы до расчёта
        }
        L.setWithdrawable(uint256(V.status()[9]) + n * 100 * USD); // стоимость ног: касса + закрытая прибыль недели 1
        for (uint256 i = 0; i < n; i++) {
            int256 free = V.freeStake(_addr(i), false);
            if (free > 0) L.withdraw(_addr(i), uint256(free), false);
        }
        L.payQueue(); // капитала не осталось — буфера нет, очередь выплачена целиком в «к получению»
        vm.resumeGasMetering();
        uint256 g = gasleft();
        L.emergencyFreeze();
        uint256 gf = g - gasleft();
        g = gasleft();
        L.emergencySnapStep(type(uint256).max);
        uint256 gs = g - gasleft();
        vm.pauseGasMetering();
        _note(gf, "emergencyFreeze (G = 60)");
        _note(gs, "emergencySnapStep (all 101 holders)");
        emit log_named_uint("  emergencyFreeze, G = 60", gf + TX);
        emit log_named_uint("  emergencySnapStep, 101 holders in one call", gs + TX);
        int256[9] memory t = V.emergencyTotals();
        assertEq(t[0], 2, "snapshot ready");
        assertEq(t[7], 0, "no capital left: S = 0");
        assertGt(t[8], 0, "live generations: P > 0");
        vm.resumeGasMetering();
        g = gasleft();
        uint256 due = V.emergencyDue(_addr(0), uint256(t[6]) * 2);
        uint256 gd = g - gasleft();
        vm.pauseGasMetering();
        _note(gd, "emergencyDue (S = 0, p over G = 60)");
        emit log_named_uint("  emergencyDue, S = 0 branch, p over G = 60 (external call)", gd + TX);
        assertGt(due, 0, "a participant of live generations takes the surplus");
        emit log_named_uint(string.concat("9.4 freeze n=BOUND + BOUND referrers, G=60: max gas, ", worstAt), worst);
    }

    /// @dev Ред. 9.4: копия MS_SNAP в `mondayBegin` на границе — 101 держатель с ненулевыми плоскостями, вторая неделя.
    function test_rev94_ms_snap_at_bound_under_25m() public {
        vm.pauseGasMetering();
        uint256 n = BOUND;
        L = _ledger(1000);
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(uint160(0x9000 + i)), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        for (uint256 w = 0; w < 3; w++) {
            bytes32 pid = bytes32(abi.encodePacked("w", vm.toString(w)));
            L.sizeOrder(pid, n * 500 * USD);
            L.fillOrder(pid);
            L.closePosition(pid, int256(n * 100 * USD));
            L.setWithdrawable(0); // часть в заявках: у каждого и капитал, и заявка, и «к получению» — все слоты копии
            if (w == 1) {
                for (uint256 i = 0; i < n; i++) {
                    L.withdraw(_addr(i), 10 * USD, false);
                }
            }
            _mondayPaged(50);
        }
        emit log_named_uint(string.concat("9.4 MS_SNAP n=BOUND + BOUND referrers: max gas, ", worstAt), worst);
        emit log_named_uint("  mondayBegin (MS_SNAP copy of 101 holders) max", worstBegin);
    }

    /// @dev Скан для README (не судит): `TRI_SCAN=1 forge test --match-test triangle_scan -vv` печатает газ по n и G.
    function test_rev921_triangle_scan() public {
        if (!vm.envOr("TRI_SCAN", false)) return;
        strict = false;
        parts = vm.envOr("TRI_PARTS", false);
        uint256[] memory ns = vm.envOr("TRI_N", ",", new uint256[](0));
        uint256 G = vm.envOr("TRI_G", uint256(1));
        for (uint256 i = 0; i < ns.length; i++) {
            _triangle(ns[i], G);
        }
    }

    // --- пакет A ревью (20.10): закрытые за неделю ордера не растят расчёт ------------------------------------------------ //
    uint256 internal constant SMALL_BLOCK = 3_000_000; // малый блок HyperEVM (газ транзакции вместе с базой — `TX`)

    /// @dev Неделя бота: `n` держателей, `m` ордеров за неделю открыты и закрыты (вход/выход, результат ±1 USD), затем
    /// `live` живых с бумажным убытком, отмена одного из них (O(1) вместо сдвига `orderPids`) и закрытие одного. Меряются
    /// вызовы книги и расчёт: атомарный `monday()` и пачками (keeper: строки по `kRows`, тяжёлые этапы — по одной единице).
    /// Возврат — (наибольший вызов расчёта пачками, атомарный `monday()`, наибольший вызов книги), газ вместе с базой `TX`.
    /// До находки (`_finalizeGenerations` удалял закрытые обходом со сдвигом) `mondayEnd` стоил ~20 тыс. газа на закрытый
    /// ордер: 500 закрытых — 10.1 млн, 1500 — 30 млн (репро `ReviewOrdersWeek`).
    function _weekOfOrders(uint256 n, uint256 m, uint256 live, uint256 kRows)
        internal
        returns (uint256 pagedMax, uint256 atomic, uint256 bookMax)
    {
        vm.pauseGasMetering();
        L = _ledger(1000);
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(uint160(0x9000 + i)), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        bytes4[3] memory book = [L.sizeOrder.selector, L.fillOrder.selector, L.closePosition.selector];
        for (uint256 j = 0; j < m; j++) {
            bytes32 pid = bytes32(abi.encodePacked("o", vm.toString(j)));
            for (uint256 s = 0; s < 3; s++) {
                bytes memory cd = s == 0
                    ? abi.encodeWithSelector(book[s], pid, n * 10 * USD)
                    : s == 1
                        ? abi.encodeWithSelector(book[s], pid)
                        : abi.encodeWithSelector(book[s], pid, j % 2 == 0 ? int256(USD) : -int256(USD));
                vm.resumeGasMetering();
                uint256 g = gasleft();
                (bool ok,) = address(L).call(cd);
                uint256 used = g - gasleft() + TX;
                vm.pauseGasMetering();
                assertTrue(ok, "book call");
                if (used > bookMax) bookMax = used;
            }
        }
        for (uint256 j = 0; j < live; j++) {
            bytes32 pid = bytes32(abi.encodePacked("l", vm.toString(j)));
            L.sizeOrder(pid, n * 10 * USD);
            L.fillOrder(pid);
            L.markPosition(pid, -int256((j + 1) * USD));
        }
        L.sizeOrder("cancelled", n * USD);
        L.sizeOrder("tail", n * USD);
        vm.resumeGasMetering();
        uint256 g0 = gasleft();
        L.cancelOrder("cancelled"); // не последний в `orderPids`: перестановка последнего на его место
        uint256 usedC = g0 - gasleft() + TX;
        vm.pauseGasMetering();
        if (usedC > bookMax) bookMax = usedC;
        uint256 snap = vm.snapshotState();
        vm.resumeGasMetering();
        g0 = gasleft();
        toNextCalendarWeek();
        L.monday();
        atomic = g0 - gasleft() + TX;
        vm.pauseGasMetering();
        int256[] memory atomicDump = PoolLedgerViews(address(L)).dump();
        vm.revertToStateAndDelete(snap);
        vm.resumeGasMetering();
        g0 = gasleft();
        toNextCalendarWeek();
        L.mondayBegin();
        pagedMax = g0 - gasleft() + TX;
        while (true) {
            (uint256 stage,,,) = PoolLedgerViews(address(L)).mondayProgress();
            if (stage == 7) break;
            g0 = gasleft();
            L.mondayStep(_k(stage, kRows));
            uint256 used = g0 - gasleft() + TX;
            if (used > pagedMax) pagedMax = used;
        }
        g0 = gasleft();
        L.mondayEnd();
        uint256 usedE = g0 - gasleft() + TX;
        vm.pauseGasMetering();
        if (usedE > pagedMax) pagedMax = usedE;
        // исход расчёта не зависит от формы (атомарный / пачками) и от числа закрытых: книга после расчёта — только живые
        assertEq(keccak256(abi.encode(PoolLedgerViews(address(L)).dump())), keccak256(abi.encode(atomicDump)), "paged == atomic");
        _assertBookIsLive(PoolLedgerViews(address(L)), live + 1);
        emit log_named_uint(string.concat("week n=", vm.toString(n), " closed=", vm.toString(m), ": monday paged max"), pagedMax);
        emit log_named_uint("  monday() atomic", atomic);
        emit log_named_uint("  book call max (size/fill/close/cancel)", bookMax);
    }

    /// @dev Книга выгрузки после расчёта — ровно `want` ордеров, все живые (закрытые ушли вместе с расчётом).
    function _assertBookIsLive(PoolLedgerViews V, uint256 want) internal view {
        int256[] memory d = V.dump();
        (uint256 p, uint256 nOrd) = _ordersAt(d);
        assertEq(nOrd, want, "orders after monday");
        for (uint256 i = 0; i < nOrd; i++) {
            assertTrue(d[p + 7 * i + 2] != 3, "a closed order survived monday");
        }
    }

    /// @dev Позиция первого ордера в выгрузке и их число: раскладка `dump()` (её же читает дифференциал).
    function _ordersAt(int256[] memory d) internal pure returns (uint256 p, uint256 nOrd) {
        p = 10;
        uint256 nInv = uint256(d[p++]);
        p += nInv * 14;
        uint256 nPl = uint256(d[p++]);
        p += nPl * 5;
        uint256 nG = uint256(d[p++]);
        for (uint256 g = 0; g < nG; g++) {
            p += 3;
            uint256 ns = uint256(d[p++]);
            p += ns * 2;
            uint256 nc = uint256(d[p++]);
            p += nc * 2;
        }
        nOrd = uint256(d[p++]);
    }

    /// @dev 2 000 закрытых за неделю ордеров при n = 10: КАЖДЫЙ вызов расчёта пачками и каждый вызов книги — в малом блоке
    /// (3 млн); атомарный `monday()` — тоже. Строки — пачкой на всех (keeper при n <= 10 берёт строки целиком).
    function test_week_of_2000_closed_orders_paged_monday_fits_small_block_n10() public {
        (uint256 pagedMax, uint256 atomic, uint256 bookMax) = _weekOfOrders(10, 2000, 3, 10);
        assertLe(pagedMax, SMALL_BLOCK, "paged monday call");
        assertLe(atomic, SMALL_BLOCK, "atomic monday");
        assertLe(bookMax, SMALL_BLOCK, "book call");
    }

    /// @dev Та же неделя на границе адресов (`BOUND`): каждый вызов расчёта пачками <= 25 млн.
    function test_week_of_2000_closed_orders_paged_monday_at_bound_under_25m() public {
        (uint256 pagedMax,,) = _weekOfOrders(BOUND, 2000, 3, BOUND);
        assertLe(pagedMax, LIMIT, "paged monday call at bound");
    }

    // --- пакет A ревью (20.10): граница адресов из заявки «вывести всё» ХРАНИЛИЩА ------------------------------------------- //
    uint256 internal constant BIG_BLOCK = 30_000_000; // большой блок HyperEVM
    uint256 internal constant BIG_BLOCK_RESERVE = 1_000_000; // запас под накладные хранилища, которых стенд не видит
    address internal constant KEEPER = address(0xbee);

    /// @dev Хранилище вокруг уже собранной бухгалтерии `L`: владелец бухгалтерии (слот 0, `owner`) переписывается на адрес
    /// хранилища, которое следующим созданием деплойера `h` проходит свою проверку связности (КЕ10). Касса хранилища на Core —
    /// с избытком: замок G1 здесь не предмет, предмет — газ вызова хранилища целиком (вывод через `processWithdrawals`).
    function _vaultAround() internal returns (PoolVault v) {
        HyperCore core = CoreSimulatorLib.init();
        CoreSimulatorLib.setOfflineMode(true);
        PoolDeployHarness h = new PoolDeployHarness();
        address at = vm.computeCreateAddress(address(h), vm.getNonce(address(h)));
        vm.store(address(L), bytes32(0), bytes32(uint256(uint160(at))));
        PoolVault.VaultInit memory p;
        (p.ledger, p.legA, p.legB) = (L, new TradingLeg(at), new TradingLeg(at));
        (p.admin, p.keeper, p.guardian, p.delay) = (address(this), KEEPER, address(0xbad1), 1 days);
        (p.tvlCap, p.legShareBps) = (type(uint256).max, 5000);
        p.emergency = new PoolVaultEmergency(2 days, 2 days, 2 days, 2 days, 2 days);
        v = h.vault(p);
        assertEq(address(v), at, "vault at the address the ledger names");
        core.forceAccountActivation(address(v));
        CoreSimulatorLib.forceSpotBalance(address(v), 0, 1e18);
    }

    /// @dev Газ `processWithdrawals(1)` хранилища (база транзакции включена) на «обратном треугольнике» n адресов и G
    /// поколений с бумажным убытком; память бухгалтерии и хранилища ХОЛОДНАЯ (`vm.cool`, EIP-2929 настоящей транзакции).
    /// Возврат — (заявка «всё», точная заявка 10 USD).
    function _vaultWithdrawGas(uint256 n, uint256 G) internal returns (uint256 allGas, uint256 exactGas) {
        _triangleBook(n, G);
        L.sizeOrder("probe", n * USD); // то же состояние, что у ледгерного замера `_triangle` (ордер рассчитан, не исполнен)
        L.setWithdrawable(n * 100 * USD);
        PoolVault v = _vaultAround();
        address who = _addr(1);
        uint256 snap = vm.snapshotState();
        for (uint256 r = 0; r < 2; r++) {
            if (r == 1) vm.revertToStateAndDelete(snap); // то же состояние: заявка 0 — точная вместо «всё»
            vm.prank(who);
            v.requestWithdraw(r == 0 ? 0 : 10 * USD, false, r == 0);
            vm.cool(address(L));
            vm.cool(address(v));
            vm.prank(KEEPER);
            vm.recordLogs();
            vm.resumeGasMetering();
            uint256 g = gasleft();
            v.processWithdrawals(1);
            uint256 used = g - gasleft() + TX;
            vm.pauseGasMetering();
            Vm.Log[] memory lg = vm.getRecordedLogs();
            bool done;
            for (uint256 i = 0; i < lg.length; i++) {
                if (lg[i].emitter == address(v) && lg[i].topics[0] == PoolVault.WithdrawProcessed.selector) done = true;
            }
            assertTrue(done, "the intent is executed, not rejected");
            if (r == 0) allGas = used;
            else exactGas = used;
        }
        emit log_named_uint(string.concat("vault processWithdrawals(1) ALL, cold, n=", vm.toString(n), " G=", vm.toString(G)), allGas);
        emit log_named_uint("  exact 10 USD, cold", exactGas);
    }

    /// @dev Граница адресов (`MAX_INVESTORS_BOUND` = 43) — из этого замера: заявка «вывести всё» хранилища на худшем
    /// проверенном входе (треугольник, G = 7 — худшее из G = 5/7/8 замера 20.10) помещается в большой блок HyperEVM с запасом
    /// не меньше 1 млн под непроверенные накладные (calldata keeper'а, иные формы книги).
    function test_vault_withdraw_all_at_bound_fits_big_block() public {
        (uint256 allGas, uint256 exactGas) = _vaultWithdrawGas(BOUND, vm.envOr("ALL_G", uint256(7)));
        assertLe(allGas + BIG_BLOCK_RESERVE, BIG_BLOCK, "ALL at the bound: big block with reserve");
        assertLe(exactGas, allGas, "exact intent is not dearer than ALL");
    }

    // --- бета в малых блоках (пакет A ревью, п. 6): какие вызовы при n = 10 и G до 60 выше 3 млн ------------------------- //
    uint256 internal overSmall;

    function _small(uint256 used, string memory what) internal {
        used += TX;
        if (used > worst) (worst, worstAt) = (used, what);
        if (used > vm.envOr("SMALL_THR", SMALL_BLOCK)) {
            overSmall++;
            emit log_named_uint(string.concat("  > threshold: ", what), used);
        }
    }

    /// @dev Неделя беты: `n` держателей (у каждого свой реферал), `G` ордеров — каждый в своём поколении (между ордерами —
    /// пополнение, новый вес), марк в минус; заявки и выплаты каждого десятого; половина ордеров закрыта с убытком, расчёт,
    /// закрытие остальных, расчёт. Каждый вызов, который зовёт keeper (и `freeStake` подачи заявки), меряется против малого
    /// блока. `paged` — расчёт пачками (строки по `n`, тяжёлые этапы по одной единице), иначе атомарный `monday()`.
    function _betaWeek(uint256 n, uint256 G, bool paged) internal {
        vm.pauseGasMetering();
        worst = 0;
        overSmall = 0;
        L = _ledger(1000);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(uint160(0x9000 + i)), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        uint256 g;
        for (uint256 j = 0; j < G; j++) {
            bytes32 pid = bytes32(abi.encodePacked("g", vm.toString(j)));
            vm.resumeGasMetering();
            g = gasleft();
            L.sizeOrder(pid, n * 1500 * USD / G);
            _small(g - gasleft(), "sizeOrder");
            g = gasleft();
            L.fillOrder(pid);
            _small(g - gasleft(), "fillOrder");
            g = gasleft();
            L.markPosition(pid, -int256((j + 1) * USD));
            _small(g - gasleft(), "markPosition");
            vm.pauseGasMetering();
            L.deposit(_addr(j % n), USD, address(0), NONE, EVM, bytes32(0)); // новый вес — новое поколение
        }
        L.setWithdrawable(n * 400 * USD);
        for (uint256 i = 0; i < n; i += 10) {
            vm.resumeGasMetering();
            g = gasleft();
            V.freeStake(_addr(i), false);
            _small(g - gasleft(), "freeStake (requestWithdraw; ALL: + withdraw)");
            g = gasleft();
            L.withdraw(_addr(i), 475 * USD, false);
            _small(g - gasleft(), "withdraw");
            g = gasleft();
            L.claim(_addr(i));
            _small(g - gasleft(), "claim");
            g = gasleft();
            L.deposit(_addr(i), 10 * USD, address(0), NONE, EVM, bytes32(0));
            _small(g - gasleft(), "deposit");
            g = gasleft();
            L.payQueue();
            _small(g - gasleft(), "payQueue");
            vm.pauseGasMetering();
        }
        for (uint256 j = 0; j < G / 2; j++) {
            vm.resumeGasMetering();
            g = gasleft();
            L.closePosition(bytes32(abi.encodePacked("g", vm.toString(j))), -int256(n * 500 * USD / (G / 2 + 1)));
            _small(g - gasleft(), "closePosition");
            vm.pauseGasMetering();
        }
        _betaMonday(n, paged);
        for (uint256 j = G / 2; j < G; j++) {
            vm.resumeGasMetering();
            g = gasleft();
            L.closePosition(bytes32(abi.encodePacked("g", vm.toString(j))), 0);
            _small(g - gasleft(), "closePosition");
            vm.pauseGasMetering();
        }
        _betaMonday(n, paged);
        vm.resumeGasMetering();
        g = gasleft();
        L.treasuryPayout();
        _small(g - gasleft(), "treasuryPayout");
        vm.pauseGasMetering();
        emit log_named_uint(string.concat("beta n=", vm.toString(n), " G=", vm.toString(G), paged ? " paged" : " atomic",
            " calls > 3M: ", vm.toString(overSmall), "; max ", worstAt), worst);
    }

    function _betaMonday(uint256 n, bool paged) internal {
        vm.resumeGasMetering();
        uint256 g = gasleft();
        if (!paged) {
            toNextCalendarWeek();
            L.monday();
            _small(g - gasleft(), "monday() atomic");
            vm.pauseGasMetering();
            return;
        }
        toNextCalendarWeek();
        L.mondayBegin();
        _small(g - gasleft(), "mondayBegin");
        while (true) {
            (uint256 stage,,,) = PoolLedgerViews(address(L)).mondayProgress();
            if (stage == 7) break;
            g = gasleft();
            L.mondayStep(_k(stage, vm.envOr("SMALL_K", n))); // строки — пачкой SMALL_K (по умолчанию все n)
            _small(g - gasleft(), string.concat("mondayStep[", vm.toString(stage), "]"));
        }
        g = gasleft();
        L.mondayEnd();
        _small(g - gasleft(), "mondayEnd");
        vm.pauseGasMetering();
    }

    // --- ревью-2, #3: выгрузка без истории не растёт с историей --------------------------------------------------------- //
    /// @dev Газ витрины (холодная память, база транзакции): `dump()`, `dumpState()` и страница истории `closedPids(0, 100)`.
    /// Меряется во СВОЁМ фрейме (внешний вызов стенда самого себя): расширение памяти под ответ не зависит от того, сколько
    /// памяти стенд успел занять сборкой состояния.
    function _viewGas(bytes memory data) internal returns (uint256) {
        vm.cool(address(L));
        return this.viewGasProbe(data);
    }

    function viewGasProbe(bytes calldata data) external returns (uint256 used) {
        vm.resumeGasMetering();
        uint256 g = gasleft();
        (bool ok,) = address(L).staticcall(data);
        used = g - gasleft() + TX;
        vm.pauseGasMetering();
        assertTrue(ok, "view reverted");
    }

    /// @dev n = 10, M сделок закрыты (расчёт каждые 200 и в конце): живого нет, отличается только история. `dumpState()` и
    /// страница фиксированного размера не растут с M (`dumpState` — газ в газ при M = 100 и M = 1000); `dump()` растёт с M.
    function test_review2_dump_state_flat_with_history() public {
        uint256[2] memory Ms = [uint256(100), 1000];
        uint256[2] memory gDump;
        uint256[2] memory gState;
        uint256[2] memory gPage;
        for (uint256 r = 0; r < 2; r++) {
            vm.pauseGasMetering();
            L = _ledger(0);
            for (uint256 i = 0; i < 10; i++) {
                L.deposit(_addr(i), 1000 * USD, address(0), NONE, EVM, bytes32(0));
            }
            L.sweepToPerp();
            for (uint256 j = 0; j < Ms[r]; j++) {
                bytes32 pid = bytes32(abi.encodePacked("o", vm.toString(j)));
                L.sizeOrder(pid, 100 * USD);
                L.fillOrder(pid);
                L.closePosition(pid, 0);
                if (j % 200 == 199) {
                    toNextCalendarWeek();
                    L.monday();
                }
            }
            toNextCalendarWeek();
            L.monday();
            assertEq(PoolLedgerViews(address(L)).liveGenCount(), 0);
            gDump[r] = _viewGas(abi.encodeCall(PoolLedgerViews.dump, ()));
            gState[r] = _viewGas(abi.encodeCall(PoolLedgerViews.dumpState, ()));
            gPage[r] = _viewGas(abi.encodeCall(PoolLedgerViews.closedPids, (0, 100)));
            emit log_named_uint(string.concat("M=", vm.toString(Ms[r]), " dump()"), gDump[r]);
            emit log_named_uint(string.concat("M=", vm.toString(Ms[r]), " dumpState()"), gState[r]);
            emit log_named_uint(string.concat("M=", vm.toString(Ms[r]), " closedPids(0,100)"), gPage[r]);
        }
        assertEq(gState[1], gState[0], "dumpState does not grow with history");
        // страница — те же 100 записей; разница в десятки газа (замер: 73, в обе стороны не растёт с M) — не история
        assertApproxEqAbs(gPage[1], gPage[0], 500, "a fixed page does not grow with history");
        assertGt(gDump[1], gDump[0] + 900 * 2100, "dump() reads the whole history (>= one cold slot per closed pid)");
    }

    /// @dev Скан для README (не судит): `SMALL_SCAN=1 SMALL_N=10 SMALL_G=1,3,10,20,30,60 forge test --match-test beta_small_block_scan -vv`
    /// печатает каждый вызов выше 3 млн и наибольший вызов недели — требование к keeper'у (большие блоки), а не отказ.
    function test_beta_small_block_scan() public {
        if (!vm.envOr("SMALL_SCAN", false)) return;
        uint256 n = vm.envOr("SMALL_N", uint256(10));
        uint256[] memory Gs = vm.envOr("SMALL_G", ",", new uint256[](0));
        for (uint256 i = 0; i < Gs.length; i++) {
            _betaWeek(n, Gs[i], true);
            _betaWeek(n, Gs[i], false);
        }
    }

    // --- ревью-2 (газ), стенды второго круга (`hlu-review2-gas`, перенесены сюда — ред. 9.5): «должники по маркам» и неделя из
    // M поколений. Только по RV_SCAN=1 (печать газа без отказа): R2_N, R2_G, R2_M, R2_CANCEL, R2_K — см. README «Ред. 9.5: газ».
    function _m(uint256 used, string memory what) internal {
        used += TX;
        if (used > worst) (worst, worstAt) = (used, what);
        emit log_named_uint(what, used);
    }

    function _pid(uint256 j) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked("g", vm.toString(j)));
    }

    /// @dev Убыток марков: на каждом ордере -(базовый + extra/G); extra подбирается.
    function _markAll(uint256 G, uint256 base, uint256 extra) internal {
        for (uint256 j = 0; j < G; j++) {
            L.markPosition(_pid(j), -int256(base + extra / G + j));
        }
    }

    function _build(uint256 n, uint256 G, uint256 nW, uint256 base, uint256 extra) internal {
        vm.pauseGasMetering();
        strict = false;
        worst = 0;
        L = _ledger(0);
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(uint160(0x9000 + i)), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        uint256 nj = n * 1500 * USD / G;
        for (uint256 j = 0; j < G; j++) {
            L.sizeOrder(_pid(j), nj);
            L.fillOrder(_pid(j));
            L.markPosition(_pid(j), -int256((j + 1) * USD));
        }
        assertEq(PoolLedgerViews(address(L)).status()[2], int256(G), "one generation per order");
        L.setWithdrawable(n * 800 * USD);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        for (uint256 i = 0; i < nW; i++) {
            uint256 f = _free(V, _addr(i));
            if (f > 0) {
                L.withdraw(_addr(i), f, false);
                L.claim(_addr(i));
            }
        }
        if (base == 0) {
            // наибольший базовый убыток, при котором стоимость ног не уходит в минус; берётся доля R2_FRAC %
            uint256 lo = 0;
            uint256 hi = n * 1500 * USD / G;
            while (hi - lo > USD / 100) {
                uint256 mid = (lo + hi) / 2;
                try this.markAllExt(G, mid) { lo = mid; } catch { hi = mid; }
            }
            base = lo * vm.envOr("R2_FRAC", uint256(90)) / 100;
            emit log_named_uint("base max", lo);
        }
        _markAll(G, base, extra);
    }

    function _setWd(uint256 w) internal {
        while (w > 0) {
            try L.setWithdrawable(w) { return; } catch { w /= 2; }
        }
    }

    function markAllExt(uint256 G, uint256 b) external {
        for (uint256 j = 0; j < G; j++) {
            L.markPosition(_pid(j), -int256(b + j));
        }
    }

    function _measure(uint256 n, uint256 G, string memory tag) internal {
        PoolLedgerViews V = PoolLedgerViews(address(L));
        emit log_named_int("projectedShortfall", V.projectedShortfall());
        address who = _addr(n - 1); // не вышедший
        uint256 g;
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        try L.sizeOrder("probe", n * USD) {
            _m(g - gasleft(), "sizeOrder");
            vm.pauseGasMetering();
            L.cancelOrder("probe");
        } catch {
            _m(g - gasleft(), "sizeOrder REVERT");
            vm.pauseGasMetering();
        }
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        V.freeStake(who, false);
        _m(g - gasleft(), "freeStake");
        vm.pauseGasMetering();
        uint256 snap = vm.snapshotState();
        // очередь: у нескольких не вышедших есть заявки — проход очереди зовёт `_holdAt` на каждого
        uint256 nq = vm.envOr("R2_NQ", uint256(0));
        L.setWithdrawable(0);
        for (uint256 i = 0; i < nq; i++) {
            address q = _addr(n - 2 - i);
            uint256 f = _free(V, q);
            if (f > 2) L.withdraw(q, f / 2, false);
        }
        _setWd(vm.envOr("R2_WD", n * 100) * USD);
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        uint256 f2 = _free(V, who);
        if (f2 > 0) L.withdraw(who, f2, false);
        _m(g - gasleft(), "withdraw ALL as vault (freeStake + withdraw)");
        vm.pauseGasMetering();
        vm.revertToState(snap);
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.withdraw(who, 1 * USD, false);
        _m(g - gasleft(), "withdraw exact");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        try L.claim(who) returns (int256) {
            _m(g - gasleft(), "claim");
        } catch {
            _m(g - gasleft(), "claim REVERT");
        }
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.payQueue();
        _m(g - gasleft(), "payQueue");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.markPosition(_pid(0), -int256(2000 * USD));
        _m(g - gasleft(), "markPosition");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.reducePosition(_pid(1), -int256(USD), n * 1500 * USD / G / 2, -int256(USD));
        _m(g - gasleft(), "reducePosition");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.closePosition(_pid(2), -int256(10 * USD));
        _m(g - gasleft(), "closePosition");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        try L.treasuryPayout() returns (int256, int256) {
            _m(g - gasleft(), "treasuryPayout");
        } catch {
            _m(g - gasleft(), "treasuryPayout REVERT");
        }
        vm.pauseGasMetering();
        L.setWithdrawable(0);
        uint256 s2 = vm.snapshotState();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        toNextCalendarWeek();
        try L.monday() {
            _m(g - gasleft(), "monday() atomic");
        } catch {
            _m(g - gasleft(), "monday() atomic REVERT");
        }
        vm.pauseGasMetering();
        vm.revertToState(s2);
        // пачками по одной строке
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        toNextCalendarWeek();
        L.mondayBegin();
        _m(g - gasleft(), "mondayBegin");
        vm.pauseGasMetering();
        while (true) {
            (uint256 stage,,,) = V.mondayProgress();
            if (stage == 7) break;
            vm.cool(address(L));
            vm.resumeGasMetering();
            g = gasleft();
            L.mondayStep(1);
            _m(g - gasleft(), string.concat("mondayStep[", vm.toString(stage), "] k=1"));
            vm.pauseGasMetering();
        }
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.mondayEnd();
        _m(g - gasleft(), "mondayEnd");
        vm.pauseGasMetering();
        emit log_named_uint(string.concat(tag, " n=", vm.toString(n), " G=", vm.toString(G), " max ", worstAt), worst);
    }

    function test_r2_debtors_scan() public {
        if (!vm.envOr("RV_SCAN", false)) return;
        uint256 n = vm.envOr("R2_N", uint256(43));
        uint256 G = vm.envOr("R2_G", uint256(60));
        uint256 nW = vm.envOr("R2_NW", uint256(21));
        uint256 base = vm.envOr("R2_BASE", uint256(0));
        uint256 extra = vm.envOr("R2_EXTRA", uint256(0));
        _build(n, G, nW, base, extra);
        _measure(n, G, "DEBTORS");
    }

    /// @dev Подбор марка: недостача на должника — несколько микро (граница `_holdAt` не достигается раньше конца).
    function test_r2_tiny_scan() public {
        if (!vm.envOr("RV_SCAN", false)) return;
        uint256 n = vm.envOr("R2_N", uint256(43));
        uint256 G = vm.envOr("R2_G", uint256(60));
        uint256 nW = vm.envOr("R2_NW", uint256(21));
        _build(n, G, nW, 1, 0);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        // бинарный поиск по базовому убытку на ордер: наименьший, при котором projectedShortfall > 0
        uint256 lo = 0;
        uint256 hi = n * 1500 * USD / G;
        for (uint256 it = 0; it < 60 && hi - lo > 1; it++) {
            uint256 mid = (lo + hi) / 2;
            _markAll(G, mid, 0);
            if (V.projectedShortfall() > 0) hi = mid;
            else lo = mid;
        }
        _markAll(G, hi, 0);
        emit log_named_uint("tiny: base loss per order", hi);
        _measure(n, G, "TINY");
    }

    /// @dev Тот же вход, хранилище поверх: `processWithdrawals(1)` для заявки «всё» и точной, холодная память, база транзакции.
    function test_r2_vault_scan() public {
        if (!vm.envOr("RV_SCAN", false)) return;
        uint256 n = vm.envOr("R2_N", uint256(43));
        uint256 G = vm.envOr("R2_G", uint256(60));
        uint256 nW = vm.envOr("R2_NW", uint256(21));
        _build(n, G, nW, vm.envOr("R2_BASE", uint256(0)), 0);
        emit log_named_int("projectedShortfall", PoolLedgerViews(address(L)).projectedShortfall());
        _setWd(vm.envOr("R2_WD", n * 100) * USD);
        PoolVault v = _vaultAround();
        address who = _addr(n - 1);
        uint256 snap = vm.snapshotState();
        for (uint256 r = 0; r < 2; r++) {
            if (r == 1) vm.revertToStateAndDelete(snap);
            vm.cool(address(L));
            vm.resumeGasMetering();
            uint256 g0 = gasleft();
            vm.prank(who);
            v.requestWithdraw(r == 0 ? 0 : 1 * USD, false, r == 0);
            uint256 req = g0 - gasleft() + TX;
            vm.pauseGasMetering();
            vm.cool(address(L));
            vm.cool(address(v));
            vm.prank(KEEPER);
            vm.resumeGasMetering();
            uint256 g = gasleft();
            (bool ok,) = address(v).call{gas: vm.envOr("R2_CAP", uint256(30_000_000)) - TX}(abi.encodeCall(PoolVault.processWithdrawals, (1)));
            uint256 used = g - gasleft() + TX;
            vm.pauseGasMetering();
            emit log_named_uint(r == 0 ? "requestWithdraw ALL" : "requestWithdraw exact", req);
            emit log_named_uint(string.concat(r == 0 ? "processWithdrawals(1) ALL" : "processWithdrawals(1) exact", ok ? " ok" : " REVERT (cap)"), used);
            if (!ok) {
                assertEq(v.nextIntent(), 0, "intent not consumed");
                assertTrue(v.openIntent(who), "intent still open");
            }
        }
    }

    /// @dev Выход keeper'а из состояния: закрыть все ордера по текущему марку и провести расчёт — затем «всё» дёшево?
    function test_r2_recover() public {
        if (!vm.envOr("RV_SCAN", false)) return;
        uint256 n = vm.envOr("R2_N", uint256(43));
        uint256 G = vm.envOr("R2_G", uint256(60));
        uint256 nW = vm.envOr("R2_NW", uint256(30));
        _build(n, G, nW, 0, 0);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        uint256 maxClose;
        for (uint256 j = 0; j < G; j++) {
            (, , , int256 up, , ) = (uint256(0), uint256(0), uint256(0), int256(0), uint256(0), uint256(0));
            vm.cool(address(L));
            vm.resumeGasMetering();
            uint256 g = gasleft();
            L.closePosition(_pid(j), -int256(1));
            uint256 u = g - gasleft() + TX;
            vm.pauseGasMetering();
            if (u > maxClose) maxClose = u;
            up;
        }
        emit log_named_uint("max closePosition", maxClose);
        L.setWithdrawable(0);
        vm.cool(address(L));
        vm.resumeGasMetering();
        uint256 g2 = gasleft();
        toNextCalendarWeek();
        L.monday();
        emit log_named_uint("monday after closing all", g2 - gasleft() + TX);
        vm.pauseGasMetering();
        emit log_named_int("projectedShortfall after", V.projectedShortfall());
        _setWd(n * 100 * USD);
        address who = _addr(n - 1);
        vm.cool(address(L));
        vm.resumeGasMetering();
        uint256 g3 = gasleft();
        uint256 f = _free(V, who);
        if (f > 0) L.withdraw(who, f, false);
        emit log_named_uint("withdraw ALL after recovery", g3 - gasleft() + TX);
        vm.pauseGasMetering();
    }

    /// @dev Неделя из M сделок, каждая закрыта с результатом (вес меняется -> новое поколение на каждый ордер): поколения живут
    /// в `gens` до `mondayEnd`. Меряются вызовы книги и расчёт (пачками k строк и атомарный), память холодная.
    function test_r2_gens_week() public {
        if (!vm.envOr("RV_SCAN", false)) return;
        uint256 n = vm.envOr("R2_N", uint256(10));
        uint256 M = vm.envOr("R2_M", uint256(500));
        uint256 live = vm.envOr("R2_LIVE", uint256(3));
        uint256 kRows = vm.envOr("R2_K", uint256(1));
        vm.pauseGasMetering();
        strict = false;
        worst = 0;
        L = _ledgerG(0, 0);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(uint160(0x9000 + i)), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        L.sizeOrder("anchor", n * 100 * USD);
        L.fillOrder("anchor");
        for (uint256 j = 0; j < M; j++) {
            L.markPosition("anchor", -int256((j % 50 + 1) * USD)); // марк якоря меняет веса следующего снимка
            bytes32 pid = bytes32(abi.encodePacked("o", vm.toString(j)));
            L.sizeOrder(pid, n * 10 * USD);
            if (vm.envOr("R2_CANCEL", false)) {
                L.cancelOrder(pid); // неисполненный вход (maker не взят): поколение остаётся до mondayEnd
                continue;
            }
            L.fillOrder(pid);
            L.closePosition(pid, j % 3 == 0 ? int256(2 * USD) : -int256(USD));
        }
        for (uint256 j = 0; j < live; j++) {
            bytes32 pid = bytes32(abi.encodePacked("l", vm.toString(j)));
            L.sizeOrder(pid, n * 10 * USD);
            L.fillOrder(pid);
            L.markPosition(pid, -int256((j + 1) * USD));
        }
        emit log_named_int("gens alive (status[2])", V.status()[2]);
        uint256 g;
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.sizeOrder("probe", n * USD);
        _m(g - gasleft(), "sizeOrder");
        vm.pauseGasMetering();
        L.fillOrder("probe");
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.markPosition("probe", -int256(USD));
        _m(g - gasleft(), "markPosition");
        vm.pauseGasMetering();
        L.setWithdrawable(n * 10 * USD);
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        uint256 f = _free(V, _addr(1));
        L.withdraw(_addr(1), f, false);
        _m(g - gasleft(), "withdraw ALL");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.deposit(_addr(2), 10 * USD, address(0), NONE, EVM, bytes32(0));
        _m(g - gasleft(), "deposit");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.claim(_addr(1));
        _m(g - gasleft(), "claim");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.closePosition("probe", 0);
        _m(g - gasleft(), "closePosition");
        vm.pauseGasMetering();
        L.setWithdrawable(0);
        uint256 snap = vm.snapshotState();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        toNextCalendarWeek();
        L.monday();
        _m(g - gasleft(), "monday() atomic");
        vm.pauseGasMetering();
        vm.revertToState(snap);
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        toNextCalendarWeek();
        L.mondayBegin();
        _m(g - gasleft(), "mondayBegin");
        vm.pauseGasMetering();
        uint256 maxStep;
        string memory maxAt;
        while (true) {
            (uint256 stage,,,) = V.mondayProgress();
            if (stage == 7) break;
            uint256 k = stage <= 1 || stage == 8 ? kRows : 1;
            vm.cool(address(L));
            vm.resumeGasMetering();
            g = gasleft();
            L.mondayStep(k);
            uint256 u = g - gasleft() + TX;
            vm.pauseGasMetering();
            if (u > maxStep) (maxStep, maxAt) = (u, string.concat("mondayStep[", vm.toString(stage), "]"));
        }
        emit log_named_uint(string.concat("max ", maxAt), maxStep);
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.mondayEnd();
        _m(g - gasleft(), "mondayEnd");
        vm.pauseGasMetering();
        emit log_named_int("gens after", V.status()[2]);
    }

    /// @dev Витрина `dump()` (её читает keeper ветки work/vault-keeper — `pool_ledger_dump`): растёт ли с историей закрытых.
    function test_r2_dump_growth() public {
        if (!vm.envOr("RV_SCAN", false)) return;
        uint256 n = vm.envOr("R2_N", uint256(10));
        uint256 M = vm.envOr("R2_M", uint256(2000));
        vm.pauseGasMetering();
        L = _ledgerG(0, 0);
        PoolLedgerViews V = PoolLedgerViews(address(L));
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        for (uint256 j = 0; j < M; j++) {
            bytes32 pid = bytes32(abi.encodePacked("o", vm.toString(j)));
            L.sizeOrder(pid, n * 10 * USD);
            L.fillOrder(pid);
            L.closePosition(pid, 0);
            if (j % 200 == 199) {
                toNextCalendarWeek();
                L.monday();
            }
        }
        toNextCalendarWeek();
        L.monday();
        vm.cool(address(L));
        vm.resumeGasMetering();
        uint256 g = gasleft();
        int256[] memory d = V.dump();
        uint256 used = g - gasleft() + TX;
        vm.pauseGasMetering();
        emit log_named_uint(string.concat("dump() gas after closed=", vm.toString(M)), used);
        emit log_named_uint("dump words", d.length);
    }

    // --- ред. 9.5: вывод предела поколений `maxGens` (README «Ред. 9.5: предел поколений») ----------------------------------- //
    /// @dev Худший вход для предела: n держателей, якорь (марк якоря меняет веса — каждый ордер в СВОЁМ поколении) и G
    /// поколений недели, каждое закрыто с убытком (результат недели у каждого участника — убыток во ВСЕХ G поколениях), адрес 0
    /// вывел свободное. Вариант «марки»: якорь под марком — адрес 0 должник по маркам, меряются вызовы с проекцией (sizeOrder,
    /// вывод, забор, очередь) и операции книги. Вариант «закрыто»: якорь закрыт тем же убытком — должник РАСЧЁТА, меряются
    /// расчёт целиком, пачки строк по R2_K единиц (строка должника — пачками по поколениям) и пачки этапов по одной.
    function test_r95_debtor_gens_scan() public {
        if (!vm.envOr("RV_SCAN", false)) return;
        uint256 n = vm.envOr("R2_N", uint256(43));
        uint256 G = vm.envOr("R2_G", uint256(500));
        uint256 kRows = vm.envOr("R2_K", uint256(500));
        int256 hit = int256(vm.envOr("R2_HIT", uint256(300))) * int256(USD) * int256(n); // убыток якоря
        vm.pauseGasMetering();
        strict = false;
        worst = 0;
        L = _ledgerG(0, GENS); // предел не связывает: G < GENS, расчётов нет; хранилище без предела не связывается
        PoolLedgerViews V = PoolLedgerViews(address(L));
        for (uint256 i = 0; i < n; i++) {
            L.deposit(_addr(i), 1000 * USD, address(0), NONE, EVM, bytes32(0));
        }
        L.sweepToPerp();
        L.sizeOrder("anchor", n * 200 * USD);
        L.fillOrder("anchor");
        for (uint256 j = 0; j < G; j++) {
            L.markPosition("anchor", -int256((j % 50 + 1) * USD));
            bytes32 pid = _pid(j);
            L.sizeOrder(pid, n * 10 * USD);
            L.fillOrder(pid);
            L.closePosition(pid, -int256(USD));
        }
        L.markPosition("anchor", 0);
        L.setWithdrawable(n * 900 * USD);
        uint256 f0 = _free(V, _addr(0));
        L.withdraw(_addr(0), f0, false);
        L.claim(_addr(0));
        emit log_named_uint("gens in snapshots", V.liveGenCount());
        uint256 snap = vm.snapshotState();
        // --- вариант «марки»: должник по маркам, проекция
        L.markPosition("anchor", -hit);
        emit log_named_int("projectedShortfall (marks)", V.projectedShortfall());
        address who = _addr(n - 1);
        uint256 g;
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        try L.sizeOrder("probe", n * USD) {
            _m(g - gasleft(), "sizeOrder");
        } catch {
            _m(g - gasleft(), "sizeOrder REVERT");
        }
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        uint256 f = _free(V, who);
        if (f > 0) L.withdraw(who, f, false);
        _m(g - gasleft(), "withdraw ALL (freeStake + withdraw)");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        try L.claim(who) returns (int256) {
            _m(g - gasleft(), "claim");
        } catch {
            _m(g - gasleft(), "claim REVERT");
        }
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.payQueue();
        _m(g - gasleft(), "payQueue");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.markPosition("anchor", -hit - int256(USD));
        _m(g - gasleft(), "markPosition");
        vm.pauseGasMetering();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        try L.deposit(_addr(1), 10 * USD, address(0), NONE, EVM, bytes32(0)) {
            _m(g - gasleft(), "deposit");
        } catch {
            _m(g - gasleft(), "deposit REVERT (pool debt)");
        }
        vm.pauseGasMetering();
        emit log_named_uint(string.concat("MARKS n=", vm.toString(n), " G=", vm.toString(G), " max ", worstAt), worst);
        // то же хранилищем: заявка «вывести всё» и точная, `processWithdrawals(1)` keeper'а — холодная память, база транзакции
        vm.revertToState(snap);
        L.markPosition("anchor", -hit);
        _setWd(n * 100 * USD);
        uint256 s1 = vm.snapshotState();
        for (uint256 r = 0; r < 2; r++) {
            if (r == 1) vm.revertToState(s1);
            PoolVault v = _vaultAround();
            vm.prank(who);
            v.requestWithdraw(r == 0 ? 0 : 1 * USD, false, r == 0);
            vm.cool(address(L));
            vm.cool(address(v));
            vm.prank(KEEPER);
            vm.resumeGasMetering();
            g = gasleft();
            (bool ok,) = address(v).call(abi.encodeCall(PoolVault.processWithdrawals, (1)));
            uint256 used = g - gasleft();
            vm.pauseGasMetering();
            _m(used, string.concat(r == 0 ? "vault processWithdrawals(1) ALL" : "vault processWithdrawals(1) exact", ok ? "" : " REVERT"));
        }
        // --- вариант «закрыто»: должник расчёта
        vm.revertToState(snap);
        worst = 0;
        L.closePosition("anchor", -hit);
        L.setWithdrawable(0);
        uint256 s2 = vm.snapshotState();
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        toNextCalendarWeek();
        L.monday();
        _m(g - gasleft(), "monday() atomic");
        vm.pauseGasMetering();
        emit log_named_int("debtor uncovered after", int256(V.investorView(_addr(0))[7]));
        vm.revertToState(s2);
        worst = 0;
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        toNextCalendarWeek();
        L.mondayBegin();
        _m(g - gasleft(), "mondayBegin");
        vm.pauseGasMetering();
        uint256 steps;
        while (true) {
            (uint256 stage,,,) = V.mondayProgress();
            if (stage == 7) break;
            vm.cool(address(L));
            vm.resumeGasMetering();
            g = gasleft();
            L.mondayStep(stage == 0 ? kRows : 1);
            _m(g - gasleft(), string.concat("mondayStep[", vm.toString(stage), "]"));
            vm.pauseGasMetering();
            steps++;
        }
        vm.cool(address(L));
        vm.resumeGasMetering();
        g = gasleft();
        L.mondayEnd();
        _m(g - gasleft(), "mondayEnd");
        vm.pauseGasMetering();
        emit log_named_uint("paged steps", steps);
        emit log_named_uint(string.concat("CLOSED n=", vm.toString(n), " G=", vm.toString(G), " max ", worstAt), worst);
    }
}
