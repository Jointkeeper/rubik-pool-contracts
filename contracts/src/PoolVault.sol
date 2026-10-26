// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {PoolLedger, PoolLedgerBase, PoolLedgerViews} from "./PoolLedger.sol";
import {TradingLeg} from "./TradingLeg.sol";
import {
    PoolVaultEmergency, EmergencyClock, EMERGENCY_SLOT, P_EMERGENCY, EMERGENCY_HASH, poolSink
} from "./PoolVaultEmergency.sol";

/// @title PoolVault — денежный слой пула Rubik поверх бухгалтерии `PoolLedger` (контракт #2, этап 6).
/// @notice Бухгалтерию ведёт `PoolLedger` (сверен с эталоном вызов за вызовом); здесь — только деньги и роли.
///
/// ДЕНЬГИ ЖИВУТ НА HYPERCORE. Депозит — переводом `Send` USDC на Core-адрес хранилища; мост EVM -> Core на счёт контракта
/// на testnet деньги НЕ зачислил (прогон #0, R1) и до проверки на mainnet не используется. Бухгалтерские плоскости
/// `spot` и `evm` — это деньги на Core-счёте ХРАНИЛИЩА (вторая — зарезервированные под «к получению»), `venue` — на
/// счетах двух торговых ног. Деньги уходят ТОЛЬКО на адрес держателя (`claim`), на ноги и обратно.
///
/// РОЛИ (README «Роли и доверие»). Admin (Safe): роли, ключи ног, партнёры, лимит TVL, снятие паузы. Смена admin, keeper,
/// guardian, добавление agent-ключа ноги, доля ног в раздаче и подъём предела адресов — ОДИН механизм таймлока:
/// предложение хранит хеш действия и срок `eta = now + DELAY`, перезапись сдвигает срок. Guardian (ключ человека): только
/// отнимает — пауза депозитов, отзыв keeper'а и agent-ключей сразу, отмена предложений admin'а (кроме замены самого
/// guardian). Восстановить ровно отозванное и снять паузу может только admin, сразу: адрес уже прошёл таймлок.
///
/// ЗАМОК КАССЫ G1 (`_slack`): `core − outPending − 100·(spot + evm + max(0, legFlow + venueCash)) >= 0` после каждой
/// операции keeper'а и до/после `claim`. `outPending` — исходящие `spotSend` текущего блока (прекомпайл их ещё видит);
/// `legFlow + venueCash` — деньги, ПОДТВЕРЖДЁННО пришедшие с ног и ещё не разнесённые бухгалтерией. Отправка с ноги и
/// раздача на ноги открывают ОКНО ноги до подтверждения по её кассе (`confirmLegSend`, `confirmSweep`, любой
/// вызывающий): пока окно открыто, притоки (`creditDeposit`, `coverShortfall`) отклоняются, а неподтверждённый приход —
/// излишек, которым зачислить депозит нельзя. Молчаливый отказ отправки с ноги замок не запирает.
///
/// ⚠ ГРАНИЦЫ, КОДОМ НЕ ЗАКРЫВАЕМЫЕ: (1) контракт не видит, КТО прислал `Send` — зачисление на верный адрес держится на
/// keeper'е (журнал перевода публичен и проверяем); (2) действия CoreWriter асинхронны, отказ на Core контракт не видит —
/// подтверждение окна судит кассу ноги в следующем блоке (видимость `spotSend` в b+1 — проба T1(а)); молча отказавшая
/// ВЫПЛАТА (`claim`) оставляет излишек, который ловит только сторож; (3) результаты сделок (`closePosition`) keeper
/// сообщает на доверии — сверка стоимости ног (G3/G4) вне этого контракта сегодня.
///
/// АВАРИЙНЫЙ ВЫХОД (ред. 9.4) — делегированный модуль `PoolVaultEmergency` (fallback, его память — свой слот): триггеры,
/// заморозка, раздача по правилу E. Здесь — только замок `_live()` во входах, часы триггеров и объявление admin'а.
contract PoolVault {
    uint64 internal constant USDC = 0;
    uint256 internal constant WEI_PER_MICRO = 100; // spot USDC на Core — 1e8 на доллар, бухгалтерия — микро (1e6)
    uint8 internal constant PATH_SPOT = 0;

    /// @dev Виды предложений таймлока — ОДНО пространство номеров на все действия (README «Таймлок: виды предложений»):
    /// 0 admin, 1 keeper, 2 guardian, 3 и 4 agent-ключ ноги A и B (`P_AGENT + leg`), 5 доля ноги A в раздаче (C7),
    /// 6 подъём предела адресов (A9), 7 объявление аварии (ред. 9.4, `P_EMERGENCY` модуля `PoolVaultEmergency`). Номера
    /// 5 и 6 читает сторож (`vault_watch.PROPOSAL_KIND`); совпадение двух видов сделало бы одно предложение исполнимым
    /// другим действием и дало бы отмене одного снять другое — уникальность судит `test_timelock_kinds_unique`.
    uint256 internal constant P_ADMIN = 0;
    uint256 internal constant P_KEEPER = 1;
    uint256 internal constant P_GUARDIAN = 2;
    uint256 internal constant P_AGENT = 3;
    uint256 internal constant P_SHARE = 5;
    uint256 internal constant P_LIMIT = 6;
    uint256 internal constant BPS = 10_000;
    /// @dev Нижняя граница таймлока (ревью-2, #5): замена keeper'а, guardian'а и agent-ключа идёт за `DELAY` — короче суток
    /// оператор не успевает ни заметить предложение, ни отменить его. Сроки модуля аварии — не короче `2·DELAY`.
    uint256 internal constant MIN_DELAY = 24 hours;

    /// @dev «Вывести всё» (A6, П5): служебная сумма заявки; при обработке подставляется свободная доля на этот момент.
    uint256 internal constant ALL = type(uint256).max;

    PoolLedger public immutable ledger;
    TradingLeg public immutable legA;
    TradingLeg public immutable legB;
    /// @notice Срок между предложением и исполнением (секунды). Значение — решение оператора, умолчания нет.
    uint256 public immutable DELAY;
    address public admin;
    address public keeper;
    address public guardian;
    /// @notice Отозванный guardian'ом/admin'ом keeper; `restoreKeeper` возвращает ровно его. Ноль — отозванного нет.
    address public revokedKeeper;
    /// @notice Пауза отклоняет ТОЛЬКО зачисление депозитов; выводы, выплаты, расчёт и торговля идут как прежде.
    bool public depositsPaused;
    /// @notice Лимит TVL (микро): капитал под управлением вместе с зачисляемым депозитом (A10, `totalStake + amount`).
    /// Значение — оператор.
    uint256 public tvlCap;
    /// @notice Счётчик отзывов agent-ключей: два отзыва никогда не дают один адрес замены (в том числе в одном блоке).
    uint256 public revokeNonce;
    /// @notice Доля ноги A в раздаче `sweepToLegs` (bps, 0..10000); нога B получает остаток. Меняется только таймлоком.
    uint256 public legShareBps;

    struct Pref {
        bool set;
        address referrer;
        bool payout;
    }

    struct Intent {
        address addr;
        uint256 amount;
        bool reward;
    }

    /// @notice Предложение таймлока: хеш действия и срок. `hash == 0` — предложения нет.
    struct Proposal {
        bytes32 hash;
        uint256 eta;
    }

    struct Agent {
        address agent;
        bool revoked;
    }

    /// @notice Окно перевода ноги: блок отправки, сумма (микро), касса ноги в начале блока (wei), направление.
    /// `blockNo == 0` — окна нет.
    struct Window {
        uint64 blockNo;
        uint64 amount;
        uint64 before;
        bool fromLeg;
    }

    /// @notice Параметры развёртывания (`deploy/params.*.json`); умолчаний нет. Бухгалтерия и ноги развёрнуты ДО хранилища
    /// (КЕ10) на его вычисленный адрес; параметры бухгалтерии (treasury, bps, реализации) — аргументы её конструктора.
    struct VaultInit {
        PoolLedger ledger;
        TradingLeg legA;
        TradingLeg legB;
        address admin;
        address keeper;
        address guardian;
        uint256 delay;
        uint256 tvlCap;
        uint256 legShareBps;
        PoolVaultEmergency emergency;
    }

    mapping(address => Pref) public prefs;
    Intent[] public intents;
    uint256 public nextIntent;
    /// @notice Есть ли у адреса необработанная заявка (A6: одна открытая заявка на адрес; снимается обработкой — исполнением
    /// или отказом бухгалтерии).
    mapping(address => bool) public openIntent;
    mapping(uint256 => Proposal) public proposals;
    /// @notice Применённый agent-ключ по `keccak256(abi.encode(leg, name))` и отозван ли он.
    mapping(bytes32 => Agent) public agents;
    Window[2] public windows;
    /// @notice Подтверждённо пришедшее с ног минус отправленное на ноги (микро); `legFlow + venueCash` — не разнесённое.
    int256 public legFlow;
    /// @dev Блок последнего перевода perp <-> spot ноги: в нём касса ноги в начале блока не равна кассе до отправки.
    uint64[2] internal legActBlock;
    uint64 internal outBlock;
    uint192 internal outWei;

    // --- ред. 9.4: аварийный выход ----------------------------------------------------------------------------------- //
    /// @notice Модуль аварии (делегированный, КЕ10): адрес неизменяем — сеттера нет (В12: подмена модуля = кража всего).
    address public immutable emergency;
    /// @dev Часы триггеров: последняя операция keeper'а, открытие и закрытие расчёта, `nextQid` бухгалтерии.
    EmergencyClock internal clock;
    /// @notice В7′: журнал рождения заявок бухгалтерии — (первый id заявок операции keeper'а << 64) | время операции.
    uint256[] public qStamps;
    /// @dev `T_serve`: время подачи заявки хранилища по её id.
    mapping(uint256 => uint64) internal intentAt;

    event Registered(address indexed investor, address referrer, bool payout);
    event DepositCredited(address indexed investor, uint256 amount, bytes32 ledgerRef);
    /// @notice Незачтённый `Send` возвращён отправителю (`reason` — причина отказа из симуляции keeper'а, план пакета §5).
    /// `token` — индекс токена Core (сегодня только USDC = 0; возврат не-USDC — A11, не реализован).
    event DepositRefunded(address indexed to, uint64 token, uint64 amountWei, bytes32 indexed ledgerRef, uint8 reason);
    event WithdrawRequested(uint256 indexed id, address indexed investor, uint256 amount, bool reward);
    event WithdrawProcessed(uint256 indexed id, int256 paid, int256 queued);
    event WithdrawRejected(uint256 indexed id, bytes reason);
    event Paid(address indexed to, uint256 amount);
    event Moved(string what, uint256 leg, uint256 amount);
    event LegTransferConfirmed(uint256 indexed leg, bool fromLeg, uint256 amount, bool arrived);
    event Proposed(uint256 indexed kind, bytes32 hash, uint256 eta);
    event ProposalCancelled(uint256 indexed kind, bytes32 hash, address by);
    event AdminChanged(address indexed previous, address indexed current);
    event KeeperChanged(address indexed previous, address indexed current);
    event GuardianChanged(address indexed previous, address indexed current);
    event AgentSet(uint256 indexed leg, address agent, string name);
    /// @notice `replacement` — свежий адрес без ключа, поставленный Core по имени `name` вместо `agent`. Контракт
    /// исход не видит (прекомпайла ролей нет): keeper/сторож обязаны проверить `userRole(agent) == missing`.
    event AgentRevoked(uint256 indexed leg, address agent, string name, address replacement);
    event AgentRestored(uint256 indexed leg, address agent, string name);
    event KeeperRevoked(address indexed keeper, address by);
    event LegOrdersCancelled(uint256 indexed leg, uint64[] oids);
    event DepositsPauseSet(bool paused);
    event TvlCapSet(uint256 cap);
    event LegShareSet(uint256 bpsA);
    event MaxInvestorsRaised(uint256 maxInvestors);
    /// @notice События для сторожа (`vault_watch.CONTRACT_EVENTS_NEEDED`): решение контракта датируется блоком, а не снимком.
    event ShortfallCovered(uint256 amount, bytes32 ledgerRef);
    /// @notice `gen` — поколение весов ордера (ответ бухгалтерии), `week` — неделя бухгалтерии на момент размера.
    event OrderSized(bytes32 indexed pid, uint256 notional, int256 gen, uint256 week);
    event OrderFilled(bytes32 indexed pid);
    event OrderCancelled(bytes32 indexed pid);
    event PositionMarked(bytes32 indexed pid, int256 upnl);
    event PositionClosed(bytes32 indexed pid, int256 realized);
    /// @notice Частичное закрытие: результат части (в R поколения), нотионал и марк ОСТАТКА — ровно аргументы вызова, всё, что он
    /// меняет в ордере (сторож: свёртка автомата ордера W9 и Σ realized W7 по событиям).
    event PositionReduced(bytes32 indexed pid, int256 realized, uint256 notional, int256 upnl);
    event WithdrawableSet(uint256 amount);
    /// @notice Недельный расчёт завершён; `week` — неделя бухгалтерии, открытая этим расчётом (`status()[1]`).
    event MondaySettled(uint256 week);

    error NotAdmin();
    error NotKeeper();
    error VaultSlack(int256 slackWei);
    error AlreadyRegistered();
    error ZeroAddress();
    error SelfReferrer();
    error MondayOpen();
    error NotProposed();
    error TooEarly(uint256 eta);
    error Paused();
    error NothingToChange();
    error LegBusy(uint256 leg);
    error NoWindow(uint256 leg);
    error BadAmount();
    error WithdrawableAbovePhysical(uint256 amount, uint256 physical);
    error TvlCapExceeded(uint256 capital, uint256 cap);
    error IntentOpen();
    error AboveFree(uint256 amount, int256 free);
    error NotActivated(address account);
    error AgentIsUser(address agent);
    error ZeroSalt();
    error NotLinked(address part);
    error BadRecipient(address to);
    error Frozen();
    error Matured(uint256 eta);
    error BadDelay(uint256 delay);

    /// @dev Ред. 9.4: после заморозки admin не правит ничего (В8: ни ролей, ни партнёров, ни лимита). Agent-ключи ног —
    /// `onlyAdminKeys`.
    modifier onlyAdmin() {
        _adminLive();
        _;
    }

    function _adminLive() internal view {
        _live();
        _admin();
    }

    function _admin() internal view {
        if (msg.sender != admin) revert NotAdmin();
    }

    /// @dev Ревью-3, R3-A: agent-ключи ног admin ведёт и после заморозки. Закрыть позиции ног после заморозки может только agent
    /// (модуль аварии позиций не закрывает), а отзыв guardian'а (`onlyPauser`) открыт и тогда — без этого отзыв был бы
    /// необратим. Права те же, что до заморозки: `restoreAgent` — ровно отозванный ключ, сразу; новый ключ — таймлоком
    /// (`cancel` guardian'а открыт и после заморозки). Денег хранилища agent-ключ не двигает: ни один вход keeper'а,
    /// инвестора и прочих admin-действий после заморозки не открыт (`_live`).
    modifier onlyAdminKeys() {
        _admin();
        _;
    }

    /// @dev ЕДИНСТВЕННАЯ точка прав на действия, которые только отнимают: пауза депозитов, отзыв keeper'а и agent-ключей.
    modifier onlyPauser() {
        if (msg.sender != admin && msg.sender != guardian) revert NotAdmin();
        _;
    }

    modifier onlyKeeper() {
        _keeperLive();
        _;
        _keeperDone();
    }

    function _keeperLive() internal view {
        _live();
        if (msg.sender != keeper) revert NotKeeper();
    }

    /// @notice КЕ10: бухгалтерия и обе ноги развёрнуты заранее, их владелец — вычисленный адрес хранилища (README «Схема
    /// деплоя»). Связность судится здесь: части без кода, чужой владелец бухгалтерии, нога чужого хранилища или одна нога на
    /// оба места — отказ. Адреса неизменяемы; что по ним лежит ИМЕННО ожидаемый код, проверяет манифест (`codehash`).
    constructor(VaultInit memory p) {
        if (p.admin == address(0) || p.keeper == address(0) || p.guardian == address(0)) revert ZeroAddress();
        if (p.legShareBps > BPS) revert BadAmount();
        if (p.delay < MIN_DELAY) revert BadDelay(p.delay);
        _assertLinked(p);
        ledger = p.ledger;
        legA = p.legA;
        legB = p.legB;
        admin = p.admin;
        keeper = p.keeper;
        guardian = p.guardian;
        DELAY = p.delay;
        tvlCap = p.tvlCap;
        legShareBps = p.legShareBps;
        emergency = address(p.emergency);
        clock.keeperAt = uint64(block.timestamp);
    }

    function _assertLinked(VaultInit memory p) internal view {
        address l = address(p.ledger);
        if (l.code.length == 0) revert NotLinked(l);
        (address owner,,,,,,,) = PoolLedgerViews(l).params();
        if (owner != address(this)) revert NotLinked(l);
        if (address(p.legA) == address(p.legB)) revert NotLinked(address(p.legB));
        TradingLeg[2] memory legs = [p.legA, p.legB];
        for (uint256 i = 0; i < 2; i++) {
            if (address(legs[i]).code.length == 0 || legs[i].vault() != address(this)) revert NotLinked(address(legs[i]));
        }
        // ред. 9.4: модуль аварии с кодом, и ни один его срок не короче ДВУХ таймлоков (ревью-2, #5): новый keeper ставится
        // предложением за `DELAY`, и срок обязан пережить замену с запасом ещё на один `DELAY` (заметить, предложить, дождаться)
        address e = address(p.emergency);
        if (e.code.length == 0 || p.emergency.minTerm() < 2 * p.delay) revert NotLinked(e);
        // ред. 9.5: бухгалтерия без предела поколений (0 — «правила нет», только у стендов эталона) — отказ: без предела
        // газ расчёта не ограничен, а внеочередной расчёт принимался бы без условия
        (uint256 mg,,) = PoolLedgerViews(l).genLimits();
        if (mg == 0) revert NotLinked(l);
    }

    // --- замок кассы G1 ------------------------------------------------------------------------------------------- //
    function _coreWei() internal view returns (uint256) {
        return PrecompileLib.spotBalance(address(this), USDC).total;
    }

    /// @dev Исходящие `spotSend` хранилища в ТЕКУЩЕМ блоке (wei): прекомпайл видит состояние начала блока, деньги уйдут
    /// после него.
    function _outPending() internal view returns (uint256) {
        return outBlock == block.number ? outWei : 0;
    }

    function _out(uint256 w) internal {
        uint256 cur = _outPending();
        outBlock = uint64(block.number);
        outWei = uint192(cur + w);
    }

    /// @dev Деньги, подтверждённо пришедшие с ног и ещё не разнесённые бухгалтерией (микро, не меньше нуля). `venueCash`
    /// растёт только раздачей на ноги и падает только разнесением прихода (`_fundClaimable`).
    function _unbooked(int256[13] memory s) internal view returns (int256 u) {
        u = legFlow + s[9];
        if (u < 0) u = 0;
    }

    function _slack() internal view returns (int256) {
        return _slackWith(PoolLedgerViews(address(ledger)).status());
    }

    function _slackWith(int256[13] memory s) internal view returns (int256) {
        return _slackOf(s, _unbooked(s));
    }

    /// @dev `core − outPending − 100·(spot + evm + u)`: ЕДИНСТВЕННЫЙ владелец формулы излишка; `u` — не разнесённое с ног.
    function _slackOf(int256[13] memory s, int256 u) internal view returns (int256) {
        return int256(_coreWei()) - int256(_outPending()) - (s[7] + s[8] + u) * int256(WEI_PER_MICRO);
    }

    /// @dev Хвост каждой операции keeper'а: замок G1 и часы триггеров аварии — одним чтением `status()`. Новые заявки
    /// бухгалтерии (сдвиг `nextQid`) родились в ЭТОЙ операции: их время — запись журнала `qStamps` (В7′).
    function _keeperDone() internal {
        int256[13] memory s = PoolLedgerViews(address(ledger)).status();
        int256 x = _slackWith(s);
        if (x < 0) revert VaultSlack(x);
        EmergencyClock memory c = clock;
        c.keeperAt = uint64(block.timestamp);
        uint64 nq = uint64(uint256(s[6]));
        if (nq != c.qSeen) {
            qStamps.push((uint256(c.qSeen) << 64) | block.timestamp);
            c.qSeen = nq;
        }
        clock = c;
    }

    /// @dev Ред. 9.4: пул заморожен — младший байт слова модуля аварии (`PoolVaultEmergency.Store.state`).
    function _live() internal view {
        bytes32 slot = EMERGENCY_SLOT;
        uint256 w;
        assembly {
            w := sload(slot)
        }
        if (w & 0xff != 0) revert Frozen();
    }

    function _assertSlack() internal view {
        int256 x = _slack();
        if (x < 0) revert VaultSlack(x);
    }

    /// @notice Излишек Core-счёта хранилища над обязательствами (wei): незачтённые `Send`, неподтверждённый приход с ног,
    /// остатки wei mod 100. Отрицательный — замок G1 закрыт.
    function vaultSlack() external view returns (int256) {
        return _slack();
    }

    /// @notice U_s аварии (wei): тот же излишек, но не разнесённое с ног `legFlow + venueCash` БЕЗ обрезки нулём снизу (эталон
    /// `emergency_foreign`, находка ревью F2). Отрицательное `u` — бухгалтерия уже провела деньги с ног (вывод из ликвидности
    /// ног), а физически они ещё на ноге и придут позже; замок G1 их не засчитывает (сторона отказа), а излишек на заморозке —
    /// обязан: иначе чужой незачтённый `Send` на ту же сумму ушёл бы держателям. Только для фиксации U_s при заморозке.
    function vaultSlackSigned() external view returns (int256) {
        int256[13] memory s = PoolLedgerViews(address(ledger)).status();
        return _slackOf(s, legFlow + s[9]);
    }

    /// @dev Открыт ли недельный расчёт пачками (`status()[11]`, флаг `mondayOpen` бухгалтерии). Пока открыт, бухгалтерия
    /// отклоняет всё, кроме шагов расчёта.
    function _mondayOpen() internal view returns (bool) {
        return PoolLedgerViews(address(ledger)).status()[11] != 0;
    }

    /// @dev Приток создаёт обязательство хранилища: пока перевод ноги не подтверждён, излишек может быть деньгами ног.
    function _assertNoWindows() internal view {
        for (uint256 i = 0; i < 2; i++) {
            if (windows[i].blockNo != 0) revert LegBusy(i);
        }
    }

    // --- инвестор ------------------------------------------------------------------------------------------------ //
    /// @notice Реферал и режим выплат — ДО первого депозита и один раз (бухгалтерия принимает их только первым депозитом).
    /// Самореферал отклоняется здесь: бухгалтерия отвергла бы с ним КАЖДЫЙ депозит адреса, а повторить регистрацию нельзя —
    /// адрес был бы навсегда закрыт для депозитов. Ревью-3, R3-I: после первого депозита (`_old`) — тот же отказ
    /// `AlreadyRegistered`: бухгалтерия режим и реферала уже не примет, и молчаливая запись выглядела бы включённой.
    function register(address referrer, bool payout) external {
        _live();
        if (prefs[msg.sender].set || _old(msg.sender)) revert AlreadyRegistered();
        if (referrer == msg.sender) revert SelfReferrer();
        if (_sink(referrer)) revert BadRecipient(referrer); // ревью 20.10, F3: нога/хранилище в держателях — двойной счёт аварии
        prefs[msg.sender] = Pref(true, referrer, payout);
        emit Registered(msg.sender, referrer, payout);
    }

    /// @notice Заявка на вывод (A6, П5): одна открытая на адрес; сумма — либо точная (`withdrawAll = false`, > 0), либо
    /// «всё» (`withdrawAll = true`, сумма обязана быть 0): контракт ставит служебное `ALL`, и при обработке выводится
    /// свободная доля на тот момент. Свободная доля проверяется ПРИ ПОДАЧЕ (`freeStake`, газ платит заявитель): заявки
    /// не-держателей и сверх свободного отклоняются сразу, а не стоят в очереди перед честными (В4 пакета). К обработке
    /// доля может измениться — тогда отказ бухгалтерии событием. Ред. 9.4: после заморозки — отказ (`Frozen`) раньше всех
    /// проверок, в том числе «всё»; время подачи — для триггера `T_serve`.
    function requestWithdraw(uint256 amount, bool reward, bool withdrawAll) external returns (uint256 id) {
        _live();
        if (openIntent[msg.sender]) revert IntentOpen();
        if (withdrawAll ? amount != 0 : amount == 0) revert BadAmount();
        int256 free = PoolLedgerViews(address(ledger)).freeStake(msg.sender, reward);
        if (free <= 0 || amount > uint256(free)) revert AboveFree(amount, free);
        if (withdrawAll) amount = ALL;
        openIntent[msg.sender] = true;
        id = intents.length;
        intentAt[id] = uint64(block.timestamp);
        intents.push(Intent(msg.sender, amount, reward));
        emit WithdrawRequested(id, msg.sender, amount, reward);
    }

    function setPayoutMode(bool payout) external {
        ledger.setPayoutMode(msg.sender, payout);
    }

    function claim() external returns (int256 paid) {
        paid = _claim(msg.sender);
        _assertSlack();
    }

    /// @dev Выплата идёт ТОЛЬКО на адрес держателя `a` (он же отправитель депозита — решение 18.10). Замок G1 судится
    /// ПОСЛЕ (`claim`, модификатор `claimFor`): выплата его не меняет (`held` падает ровно на то, на что растёт
    /// `outPending`), поэтому проверка до неё была бы тем же числом.
    function _claim(address a) internal returns (int256 paid) {
        _activated(a);
        paid = ledger.claim(a);
        CoreWriterLib.spotSend(a, USDC, uint64(uint256(paid) * WEI_PER_MICRO));
        _out(uint256(paid) * WEI_PER_MICRO);
        emit Paid(a, uint256(paid));
    }

    /// @dev Адрес уже вносил деньги: бухгалтерия приняла его первый депозит, реферал и режим выплат уже не меняются. O(1):
    /// полная витрина считала бы проекцию. Один владелец «первого депозита» для `creditDeposit` и `register` (R3-I).
    function _old(address a) internal view returns (bool) {
        return PoolLedgerViews(address(ledger)).isInvestor(a);
    }

    /// @dev Набор адресов, которым деньги пула не идут и которые не бывают рефералом, — `poolSink` (один владелец).
    function _sink(address a) internal view returns (bool) {
        return poolSink(a, address(this), address(legA), address(legB), address(ledger));
    }

    /// @dev Получатель `spotSend` обязан быть на Core: иначе Core спишет с хранилища комиссию активации (1 USDC) сверх
    /// суммы — мимо бухгалтерии, и G1 со следующего блока закроется у всех. Держатель активирован своим депозитом
    /// (решение 18.10); реферал, ни разу не присылавший денег, копит награду до активации.
    function _activated(address a) internal view {
        if (!PrecompileLib.coreUserExists(a)) revert NotActivated(a);
    }

    // --- keeper: деньги снаружи --------------------------------------------------------------------------------- //
    /// @notice Депозит, уже пришедший `Send` на Core-адрес хранилища. `ledgerRef` — хеш записи леджера Core: бухгалтерия
    /// не зачтёт его дважды. Реферал и режим берутся из `register` и передаются ТОЛЬКО первым депозитом адреса.
    function creditDeposit(address a, uint256 amount, bytes32 ledgerRef) external onlyKeeper {
        if (depositsPaused) revert Paused();
        _assertNoWindows();
        // A10: мера — капитал под управлением + депозит, а не физические деньги: те растут от прибыли пула и зависят от
        // порядка прихода двух `Send`
        uint256 capital = uint256(PoolLedgerViews(address(ledger)).totalStake()) + amount;
        if (capital > tvlCap) revert TvlCapExceeded(capital, tvlCap);
        Pref memory p = prefs[a];
        bool first = !_old(a);
        uint8 payout = first && p.set ? (p.payout ? 2 : 1) : 0;
        address referrer = first && p.set ? p.referrer : address(0);
        ledger.deposit(a, amount, referrer, payout, PATH_SPOT, ledgerRef);
        if (clock.mondayEndAt == 0) clock.mondayEndAt = uint64(block.timestamp); // `T_nomonday` и `T_dead` — с первых денег
        emit DepositCredited(a, amount, ledgerRef);
    }

    /// @notice П3 / V3 пакета безопасности: `Send` USDC на Core хранилища, который бухгалтерия НЕ зачла (ниже минимума, предел
    /// адресов, долг пула, treasury, пауза), keeper возвращает ОТПРАВИТЕЛЮ — решение 18.10: «выводить туда, откуда пришло».
    /// Запись перевода `ledgerRef` сгорает в бухгалтерии (`refundRef`, общее пространство с депозитами и `coverShortfall`):
    /// один перевод нельзя ни вернуть дважды, ни вернуть и зачесть. Сумма — в wei Core (8 знаков): возвращается ровно
    /// пришедшее, без округления до микро. Пауза возврата не трогает (отказ зачисления обязан вернуться отправителю).
    /// Деньги возврата — только излишек кассы: замок G1 после вызова (`onlyKeeper`) судит `core − outPending − held >= 0`, и
    /// `outPending` уже несёт этот возврат и ВСЕ исходящие этого блока (Н5: фантом после `claim`/`sweep` возвратом не взять).
    /// Пока окно перевода ноги открыто, неподтверждённый приход с ноги — тоже «излишек»: возврат отклоняется, как приток.
    /// ⚠ Контракт не видит, кто прислал `Send` (граница (1) шапки): адресат — запись леджера, которую keeper называет, а
    /// сторож сверяет. Код держит, что можно: адресат — Core-пользователь (отправитель активирован по определению, и комиссия
    /// активации на хранилище не ляжет), не из набора `poolSink` (хранилище, ноги, бухгалтерия, системный адрес токена).
    /// Возврат не-USDC (A11) не реализован — решение открыто.
    function refundDeposit(address to, uint64 amountWei, bytes32 ledgerRef, uint8 reason) external onlyKeeper {
        _assertNoWindows();
        if (to == address(0) || _sink(to)) revert BadRecipient(to);
        if (amountWei == 0) revert BadAmount();
        _activated(to);
        ledger.refundRef(ledgerRef);
        CoreWriterLib.spotSend(to, USDC, amountWei);
        _out(amountWei);
        emit DepositRefunded(to, USDC, amountWei, ledgerRef, reason);
    }

    function coverShortfall(uint256 amount, bytes32 ledgerRef) external onlyKeeper returns (int256 left) {
        _assertNoWindows();
        left = ledger.coverShortfall(amount, PATH_SPOT, ledgerRef);
        emit ShortfallCovered(amount, ledgerRef);
    }

    /// @notice Депозит, пришедший на PERP-счёт хранилища (`usdSend`): перевод на spot, затем — `creditDeposit` как обычно.
    /// Сумма — не больше выводимого perp хранилища (иначе Core отказал бы молча).
    function vaultToSpot(uint64 usd) external onlyKeeper {
        if (usd == 0 || usd > PrecompileLib.withdrawable(address(this))) revert BadAmount();
        CoreWriterLib.transferUsdClass(usd, false);
        emit Moved("vaultToSpot", 2, usd);
    }

    // --- keeper: заявки и выплаты ------------------------------------------------------------------------------- //
    /// @notice Заявки исполняются СТРОГО по порядку подачи. Бизнес-отказ бухгалтерии (сумма ноль или больше свободной доли,
    /// сумма вне uint128) приходит КОДОМ (`PoolLedger.withdraw` -> `status`) и уходит событием `WithdrawRejected`, а не
    /// останавливает очередь; обработка в обоих исходах снимает `openIntent` адреса. Бухгалтерия зовётся БЕЗ `try`: любой её
    /// отказ — нехватка газа на ЛЮБОЙ глубине (в том числе во вложенной проекции `_projCall`), инвариант, заморозка —
    /// откатывает ВСЮ транзакцию, `nextIntent` и `openIntent` на месте, заявку нельзя «съесть» подбором газа (§4.2 намерений,
    /// находка ревью: порог EIP-150 одного фрейма вложенный staticcall обходил). Пока открыт недельный расчёт пачками, вызов
    /// отклоняется целиком (`MondayOpen`): бухгалтерия отвергла бы каждую заявку.
    /// ⚠ Цена правила: заявка, на которой бухгалтерия откатывается ДЕТЕРМИНИРОВАННО (не газ), останавливает очередь до правки
    /// причины — громко (keeper видит отказ, сторож — стоящую очередь, авария — `T_serve`), а не тихой потерей заявки.
    function processWithdrawals(uint256 n) external onlyKeeper {
        if (_mondayOpen()) revert MondayOpen();
        uint256 i = nextIntent;
        // насыщение, а не `i + n` (ревью-2, #8): `n` у keeper'а — «сколько есть» (до type(uint256).max) без переполнения
        uint256 end = intents.length - i <= n ? intents.length : i + n;
        for (; i < end; i++) {
            Intent memory it = intents[i];
            _processOne(i, it);
            delete openIntent[it.addr];
        }
        nextIntent = i;
    }

    /// @dev Одна заявка: «всё» — свободная доля сейчас (`freeStake`: витрина, бизнес-отказов у неё нет), затем
    /// `ledger.withdraw`. Ответ бухгалтерии — код; отказ кодом уходит событием с прежней причиной (`Revert(string)` эталона:
    /// сторож и журнал читают её как раньше). Вызовы — без `try`: их отказ — отказ транзакции. Ответ — исполнена ли заявка.
    function _processOne(uint256 i, Intent memory it) internal returns (bool done) {
        uint256 amt = it.amount;
        if (amt == ALL) {
            int256 f = PoolLedgerViews(address(ledger)).freeStake(it.addr, it.reward);
            amt = f > 0 ? uint256(f) : 0; // ноль бухгалтерия отклонит кодом (`W_AMOUNT`)
        }
        (uint8 st, int256 paid, int256 queued) = ledger.withdraw(it.addr, amt, it.reward);
        done = st == 0;
        if (done) {
            emit WithdrawProcessed(i, paid, queued);
        } else {
            // коды бухгалтерии (`PoolLedgerBase.W_*`): 1 — ноль или больше свободной доли, 2 — сумма вне uint128
            if (st > 2) revert BadAmount();
            emit WithdrawRejected(i, abi.encodeWithSelector(PoolLedgerBase.Revert.selector, st == 1 ? "withdraw: amount" : "uint128"));
        }
    }

    function claimFor(address a) external onlyKeeper returns (int256) {
        return _claim(a);
    }

    function payQueue() external onlyKeeper {
        ledger.payQueue();
    }

    function treasuryPayout() external onlyKeeper returns (int256 paid, int256 queued) {
        return ledger.treasuryPayout();
    }

    // --- keeper: торговля (книга бота) -------------------------------------------------------------------------- //
    function sizeOrder(bytes32 pid, uint256 notional) external onlyKeeper returns (int256 gen) {
        gen = ledger.sizeOrder(pid, notional);
        emit OrderSized(pid, notional, gen, _week());
    }

    function fillOrder(bytes32 pid) external onlyKeeper {
        ledger.fillOrder(pid);
        emit OrderFilled(pid);
    }

    function cancelOrder(bytes32 pid) external onlyKeeper {
        ledger.cancelOrder(pid);
        emit OrderCancelled(pid);
    }

    function markPosition(bytes32 pid, int256 upnl) external onlyKeeper {
        ledger.markPosition(pid, upnl);
        emit PositionMarked(pid, upnl);
    }

    function closePosition(bytes32 pid, int256 realized) external onlyKeeper {
        ledger.closePosition(pid, realized);
        emit PositionClosed(pid, realized);
    }

    function _week() internal view returns (uint256) {
        return uint256(PoolLedgerViews(address(ledger)).status()[1]);
    }

    /// @notice Ред. 9.3: частичное закрытие (результат части, нотионал и марк ОСТАТКА — из одного снимка venue, спека 8.12 F3).
    function reducePosition(bytes32 pid, int256 realized, uint256 notional, int256 upnl) external onlyKeeper {
        ledger.reducePosition(pid, realized, notional, upnl);
        emit PositionReduced(pid, realized, notional, upnl);
    }

    /// @notice G2: ликвидность бухгалтерии не больше физически выводимого — выводимое perp обеих ног + их spot + не
    /// разнесённый приход с ног на хранилище. Неподтверждённые переводы не считаются (сторона отказа, а не обещания).
    function setWithdrawable(uint256 amount) external onlyKeeper {
        _assertWithdrawable(amount, PoolLedgerViews(address(ledger)).status());
        ledger.setWithdrawable(amount);
        emit WithdrawableSet(amount);
    }

    function _assertWithdrawable(uint256 amount, int256[13] memory s) internal view {
        uint256 phys = _physWithdrawable(s);
        if (amount > phys) revert WithdrawableAbovePhysical(amount, phys);
    }

    /// @notice G2: физически выводимое — выводимое perp обеих ног + их свободный spot + не разнесённый приход. Триггер аварии
    /// В7′ её не читает (ревью 20.10): её двигают посторонний донатом на ногу и торговый ключ удержанием spot/маржи.
    function physicalWithdrawable() external view returns (uint256) {
        return _physWithdrawable(PoolLedgerViews(address(ledger)).status());
    }

    function _physWithdrawable(int256[13] memory s) internal view returns (uint256 phys) {
        phys = uint256(_unbooked(s));
        for (uint256 i = 0; i < 2; i++) {
            address l = address(_leg(i));
            // нога не на Core (бета на одной ноге, C7) денег не имеет; её прекомпайлы не читаются — их поведение на
            // неактивированном адресе HL не описано (ревью 20.10, R7)
            if (!PrecompileLib.coreUserExists(l)) continue;
            PrecompileLib.SpotBalance memory b = PrecompileLib.spotBalance(l, USDC);
            phys += PrecompileLib.withdrawable(l) + (b.total - b.hold) / WEI_PER_MICRO;
        }
    }

    // --- keeper: недельный расчёт ------------------------------------------------------------------------------- //
    function monday() external onlyKeeper {
        ledger.monday();
        _settled();
    }

    /// @notice Ред. 9.5: `false` — ВНЕОЧЕРЕДНОЙ расчёт (неделя бухгалтерии не сдвигается). Право судит бухгалтерия: открыто
    /// поколений с расчёта не меньше половины предела или есть должник по маркам — иначе отказ (спека 8.15).
    function monday(bool calendar) external onlyKeeper {
        ledger.monday(calendar);
        _settled();
    }

    /// @dev Расчёт закрыт: перезапуск `T_nomonday` и событие. Часы аварии идут только с первого зачисленного депозита
    /// (ревью 20.10, R6): расчёт пула без денег их не запускает — иначе посторонний заморозил бы ещё не запущенный пул
    /// по `T_dead` / `T_nomonday`.
    function _settled() internal {
        if (clock.mondayEndAt != 0) clock.mondayEndAt = uint64(block.timestamp);
        emit MondaySettled(_week());
    }

    /// @notice G2 и на открытии расчёта пачками: выплаты очереди в `mondayEnd` берут ликвидность бухгалтерии, и если её
    /// нет физически, `mondayEnd` откатится G1 при открытом расчёте — а тогда бухгалтерия не даст опустить `withdrawable`.
    /// Атомарный `monday()` откатывается целиком и этой проверки не требует.
    function mondayBegin() external onlyKeeper {
        _mondayBegin(true);
    }

    /// @notice Ред. 9.5: тот же расчёт пачками; `false` — внеочередной (условие — как у `monday(false)`).
    function mondayBegin(bool calendar) external onlyKeeper {
        _mondayBegin(calendar);
    }

    function _mondayBegin(bool calendar) internal {
        int256[13] memory s = PoolLedgerViews(address(ledger)).status();
        _assertWithdrawable(uint256(s[10]), s);
        ledger.mondayBegin(calendar);
        clock.mondayBeganAt = uint64(block.timestamp);
    }

    function mondayStep(uint256 k) external onlyKeeper returns (uint256) {
        return ledger.mondayStep(k);
    }

    function mondayEnd() external onlyKeeper {
        ledger.mondayEnd();
        _settled();
    }

    // --- keeper: деньги между хранилищем и ногами --------------------------------------------------------------- //
    /// @dev Касса ноги в начале блока равна кассе до перевода, только если в этом блоке и в окне её не двигало ничто иное.
    function _legFree(uint256 leg) internal view {
        if (windows[leg].blockNo != 0 || legActBlock[leg] == block.number) revert LegBusy(leg);
    }

    function _legSpot(uint256 leg) internal view returns (PrecompileLib.SpotBalance memory) {
        return PrecompileLib.spotBalance(address(_leg(leg)), USDC);
    }

    /// @notice Бухгалтерский перевод свободного сверх буфера и очереди в торговлю И физическая отправка его ногам: нога A
    /// получает `legShareBps` (округление вниз), нога B — остаток (C7: бета на одной ноге — 10000/0). Окно открывается у
    /// каждой ноги, получившей деньги, до `confirmSweep`; нога с нулевой долей не получает ничего, окна и проверки
    /// активации у неё нет, и торгующей ей быть не нужно. Ноги переводят полученное на perp отдельным шагом (`legToPerp`).
    function sweepToLegs() external onlyKeeper returns (int256 move) {
        _legFree(0);
        _legFree(1);
        move = ledger.sweepToPerp();
        if (move > 0) {
            legFlow -= move; // venueCash вырос на move: сумма не меняется, пока раздача не подтверждена
            uint256 toA = uint256(move) * legShareBps / BPS;
            _sendToLeg(0, toA);
            _sendToLeg(1, uint256(move) - toA);
            _out(uint256(move) * WEI_PER_MICRO);
            emit Moved("sweep", 0, uint256(move));
        }
    }

    function _sendToLeg(uint256 leg, uint256 micro) internal {
        if (micro == 0) return;
        _activated(address(_leg(leg)));
        windows[leg] = Window(uint64(block.number), uint64(micro), _legSpot(leg).total, false);
        CoreWriterLib.spotSend(address(_leg(leg)), USDC, uint64(micro * WEI_PER_MICRO));
    }

    function legToPerp(uint256 leg, uint64 usd) external onlyKeeper {
        if (windows[leg].blockNo != 0) revert LegBusy(leg);
        legActBlock[leg] = uint64(block.number);
        _leg(leg).toPerp(usd);
        emit Moved("toPerp", leg, usd);
    }

    function legToSpot(uint256 leg, uint64 usd) external onlyKeeper {
        if (windows[leg].blockNo != 0) revert LegBusy(leg);
        legActBlock[leg] = uint64(block.number);
        _leg(leg).toSpot(usd);
        emit Moved("toSpot", leg, usd);
    }

    /// @notice Нога отправляет хранилищу `usd` (микро) со своего spot. Сумма — не больше кассы ноги в этом блоке; окно
    /// ноги открыто до `confirmLegSend`. До подтверждения приход в замке G1 не считается.
    function legSendToVault(uint256 leg, uint64 usd) external onlyKeeper {
        _legFree(leg);
        PrecompileLib.SpotBalance memory b = _legSpot(leg);
        if (usd == 0 || uint256(usd) * WEI_PER_MICRO > b.total - b.hold) revert BadAmount();
        windows[leg] = Window(uint64(block.number), usd, b.total, true);
        _leg(leg).sendToVault(uint64(uint256(usd) * WEI_PER_MICRO));
        emit Moved("toVault", leg, usd);
    }

    /// @notice Подтверждение отправки с ноги по её кассе (любой вызывающий, блоком позже). Касса уменьшилась — деньги
    /// пришли и считаются в G1; не уменьшилась — Core отказал молча, счётчик не меняется.
    function confirmLegSend(uint256 leg) external {
        if (!windows[leg].fromLeg) revert NoWindow(leg);
        _confirm(leg);
    }

    /// @notice Подтверждение раздачи на ноги (любой вызывающий, блоком позже). Нога не получила сумму — Core отказал молча,
    /// деньги лежат на хранилище и проводятся как пришедшие с ног, но не разнесённые.
    function confirmSweep() external {
        bool any;
        for (uint256 i = 0; i < 2; i++) {
            if (windows[i].blockNo != 0 && !windows[i].fromLeg) {
                _confirm(i);
                any = true;
            }
        }
        if (!any) revert NoWindow(2);
    }

    function _confirm(uint256 leg) internal {
        Window memory w = windows[leg];
        if (w.blockNo == 0 || block.number <= w.blockNo) revert NoWindow(leg);
        uint256 nowWei = _legSpot(leg).total;
        // чужой `Send` на ногу в окне меняет вывод только платой не меньше суммы окна
        bool arrived = w.fromLeg ? nowWei < w.before : nowWei >= uint256(w.before) + uint256(w.amount) * WEI_PER_MICRO;
        if (w.fromLeg == arrived) legFlow += int256(uint256(w.amount));
        delete windows[leg];
        emit LegTransferConfirmed(leg, w.fromLeg, w.amount, arrived);
    }

    function _leg(uint256 leg) internal view returns (TradingLeg) {
        if (leg == 0) return legA;
        if (leg == 1) return legB;
        revert ZeroAddress();
    }

    // --- таймлок: один механизм на admin, keeper, guardian и agent-ключи ------------------------------------------ //
    /// @dev Предложение хранит хеш действия; перезапись (в том числе тем же действием) отсчитывает `DELAY` заново.
    function _propose(uint256 kind, bytes32 h) internal {
        uint256 eta = block.timestamp + DELAY;
        proposals[kind] = Proposal(h, eta);
        emit Proposed(kind, h, eta);
    }

    function _take(uint256 kind, bytes32 h) internal {
        Proposal memory p = proposals[kind];
        if (p.hash == bytes32(0) || p.hash != h) revert NotProposed();
        if (block.timestamp < p.eta) revert TooEarly(p.eta);
        delete proposals[kind];
    }

    /// @notice Снять предложение: admin — любое; guardian — любое, кроме замены самого guardian (иначе захваченный
    /// guardian навсегда держал бы свою роль). Созревшее объявление аварии (`eta` прошёл) не снимает никто (ревью 20.10, R5).
    function cancel(uint256 kind) external {
        if (msg.sender != admin && (msg.sender != guardian || kind == P_GUARDIAN)) revert NotAdmin();
        bytes32 h = proposals[kind].hash;
        if (h == bytes32(0)) revert NotProposed();
        if (kind == P_EMERGENCY) _announcementOpen();
        delete proposals[kind];
        emit ProposalCancelled(kind, h, msg.sender);
    }

    function proposeAdmin(address a) external onlyAdmin {
        if (a == address(0)) revert ZeroAddress();
        _propose(P_ADMIN, keccak256(abi.encode(a)));
    }

    /// @notice Принимает сам предложенный адрес (в том числе контракт, например Safe), не раньше `eta`.
    function acceptAdmin() external {
        _live();
        _take(P_ADMIN, keccak256(abi.encode(msg.sender)));
        emit AdminChanged(admin, msg.sender);
        admin = msg.sender;
    }

    function proposeKeeper(address k) external onlyAdmin {
        if (k == address(0)) revert ZeroAddress();
        _propose(P_KEEPER, keccak256(abi.encode(k)));
    }

    function applyKeeper(address k) external onlyAdmin {
        _take(P_KEEPER, keccak256(abi.encode(k)));
        emit KeeperChanged(keeper, k);
        keeper = k;
        delete revokedKeeper;
    }

    /// @notice Guardian сменяется только через таймлок: он отменяет предложения admin'а, и мгновенная замена дала бы
    /// захваченному admin'у сначала снять отмену, а потом провести любое предложение за `DELAY`.
    function proposeGuardian(address g) external onlyAdmin {
        if (g == address(0)) revert ZeroAddress();
        _propose(P_GUARDIAN, keccak256(abi.encode(g)));
    }

    function applyGuardian(address g) external onlyAdmin {
        _take(P_GUARDIAN, keccak256(abi.encode(g)));
        emit GuardianChanged(guardian, g);
        guardian = g;
    }

    /// @notice C7: доля ноги A в раздаче — через таймлок (раздача решает, на каком счёте лежат деньги пула; keeper её не
    /// выбирает). Граница проверяется при предложении, чтобы негодное значение не ждало `DELAY`.
    function proposeLegShare(uint256 bpsA) external onlyAdmin {
        if (bpsA > BPS) revert BadAmount();
        _propose(P_SHARE, keccak256(abi.encode(bpsA)));
    }

    function applyLegShare(uint256 bpsA) external onlyAdmin {
        _take(P_SHARE, keccak256(abi.encode(bpsA)));
        legShareBps = bpsA;
        emit LegShareSet(bpsA);
    }

    /// @notice A9: подъём предела адресов бухгалтерии через таймлок. Только вверх и не выше `MAX_INVESTORS_BOUND` — судит
    /// бухгалтерия (`raiseMaxInvestors`, у границы один владелец); негодное значение отклоняется при исполнении.
    function proposeMaxInvestors(uint256 n) external onlyAdmin {
        _propose(P_LIMIT, keccak256(abi.encode(n)));
    }

    function applyMaxInvestors(uint256 n) external onlyAdmin {
        _take(P_LIMIT, keccak256(abi.encode(n)));
        ledger.raiseMaxInvestors(n);
        emit MaxInvestorsRaised(n);
    }

    function proposeAgent(uint256 leg, address agent, string calldata name) external onlyAdminKeys {
        _leg(leg);
        if (agent == address(0)) revert ZeroAddress();
        _propose(P_AGENT + leg, keccak256(abi.encode(agent, name)));
    }

    function applyAgent(uint256 leg, address agent, string calldata name) external onlyAdminKeys {
        _take(P_AGENT + leg, keccak256(abi.encode(agent, name)));
        agents[keccak256(abi.encode(leg, name))] = Agent(agent, false);
        _addAgent(leg, agent, name);
        emit AgentSet(leg, agent, name);
    }

    /// @dev Core МОЛЧА отвергает agent'а, который уже Core-пользователь (testnet T1(б): `0xdEaD` не отзывал ключ, receipt 1),
    /// поэтому такой адрес отклоняется здесь. Agent, занятый ЧУЖИМ аккаунтом, Core отвергает так же молча (T1k), но
    /// прекомпайла ролей нет — это проверяет keeper по `userRole` (README «Agent-ключи ноги»).
    function _addAgent(uint256 leg, address agent, string calldata name) internal {
        if (PrecompileLib.coreUserExists(agent)) revert AgentIsUser(agent);
        _leg(leg).addApiWallet(agent, name);
    }

    // --- отнимающие действия (guardian или admin) и восстановление (admin) ---------------------------------------- //
    function pauseDeposits() external onlyPauser {
        depositsPaused = true;
        emit DepositsPauseSet(true);
    }

    /// @notice Снимает паузу только admin (и тогда, когда её поставил guardian).
    function unpauseDeposits() external onlyAdmin {
        depositsPaused = false;
        emit DepositsPauseSet(false);
    }

    /// @notice Отзыв keeper'а сразу: все операции keeper'а отклоняются до `restoreKeeper` или нового keeper'а по таймлоку.
    function revokeKeeper() external onlyPauser {
        address k = keeper;
        if (k == address(0)) revert NothingToChange();
        revokedKeeper = k;
        keeper = address(0);
        emit KeeperRevoked(k, msg.sender);
    }

    /// @notice Возвращает ровно отозванный адрес (он уже прошёл таймлок) — ложная тревога не стоит `DELAY`.
    function restoreKeeper() external onlyAdmin {
        address k = revokedKeeper;
        if (k == address(0)) revert NothingToChange();
        emit KeeperChanged(address(0), k);
        keeper = k;
        delete revokedKeeper;
    }

    /// @notice Отзыв применённого agent-ключа ноги сразу: Core заменяет ключ по имени СВЕЖИМ адресом без ключа.
    /// Заранее известная константа не годится: Core не берёт в agent'ы Core-пользователя, а сделать им любой известный
    /// адрес стоит 1 USDC (testnet T1(б): `0xdEaD` молча не отзывал ни именованный, ни безымянный ключ). Адрес замены
    /// зависит от `salt` вызывающего — единственного входа, неизвестного третьему лицу ДО вызова (`prevrandao` HyperEVM
    /// документацией не описан и за непредсказуемый не принимается; README «Agent-ключи ноги»), и от счётчика отзывов.
    /// Повторный отзыв уже отозванного имени РАЗРЕШЁН (новой солью): Core мог отказать молча, и guardian обязан суметь
    /// повторить без admin'а. Висящие заявки ноги отзыв НЕ снимает — `cancelLegOrders`.
    function revokeAgent(uint256 leg, string calldata name, bytes32 salt) external onlyPauser returns (address r) {
        Agent storage g = agents[keccak256(abi.encode(leg, name))];
        if (g.agent == address(0)) revert NothingToChange();
        if (salt == bytes32(0)) revert ZeroSalt();
        r = address(
            uint160(
                uint256(
                    keccak256(abi.encode(address(this), leg, name, ++revokeNonce, salt, block.prevrandao, block.number))
                )
            )
        );
        g.revoked = true;
        _addAgent(leg, r, name);
        emit AgentRevoked(leg, g.agent, name, r);
    }

    /// @notice Отмена висящих заявок ноги по `(asset, oid)` — при отзыве agent-ключа или аварийно. oid'ы даёт
    /// вызывающий (info API `frontendOpenOrders` по каждому дексу); исход Core контракт не видит — проверка тем же API.
    function cancelLegOrders(uint256 leg, uint32[] calldata assets, uint64[] calldata oids) external onlyPauser {
        if (oids.length == 0 || assets.length != oids.length) revert BadAmount();
        _leg(leg).cancelOrders(assets, oids);
        emit LegOrdersCancelled(leg, oids);
    }

    function restoreAgent(uint256 leg, string calldata name) external onlyAdminKeys {
        Agent storage g = agents[keccak256(abi.encode(leg, name))];
        if (!g.revoked) revert NothingToChange();
        g.revoked = false;
        _addAgent(leg, g.agent, name);
        emit AgentRestored(leg, g.agent, name);
    }

    // --- admin ---------------------------------------------------------------------------------------------------- //
    function setTvlCap(uint256 cap) external onlyAdmin {
        tvlCap = cap;
        emit TvlCapSet(cap);
    }

    function setPartner(address a, uint8 status) external onlyAdmin {
        ledger.setPartner(a, status);
    }

    function initPartner(address a) external onlyAdmin {
        ledger.initPartner(a);
    }

    // --- ред. 9.4: аварийный выход ------------------------------------------------------------------------------------ //
    /// @notice Объявление аварии admin'ом — тем же таймлоком (`DELAY`, вид 7); guardian вправе отменить в окне (`cancel(7)`).
    /// Заморозку по нему (и по любому триггеру по времени) исполняет кто угодно — `emergencyFreeze` модуля. После `eta`
    /// объявление может только исполниться: ни отмена, ни перезапись (она сдвинула бы срок) — отказ `Matured`.
    function proposeEmergency() external onlyAdmin {
        _announcementOpen();
        _propose(P_EMERGENCY, EMERGENCY_HASH);
    }

    /// @dev Ревью 20.10, R5: созревшее объявление — гонка «заморозить» против «снять/перевзвести» решалась бы тем, кто
    /// первым попал в блок; теперь после `eta` у объявления один исход — заморозка.
    function _announcementOpen() internal view {
        Proposal memory p = proposals[P_EMERGENCY];
        if (p.hash != bytes32(0) && block.timestamp >= p.eta) revert Matured(p.eta);
    }

    /// @notice Входы триггеров для модуля аварии: часы, время старейшей неисполненной заявки хранилища (0 — нет), исходящие
    /// блока (wei), длина журнала `qStamps`.
    function emergencyClock()
        external
        view
        returns (EmergencyClock memory c, uint256 oldestIntentAt, uint256 outPendingWei, uint256 nStamps)
    {
        c = clock;
        if (nextIntent < intents.length) oldestIntentAt = intentAt[nextIntent];
        outPendingWei = _outPending();
        nStamps = qStamps.length;
    }

    /// @notice Всё прочее — модуль аварии на памяти хранилища (`emergencyFreeze`, `emergencySnapStep`, `emergencyClaim`,
    /// витрины); неизвестный модулю селектор — его отказ.
    fallback() external {
        address e = emergency;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), e, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // --- сверка для keeper'а ---------------------------------------------------------------------------------------- //
    /// @notice (деньги на Core хранилища в микро, бухгалтерские spot+evm в микро, стоимость ног по прекомпайлу в микро).
    /// Нога не на Core (бета на одной ноге, C7) денег не имеет, её прекомпайлы не читаются — как в G2 и сборе аварии
    /// (ревью-3, R3-B: поведение прекомпайла на неактивированном адресе HL не описано).
    function reconcile() external view returns (uint256 vaultMicro, uint256 heldMicro, int256 legsMicro) {
        int256[13] memory s = PoolLedgerViews(address(ledger)).status();
        vaultMicro = _coreWei() / WEI_PER_MICRO;
        heldMicro = uint256(s[7] + s[8]);
        uint256 spotWei;
        for (uint256 i = 0; i < 2; i++) {
            TradingLeg l = _leg(i);
            if (!PrecompileLib.coreUserExists(address(l))) continue;
            legsMicro += l.accountValue();
            spotWei += l.spotUsdcWei();
        }
        legsMicro += int256(spotWei / WEI_PER_MICRO);
    }
}
