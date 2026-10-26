// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {toNextCalendarWeek} from "./CalendarWeek.sol";
import {Vm} from "forge-std/Vm.sol";
import {HyperCore} from "hyper-evm-sim/HyperCore.sol";
import {CoreSimulatorLib} from "hyper-evm-sim/CoreSimulatorLib.sol";
import {CoreWriterSim} from "hyper-evm-sim/CoreWriterSim.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {HLConstants} from "hyper-evm-lib/common/HLConstants.sol";
import {PoolLedger, PoolLedgerBase, PoolLedgerViews, PoolLedgerMonday, PoolLedgerProj, PoolLedgerEmergency, PoolLedgerBook} from "../src/PoolLedger.sol";
import {TradingLeg} from "../src/TradingLeg.sol";
import {PoolVault} from "../src/PoolVault.sol";
import {PoolVaultEmergency} from "../src/PoolVaultEmergency.sol";

/// @notice Admin-контракт (как Safe): исполняет вызов от своего адреса, отказ пробрасывает как есть.
contract SafeLike {
    function exec(address to, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }
}

/// @notice Деплойер пула для стендов: части и хранилище — его созданиями подряд, как деплой с одного ключа (README «Схема
/// деплоя»). Свой контракт, а не тест: forge считает внешний вызов теста транзакцией и сдвигает nonce самого теста (замер:
/// +1 на вызов), а nonce контракта двигает только CREATE.
contract PoolDeployHarness {
    address internal constant T = address(0xfee);
    /// @dev Минимум депозита бухгалтерии следующих `parts` (пакет безопасности П1); сеттер nonce деплойера не двигает.
    uint256 public minDeposit;

    function setMinDeposit(uint256 m) external {
        minDeposit = m;
    }

    /// @dev Предел адресов бухгалтерии следующих `parts` (0 — граница 43); сеттер nonce деплойера не двигает.
    uint256 public maxInvestors;

    function setMaxInvestors(uint256 m) external {
        maxInvestors = m;
    }

    /// @dev Ред. 9.5: предел поколений бухгалтерии следующих `parts` (по умолчанию — граница контракта 1000; 0 — без предела,
    /// такую бухгалтерию хранилище не связывает); сеттер nonce деплойера не двигает.
    uint256 public maxGens = 1000;

    function setMaxGens(uint256 m) external {
        maxGens = m;
    }

    function parts(address ledgerOwner, address legAVault, address legBVault)
        external
        returns (PoolLedger ledger, TradingLeg legA, TradingLeg legB)
    {
        PoolLedger.Init memory q;
        q.viewsImpl = address(new PoolLedgerViews());
        q.mondayImpl = address(new PoolLedgerMonday());
        q.projImpl = address(new PoolLedgerProj());
        q.emergencyImpl = address(new PoolLedgerEmergency());
        q.bookImpl = address(new PoolLedgerBook());
        (q.treasury, q.bufferBps, q.feeBps, q.refShareBps, q.holdBps) = (T, 1000, 5000, 2000, 3500);
        (q.openRefShareBps, q.partnerTermWeeks, q.minDeposit, q.owner) = (200, 52, minDeposit, ledgerOwner);
        q.maxInvestors = maxInvestors == 0 ? 43 : maxInvestors;
        q.maxGens = maxGens; // ред. 9.5: хранилище не связывается с бухгалтерией без предела поколений
        ledger = new PoolLedger(q);
        legA = new TradingLeg(legAVault);
        legB = new TradingLeg(legBVault);
    }

    function vault(PoolVault.VaultInit memory p) external returns (PoolVault) {
        return new PoolVault(p);
    }

    /// @dev Создание мимо порядка деплоя: nonce, на который вычислен адрес хранилища, уходит другому контракту.
    function burn() external {
        new SafeLike();
    }
}

/// @notice Денежный цикл пула на симуляторе HyperCore (офлайн): Send-депозит -> зачисление keeper'ом -> ноги -> заявка на
/// вывод -> возврат из ног -> выплата на Core-адрес инвестора. Бухгалтерию судит дифференциал с эталоном; здесь —
/// замки кассы (G1) и ликвидности (G2), окна переводов ног, роли и таймлок, лимит TVL и то, что деньги физически доходят.
/// Симулятор моделирует блоки как HyperCore: прекомпайл видит состояние начала блока, действия CoreWriter исполняются
/// после него (`nextBlock`), отказ действия молчалив.
/// @notice Заглушка «бухгалтерия съела весь газ»: подставляется вместо `withdraw` (`vm.mockFunction`) и не возвращается —
/// худший вызов, которому переданного газа не хватает (§4.2 намерений).
contract GasBurner {
    fallback() external {
        while (true) {}
    }
}

contract PoolVaultTest is Test {
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
    address internal X = makeAddr("newAdmin");
    address internal N = makeAddr("newKeeper");
    address internal BOT = makeAddr("botAgent");
    uint64 internal constant USDC = 0;
    uint256 internal constant DELAY = 2 days;
    uint256 internal constant NO_CAP = type(uint256).max;
    address internal constant DEAD = address(0xdEaD);
    bytes32 internal constant SALT = keccak256("salt-1");

    /// @dev Порча связности для стендов конструктора: 0 — всё верно; 1 — владелец бухгалтерии чужой; 2/3 — нога A/B чужого
    /// хранилища; 4 — одна нога на оба места.
    uint256 internal constant LINK_OK = 0;

    /// @dev Части пула деплоятся ДО хранилища (КЕ10, порядок README «Схема деплоя»): реализации, затем бухгалтерия и ноги на
    /// ВЫЧИСЛЕННЫЙ адрес хранилища — шестое создание деплойера `H` отсюда. Хранилище обязано быть его следующим созданием
    /// (`H.vault`): тогда адрес совпадёт с вычисленным.
    function _parts(address admin_, uint256 delay_, uint256 cap_, uint256 bad)
        internal
        returns (PoolVault.VaultInit memory p)
    {
        address v = vm.computeCreateAddress(address(H), vm.getNonce(address(H)) + 8);
        address other = makeAddr("otherVault");
        (p.ledger, p.legA, p.legB) = H.parts(bad == 1 ? other : v, bad == 2 ? other : v, bad == 3 ? other : v);
        if (bad == 4) p.legB = p.legA;
        p.admin = admin_;
        p.keeper = K;
        p.guardian = G;
        p.delay = delay_;
        p.tvlCap = cap_;
        p.legShareBps = 5000; // прежние стенды раздачи — пополам; доли судят стенды C7
        // ред. 9.4: модуль аварии — создание теста, а не деплойера `H` (адрес хранилища от него не зависит); сроки >= 2·DELAY
        p.emergency = new PoolVaultEmergency(2 * delay_, 2 * delay_, 2 * delay_, 2 * delay_, 2 * delay_);
    }

    function _init(address admin_, uint256 delay_, uint256 cap_) internal returns (PoolVault.VaultInit memory) {
        return _parts(admin_, delay_, cap_, LINK_OK);
    }

    function _vault(uint256 cap_) internal returns (PoolVault v) {
        v = H.vault(_init(address(this), DELAY, cap_));
        for (uint256 i = 0; i < 3; i++) {
            core.forceAccountActivation([address(v), address(v.legA()), address(v.legB())][i]);
        }
    }

    function setUp() public {
        core = CoreSimulatorLib.init();
        CoreSimulatorLib.setOfflineMode(true);
        H = new PoolDeployHarness();
        V = _vault(NO_CAP);
        for (uint256 i = 0; i < 4; i++) {
            core.forceAccountActivation([A, B, C, T][i]);
        }
        CoreSimulatorLib.forceSpotBalance(A, USDC, 5000e8);
        CoreSimulatorLib.forceSpotBalance(B, USDC, 5000e8);
        CoreSimulatorLib.forceSpotBalance(C, USDC, 5000e8);
        CoreSimulatorLib.forceSpotBalance(T, USDC, 5000e8);
    }

    // --- помощники -------------------------------------------------------------------------------------------------- //
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

    function _slackErr(int256 w) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PoolVault.VaultSlack.selector, w);
    }

    /// @dev Раздача в ноги, следующий блок, подтверждение по кассе ног.
    function _sweep() internal returns (int256 move) {
        vm.prank(K);
        move = V.sweepToLegs();
        CoreSimulatorLib.nextBlock();
        if (move > 0) V.confirmSweep();
    }

    /// @dev Нога шлёт хранилищу, следующий блок, подтверждение.
    function _fromLeg(uint256 leg, uint64 usd) internal {
        vm.prank(K);
        V.legSendToVault(leg, usd);
        CoreSimulatorLib.nextBlock();
        V.confirmLegSend(leg);
    }

    function _request(address who, uint256 amount) internal {
        vm.prank(who);
        V.requestWithdraw(amount, false, false);
    }

    function _process(uint256 n) internal {
        vm.prank(K);
        V.processWithdrawals(n);
    }

    /// @dev Адрес замены, который обязан поставить `revokeAgent` (`nonce` — значение счётчика ПОСЛЕ отзыва).
    function _replacement(uint256 leg, string memory name, uint256 nonce, bytes32 salt) internal view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encode(address(V), leg, name, nonce, salt, block.prevrandao, block.number))))
        );
    }

    /// @dev Ключ BOT на ноге `leg` под именем `name` через таймлок.
    function _applyBot(uint256 leg, string memory name) internal {
        V.proposeAgent(leg, BOT, name);
        vm.warp(block.timestamp + DELAY);
        V.applyAgent(leg, BOT, name);
    }

    function _addApiAction(address leg, address agent, string memory name) internal {
        vm.expectEmit(true, false, false, true, CW);
        emit CoreWriterSim.RawAction(
            leg, abi.encodePacked(uint8(1), HLConstants.ADD_API_WALLET_ACTION, abi.encode(agent, name))
        );
    }

    // --- депозит, замок кассы, денежный цикл ---------------------------------------------------------------------- //
    function test_send_deposit_is_credited_and_backed() public {
        _deposit(A, 1000e6, "tx-a1");
        (uint256 vaultMicro, uint256 heldMicro,) = V.reconcile();
        assertEq(vaultMicro, 1000e6, "money on vault Core account");
        assertEq(heldMicro, 1000e6, "ledger spot+evm");
        assertEq(V.vaultSlack(), 0);
    }

    function test_keeper_cannot_credit_money_that_never_arrived() public {
        vm.prank(K);
        vm.expectRevert(_slackErr(-int256(1000e6 * 100)));
        V.creditDeposit(A, 1000e6, "phantom");
    }

    function test_same_ledger_ref_twice_is_refused() public {
        _deposit(A, 1000e6, "tx-a1");
        _send(A, address(V), 1000e8);
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "ledger_ref used"));
        V.creditDeposit(A, 1000e6, "tx-a1");
    }

    function test_only_keeper_moves_ledger() public {
        vm.prank(A);
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.creditDeposit(A, 1, "x");
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.monday();
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.vaultToSpot(1);
    }

    /// @dev Ред. 9.3: частичное закрытие — только keeper, и вызов доходит до бухгалтерии теми же аргументами (нотионал и
    /// марк остатка, часть копится в `partR` — ред. 9.3.1), событие `PositionReduced` — для сторожа (W7, W9). Порядок
    /// слов ордера — выгрузка `dump()`: pid, gen, state, notional, upnl, sized_week, partR.
    function test_reduce_position_keeper_only_and_reaches_ledger() public {
        _deposit(A, 1000e6, "tx-a1");
        _sweep();
        vm.startPrank(K);
        V.sizeOrder("W", 1000e6);
        V.fillOrder("W");
        vm.stopPrank();
        vm.prank(A);
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.reducePosition("W", 100e6, 400e6, 7e6);
        // сторож (W7 Σ realized, W9 автомат ордера): частичное закрытие — событием с тем, что вызов меняет
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.PositionReduced("W", 100e6, 400e6, 7e6);
        vm.prank(K);
        V.reducePosition("W", 100e6, 400e6, 7e6);
        int256[] memory d = PoolLedgerViews(address(V.ledger())).dump();
        uint256 o = d.length - 7;
        while (d[o] != int256(uint256(bytes32("W")))) o--;
        assertEq(d[o + 2], 2, "order stays open");
        assertEq(d[o + 3], 400e6, "notional of the rest");
        assertEq(d[o + 4], 7e6, "mark of the rest");
        assertEq(d[o + 6], 100e6, "partR = result of the part");
    }

    function test_register_once() public {
        vm.startPrank(A);
        V.register(B, true);
        vm.expectRevert(PoolVault.AlreadyRegistered.selector);
        V.register(address(0), false);
        vm.stopPrank();
    }

    /// @dev Ревью-3, R3-I: регистрация ПОСЛЕ первого депозита — отказ `AlreadyRegistered`: бухгалтерия режим и реферала
    /// принимает только первым депозитом, и молчаливая запись выглядела бы включённой. До первого депозита — как прежде.
    function test_review3_register_after_first_deposit_refused() public {
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(A);
        vm.expectRevert(PoolVault.AlreadyRegistered.selector);
        V.register(B, true);
        (bool set,,) = V.prefs(A);
        assertFalse(set, "nothing recorded");
        vm.prank(C);
        V.register(B, true); // ещё без денег — регистрация принимается
        (set,,) = V.prefs(C);
        assertTrue(set);
    }

    /// @dev Честный путь «нога -> хранилище -> выплата» (стенд G1-2), шаги по блокам; отправка с ноги проходит в своём
    /// блоке (G1-6), выплата приходит ровно на адрес держателя.
    function test_full_money_cycle_with_legs() public {
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");

        // в торговлю: всё сверх буфера 10 % — 1 800, по 900 каждой ноге; в блоке раздачи излишка нет (outPending)
        vm.prank(K);
        int256 move = V.sweepToLegs();
        assertEq(move, 1800e6);
        assertEq(V.vaultSlack(), 0, "sweep block: outgoing counted, no phantom surplus");
        CoreSimulatorLib.nextBlock();
        V.confirmSweep();
        assertEq(_spot(address(V.legA())), 900e8);
        assertEq(_spot(address(V.legB())), 900e8);
        vm.startPrank(K);
        V.legToPerp(0, 900e6);
        V.legToPerp(1, 900e6);
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        assertEq(int256(V.legA().accountValue()) + int256(V.legB().accountValue()), 1800e6, "legs hold 1800 on perp");

        // заявка A на 600: бухгалтерия берёт 400 из ног, а их ещё нет в хранилище -> keeper обязан сначала вернуть
        _request(A, 600e6);
        vm.prank(K);
        vm.expectRevert(_slackErr(-400e8)); // ликвидность бухгалтерии > денег на Core-счёте хранилища
        V.processWithdrawals(1);

        // возврат 400 из ноги A: perp -> spot -> хранилище (два действия Core, два блока)
        vm.prank(K);
        V.legToSpot(0, 400e6);
        CoreSimulatorLib.nextBlock();
        vm.prank(K);
        V.legSendToVault(0, 400e6); // G1-6: честная отправка принята в своём блоке
        CoreSimulatorLib.nextBlock();
        _process(1);
        V.confirmLegSend(0);
        assertEq(V.legFlow() + PoolLedgerViews(address(V.ledger())).status()[9], 0, "arrival fully booked");

        // выплата на Core-адрес A
        uint64 before = _spot(A);
        vm.prank(A);
        int256 paid = V.claim();
        assertEq(paid, 600e6, "A claims the full 600");
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(A) - before, 600e8, "600 USDC arrived on A's Core account");
        assertEq(V.vaultSlack(), 0, "vault exactly backed after payout");
    }

    function _mondayPaged() internal {
        vm.startPrank(K);
        V.mondayBegin();
        while (V.mondayStep(1000) != 0) {}
        V.mondayEnd();
        vm.stopPrank();
    }

    // --- G1: фантомный излишек не зачисляется ------------------------------------------------------------------ //
    /// @dev Н8 (G1-1): деньги ног, присланные хранилищу, — не излишек. До подтверждения притоки закрыты окном, после —
    /// замком G1; зачисляется только настоящий `Send`.
    function test_g1_leg_money_is_not_creditable() public {
        _deposit(A, 1000e6, "tx-a1");
        _sweep();
        vm.prank(K);
        V.legSendToVault(0, 400e6);
        CoreSimulatorLib.nextBlock();
        assertEq(V.vaultSlack(), 400e8, "unconfirmed arrival is surplus");
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.creditDeposit(B, 400e6, "phantom");

        vm.prank(B); // подтверждает любой
        V.confirmLegSend(0);
        assertEq(V.legFlow(), -900e6 + 400e6);
        assertEq(V.vaultSlack(), 0, "confirmed arrival is an obligation");
        vm.prank(K);
        vm.expectRevert(_slackErr(-400e8));
        V.creditDeposit(B, 400e6, "phantom");

        _deposit(B, 400e6, "tx-b1"); // настоящий Send зачисляется
        assertEq(V.vaultSlack(), 0);

        // окно второй ноги закрывает притоки так же
        vm.prank(K);
        V.legSendToVault(1, 100e6);
        CoreSimulatorLib.nextBlock();
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 1));
        V.creditDeposit(C, 100e6, "phantom");
    }

    /// @dev Н5 (G1-3): исходящие блока прекомпайл ещё видит; они копятся по блоку и не дают зачислить фантом.
    function test_g1_phantom_after_payouts_in_same_block() public {
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");
        _request(A, 100e6);
        _request(B, 100e6);
        _process(2);
        vm.startPrank(K);
        V.claimFor(A);
        V.claimFor(B);
        assertEq(V.vaultSlack(), 0);
        vm.expectRevert(_slackErr(-100e8));
        V.creditDeposit(C, 100e6, "phantom");
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        assertEq(V.vaultSlack(), 0, "payouts left; pending outflow is per block");
        _deposit(C, 100e6, "tx-c1");
    }

    /// @dev Молчаливый отказ отправки с ноги (G1-8): касса ноги не изменилась. Выплату инвестору это не запирает ни до,
    /// ни после подтверждения; подтверждение не засчитывает несуществующий приход.
    function test_g1_silent_leg_send_failure_does_not_lock_claim() public {
        _deposit(A, 1000e6, "tx-a1");
        _sweep();
        _request(A, 100e6);
        _process(1);
        address la = address(V.legA());
        vm.prank(K);
        V.legSendToVault(0, 400e6);
        // Core отказывает молча: в момент исполнения кассы нет, после — касса прежняя
        CoreSimulatorLib.forceSpotBalance(la, USDC, 0);
        CoreSimulatorLib.nextBlock();
        CoreSimulatorLib.forceSpotBalance(la, USDC, 450e8);
        assertEq(_spot(address(V)), 100e8, "nothing arrived: the vault holds only the claimable 100");

        vm.prank(A);
        assertEq(V.claim(), 100e6, "claim works before confirm");
        V.confirmLegSend(0);
        assertEq(V.legFlow(), -900e6, "failed send not counted");
        CoreSimulatorLib.nextBlock();
        assertEq(V.vaultSlack(), 0);
        _deposit(B, 100e6, "tx-b1"); // keeper работает дальше
        assertEq(V.vaultSlack(), 0);
    }

    /// @dev Молчаливый отказ раздачи (G1-9): деньги остались на хранилище. До `confirmSweep` притоки закрыты; после —
    /// отказ проводится как пришедшее с ног, не разнесённое (излишка нет, G2 его считает).
    function test_g1_silent_sweep_failure() public {
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(K);
        assertEq(V.sweepToLegs(), 900e6);
        CoreSimulatorLib.forceSpotBalance(address(V), USDC, 0);
        CoreSimulatorLib.nextBlock();
        CoreSimulatorLib.forceSpotBalance(address(V), USDC, 1000e8);
        assertEq(_spot(address(V.legA())), 0, "sweep failed silently");
        assertEq(V.vaultSlack(), 900e8, "failed sweep is surplus until confirmed");
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.creditDeposit(B, 900e6, "phantom");

        V.confirmSweep();
        assertEq(V.legFlow(), 0, "both halves counted back");
        assertEq(V.vaultSlack(), 0);
        vm.prank(K);
        vm.expectRevert(_slackErr(-900e8));
        V.creditDeposit(B, 900e6, "phantom");

        // G2-2: не разнесённый приход — физически выводимое
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.WithdrawableAbovePhysical.selector, 900e6 + 1, 900e6));
        V.setWithdrawable(900e6 + 1);
        vm.prank(K);
        V.setWithdrawable(900e6);
    }

    /// @dev Окно ноги: касса начала блока равна кассе до перевода, только если ногу в нём не двигало ничто иное.
    function test_leg_window_rules() public {
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(K);
        V.sweepToLegs();
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.legSendToVault(0, 1e6); // окно раздачи открыто
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NoWindow.selector, 0));
        V.confirmSweep(); // тот же блок
        CoreSimulatorLib.nextBlock();
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NoWindow.selector, 0));
        V.confirmLegSend(0); // окно — раздачи, не отправки
        V.confirmSweep();
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NoWindow.selector, 2));
        V.confirmSweep();

        vm.startPrank(K);
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.legSendToVault(0, 450e6 + 1); // сверх кассы ноги
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.legSendToVault(0, 0);
        V.legSendToVault(0, 100e6);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.legSendToVault(0, 100e6); // окно одно на ногу
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.legToPerp(0, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.legToSpot(0, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.sweepToLegs();
        // перевод perp <-> spot другой ноги в этом блоке закрывает её отправку и раздачу в этом же блоке
        V.legToPerp(1, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 1));
        V.legSendToVault(1, 1e6);
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        V.confirmLegSend(0);
        vm.startPrank(K);
        V.legToSpot(1, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 1));
        V.legSendToVault(1, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 1));
        V.sweepToLegs();
        vm.stopPrank();
    }

    /// @dev Деньги хранилища ушли вне бухгалтерии (например, комиссия активации): `claim` инвестора отклоняется громко.
    function test_claim_refused_when_vault_short() public {
        _deposit(A, 1000e6, "tx-a1");
        _request(A, 100e6);
        _process(1);
        CoreSimulatorLib.forceSpotBalance(address(V), USDC, 500e8);
        vm.prank(A);
        vm.expectRevert(_slackErr(-500e8));
        V.claim();
    }

    /// @dev Фантом не зачисляется и через `coverShortfall` (дыра пула — сценарий фикстуры 204 через хранилище).
    /// @dev Находка ревью F2 (MEDIUM): бухгалтерия оплатила вывод из ликвидности ног (`u = legFlow + venueCash < 0`, деньги ещё на
    /// ноге), замок G1 прошёл за счёт чужого незачтённого `Send` B. Излишек G1 (`vaultSlack`, `u` обрезан нулём) — 600, а чужого
    /// на хранилище 1000: зафиксируй модуль аварии U_s по нему — A получил бы 900 при доле 500, а 400 из денег B ушли бы
    /// держателям. U_s — `vaultSlackSigned` (без обрезки): ровно Send B; его зовёт сам модуль аварии на заморозке (заглушки
    /// нет — судится настоящая связка). Итог: держатель получает свою долю (500), Send B остаётся на хранилище целиком.
    function test_f2_foreign_send_stays_in_us_when_unbooked_negative() public {
        _deposit(A, 1000e6, "a1");
        _sweep(); // на хранилище 100 (буфер), на ногах 900
        _send(B, address(V), 1000e8); // депозит B пришёл, keeper ещё не зачёл
        _request(A, 500e6);
        _process(1); // 400 — из ликвидности ног, денег с ног ещё нет
        vm.prank(A);
        V.claim();
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(address(V)), 600e8, "vault: 100 + 1000 - 500");
        assertEq(V.vaultSlack(), 600e8, "G1: the leg receivable is not counted (refusal side)");
        assertEq(V.vaultSlackSigned(), 1000e8, "U_s: exactly B's Send");

        V.proposeEmergency();
        vm.warp(block.timestamp + DELAY);
        PoolVaultEmergency E = PoolVaultEmergency(address(V));
        E.emergencyFreeze();
        E.emergencySnapStep(type(uint256).max);
        (,,, uint256 foreign,) = E.emergencyState();
        assertEq(foreign, 1000e8, "U_s = B's whole Send");
        E.emergencyCollect(0);
        E.emergencyCollect(1);
        CoreSimulatorLib.nextBlock();
        uint64 was = _spot(A);
        assertEq(E.emergencyClaim(A), 500e6, "A takes exactly the ledger share");
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(A) - was, 500e8);
        assertEq(_spot(address(V)), 1000e8, "B's Send stays on the vault whole");
    }

    function test_g1_cover_shortfall_takes_only_real_money() public {
        address la = address(V.legA());
        address lb = address(V.legB());
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");
        _sweep();
        vm.startPrank(K);
        V.sizeOrder("W", 1000e6);
        V.fillOrder("W");
        V.closePosition("W", 1000e6);
        vm.stopPrank();
        CoreSimulatorLib.forceSpotBalance(la, USDC, 1400e8); // прибыль сделки — на ногах
        CoreSimulatorLib.forceSpotBalance(lb, USDC, 1400e8);
        vm.startPrank(K);
        V.setWithdrawable(2800e6);
        V.monday();
        vm.stopPrank();
        _sweep();
        vm.startPrank(K);
        V.sizeOrder("P", 2500e6);
        V.fillOrder("P");
        V.sizeOrder("Q", 500e6);
        V.fillOrder("Q");
        V.setWithdrawable(2800e6);
        vm.stopPrank();
        _fromLeg(0, 1250e6);
        _fromLeg(1, 1250e6);
        _request(A, 1250e6);
        _request(B, 1250e6);
        _process(2);
        vm.startPrank(K);
        V.claimFor(A);
        V.claimFor(B);
        V.closePosition("P", -1200e6);
        V.setWithdrawable(350e6);
        toNextCalendarWeek(); // ревью-3b: второй календарный расчёт — в следующей неделе
        V.monday();
        vm.stopPrank();
        int256 hole = PoolLedgerViews(address(V.ledger())).status()[5];
        assertEq(hole, 150e6, "shortfall = hole");
        CoreSimulatorLib.nextBlock();

        vm.prank(K);
        vm.expectRevert(_slackErr(-50e8));
        V.coverShortfall(50e6, "cover-phantom");
        // деньги ног, присланные хранилищу, недостачу не покрывают
        vm.prank(K);
        V.legSendToVault(0, 50e6);
        CoreSimulatorLib.nextBlock();
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.coverShortfall(50e6, "cover-phantom");
        V.confirmLegSend(0);
        vm.prank(K);
        vm.expectRevert(_slackErr(-50e8));
        V.coverShortfall(50e6, "cover-phantom");

        _send(T, address(V), 50e8);
        vm.expectEmit(false, false, false, true, address(V));
        emit PoolVault.ShortfallCovered(50e6, "cover-1");
        vm.prank(K);
        assertEq(V.coverShortfall(50e6, "cover-1"), 100e6, "real money covers");
        assertEq(V.vaultSlack(), 0);
    }

    // --- получатель обязан быть на Core (комиссия активации мимо бухгалтерии) ---------------------------------- //
    function test_payout_and_sweep_refused_to_unactivated_core_account() public {
        _deposit(A, 1000e6, "tx-a1");
        _request(A, 100e6);
        _process(1);
        vm.mockCall(
            HLConstants.CORE_USER_EXISTS_PRECOMPILE_ADDRESS,
            abi.encode(A),
            abi.encode(PrecompileLib.CoreUserExists(false))
        );
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotActivated.selector, A));
        V.claim();
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotActivated.selector, A));
        V.claimFor(A);
        vm.clearMockedCalls();
        vm.prank(A);
        assertEq(V.claim(), 100e6);

        // ноги свежего хранилища не на Core: раздача отклоняется до отправки
        PoolVault v = H.vault(_init(address(this), DELAY, NO_CAP));
        (address la, address lb) = (address(v.legA()), address(v.legB()));
        core.forceAccountActivation(address(v));
        _send(B, address(v), 1000e8);
        vm.startPrank(K);
        v.creditDeposit(B, 1000e6, "tx-b1");
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotActivated.selector, la));
        v.sweepToLegs();
        vm.stopPrank();
        core.forceAccountActivation(la);
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotActivated.selector, lb));
        v.sweepToLegs();
    }

    /// @dev G2 на открытии расчёта пачками: ликвидность, которой физически нет, не доходит до `mondayEnd`.
    function test_monday_begin_refused_when_withdrawable_above_physical() public {
        _deposit(A, 1000e6, "tx-a1");
        _sweep();
        vm.prank(K);
        V.setWithdrawable(900e6);
        CoreSimulatorLib.forceSpotBalance(address(V.legA()), USDC, 100e8); // нога потеряла 350
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.WithdrawableAbovePhysical.selector, 900e6, 550e6));
        V.mondayBegin();
        vm.startPrank(K);
        V.setWithdrawable(550e6);
        V.mondayBegin();
        vm.stopPrank();
    }

    // --- G2: ликвидность не больше физической ---------------------------------------------------------------- //
    function test_g2_withdrawable_bounded_by_leg_money() public {
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");
        _sweep();
        // деньги ног на spot: 900 + 900
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.WithdrawableAbovePhysical.selector, 1800e6 + 1, 1800e6));
        V.setWithdrawable(1800e6 + 1);
        vm.prank(K);
        V.setWithdrawable(1800e6);
        vm.startPrank(K);
        V.legToPerp(0, 900e6);
        V.legToPerp(1, 900e6);
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        // те же деньги на perp — выводимое прекомпайла
        vm.prank(K);
        V.setWithdrawable(1800e6);
        // нога потеряла 400 на бирже: обещать прежнюю ликвидность нельзя
        CoreSimulatorLib.forcePerpBalance(address(V.legA()), 500e6);
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.WithdrawableAbovePhysical.selector, 1500e6, 1400e6));
        V.setWithdrawable(1500e6);
        vm.prank(K);
        V.setWithdrawable(1400e6);
    }

    // --- депозит на perp хранилища ---------------------------------------------------------------------------- //
    function test_perp_deposit_moved_to_spot_then_credited() public {
        CoreSimulatorLib.forcePerpBalance(address(V), 500e6); // `usdSend` инвестора лёг на perp хранилища
        vm.prank(K);
        vm.expectRevert(_slackErr(-500e8));
        V.creditDeposit(A, 500e6, "tx-a1"); // на spot денег нет
        vm.prank(K);
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.vaultToSpot(500e6 + 1);
        vm.prank(K);
        V.vaultToSpot(500e6);
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(address(V)), 500e8, "moved to vault spot");
        assertEq(PrecompileLib.withdrawable(address(V)), 0);
        vm.prank(K);
        V.creditDeposit(A, 500e6, "tx-a1");
        assertEq(V.vaultSlack(), 0);
    }

    // --- лимит TVL: капитал под управлением + депозит (A10) -------------------------------------------------------- //
    function _capErr(uint256 capital, uint256 cap) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PoolVault.TvlCapExceeded.selector, capital, cap);
    }

    /// @dev Ровно на лимите принят, +1 микро — отказ; лимит меняет только admin. Деньги в ногах мера не считает: она —
    /// капитал бухгалтерии (`totalStake`), а не касса.
    function test_tvl_cap_is_capital_plus_deposit() public {
        V = _vault(1500e6);
        _deposit(A, 1000e6, "tx-a1");
        _sweep();
        _send(B, address(V), 500e8);
        vm.prank(K);
        V.creditDeposit(B, 500e6, "tx-b1"); // ровно лимит
        assertEq(PoolLedgerViews(address(V.ledger())).totalStake(), 1500e6);
        _send(C, address(V), 100);
        vm.prank(K);
        vm.expectRevert(_capErr(1500e6 + 1, 1500e6));
        V.creditDeposit(C, 1, "tx-c1");

        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.setTvlCap(1500e6 + 1);
        V.setTvlCap(1500e6 + 1);
        assertEq(V.tvlCap(), 1500e6 + 1);
        vm.prank(K);
        V.creditDeposit(C, 1, "tx-c1");
    }

    /// @dev О15 (а): прибыль пула на ногах (физических денег больше лимита) приём не закрывает — до расчёта недели она не
    /// капитал. Прежняя мера «физические деньги» отклонила бы этот депозит (1 000 + 500 прибыли > 1 000).
    function test_tvl_cap_profit_does_not_close_intake() public {
        V = _vault(1000e6);
        _deposit(A, 900e6, "tx-a1");
        _sweep();
        vm.startPrank(K);
        V.sizeOrder("p", 810e6);
        V.fillOrder("p");
        V.closePosition("p", 500e6);
        vm.stopPrank();
        CoreSimulatorLib.forcePerpBalance(address(V.legA()), 500e6); // прибыль сделки — на ноге
        _send(B, address(V), 100e8);
        vm.prank(K);
        V.creditDeposit(B, 100e6, "tx-b1");
        assertEq(PoolLedgerViews(address(V.ledger())).totalStake(), 1000e6);
    }

    /// @dev О15 (б): два `Send` при запасе под один — зачисляется первый, отказ — только второму (физическая мера видела бы
    /// оба уже пришедшими и отвергла бы оба). Вывод освобождает место.
    function test_tvl_cap_does_not_depend_on_arrival_order() public {
        V = _vault(1000e6);
        _deposit(A, 800e6, "tx-a1");
        _send(B, address(V), 200e8);
        _send(C, address(V), 200e8);
        vm.prank(K);
        V.creditDeposit(B, 200e6, "tx-b1");
        vm.prank(K);
        vm.expectRevert(_capErr(1200e6, 1000e6));
        V.creditDeposit(C, 200e6, "tx-c1");
        _request(A, 200e6);
        _process(1);
        vm.prank(K);
        V.creditDeposit(C, 200e6, "tx-c1");
    }

    // --- заявки при открытом недельном расчёте ------------------------------------------------------------------ //
    function test_withdrawals_refused_whole_while_monday_open_and_kept() public {
        _deposit(A, 1000e6, "tx-a1");
        _request(A, 100e6);

        vm.prank(K);
        V.mondayBegin();
        vm.prank(K);
        vm.expectRevert(PoolVault.MondayOpen.selector);
        V.processWithdrawals(1);
        assertEq(V.nextIntent(), 0, "intent not consumed while monday is open");

        vm.startPrank(K);
        while (V.mondayStep(1000) != 0) {}
        V.mondayEnd();
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.WithdrawProcessed(0, 100e6, 0);
        V.processWithdrawals(1);
        vm.stopPrank();
        assertEq(V.nextIntent(), 1);
        vm.prank(A);
        assertEq(V.claim(), 100e6, "the kept intent is paid after monday");
    }

    /// @dev Свободная доля упала между подачей и обработкой (закрытый убыток до расчёта недели): бухгалтерия отказывает событием, очередь
    /// идёт дальше, а отказ снимает `openIntent` — адрес подаёт заново (стенд V4 «отказ снимает openIntent»).
    function test_withdraw_rejection_outside_monday_is_still_an_event() public {
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");
        _sweep();
        vm.startPrank(K);
        V.sizeOrder("p1", 1800e6);
        V.fillOrder("p1");
        vm.stopPrank();
        int256 f = PoolLedgerViews(address(V.ledger())).freeStake(A, false);
        _request(A, uint256(f));
        _request(B, 1e6);
        vm.prank(K);
        V.closePosition("p1", -400e6);
        assertLt(PoolLedgerViews(address(V.ledger())).freeStake(A, false), f, "pending loss lowers the free stake");
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.WithdrawRejected(0, abi.encodeWithSignature("Revert(string)", "withdraw: amount"));
        vm.expectEmit(true, false, false, false, address(V));
        emit PoolVault.WithdrawProcessed(1, 0, 0);
        _process(2);
        assertEq(V.nextIntent(), 2);
        assertFalse(V.openIntent(A), "rejection clears the open intent");
        assertFalse(V.openIntent(B), "execution clears the open intent");
        _request(A, 1e6);
        assertTrue(V.openIntent(A));
    }

    // --- самореферал ------------------------------------------------------------------------------------------------ //
    function test_self_referrer_refused_at_register() public {
        vm.prank(A);
        vm.expectRevert(PoolVault.SelfReferrer.selector);
        V.register(A, true);
        // отказ регистрацию не расходует: адрес регистрируется заново и вносит депозит
        vm.prank(A);
        V.register(B, true);
        _deposit(A, 1000e6, "tx-a1");
        (uint256 vaultMicro, uint256 heldMicro,) = V.reconcile();
        assertEq(heldMicro, 1000e6);
        assertEq(vaultMicro, 1000e6);
    }

    // --- таймлок: admin ------------------------------------------------------------------------------------------- //
    function _proposal(uint256 kind) internal view returns (bytes32 h, uint256 eta) {
        (h, eta) = V.proposals(kind);
    }

    function test_admin_two_step_accept_after_eta_only_by_proposed() public {
        uint256 eta = block.timestamp + DELAY;
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.Proposed(0, keccak256(abi.encode(X)), eta);
        V.proposeAdmin(X);
        (bytes32 h, uint256 e) = _proposal(0);
        assertEq(h, keccak256(abi.encode(X)));
        assertEq(e, eta);

        vm.prank(X);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, eta));
        V.acceptAdmin();
        vm.warp(eta - 1);
        vm.prank(X);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, eta));
        V.acceptAdmin();

        vm.warp(eta);
        vm.prank(A);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.acceptAdmin();
        vm.prank(X);
        V.acceptAdmin();
        assertEq(V.admin(), X);
        (h, e) = _proposal(0);
        assertEq(h, bytes32(0), "proposal cleared on accept");
        assertEq(e, 0);

        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeKeeper(A); // прежний admin прав больше не имеет
        vm.prank(X);
        V.proposeKeeper(A);
        vm.prank(X);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.acceptAdmin(); // принятое предложение повторно не принимается
    }

    function test_admin_propose_is_admin_only() public {
        vm.prank(A);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeAdmin(A);
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeAdmin(G);
        vm.expectRevert(PoolVault.ZeroAddress.selector);
        V.proposeAdmin(address(0));
    }

    function test_admin_cancel() public {
        V.proposeAdmin(X);
        V.cancel(0);
        (bytes32 h,) = _proposal(0);
        assertEq(h, bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.prank(X);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.acceptAdmin();
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.cancel(0);
        assertEq(V.admin(), address(this));
    }

    function test_admin_reproposal_restarts_eta() public {
        uint256 t0 = block.timestamp;
        V.proposeAdmin(X);
        vm.warp(t0 + DELAY - 1);
        V.proposeAdmin(B); // подмена за секунду до срока
        (, uint256 e) = _proposal(0);
        assertEq(e, t0 + 2 * DELAY - 1);
        vm.warp(t0 + DELAY);
        vm.prank(X);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.acceptAdmin();
        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, t0 + 2 * DELAY - 1));
        V.acceptAdmin();
        // повтор того же адреса тоже отсчитывает срок заново
        V.proposeAdmin(B);
        vm.warp(t0 + 2 * DELAY - 1);
        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, t0 + 2 * DELAY));
        V.acceptAdmin();
        vm.warp(t0 + 2 * DELAY);
        vm.prank(B);
        V.acceptAdmin();
        assertEq(V.admin(), B);
    }

    function test_one_step_setters_are_gone() public {
        bytes[3] memory calls = [
            abi.encodeWithSignature("setAdmin(address)", X),
            abi.encodeWithSignature("setKeeper(address)", X),
            abi.encodeWithSignature("legAddApiWallet(uint256,address,string)", 0, X, "bot")
        ];
        for (uint256 i = 0; i < 3; i++) {
            (bool ok,) = address(V).call(calls[i]);
            assertFalse(ok, "one-step setter removed");
        }
        assertEq(V.admin(), address(this));
        assertEq(V.keeper(), K);
    }

    function test_constructor_refuses_zero_roles() public {
        PoolVault.VaultInit memory p = _init(address(this), DELAY, NO_CAP);
        p.guardian = address(0);
        vm.expectRevert(PoolVault.ZeroAddress.selector);
        H.vault(p);
        p = _init(address(this), DELAY, NO_CAP);
        p.keeper = address(0);
        vm.expectRevert(PoolVault.ZeroAddress.selector);
        H.vault(p);
        p = _init(address(0), DELAY, NO_CAP);
        vm.expectRevert(PoolVault.ZeroAddress.selector);
        H.vault(p);
        p = _init(address(this), 48 hours, 777);
        PoolVault v = H.vault(p);
        assertEq(v.DELAY(), 48 hours);
        assertEq(v.tvlCap(), 777);
        assertEq(v.guardian(), G);
    }

    /// @dev КЕ10: хранилище встаёт ровно на вычисленный адрес, и владелец бухгалтерии, хранилище обеих ног — оно само.
    function test_separate_deploy_links_parts_to_vault() public {
        PoolVault.VaultInit memory p = _init(address(this), DELAY, NO_CAP);
        address predicted = vm.computeCreateAddress(address(H), vm.getNonce(address(H)));
        PoolVault v = H.vault(p);
        assertEq(address(v), predicted);
        (address owner,,,,,,,) = PoolLedgerViews(address(v.ledger())).params();
        assertEq(owner, address(v));
        assertEq(v.legA().vault(), address(v));
        assertEq(v.legB().vault(), address(v));
        assertTrue(address(v.legA()) != address(v.legB()));
        // бухгалтерия чужому не подчиняется: и деплойеру, и тому, кто вызывает её мимо хранилища
        (PoolLedger l, TradingLeg a) = (v.ledger(), v.legA());
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "owner"));
        l.setWithdrawable(0);
        vm.expectRevert(TradingLeg.NotVault.selector);
        a.toPerp(1);
    }

    /// @dev Ревью-2, #5: таймлок не короче суток (`BadDelay`), и КАЖДЫЙ срок модуля аварии не короче `2·DELAY` (`NotLinked`
    /// модуля): граница — ровно в секунду с обеих сторон.
    function test_constructor_delay_floor_and_terms_twice_delay() public {
        PoolVault.VaultInit memory p = _init(address(this), 24 hours - 1, NO_CAP);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.BadDelay.selector, uint256(24 hours - 1)));
        H.vault(p);
        p = _init(address(this), 24 hours, NO_CAP); // ровно сутки и сроки ровно 2·DELAY — принято
        assertEq(H.vault(p).DELAY(), 24 hours);
        for (uint256 k = 0; k < 5; k++) {
            uint256[5] memory t = [uint256(4 days), 4 days, 4 days, 4 days, 4 days];
            t[k] = 4 days - 1; // один срок на секунду короче 2·DELAY (DELAY = 2 дня)
            p = _init(address(this), DELAY, NO_CAP);
            p.emergency = new PoolVaultEmergency(t[0], t[1], t[2], t[3], t[4]);
            vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.emergency)));
            H.vault(p);
        }
    }

    /// @dev Связность судит конструктор хранилища: чужой владелец бухгалтерии, нога чужого хранилища, одна нога на оба места,
    /// часть без кода — отказ с адресом части.
    function test_constructor_refuses_unlinked_parts() public {
        PoolVault.VaultInit memory p = _parts(address(this), DELAY, NO_CAP, 1);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.ledger)));
        H.vault(p);
        p = _parts(address(this), DELAY, NO_CAP, 2);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.legA)));
        H.vault(p);
        p = _parts(address(this), DELAY, NO_CAP, 3);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.legB)));
        H.vault(p);
        p = _parts(address(this), DELAY, NO_CAP, 4);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.legB)));
        H.vault(p);
        p = _init(address(this), DELAY, NO_CAP);
        p.ledger = PoolLedger(makeAddr("noCode"));
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.ledger)));
        H.vault(p);
        p = _init(address(this), DELAY, NO_CAP);
        p.legA = TradingLeg(makeAddr("noCodeLeg"));
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.legA)));
        H.vault(p);
        // свежие части, но хранилище — НЕ следующее создание деплойера (nonce потрачен): адрес не тот, владелец чужой
        p = _init(address(this), DELAY, NO_CAP);
        H.burn();
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.ledger)));
        H.vault(p);
        vm.expectRevert(TradingLeg.ZeroVault.selector);
        new TradingLeg(address(0));
    }

    /// @dev Safe-подобный admin проходит полный цикл: принимает роль, ставит keeper'а и agent-ключ через таймлок.
    function test_safe_admin_full_cycle() public {
        SafeLike safe = new SafeLike();
        V.proposeAdmin(address(safe));
        vm.warp(block.timestamp + DELAY);
        safe.exec(address(V), abi.encodeCall(PoolVault.acceptAdmin, ()));
        assertEq(V.admin(), address(safe));
        safe.exec(address(V), abi.encodeCall(PoolVault.proposeKeeper, (N)));
        safe.exec(address(V), abi.encodeCall(PoolVault.proposeAgent, (1, BOT, "bot")));
        vm.warp(block.timestamp + DELAY);
        safe.exec(address(V), abi.encodeCall(PoolVault.applyKeeper, (N)));
        _addApiAction(address(V.legB()), BOT, "bot");
        safe.exec(address(V), abi.encodeCall(PoolVault.applyAgent, (1, BOT, "bot")));
        assertEq(V.keeper(), N);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeKeeper(B);
    }

    // --- таймлок: keeper, guardian, agent-ключи ------------------------------------------------------------------ //
    function test_keeper_change_through_timelock() public {
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeKeeper(N);
        vm.expectRevert(PoolVault.ZeroAddress.selector);
        V.proposeKeeper(address(0));
        uint256 t0 = block.timestamp;
        V.proposeKeeper(N);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, t0 + DELAY));
        V.applyKeeper(N);
        vm.warp(t0 + DELAY - 1);
        V.proposeKeeper(B); // перезапись сдвигает срок
        vm.warp(t0 + DELAY);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyKeeper(N);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, t0 + 2 * DELAY - 1));
        V.applyKeeper(B);
        vm.warp(t0 + 2 * DELAY - 1);
        vm.prank(B);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.applyKeeper(B);
        V.applyKeeper(B);
        assertEq(V.keeper(), B);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyKeeper(B); // исполненное не исполняется повторно
        vm.prank(K);
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.payQueue();
    }

    function test_guardian_change_through_timelock() public {
        address G2 = makeAddr("guardian2");
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeGuardian(G2);
        V.proposeGuardian(G2);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, block.timestamp + DELAY));
        V.applyGuardian(G2);
        vm.warp(block.timestamp + DELAY);
        vm.prank(G2);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.applyGuardian(G2);
        V.applyGuardian(G2);
        assertEq(V.guardian(), G2);
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.pauseDeposits(); // прежний guardian прав больше не имеет
        vm.prank(G2);
        V.pauseDeposits();
    }

    function test_agent_key_through_timelock_revoke_and_restore() public {
        address la = address(V.legA());
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeAgent(0, BOT, "bot");
        vm.expectRevert(PoolVault.ZeroAddress.selector);
        V.proposeAgent(0, address(0), "bot");
        V.proposeAgent(0, BOT, "bot");
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, block.timestamp + DELAY));
        V.applyAgent(0, BOT, "bot");
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyAgent(1, BOT, "bot"); // другая нога
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyAgent(0, BOT, "bot2"); // другое имя
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyAgent(0, A, "bot"); // другой ключ
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.applyAgent(0, BOT, "bot");
        _addApiAction(la, BOT, "bot");
        V.applyAgent(0, BOT, "bot");
        (address ag, bool rv) = V.agents(keccak256(abi.encode(uint256(0), "bot")));
        assertEq(ag, BOT);
        assertFalse(rv);

        // отзыв guardian'ом — сразу; неприменённое имя отозвать нельзя
        vm.prank(K);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.revokeAgent(0, "bot", SALT);
        vm.prank(G);
        vm.expectRevert(PoolVault.NothingToChange.selector);
        V.revokeAgent(1, "bot", SALT);
        _addApiAction(la, _replacement(0, "bot", 1, SALT), "bot");
        vm.prank(G);
        V.revokeAgent(0, "bot", SALT);
        // повтор отзыва (Core мог отказать молча) — guardian сам, новым свежим адресом
        _addApiAction(la, _replacement(0, "bot", 2, SALT), "bot");
        vm.prank(G);
        V.revokeAgent(0, "bot", SALT);

        // вернуть — только admin и ровно отозванный ключ
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.restoreAgent(0, "bot");
        _addApiAction(la, BOT, "bot");
        V.restoreAgent(0, "bot");
        (, rv) = V.agents(keccak256(abi.encode(uint256(0), "bot")));
        assertFalse(rv);
        vm.expectRevert(PoolVault.NothingToChange.selector);
        V.restoreAgent(0, "bot");
        // admin тоже отзывает сразу
        _addApiAction(la, _replacement(0, "bot", 3, SALT), "bot");
        V.revokeAgent(0, "bot", SALT);
    }

    /// @dev testnet T1(б): известная константа (`0xdEaD`) молча НЕ отзывает ключ — она уже Core-пользователь. Замена —
    /// свежий адрес от счётчика и соли вызывающего; два отзыва никогда не дают один адрес.
    function test_revoke_agent_puts_fresh_unpredictable_address() public {
        address la = address(V.legA());
        _applyBot(0, "bot");
        vm.prank(G);
        vm.expectRevert(PoolVault.ZeroSalt.selector);
        V.revokeAgent(0, "bot", bytes32(0));

        address r1 = _replacement(0, "bot", 1, SALT);
        assertTrue(r1 != DEAD && r1 != BOT && r1 != address(0));
        assertFalse(PrecompileLib.coreUserExists(r1));
        _addApiAction(la, r1, "bot");
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.AgentRevoked(0, BOT, "bot", r1);
        vm.prank(G);
        assertEq(V.revokeAgent(0, "bot", SALT), r1);
        assertEq(V.revokeNonce(), 1);

        // второй отзыв в ТОМ ЖЕ блоке с той же солью — другой адрес (счётчик)
        V.restoreAgent(0, "bot");
        address r2 = _replacement(0, "bot", 2, SALT);
        assertTrue(r2 != r1);
        _addApiAction(la, r2, "bot");
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.AgentRevoked(0, BOT, "bot", r2);
        vm.prank(G);
        assertEq(V.revokeAgent(0, "bot", SALT), r2);

        // при том же счётчике другая соль — другой адрес: без соли адрес предсказуем до вызова
        V.restoreAgent(0, "bot");
        uint256 snap = vm.snapshotState();
        vm.prank(G);
        address a1 = V.revokeAgent(0, "bot", SALT);
        vm.revertToState(snap);
        vm.prank(G);
        address a2 = V.revokeAgent(0, "bot", keccak256("salt-2"));
        assertTrue(a1 != a2);
        assertEq(a2, _replacement(0, "bot", 3, keccak256("salt-2")));

        // безымянный ключ отзывается тем же путём
        _applyBot(1, "");
        address r3 = _replacement(1, "", 4, SALT);
        _addApiAction(address(V.legB()), r3, "");
        vm.prank(G);
        assertEq(V.revokeAgent(1, "", SALT), r3);
    }

    /// @dev Core молча отвергает agent'а — Core-пользователя: применение, восстановление и замена на такой адрес
    /// отклоняются громко.
    function test_agent_that_is_core_user_is_rejected() public {
        core.forceAccountActivation(DEAD);
        V.proposeAgent(0, DEAD, "bot");
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.AgentIsUser.selector, DEAD));
        V.applyAgent(0, DEAD, "bot");

        _applyBot(0, "bot");
        address r = _replacement(0, "bot", 1, SALT);
        core.forceAccountActivation(r); // соль утекла, и замену сделали пользователем заранее
        vm.prank(G);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.AgentIsUser.selector, r));
        V.revokeAgent(0, "bot", SALT);
        vm.prank(G);
        V.revokeAgent(0, "bot", keccak256("salt-2")); // новая соль — новый адрес
        core.forceAccountActivation(BOT); // прежний ключ стал пользователем: вернуть его Core не даст
        vm.expectRevert(abi.encodeWithSelector(PoolVault.AgentIsUser.selector, BOT));
        V.restoreAgent(0, "bot");
    }

    /// @dev Отзыв не снимает висящие заявки (testnet T1(б)); их снимает отмена по oid от имени ноги.
    function test_cancel_leg_orders_sends_cancel_by_oid() public {
        address lb = address(V.legB());
        uint32[] memory assets = new uint32[](2);
        uint64[] memory oids = new uint64[](2);
        (assets[0], assets[1], oids[0], oids[1]) = (3, 110005, 11, 12);
        for (uint256 i = 0; i < 2; i++) {
            vm.expectEmit(true, false, false, true, CW);
            emit CoreWriterSim.RawAction(
                lb, abi.encodePacked(uint8(1), HLConstants.CANCEL_ORDER_BY_OID_ACTION, abi.encode(assets[i], oids[i]))
            );
        }
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.LegOrdersCancelled(1, oids);
        vm.prank(G);
        V.cancelLegOrders(1, assets, oids);
        V.cancelLegOrders(0, assets, oids); // admin тоже

        vm.prank(K);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.cancelLegOrders(1, assets, oids);
        vm.prank(A);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.cancelLegOrders(1, assets, oids);
        uint32[] memory more = new uint32[](3);
        vm.prank(G);
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.cancelLegOrders(1, more, oids); // длины не совпадают
        vm.prank(G);
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.cancelLegOrders(1, new uint32[](0), new uint64[](0));
        vm.prank(G);
        vm.expectRevert(PoolVault.ZeroAddress.selector);
        V.cancelLegOrders(2, assets, oids);
    }

    // --- guardian ----------------------------------------------------------------------------------------------- //
    function test_guardian_cancels_admin_proposals_but_not_own_replacement() public {
        V.proposeAdmin(X);
        V.proposeKeeper(N);
        V.proposeAgent(1, BOT, "bot");
        V.proposeGuardian(B);
        vm.prank(A);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.cancel(1);
        vm.prank(K);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.cancel(1);
        for (uint256 kind = 0; kind < 5; kind++) {
            (bytes32 h,) = V.proposals(kind);
            if (kind == 2) {
                vm.expectRevert(PoolVault.NotAdmin.selector);
            } else if (kind == 3) {
                vm.expectRevert(PoolVault.NotProposed.selector);
            } else {
                vm.expectEmit(true, false, false, true, address(V));
                emit PoolVault.ProposalCancelled(kind, h, G);
            }
            vm.prank(G);
            V.cancel(kind);
        }
        vm.warp(block.timestamp + DELAY);
        vm.prank(X);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.acceptAdmin();
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyKeeper(N);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyAgent(1, BOT, "bot");
        V.applyGuardian(B); // замена guardian не отменена им самим
        assertEq(V.guardian(), B);
    }

    function test_guardian_pauses_admin_unpauses() public {
        vm.prank(A);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.pauseDeposits();
        vm.prank(K);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.pauseDeposits();
        vm.prank(G);
        V.pauseDeposits();
        assertTrue(V.depositsPaused());
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.unpauseDeposits();
        vm.prank(K);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.unpauseDeposits();
        V.unpauseDeposits();
        assertFalse(V.depositsPaused());
        V.pauseDeposits(); // admin тоже ставит
        assertTrue(V.depositsPaused());
    }

    function test_revoke_keeper_immediately_and_restore_exact_address() public {
        _deposit(A, 1000e6, "tx-a1");
        _request(A, 100e6);
        _process(1);
        vm.prank(A);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.revokeKeeper();
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.KeeperRevoked(K, G);
        vm.prank(G);
        V.revokeKeeper();
        assertEq(V.keeper(), address(0));
        assertEq(V.revokedKeeper(), K);
        vm.startPrank(K);
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.creditDeposit(A, 1, "x");
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.claimFor(A);
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.markPosition("p", 0);
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.mondayBegin();
        vm.stopPrank();
        vm.prank(G);
        vm.expectRevert(PoolVault.NothingToChange.selector);
        V.revokeKeeper();
        // собственный claim инвестора вне открытого расчёта работает
        vm.prank(A);
        assertEq(V.claim(), 100e6);

        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.restoreKeeper();
        V.restoreKeeper();
        assertEq(V.keeper(), K);
        assertEq(V.revokedKeeper(), address(0));
        vm.expectRevert(PoolVault.NothingToChange.selector);
        V.restoreKeeper();
        vm.prank(K);
        V.payQueue();
    }

    /// @dev Отзыв посреди открытого расчёта пачками: бухгалтерия отклоняет и собственный `claim()` инвестора (`_start`),
    /// пока keeper не возвращён — цена ложной тревоги, которую снимает немедленный `restoreKeeper`.
    function test_revoke_keeper_during_open_monday_blocks_claim_until_restore() public {
        _deposit(A, 1000e6, "tx-a1");
        _request(A, 100e6);
        _process(1);
        vm.prank(K);
        V.mondayBegin();
        vm.prank(G);
        V.revokeKeeper();
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "monday in progress"));
        V.claim();
        V.restoreKeeper();
        vm.startPrank(K);
        while (V.mondayStep(1000) != 0) {}
        V.mondayEnd();
        vm.stopPrank();
        vm.prank(A);
        assertEq(V.claim(), 100e6);
    }

    function test_restore_keeper_superseded_by_timelocked_change() public {
        vm.prank(G);
        V.revokeKeeper();
        V.proposeKeeper(N);
        vm.warp(block.timestamp + DELAY);
        V.applyKeeper(N);
        assertEq(V.revokedKeeper(), address(0));
        vm.expectRevert(PoolVault.NothingToChange.selector);
        V.restoreKeeper();
        assertEq(V.keeper(), N);
    }

    // --- пауза депозитов -------------------------------------------------------------------------------------------- //
    function test_pause_refuses_only_credit_deposit() public {
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");
        vm.prank(G);
        V.pauseDeposits();

        _send(A, address(V), 500e8);
        vm.prank(K);
        vm.expectRevert(PoolVault.Paused.selector);
        V.creditDeposit(A, 500e6, "tx-a2");

        _request(A, 100e6);
        _request(B, 100e6);
        _process(2);
        assertEq(V.nextIntent(), 2);
        vm.prank(A);
        assertEq(V.claim(), 100e6, "claim under pause");
        vm.prank(K);
        assertEq(V.claimFor(B), 100e6, "claimFor under pause");
        vm.startPrank(K);
        V.payQueue();
        V.treasuryPayout();
        V.monday();
        vm.stopPrank();
        toNextCalendarWeek(); // ревью-3b: второй календарный расчёт — в следующей неделе
        _mondayPaged();
        // покрытие недостачи паузой не закрыто: отказ — собственный бухгалтерии (недостачи нет), а не пауза
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "cover_shortfall: amount"));
        V.coverShortfall(1e6, "cover-1");

        V.unpauseDeposits();
        vm.prank(K);
        V.creditDeposit(A, 500e6, "tx-a2");
        (, uint256 heldMicro,) = V.reconcile();
        assertEq(heldMicro, 2300e6);
    }

    // --- возврат незачтённого Send отправителю (П3 / V3 пакета безопасности, решение 18.10) ------------------------- //
    function _refund(address to, uint64 amountWei, bytes32 ref) internal {
        vm.prank(K);
        V.refundDeposit(to, amountWei, ref, 1);
    }

    function _usedRef() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Revert(string)", "ledger_ref used");
    }

    /// @dev `Send` ниже минимума 10 USDC бухгалтерия не зачитывает; keeper возвращает его ОТПРАВИТЕЛЮ ровно в wei (с хвостом
    /// мельче микро), ref сгорает: ни повторный возврат, ни зачисление тем же ref больше не проходят.
    function test_refund_below_min_send_to_sender_and_burn_ref() public {
        H.setMinDeposit(10e6);
        V = _vault(NO_CAP);
        uint64 before = _spot(A);
        _send(A, address(V), 5e8 + 37);
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "deposit: below min"));
        V.creditDeposit(A, 5e6, "s1");
        _refund(A, 5e8 + 37, "s1");
        assertEq(V.vaultSlack(), 0, "refund takes exactly the surplus (outPending)");
        CoreSimulatorLib.nextBlock();
        assertEq(_spot(A), before, "money is back at the sender");
        assertEq(_spot(address(V)), 0);
        vm.prank(K);
        vm.expectRevert(_usedRef());
        V.refundDeposit(A, 1, "s1", 1);
        _send(A, address(V), 20e8);
        vm.prank(K);
        vm.expectRevert(_usedRef());
        V.creditDeposit(A, 20e6, "s1");
        vm.prank(K);
        V.creditDeposit(A, 20e6, "s2");
        vm.prank(K);
        vm.expectRevert(_usedRef());
        V.refundDeposit(A, 20e8, "s2", 1); // зачтённый ref вернуть нельзя
    }

    /// @dev Возврат — только излишек кассы, с учётом ВСЕХ исходящих блока: два возврата сверх излишка в одном блоке — второй
    /// отклонён замком G1, в следующем блоке (касса уже без первого) — тоже, а на остаток — проходит. Денег не пришло — отказ.
    function test_refund_only_surplus_counts_outgoing_of_block() public {
        vm.prank(K);
        vm.expectRevert(_slackErr(-int256(1e8)));
        V.refundDeposit(A, 1e8, "phantom", 1);
        _send(A, address(V), 100e8);
        _refund(A, 60e8, "r1");
        vm.prank(K);
        vm.expectRevert(_slackErr(-int256(20e8)));
        V.refundDeposit(A, 60e8, "r2", 1);
        CoreSimulatorLib.nextBlock();
        vm.prank(K);
        vm.expectRevert(_slackErr(-int256(20e8)));
        V.refundDeposit(A, 60e8, "r2", 1);
        _refund(A, 40e8, "r2");
        assertEq(V.vaultSlack(), 0);
        // фантом после выплаты в том же блоке возвратом не взять (Н5): касса ещё видит выплаченное
        _deposit(B, 100e6, "tx-b1");
        _request(B, 100e6);
        _process(1);
        vm.prank(K);
        V.claimFor(B);
        vm.prank(K);
        vm.expectRevert(_slackErr(-int256(1e8)));
        V.refundDeposit(B, 1e8, "r3", 1);
    }

    /// @dev Пока окно перевода ноги открыто, неподтверждённый приход с ноги выглядит излишком — возврат отклоняется, как
    /// приток; после подтверждения проходит.
    function test_refund_refused_while_leg_window_open() public {
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(K);
        V.sweepToLegs();
        _send(B, address(V), 50e8);
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.LegBusy.selector, 0));
        V.refundDeposit(B, 50e8, "rb", 1);
        CoreSimulatorLib.nextBlock();
        V.confirmSweep();
        _refund(B, 50e8, "rb");
    }

    /// @dev Адресат — отправитель: Core-пользователь (иначе активацию заплатило бы хранилище), не хранилище и не его ноги;
    /// нулевая сумма — отказ. Пауза возврат не трогает; открытый расчёт пачками — отказ бухгалтерии.
    function test_refund_recipient_checks_pause_and_monday() public {
        _deposit(A, 1000e6, "tx-a1");
        _send(B, address(V), 50e8);
        address[4] memory bad = [address(0), address(V), address(V.legA()), address(V.legB())];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(K);
            vm.expectRevert(abi.encodeWithSelector(PoolVault.BadRecipient.selector, bad[i]));
            V.refundDeposit(bad[i], 50e8, "rb", 1);
        }
        address stranger = makeAddr("neverOnCore");
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotActivated.selector, stranger));
        V.refundDeposit(stranger, 50e8, "rb", 1);
        vm.prank(K);
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.refundDeposit(B, 0, "rb", 1);
        vm.prank(A);
        vm.expectRevert(PoolVault.NotKeeper.selector);
        V.refundDeposit(B, 50e8, "rb", 1);
        vm.prank(K);
        V.mondayBegin();
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "monday in progress"));
        V.refundDeposit(B, 50e8, "rb", 1);
        vm.startPrank(K);
        while (V.mondayStep(1000) != 0) {}
        V.mondayEnd();
        vm.stopPrank();
        vm.prank(G);
        V.pauseDeposits();
        vm.expectEmit(true, true, false, true, address(V));
        emit PoolVault.DepositRefunded(B, 0, 50e8, "rb", 7);
        vm.prank(K);
        V.refundDeposit(B, 50e8, "rb", 7);
    }

    // --- раздача ногам с долей (C7) --------------------------------------------------------------------------------- //
    function _share(PoolVault v, uint256 bpsA) internal {
        v.proposeLegShare(bpsA);
        vm.warp(block.timestamp + DELAY);
        v.applyLegShare(bpsA);
    }

    /// @dev Бета на одной ноге: 10000/0 — всё ноге A; нога B не получает ничего, окна у неё нет, и она даже не активирована
    /// на Core (торгующей ей быть не нужно).
    function test_sweep_share_all_to_leg_a_second_leg_untouched() public {
        PoolVault.VaultInit memory p = _init(address(this), DELAY, NO_CAP);
        p.legShareBps = 10_000;
        V = H.vault(p);
        core.forceAccountActivation(address(V));
        core.forceAccountActivation(address(V.legA()));
        assertEq(V.legShareBps(), 10_000);
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(K);
        assertEq(V.sweepToLegs(), 900e6);
        (uint64 blockB,,,) = V.windows(1);
        assertEq(blockB, 0, "leg B: no window");
        assertEq(V.vaultSlack(), 0);
        CoreSimulatorLib.nextBlock();
        V.confirmSweep();
        assertEq(_spot(address(V.legA())), 900e8, "leg A takes the whole move");
        assertEq(_spot(address(V.legB())), 0, "leg B untouched");
        assertEq(V.legFlow(), -900e6);
        assertEq(V.vaultSlack(), 0);
    }

    /// @dev 5000/5000 — пополам; 0/10000 — всё ноге B; доля меняется только таймлоком.
    function test_sweep_share_half_and_all_to_leg_b() public {
        _deposit(A, 1000e6, "tx-a1");
        _sweep();
        assertEq(_spot(address(V.legA())), 450e8);
        assertEq(_spot(address(V.legB())), 450e8);
        _share(V, 0);
        _deposit(B, 1000e6, "tx-b1");
        vm.prank(K);
        assertEq(V.sweepToLegs(), 900e6);
        (uint64 blockA,,,) = V.windows(0);
        assertEq(blockA, 0, "leg A: no window");
        CoreSimulatorLib.nextBlock();
        V.confirmSweep();
        assertEq(_spot(address(V.legA())), 450e8, "leg A untouched");
        assertEq(_spot(address(V.legB())), 1350e8, "leg B takes the whole move");
        assertEq(V.vaultSlack(), 0);
    }

    /// @dev Граница округления: нога A — вниз, нога B — остаток; сумма ровно `move`, касса G1 сходится.
    function test_sweep_share_rounding_remainder_to_leg_b() public {
        _share(V, 3333);
        _deposit(A, 1000e6 + 7, "tx-a1");
        vm.prank(K);
        int256 move = V.sweepToLegs();
        assertEq(move, 900e6 + 7);
        uint256 toA = uint256(move) * 3333 / 10_000;
        assertEq(toA, 299_970_002);
        CoreSimulatorLib.nextBlock();
        V.confirmSweep();
        assertEq(_spot(address(V.legA())), toA * 100);
        assertEq(_spot(address(V.legB())), (900e6 + 7 - toA) * 100);
        assertEq(V.legFlow(), -int256(900e6 + 7));
        assertEq(V.vaultSlack(), 0);
    }

    function test_leg_share_through_timelock() public {
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.proposeLegShare(10_001);
        vm.prank(K);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeLegShare(10_000);
        V.proposeLegShare(10_000);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, block.timestamp + DELAY));
        V.applyLegShare(10_000);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyLegShare(9_999);
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.applyLegShare(10_000);
        vm.expectEmit(false, false, false, true, address(V));
        emit PoolVault.LegShareSet(10_000);
        V.applyLegShare(10_000);
        assertEq(V.legShareBps(), 10_000);
        // guardian снимает предложение доли
        V.proposeLegShare(5000);
        vm.prank(G);
        V.cancel(5);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyLegShare(5000);
        // конструктор: доля выше 100 % — отказ
        PoolVault.VaultInit memory p = _init(address(this), DELAY, NO_CAP);
        p.legShareBps = 10_001;
        vm.expectRevert(PoolVault.BadAmount.selector);
        H.vault(p);
    }

    // --- заявки: одна открытая на адрес, «вывести всё», проверка при подаче (A6, П5) -------------------------------- //
    function test_one_open_intent_per_address() public {
        _deposit(A, 1000e6, "tx-a1");
        _request(A, 100e6);
        assertTrue(V.openIntent(A));
        vm.startPrank(A);
        vm.expectRevert(PoolVault.IntentOpen.selector);
        V.requestWithdraw(50e6, false, false);
        vm.expectRevert(PoolVault.IntentOpen.selector);
        V.requestWithdraw(0, false, true);
        vm.stopPrank();
        _process(1);
        assertFalse(V.openIntent(A));
        _request(A, 50e6); // после обработки — снова можно
        assertTrue(V.openIntent(A));
    }

    /// @dev Ревью-2, #8: `processWithdrawals(n)` — пачка насыщается длиной очереди, `n = type(uint256).max` при ненулевом
    /// `nextIntent` не переполняет `i + n` (раньше — откат арифметики, keeper со «сколько есть» стоял бы).
    function test_process_withdrawals_n_saturates() public {
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");
        _request(A, 100e6);
        _process(type(uint256).max); // nextIntent 0 -> 1
        assertEq(V.nextIntent(), 1);
        _request(A, 50e6);
        _request(B, 70e6);
        _process(type(uint256).max); // i = 1: прежнее `1 + max` переполнялось
        assertEq(V.nextIntent(), 3);
        assertFalse(V.openIntent(A));
        assertFalse(V.openIntent(B));
        _process(type(uint256).max); // пустая очередь — без отказа
        assertEq(V.nextIntent(), 3);
        _request(B, 10e6);
        _process(0); // ноль — ничего
        assertEq(V.nextIntent(), 3);
        _process(1);
        assertEq(V.nextIntent(), 4);
    }

    function test_request_checks_free_stake_at_submission() public {
        _deposit(A, 1000e6, "tx-a1");
        vm.startPrank(A);
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.requestWithdraw(0, false, false);
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.requestWithdraw(1, false, true); // «всё» — сумма обязана быть 0
        vm.expectRevert(abi.encodeWithSelector(PoolVault.AboveFree.selector, uint256(1000e6 + 1), int256(1000e6)));
        V.requestWithdraw(1000e6 + 1, false, false);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.AboveFree.selector, uint256(1), int256(0)));
        V.requestWithdraw(1, true, false); // вознаграждения нет
        vm.stopPrank();
        vm.startPrank(B); // не держатель
        vm.expectRevert(abi.encodeWithSelector(PoolVault.AboveFree.selector, uint256(100e6), int256(0)));
        V.requestWithdraw(100e6, false, false);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.AboveFree.selector, uint256(0), int256(0)));
        V.requestWithdraw(0, false, true);
        vm.stopPrank();
        assertFalse(V.openIntent(A));
        assertFalse(V.openIntent(B));
        _request(A, 1000e6); // ровно свободное
    }

    /// @dev «Всё»: в очереди — служебное значение, при обработке — свободная доля НА МОМЕНТ обработки (здесь выросла
    /// пополнением после подачи).
    function test_withdraw_all_takes_free_stake_at_processing() public {
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(A);
        uint256 id = V.requestWithdraw(0, false, true);
        (address who, uint256 amount, bool reward) = V.intents(id);
        assertEq(who, A);
        assertEq(amount, type(uint256).max, "service value ALL");
        assertFalse(reward);
        _deposit(A, 500e6, "tx-a2");
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.WithdrawProcessed(id, 1500e6, 0);
        _process(1);
        assertFalse(V.openIntent(A));
        assertEq(PoolLedgerViews(address(V.ledger())).freeStake(A, false), 0);
        vm.prank(A);
        assertEq(V.claim(), 1500e6);
    }

    /// @dev Инвариант очереди под случайными последовательностями подач (точных, «всё», лишних), обработок пачками,
    /// пополнений и бумажного убытка: `processWithdrawals` не откатывается ни разу, `openIntent[a]` истинен ровно тогда,
    /// когда у `a` есть необработанная заявка, и такая заявка у адреса одна.
    function test_intent_sequences_never_make_processing_revert() public {
        address[3] memory who = [A, B, C];
        _deposit(A, 1000e6, "s-a");
        _deposit(B, 1000e6, "s-b");
        _sweep();
        _fromLeg(0, 900e6); // деньги ног — обратно на хранилище: замок G1 выплатам не мешает, судится только очередь
        _fromLeg(1, 900e6);
        vm.startPrank(K);
        V.sizeOrder("p", 1000e6);
        V.fillOrder("p");
        vm.stopPrank();
        uint256 r = 7;
        uint256 alls;
        uint256[2] memory seen; // [исполнено, отказано]
        for (uint256 step = 0; step < 160; step++) {
            r = uint256(keccak256(abi.encode(r, step)));
            address a = who[r % 3];
            uint256 act = (r >> 8) % 6;
            if (act <= 2) {
                int256 f = PoolLedgerViews(address(V.ledger())).freeStake(a, false);
                bool all = act == 0;
                uint256 amt = all ? 0 : (f > 0 ? uint256(f) * ((r >> 16) % 3 + 1) / 2 : 1); // бывает и сверх свободного
                vm.prank(a);
                try V.requestWithdraw(amt, false, all) {
                    if (all) alls++;
                } catch {}
            } else if (act == 3) {
                vm.recordLogs(); // симулятор читает журнал на `nextBlock`, поэтому окно записи — только этот вызов
                vm.prank(K);
                V.processWithdrawals((r >> 24) % 3 + 1); // не обязан откатываться никогда
                _countOutcomes(seen);
            } else if (act == 4) {
                // закрытый убыток до расчёта недели уменьшает свободную долю — поданные ранее точные суммы получают отказ;
                // отказ самой торговой операции (стоимость ног < 0) — не предмет стенда
                vm.startPrank(K);
                try V.sizeOrder(bytes32(r), 100e6) {
                    V.fillOrder(bytes32(r));
                    try V.closePosition(bytes32(r), -int256((r >> 32) % 20e6)) {} catch {}
                } catch {}
                vm.stopPrank();
            } else {
                _send(a, address(V), 10e8);
                vm.prank(K); // отказ зачисления (долг пула) оставляет `Send` излишком — не предмет стенда
                try V.creditDeposit(a, 10e6, bytes32(r)) {} catch {}
            }
            _assertIntentsInvariant(who);
        }
        vm.recordLogs();
        vm.prank(K);
        V.processWithdrawals(1000);
        _countOutcomes(seen);
        _assertIntentsInvariant(who);
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(V.openIntent(who[i]), "queue drained: nothing open");
        }
        // стенд не пустой: были и исполнения, и отказы бухгалтерии, и заявки «всё»
        emit log_named_uint("processed", seen[0]);
        emit log_named_uint("rejected", seen[1]);
        emit log_named_uint("ALL submitted", alls);
        assertGt(seen[0], 0);
        assertGt(seen[1], 0);
        assertGt(alls, 0);
    }

    function _countOutcomes(uint256[2] memory seen) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(V)) continue;
            if (logs[i].topics[0] == PoolVault.WithdrawProcessed.selector) seen[0]++;
            if (logs[i].topics[0] == PoolVault.WithdrawRejected.selector) seen[1]++;
        }
    }

    function _assertIntentsInvariant(address[3] memory who) internal view {
        for (uint256 k = 0; k < 3; k++) {
            uint256 open;
            for (uint256 i = V.nextIntent(); ; i++) {
                try V.intents(i) returns (address x, uint256, bool) {
                    if (x == who[k]) open++;
                } catch {
                    break;
                }
            }
            assertLe(open, 1, "one open intent per address");
            assertEq(V.openIntent(who[k]), open == 1, "openIntent mirrors the queue");
        }
    }

    // --- газ: keeper не «съедает» заявку нехваткой газа (§4.2 намерений; бухгалтерия без `try`, отказ — кодом) ---------- //
    /// @dev Малый блок HyperEVM — 3 млн газа на блок; транзакция keeper'а несёт ещё базу и calldata.
    uint256 internal constant SMALL_BLOCK_CALL = 3_000_000 - 21_000 - 16 * 36;

    /// @dev Вывод при n = 2 — точная заявка и «всё» — исполняется в газе малого блока: большого блока он не требует.
    function test_small_withdraw_fits_small_block() public {
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");
        _request(A, 100e6);
        vm.prank(B);
        V.requestWithdraw(0, false, true);
        vm.prank(K);
        uint256 g = gasleft();
        V.processWithdrawals{gas: SMALL_BLOCK_CALL}(1);
        emit log_named_uint("processWithdrawals(1) exact, n=2", g - gasleft());
        assertEq(V.nextIntent(), 1);
        vm.prank(K);
        g = gasleft();
        V.processWithdrawals{gas: SMALL_BLOCK_CALL}(1);
        emit log_named_uint("processWithdrawals(1) ALL, n=2", g - gasleft());
        assertEq(V.nextIntent(), 2);
        assertFalse(V.openIntent(A));
        assertFalse(V.openIntent(B));
        assertEq(PoolLedgerViews(address(V.ledger())).freeStake(B, false), 0, "ALL took the whole free stake");
    }

    /// @dev Исход одного вызова `processWithdrawals(1)` с газом `gas`: 0 — транзакция откатилась, и заявка на месте; 1 —
    /// исполнена (капитал адреса ушёл в заявку бухгалтерии); 2 — СЪЕДЕНА (вызов прошёл, заявка снята, капитал не тронут).
    /// Состояние после замера возвращается.
    function _outcome(address who, uint256 gas) internal returns (uint8 o) {
        int256 free0 = PoolLedgerViews(address(V.ledger())).freeStake(who, false);
        uint256 n0 = V.nextIntent();
        uint256 snap = vm.snapshotState();
        vm.prank(K);
        try V.processWithdrawals{gas: gas}(1) {
            o = PoolLedgerViews(address(V.ledger())).freeStake(who, false) == free0 ? 2 : 1;
        } catch {
            assertEq(V.nextIntent(), n0, "reverted: queue untouched");
            assertTrue(V.openIntent(who), "reverted: intent still open");
        }
        vm.revertToStateAndDelete(snap);
    }

    /// @dev Скан газа (как R2c ревью): от трети нужного до нужного + 5 % шагом 1/400. На КАЖДОМ уровне — откат с заявкой на
    /// месте либо исполнение; «съеденной» заявки нет ни на одном. Возврат — (откатов, исполнений, нужный газ).
    function _scanNeverEaten(address who) internal returns (uint256 reverted, uint256 executed, uint256 need) {
        uint256 snap = vm.snapshotState();
        vm.prank(K);
        uint256 g = gasleft();
        V.processWithdrawals{gas: 29_000_000}(1);
        need = g - gasleft();
        vm.revertToStateAndDelete(snap);
        for (uint256 gas = need / 3; gas <= need + need / 20; gas += need / 400) {
            uint8 o = _outcome(who, gas);
            assertTrue(o != 2, string.concat("intent EATEN at gas ", vm.toString(gas)));
            if (o == 0) reverted++;
            else executed++;
        }
        assertGt(reverted, 0, "the scan reaches starved gas");
        assertGt(executed, 0, "the scan reaches enough gas");
    }

    /// @dev Книга с бумажным убытком (проекция `hold` — статический вызов бухгалтерии самой себя, `_projCall`): `nInv`
    /// держателей и `nGen` поколений с ордером в минус (новый вес — новое поколение; репро R2 ревью).
    function _projectedBook(uint256 nInv, uint256 nGen) internal {
        for (uint256 i = 0; i < nInv; i++) {
            address a = address(uint160(0x1000 + i));
            core.forceAccountActivation(a);
            CoreSimulatorLib.forceSpotBalance(a, USDC, 5000e8);
            _deposit(a, 1000e6, bytes32(i + 1));
        }
        _deposit(A, 1000e6, "a1");
        _sweep();
        for (uint256 j = 0; j < nGen; j++) {
            bytes32 pid = bytes32(abi.encodePacked("g", vm.toString(j)));
            vm.startPrank(K);
            V.sizeOrder(pid, 1000e6);
            V.fillOrder(pid);
            V.markPosition(pid, -int256((j + 1) * 1e6));
            vm.stopPrank();
            _deposit(address(uint160(0x1000 + j)), 100e6, bytes32(1000 + j));
        }
    }

    /// @dev Находка ревью R2/R2c (HIGH): нехватка газа ВНУТРИ вложенной проекции (`_projCall`) — отказ с пустым ответом при
    /// остатке выше порога EIP-150 одного фрейма; прежнее правило `_assertNotStarved` принимало его за законный отказ, и заявка
    /// съедалась (R2c: полосы «EATEN» между «OOG-revert» и «EXECUTED»). Теперь бухгалтерия зовётся без `try`: на всех уровнях
    /// газа — откат или исполнение. Точная заявка.
    function test_nested_projection_oog_never_eats_exact_intent() public {
        _projectedBook(30, 5);
        vm.prank(A);
        V.requestWithdraw(100e6, false, false);
        (uint256 rv, uint256 ex, uint256 need) = _scanNeverEaten(A);
        emit log_named_uint("exact: gas of an executing call", need);
        emit log_named_uint("  reverted levels", rv);
        emit log_named_uint("  executed levels", ex);
    }

    /// @dev То же для «всё»: голодать может и первый вызов (`freeStake`), и второй (`withdraw`).
    function test_nested_projection_oog_never_eats_all_intent() public {
        _projectedBook(30, 5);
        vm.prank(A);
        V.requestWithdraw(0, false, true);
        (uint256 rv, uint256 ex, uint256 need) = _scanNeverEaten(A);
        emit log_named_uint("ALL: gas of an executing call", need);
        emit log_named_uint("  reverted levels", rv);
        emit log_named_uint("  executed levels", ex);
    }

    /// @dev Репро `ReviewNestedOog` ревью газа (3 держателя, одно поколение с бумажным убытком): шаг газа 1 000 от 40 тыс. —
    /// ни одного уровня, где заявка съедена, ни у точной, ни у «всё».
    function test_nested_oog_small_book_fine_step_never_eats() public {
        _deposit(A, 1000e6, "a1");
        _deposit(B, 1000e6, "b1");
        _deposit(C, 1000e6, "c1");
        _sweep();
        _fromLeg(0, 1350e6); // деньги ног — обратно на хранилище: «всё» B платится из ликвидности ног, и G1 ему не мешает
        _fromLeg(1, 1350e6);
        vm.startPrank(K);
        V.sizeOrder("o0", 4500e6);
        V.fillOrder("o0");
        V.markPosition("o0", -1e6);
        vm.stopPrank();
        _request(A, 50e6);
        vm.prank(B);
        V.requestWithdraw(0, false, true);
        uint256 executed;
        for (uint256 gas = 40_000; gas <= 3_000_000 && executed < 20; gas += 1_000) {
            uint8 o = _outcome(A, gas);
            assertTrue(o != 2, string.concat("exact intent EATEN at gas ", vm.toString(gas)));
            if (o == 1) executed++;
        }
        assertEq(executed, 20, "exact intent executes with enough gas");
        _process(1);
        executed = 0;
        for (uint256 gas = 40_000; gas <= 3_000_000 && executed < 20; gas += 1_000) {
            uint8 o = _outcome(B, gas);
            assertTrue(o != 2, string.concat("ALL intent EATEN at gas ", vm.toString(gas)));
            if (o == 1) executed++;
        }
        assertEq(executed, 20, "ALL intent executes with enough gas");
    }

    /// @dev Урезанный газ без заглушек на простом пуле: на любом газе исход один из двух — заявка исполнена целиком, либо
    /// транзакция откатилась и заявка на месте.
    function test_cut_gas_reverts_whole_tx_never_eats_intent() public {
        _deposit(A, 1000e6, "tx-a1");
        _request(A, 100e6);
        uint256 reverted;
        for (uint256 gas = 60_000; gas <= 600_000; gas += 15_000) {
            vm.prank(K);
            try V.processWithdrawals{gas: gas}(1) {
                assertEq(V.nextIntent(), 1, "success means executed");
                assertEq(PoolLedgerViews(address(V.ledger())).freeStake(A, false), 900e6, "executed, not rejected");
                break;
            } catch {
                reverted++;
                assertEq(V.nextIntent(), 0, "reverted: queue untouched");
                assertTrue(V.openIntent(A), "reverted: intent still open");
            }
        }
        emit log_named_uint("gas levels that reverted whole", reverted);
        assertGt(reverted, 0);
        assertEq(V.nextIntent(), 1, "with enough gas the intent runs");
    }

    /// @dev Атака §4.2 в чистом виде: бухгалтерии нужен весь переданный газ (заглушка `withdraw`, съедающая всё). Отказ
    /// бухгалтерии — отказ транзакции, в том числе в газе большого блока; заявка на месте.
    /// ⚠ После заглушки — только вызовы с ограниченным газом: заглушка не возвращается никогда.
    function test_gas_starved_withdraw_reverts_whole_tx() public {
        _deposit(A, 1000e6, "tx-a1");
        _request(A, 100e6);
        GasBurner burner = new GasBurner();
        vm.mockFunction(address(V.ledger()), address(burner), abi.encodeWithSelector(PoolLedger.withdraw.selector));
        vm.prank(K);
        vm.expectRevert(bytes(""));
        V.processWithdrawals{gas: 30_000_000}(1);
        assertEq(V.nextIntent(), 0, "intent not eaten");
        assertTrue(V.openIntent(A));
    }

    /// @dev То же для «всё»: голодает первый вызов — `freeStake`.
    function test_gas_starved_free_stake_reverts_whole_tx() public {
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(A);
        V.requestWithdraw(0, false, true);
        GasBurner burner = new GasBurner();
        vm.mockFunction(address(V.ledger()), address(burner), abi.encodeWithSelector(PoolLedgerViews.freeStake.selector));
        vm.prank(K);
        vm.expectRevert(bytes(""));
        V.processWithdrawals{gas: 30_000_000}(1);
        assertEq(V.nextIntent(), 0, "intent not eaten");
        assertTrue(V.openIntent(A));
    }

    /// @dev Отказ бухгалтерии кодом — событие с прежней причиной (`Revert(string)`), заявка снята; код вне известных — отказ
    /// транзакции (fail-loud), заявка на месте. Коды — `PoolLedgerBase.W_*`: 1 — ноль/сверх свободной, 2 — вне uint128.
    function test_withdraw_status_codes_map_to_events() public {
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 1000e6, "tx-b1");
        _request(A, 100e6);
        _request(B, 100e6);
        address l = address(V.ledger());
        vm.mockCall(l, abi.encodeCall(PoolLedger.withdraw, (A, 100e6, false)), abi.encode(uint8(2), int256(0), int256(0)));
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.WithdrawRejected(0, abi.encodeWithSignature("Revert(string)", "uint128"));
        _process(1);
        assertFalse(V.openIntent(A), "rejection by code clears the intent");
        vm.mockCall(l, abi.encodeCall(PoolLedger.withdraw, (B, 100e6, false)), abi.encode(uint8(3), int256(0), int256(0)));
        vm.prank(K);
        vm.expectRevert(PoolVault.BadAmount.selector);
        V.processWithdrawals(1);
        assertEq(V.nextIntent(), 1, "unknown code: intent kept");
        assertTrue(V.openIntent(B));
        vm.clearMockedCalls();
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.WithdrawProcessed(1, 100e6, 0);
        _process(1);
    }

    /// @dev «Всё» с нулевой свободной долей к обработке — отказ кодом `W_AMOUNT` (настоящая бухгалтерия), событием, заявка
    /// снята, капитал не тронут.
    function test_withdraw_all_with_zero_free_is_rejected_by_code() public {
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(A);
        V.requestWithdraw(0, false, true);
        vm.mockCall(address(V.ledger()), abi.encodeWithSelector(PoolLedgerViews.freeStake.selector, A, false), abi.encode(int256(0)));
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.WithdrawRejected(0, abi.encodeWithSignature("Revert(string)", "withdraw: amount"));
        _process(1);
        assertFalse(V.openIntent(A));
        vm.clearMockedCalls();
        assertEq(PoolLedgerViews(address(V.ledger())).freeStake(A, false), 1000e6, "capital untouched");
    }

    /// @dev Первый депозит определяется дешёвой витриной `isInvestor` (O(1)): реферал и режим идут ТОЛЬКО первым депозитом,
    /// пополнение их повторно не передаёт (иначе бухгалтерия отвергла бы КАЖДОЕ пополнение `deposit: referrer only first`).
    /// Ревью-3, R3-I: регистрация после первого депозита — отказ (`test_review3_register_after_first_deposit_refused`),
    /// поэтому «зарегистрирован и уже инвестор» здесь — регистрация до первого депозита. Режим выплат после первого депозита
    /// меняет `setPayoutMode`; пополнение обязано пройти и после смены (режим регистрации повторно не передаётся — иначе
    /// `deposit: payout mode`).
    function test_credit_deposit_first_by_is_investor() public {
        vm.prank(A);
        V.register(B, true);
        _deposit(A, 1000e6, "tx-a1");
        vm.prank(A);
        V.setPayoutMode(false);
        _deposit(A, 100e6, "tx-a2");
        assertTrue(PoolLedgerViews(address(V.ledger())).isInvestor(A));
        assertFalse(PoolLedgerViews(address(V.ledger())).isInvestor(B));
        assertEq(PoolLedgerViews(address(V.ledger())).totalStake(), 1100e6, "top-up credited");
    }

    // --- предел адресов: подъём под таймлоком (A9) ----------------------------------------------------------------- //
    function test_max_investors_raised_through_timelock_up_to_bound() public {
        H.setMaxInvestors(2);
        V = _vault(NO_CAP);
        _deposit(A, 100e6, "tx-a1");
        _deposit(B, 100e6, "tx-b1");
        _send(C, address(V), 100e8);
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSignature("Revert(string)", "deposit: investor limit"));
        V.creditDeposit(C, 100e6, "tx-c1");

        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.proposeMaxInvestors(3);
        V.proposeMaxInvestors(3);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.TooEarly.selector, block.timestamp + DELAY));
        V.applyMaxInvestors(3);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyMaxInvestors(4);
        vm.prank(G);
        vm.expectRevert(PoolVault.NotAdmin.selector);
        V.applyMaxInvestors(3);
        vm.expectEmit(false, false, false, true, address(V));
        emit PoolVault.MaxInvestorsRaised(3);
        V.applyMaxInvestors(3);
        (, uint256 mx) = PoolLedgerViews(address(V.ledger())).limits();
        assertEq(mx, 3);
        vm.prank(K);
        V.creditDeposit(C, 100e6, "tx-c1");

        bytes memory bad = abi.encodeWithSignature("Revert(string)", "max_investors");
        uint256[3] memory wrong = [uint256(2), 3, 44]; // вниз, без изменения, выше границы
        for (uint256 i = 0; i < 3; i++) {
            V.proposeMaxInvestors(wrong[i]);
            vm.warp(block.timestamp + DELAY);
            vm.expectRevert(bad);
            V.applyMaxInvestors(wrong[i]);
        }
        V.proposeMaxInvestors(43); // ровно граница
        vm.prank(G);
        V.cancel(6); // guardian снимает предложение
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(PoolVault.NotProposed.selector);
        V.applyMaxInvestors(43);
        V.proposeMaxInvestors(43);
        vm.warp(block.timestamp + DELAY);
        V.applyMaxInvestors(43);
        (, mx) = PoolLedgerViews(address(V.ledger())).limits();
        assertEq(mx, 43);
    }

    // --- события для сторожа (`vault_watch.CONTRACT_EVENTS_NEEDED`) ------------------------------------------------- //
    function test_watcher_events_orders_positions_withdrawable_settlement() public {
        _deposit(A, 1000e6, "tx-a1");
        _sweep();
        vm.startPrank(K);
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.OrderSized("p1", 500e6, 1, 0);
        assertEq(V.sizeOrder("p1", 500e6), 1);
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.OrderFilled("p1");
        V.fillOrder("p1");
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.PositionMarked("p1", -5e6);
        V.markPosition("p1", -5e6);
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.PositionClosed("p1", 7e6);
        V.closePosition("p1", 7e6);
        V.sizeOrder("p2", 100e6);
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.OrderCancelled("p2");
        V.cancelOrder("p2");
        vm.expectEmit(false, false, false, true, address(V));
        emit PoolVault.WithdrawableSet(800e6);
        V.setWithdrawable(800e6);
        vm.expectEmit(false, false, false, true, address(V));
        emit PoolVault.MondaySettled(1);
        V.monday();
        toNextCalendarWeek(); // ревью-3b: второй календарный расчёт — в следующей неделе
        V.mondayBegin();
        while (V.mondayStep(1000) != 0) {}
        vm.expectEmit(false, false, false, true, address(V));
        emit PoolVault.MondaySettled(2);
        V.mondayEnd();
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.OrderSized("p3", 100e6, 2, 2);
        V.sizeOrder("p3", 100e6);
        vm.stopPrank();
    }

    // --- ред. 9.5: внеочередной расчёт и предел поколений (спека 8.15) ------------------------------------------------- //
    /// @dev Хранилище не связывается с бухгалтерией без предела поколений (0 — «правила нет» эталона).
    function test_r95_vault_refuses_ledger_without_gen_limit() public {
        H.setMaxGens(0);
        PoolVault.VaultInit memory p = _init(address(this), DELAY, NO_CAP);
        vm.expectRevert(abi.encodeWithSelector(PoolVault.NotLinked.selector, address(p.ledger)));
        H.vault(p);
        H.setMaxGens(1000);
        p = _init(address(this), DELAY, NO_CAP);
        H.vault(p);
    }

    /// @dev Внеочередной расчёт хранилищем (предел 2): неделя бухгалтерии та же, событие расчёта есть, пауза депозитов его не
    /// держит; без права (ноль поколений с расчёта, должника нет) — отказ бухгалтерии; пачками — то же; календарный — неделя + 1.
    function test_r95_extra_settle_through_vault() public {
        H.setMaxGens(2);
        V = _vault(NO_CAP);
        _deposit(A, 1000e6, "tx-a1");
        _deposit(B, 500e6, "tx-b1");
        _sweep();
        PoolLedgerViews L = PoolLedgerViews(address(V.ledger()));
        vm.startPrank(K);
        V.sizeOrder("o1", 300e6);
        V.fillOrder("o1");
        V.markPosition("o1", -10e6);
        vm.stopPrank();
        V.pauseDeposits();
        int256 w0 = L.status()[1];
        vm.expectEmit(true, false, false, true, address(V));
        emit PoolVault.MondaySettled(uint256(w0));
        vm.prank(K);
        V.monday(false);
        assertEq(L.status()[1], w0, "extra settle keeps the week");
        vm.prank(K);
        vm.expectRevert(abi.encodeWithSelector(PoolLedgerBase.Revert.selector, "monday: extra settle not allowed"));
        V.monday(false);
        vm.startPrank(K);
        V.sizeOrder("o2", 300e6); // веса после марка другие — новое поколение, одно из ⌊2/2⌋
        V.mondayBegin(false);
        while (true) {
            (uint256 stage,,,) = L.mondayProgress();
            if (stage == 7) break;
            V.mondayStep(1);
        }
        V.mondayEnd();
        assertEq(L.status()[1], w0, "paged extra settle keeps the week");
        V.monday(true);
        vm.stopPrank();
        assertEq(L.status()[1], w0 + 1, "calendar settle moves the week");
    }
}
