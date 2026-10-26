// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title PoolLedger — бухгалтерия пула Rubik по поколениям.
/// @notice ПЕРЕНОС 1:1 эталона `runtime/vault_accounting.pytxt` (класс `GenLedger`, редакция 9.5 «внеочередной расчёт», 9.4
/// «замороженный пул», 9.3.1.1 и пакет безопасности). Имена величин, порядок обхода и арифметика округлений — те же;
/// расхождение с эталоном на любой из 78 фикстур v9 `tests/fixtures/vault_accounting` (с фикстурами аварии 236-239, 260, 261 и
/// ред. 9.5 262-269)
/// — дефект контракта, а не «вариант». Дифференциал: `contracts/diff/pool_ledger_diff.pytxt`.
/// @dev Денег и HyperCore здесь нет: суммы — числа, как в эталоне. Все величины хранятся в int256, чтобы знак и
/// переполнение вели себя как питоновские int; границы типов (uint128 / int128 / bytes32) проверяются там же, где их
/// проверяет эталон (`_amount`, `_signed`, `_id32`).
/// ДЕЛЕНИЕ: питоновское `//` округляет к минус бесконечности, `/` Solidity — к нулю. В эталоне все `//` идут по
/// неотрицательным числам, КРОМЕ `attr`, где знак разобран явно; округление вверх `-(-a // b)` — `_ceilDivU`.
/// None в эталоне: адрес реферала — address(0); `revoked_at_order` — флаг `hasRevokedAt`; `payout` депозита — 0/1/2;
/// доплативший None (счёт пула) в книге `creditors` — отдельная книга `credPool` (во внешнем виде — нулевой адрес).
/// РЕДАКЦИЯ 9 (9.1): котла в покрытии убытка нет, операторов нет. Недостача адреса сверх его денег доплачивается участниками
/// тех же поколений (`_allocate`), это долг адреса перед ними (`cred`), гасит его только его же прибыль (`_payBack`).
/// РЕДАКЦИЯ 9.2: книга доплативших между инвесторами всегда АЦИКЛИЧНА — за каждой записью доли в книгу идёт зачёт цикла,
/// который она замкнула (этап `MS_NET`, `_netStep`); работа очереди возвратов получателя, который ещё стоит, получает прибавку.
/// РЕДАКЦИЯ 9.2.1 / 9.2.2: вес и контекст `hold` видят фазу 2 того же расчёта — черновик возвратов `_repayProjection`
/// (PoolLedgerProj); гейт по маркам при долге гасит бумажный убыток должника только остатком закрытого после гашения долга.
/// Пакет безопасности: минимум депозита, предел адресов (не выше `MAX_INVESTORS_BOUND` — замер газа), `refundRef`.
/// РЕДАКЦИЯ 9.3 / 9.3.1 / 9.3.1.1: частичное закрытие `reducePosition` (общее тело `_realize` с закрытием), результат частей
/// открытого ордера `partR` — вне базы комиссии до закрытия сделки (`_feeBase`), резерв — худший порядок закрытий (Н2).
/// РЕДАКЦИЯ 9.4: замороженный пул — `PoolLedgerEmergency` (заморозка, итоги снимка, копия MS_SNAP в `mondayBegin`), правило E
/// с КЕ13′ — витрина `emergencyDue` (PoolLedgerViews); после заморозки бухгалтерия неизменна (`_start`, шаги расчёта).
/// РЕДАКЦИЯ 9.5: амортизация поколений (обход ВСЕХ поколений расчётом заменён ведущимися суммами и закрытием поколения в момент,
/// когда оно стало окончательным — `_genDead`), внеочередной расчёт `monday(false)` (неделя не сдвигается; право —
/// `_extraAllowed`), предел `maxGens` в `sizeOrder`; книга ордеров — `PoolLedgerBook`.
/// @dev Состояние и вся внутренняя математика. Своих переменных у наследников НЕТ: раскладка памяти одна.
abstract contract PoolLedgerBase {
    // --- константы ------------------------------------------------------------------------------------------------ //
    int256 internal constant BPS = 10_000;
    uint256 internal constant U128_MAX = type(uint128).max;
    int256 internal constant I128_MAX = int256(uint256(type(uint128).max >> 1));

    uint8 internal constant ST_NONE = 0;
    uint8 internal constant ST_SIZED = 1;
    uint8 internal constant ST_OPEN = 2;
    uint8 internal constant ST_CLOSED = 3;

    uint8 internal constant P_NONE = 0;
    uint8 internal constant P_ACTIVE = 1;
    uint8 internal constant P_REVOKED = 2;
    uint8 internal constant P_REVOKED_CAUSE = 3;

    uint8 internal constant PATH_SPOT = 0;
    uint8 internal constant PATH_EVM = 1;

    /// @dev Исход `withdraw` — КОДОМ, а не отказом (находка ревью: хранилище ловило отказ `try`, и нехватка газа во вложенной
    /// проекции на любой глубине выглядела законным отказом — заявка «съедалась»). Бизнес-отказы эталона `withdraw` — ровно
    /// эти два (`_amount(amount)` и `amount == 0 or amount > free`); всё прочее (адрес, заморозка, открытый расчёт, инварианты,
    /// газ) — отказ транзакции, как прежде. Отказ кодом состояния не меняет (проверка — до первой записи).
    uint8 internal constant W_OK = 0;
    uint8 internal constant W_AMOUNT = 1; // ноль или больше свободной доли (эталон: `withdraw: … при доступных …`)
    uint8 internal constant W_RANGE = 2; //  сумма вне uint128 (эталон `_amount`)

    uint256 internal constant Q_ID = (1 << 64) - 1; // младшие 64 бита слова заявки — её id
    /// @dev Верхняя граница `maxInvestors` — решение оператора (20.10) по газу заявки хранилища «вывести всё» (`freeStake` +
    /// `withdraw`, две проекции в одной транзакции) на худшем проверенном входе — «обратный треугольник»: при n = 43 —
    /// 24.98 млн, запас до большого блока HyperEVM (30 млн) 5.0 млн; при 46 — 28.14, 48 — 30.52, 50 — 32.78 млн (README
    /// «Газ заявок», стенд `test_vault_withdraw_all_at_bound_fits_big_block`). Раньше граница была 50 (замер одиночной
    /// проекции, 25 млн).
    uint256 internal constant MAX_INVESTORS_BOUND = 43;
    /// @dev Ред. 9.5: верхняя граница `maxGens` (предел поколений между расчётами) — из замера газа после амортизации (README
    /// «Ред. 9.5: предел поколений»): проекция `sizeOrder` с одним должником по маркам при n = MAX_INVESTORS_BOUND и
    /// MAX_GENS_BOUND поколениях снимков укладывается в 25 млн газа.
    uint256 internal constant MAX_GENS_BOUND = 1000;

    uint8 internal constant PL_POT = 0;
    uint8 internal constant PL_STAKE = 1;
    uint8 internal constant PL_QUEUE = 2;
    uint8 internal constant PL_REWARD = 3;
    uint8 internal constant PL_DEBT = 4;

    // этапы недельного расчёта: ФАЗА 1 — строки адресов, ФАЗА 2 — по порядку эталона `monday`
    uint8 internal constant MS_ROWS = 0; //  строки адресов (единица пачки — участник)
    uint8 internal constant MS_REFS = 1; //  реферальные доли после всех строк (единица — доля)
    uint8 internal constant MS_REPAY = 2; // возвраты доплатившим с цепочкой (единица — работа очереди возвратов)
    uint8 internal constant MS_MATES = 3; // раздел недостачи между соучастниками (единица — должник × поколение убытка)
    uint8 internal constant MS_POOL = 4; //  «весь пул»: потребность S и доли плательщиков (один вызов)
    uint8 internal constant MS_TABLE = 5; // строки таблицы «весь пул» и дыра (единица — должник)
    uint8 internal constant MS_NET = 6; //   ред. 9.2: доли раздела — в книгу, за каждой записью зачёт цикла (единица — запись
    //                                       доли или один поиск пути зачёта)
    uint8 internal constant MS_DONE = 7; //  осталось `mondayEnd`: закрытие поколений и проход очереди

    // --- параметры экземпляра --------------------------------------------------------------------------------------- //
    address internal owner;
    address internal treasury;
    int256 internal bufferBps;
    int256 internal feeBps;
    int256 internal refShareBps;
    int256 internal holdBps;
    int256 internal openRefShareBps;
    int256 internal partnerTermWeeks;
    bool internal initialized;
    // ПАКЕТ БЕЗОПАСНОСТИ (эталон `GenLedger(min_deposit, max_investors)`, план 2026-10-17-pool-safety-pack П1/П2). Не immutable:
    // реализации исполняются делегированным вызовом на памяти PoolLedger и immutable прочли бы свои (находка Н6 плана).
    int256 internal minDeposit; //    П1: минимум КАЖДОГО депозита, включая пополнение
    uint256 internal maxInvestors; // П2: предел ЗАРЕГИСТРИРОВАННЫХ инвесторов (`order` пожизненный); 1..MAX_INVESTORS_BOUND

    // --- состояние ------------------------------------------------------------------------------------------------- //
    struct Investor {
        bool exists;
        int256 stake;
        address referrer;
        bool ever;
        bool payoutMode;
        bool exiting;
        int256 deposited;
        int256 withdrawn;
        int256 cumPnl;
        int256 hwm;
        int256 firstWeek;
        int256 regIndex;
        int256 feesPaid;
        int256 uncovered;
    }

    struct Order {
        uint8 state;
        int256 gen;
        int256 notional;
        int256 upnl;
        int256 sizedWeek;
        // ред. 9.3.1: результат частей ОТКРЫТОГО ордера (`part_R` эталона; 0 — ключа нет). int256, а не int128: границы судят
        // `upnl + partR` и `R[g] − genP[g]`, а сама сумма частей доходит до −(2^128 − 2) (эталон принимает две части по
        // −(2^127 − 1) с закрытием другого ордера между ними)
        int256 partR;
    }

    /// @dev Заявки ОДНОГО ключа (адрес, reward) — непрерывная полоса сумм: запись i покрывает (end[i-1], end[i]] (end[-1] = 0),
    /// живая часть ключа — (P, P + queued]. Выплата снимает с ГОЛОВЫ (P растёт), снятие каскадом — с ХВОСТА (queued
    /// падает): записи, целиком вышедшие за границу, мертвы без единой записи в память. Это ровно порядок эталона — FIFO
    /// выплаты по id и «новейшие первыми» у `_take_from_queue`, — а стоимость снятия не зависит от числа заявок.
    struct QHead {
        int192 P; //       начало живой части (выплачено с головы с последнего опустошения ключа)
        uint64 head; //    первая живая запись: end > P (одно слово с P: выплата пишет его одно)
        uint128 len; //    записей в массиве ключа (дальше — мусор прежних, не читается)
    }

    struct Partner {
        uint8 state;
        int256 sinceWeek;
        bool hasRevokedAt;
        int256 revokedAtOrder;
    }

    int256 internal week;
    int256 internal gen;
    mapping(address => Investor) internal inv;
    address[] internal order;

    // ПОКОЛЕНИЯ СО СНИМКАМИ (`snaps` эталона) — по возрастанию номера: пережившие прошлый расчёт `surv[0..survN)`, затем
    // ВСЕ открытые после него (genBase, gen] — номера поколений идут подряд, и расчёт закрывает их только целиком (ред. 9.5:
    // список не хранится, `_genAt`/`_snapCount`). Окончательное до расчёта поколение остаётся здесь до его конца, как у эталона.
    mapping(uint256 => int256) internal surv;
    uint256 internal survN;
    int256 internal genBase;
    mapping(int256 => bool) internal snapExists;
    // участники снимка — адреса `order[0..snapN)` с ненулевым весом (список адресов не хранится: участник снимка —
    // инвестор, зарегистрированный до него, а вес остальных 0)
    mapping(int256 => uint256) internal snapN;
    mapping(int256 => mapping(address => int256)) internal snapW;
    mapping(int256 => int256) internal snapTotal;
    mapping(int256 => int256) internal R;
    // `col` эталона (доля R поколения, разнесённая адресу) НЕ хранится: вне фазы строк она РАВНА доле `rMon` поколения (R на
    // последнем расчёте) — ровно это `_settle` и записывал бы. Сумма по адресам после строк равна Σ_a доля(R_g) — её ведёт
    // `shareSum` (ред. 9.5): её читают проверка разноса и закрытие поколения, которым иначе пришлось бы обходить участников.
    mapping(int256 => int256) internal shareSum; //  Σ_a доля(a, g, R_g) — пишет `_aggR` той же разницей, что `aggPend`
    mapping(int256 => int256) internal genLive; //   ордеров поколения в sized/open (поколение живо, пока > 0)

    // ЖИВЫЕ ордера (sized/open). Порядок — не порядок создания: удаление (отмена, закрытие) — перестановкой последнего на место
    // удалённого за O(1) (`_unlistOrder`); ни одно чтение от порядка не зависит (суммы по ордерам, выгрузка — по pid).
    bytes32[] internal orderPids;
    mapping(bytes32 => Order) internal orders;
    bytes32[] internal closedPidList;
    mapping(bytes32 => bool) internal closedPid;

    int256 internal closedR;
    int256 internal settledR;
    int256 internal shortfall;
    // очередь выплат: заявки по ключу (адрес, reward), см. `QHead`; глобальный порядок FIFO — по id (младшие 64 бита `qE`)
    mapping(address => mapping(bool => QHead)) internal qh;
    mapping(address => mapping(bool => mapping(uint256 => uint256))) internal qE; //    накопленный конец записи << 64 | id
    mapping(address => mapping(bool => mapping(uint256 => int256))) internal qWeek; //  неделя записи (только выгрузка)
    int256 internal nextQid;

    mapping(address => int256) internal claimable;
    mapping(address => int256) internal claimableReward;
    mapping(address => int256) internal rewardCash;
    mapping(address => int256) internal withdrawnReward;
    address[] internal known; // все адреса, у которых когда-либо была плоскость (для выгрузки состояния)
    mapping(address => bool) internal isKnown;

    bytes32[] internal ledgerRefList;
    mapping(bytes32 => bool) internal ledgerRef;

    int256 internal spot;
    int256 internal evm;
    int256 internal venueCash;
    int256 internal withdrawable;

    mapping(address => Partner) internal partners;
    address[] internal partnerList;

    // --- КНИГА ДОПЛАТИВШИХ (ред. 9, эталон `creditors`): должник -> доплативший -> непогашенная сумма. Доплативший
    // None эталона (счёт пула `shortfall`) — отдельная книга, а не нулевой ключ: адрес инвестора с ним не столкнётся.
    mapping(address => mapping(address => int256)) internal cred;
    mapping(address => int256) internal credPool;
    // ред. 9.2: рёбра книги — битовая строка должника (бит i слова i >> 8: cred[x][order[i]] > 0). Соседи по порядку
    // регистрации читаются за O(слов + рёбер), а не O(адресов): поиск пути зачёта и строка возврата не обходят всех.
    // Пишет ТОЛЬКО `_credAdd` — единственный писатель `cred`, поэтому бит и сумма не расходятся.
    mapping(address => mapping(uint256 => uint256)) internal credBits;

    // --- ВЕДУЩИЕСЯ СУММЫ (этап 5а, Q9): вместо обхода на каждом чтении. Каждая равна обходу, который заменяет, ПО
    // ПОСТРОЕНИЮ — её обновляет каждый писатель величины; дифференциал судит это на всех вызовах фикстур.
    int256 internal stakeSum; //       Σ inv[a].stake                                      (эталон total_stake)
    int256 internal claimableSum; //   Σ claimable + claimable_reward                      (эталон claimable_all)
    int256 internal queuedSum; //      Σ amount всех заявок                                 (эталон queued_total)
    mapping(address => int256) internal queuedInv; //    заявки инвестора адреса       (эталон _queued_of(a, False))
    mapping(address => int256) internal queuedRew; //    reward-заявки адреса          (эталон _queued_of(a, True))
    int256 internal queuedInvSum; //   Σ queuedInv (непогашенное инвесторов во втором проходе `_pay_fifo`)
    int256 internal rAll; //           Σ R по ВСЕМ поколениям, живым и закрытым             (эталон R_total)
    int256 internal uOpen; //          Σ upnl открытых ордеров                              (эталон U_total)
    mapping(int256 => int256) internal genU; //          Σ upnl открытых ордеров поколения
    mapping(int256 => int256) internal genUpos; //       Σ max(0, upnl) открытых ордеров поколения
    // этап 5б: число открытых ордеров поколения с upnl < 0 — граница «проектного убытка нет», см. `_noProjectedLoss`
    mapping(int256 => int256) internal genLossOrders;
    // ВЕДУЩИЕСЯ СУММЫ АДРЕСА по ордерам и поколениям (вместо обхода всех ордеров на каждое чтение — O(адресов × ордеров) на
    // проекцию): пишет только `_aggOrder` (вклад ордера снимается до изменения и прибавляется после) и `_aggR` (сдвиг
    // закрытого результата поколения); строка расчёта обнуляет неразнесённое. Дифференциал судит их на каждом вызове.
    mapping(address => int256) internal aggPend; //      Σ_g доля(R_g) − col                  (эталон _pending_realized)
    mapping(address => int256) internal aggU; //         Σ доля(upnl) открытых                (эталон unrealized)
    mapping(address => int256) internal aggPL; //        Σ −доля(min(0, upnl)) открытых       (бумажный убыток)
    mapping(address => int256) internal aggEx; //        Σ удержание по ордерам sized/open    (эталон exposure_hold)
    // РЕД. 9.3.1 — КОМИССИЯ С ИТОГА СДЕЛКИ: части открытых ордеров в базу комиссии не входят (эталон `_fee_deferral`,
    // `_fee_reserve_base`). Те же ведущиеся суммы: пишут `_aggOrder` (вклад ордера с частью) и `_aggR` (D поколения).
    mapping(int256 => int256) internal genP; //          Σ partR открытых ордеров поколения             (P_g эталона)
    mapping(address => int256) internal aggD; //         Σ_g доля(R_g) − доля(R_g − P_g)                 (D эталона)
    mapping(address => int256) internal aggUd; //        Σ по ордерам с частью: доля(upnl + p) − доля(upnl)  (U − unrealized)
    mapping(address => int256) internal aggRb; //        резерв: Σ_{p<0} −доля(p) + Σ_{p>0} доля(min(0, upnl))
    mapping(address => int256) internal aggRU; //        резерв: Σ_{p<0} [доля(upnl + p) − доля(upnl)] − Σ_{p>0} доля(upnl)
    uint256 internal partOrders; //                      открытых ордеров с partR != 0 (0 — все суммы выше нули: база прежняя)
    // этап 5в: недельный расчёт ПАЧКАМИ. Пока `mondayOpen`, любая другая операция отклоняется — значит, исход тот же, что
    // у атомарного расчёта эталона (между пачками никто не видит полу-разнесённое состояние, спека §4 контракт п. 2).
    bool internal mondayOpen;
    uint256 internal mondayCursor;
    mapping(int256 => int256) internal rMon; //          R поколения на последнем недельном расчёте (0 — после создания)
    // ред. 9: ФАЗА 1 расчёта (строки адресов) копит здесь то, что эталон держит в списках `repays`, `refs`, `debts`;
    // ФАЗА 2 их исполняет этапами (`monStage`). Между пачками они живут в памяти контракта — исход тот же, потому что никто,
    // кроме следующей пачки, их не читает и состояние не меняет. Списки — буферы со СВОЕЙ длиной (`…N`): `_mondayBegin`
    // обнуляет длину, а не стирает слова — очистка не растёт с длиной списка (находка M3); слова за длиной не читаются.
    mapping(uint256 => address) internal monRepayA;
    mapping(uint256 => int256) internal monRepayX;
    uint256 internal monRepayN;
    mapping(uint256 => address) internal monRefA;
    mapping(uint256 => int256) internal monRefX;
    uint256 internal monRefN;
    mapping(uint256 => address) internal monDebtA;
    // недостача должника: после фазы 1 — недостача недели (её уменьшает возврат, гасящий недостачу получателя), после
    // этапа соучастников — его невместившийся остаток (`rest_by` эталона)
    mapping(uint256 => int256) internal monDebtX;
    uint256 internal monDebtN;
    // ред. 9.5: убыток недели должника по поколениям — только НЕНУЛЕВЫЕ пары (поколение, убыток) по возрастанию поколения,
    // подряд: пары должника d — [monDebtOff[d], начало d + 1 или monLossN). Строка должника пишет их пачками (`_scanLoss`)
    mapping(uint256 => int256) internal monLossG;
    mapping(uint256 => int256) internal monLossV;
    uint256 internal monLossN;
    mapping(uint256 => uint256) internal monDebtOff;
    // ФАЗА 2 ПАЧКАМИ (этапы MS_*): этап и курсор внутри него
    uint8 internal monStage;
    uint256 internal monCur;
    // позиция должника + 1 С МЕТКОЙ РАСЧЁТА: monEpoch << 128 | pos (метка чужого расчёта — «не должник»; стирать не нужно)
    mapping(address => uint256) internal monDebtPos;
    // база «всего пула» (капитал + свои заявки) НА НАЧАЛО РАЗДЕЛА, +1: пишется перед первым снятием у доплатившего соучастника;
    // у остальных она равна текущей (их деньги раздел ещё не трогал)
    mapping(address => int256) internal monBasis1;
    mapping(uint256 => uint256) internal monGive; //  доля «всего пула» плательщика (по позиции в `order`), метка расчёта
    mapping(uint256 => int256) internal monCov; //    доля «всего пула», покрытая у должника (`cov` эталона)
    int256 internal monC; //                           Σ долей «всего пула» (`C` эталона)
    // этап соучастников: единица — (должник, поколение его убытка); курсор поколения внутри должника и его остаток
    uint256 internal monGenCur; //                     пара убытка (позиция среди пар должника) следующей единицы должника `monCur` (0 — не начат)
    int256 internal monMatesR; //                      невместившееся начатого должника (`r` эталона) на конец пачки
    uint256 internal monUnits; //                      единиц этапа соучастников всего (поколений убытка всех должников)
    uint256 internal monUnitsDone; //                  единиц сделано (этап соучастников; на этапе зачёта — его единиц)
    // ред. 9.2: работа возврата адреса в очереди этого расчёта — monEpoch << 128 | (позиция + 1); получатель, чья работа ещё
    // стоит, получает прибавку к ней, а не вторую работу (эталон `_pay_back`, слияние)
    mapping(address => uint256) internal monRepayPos;
    // ред. 9.2: доли раздела этой недели (должник -> доплативший) ЖДУТ ЗАПИСИ В КНИГУ. Эталон пишет их по одной в порядке
    // (должник по регистрации, доплативший по адресу) и за каждой записью зачитывает замкнутый ею цикл — поиск пути обязан
    // видеть книгу ровно на этот момент. Этапы соучастников и таблицы копят доли здесь, этап зачёта переносит их в `cred`.
    mapping(address => mapping(address => int256)) internal monPend;
    mapping(address => mapping(uint256 => uint256)) internal monPendBits; // бит доплатившего с ждущей долей (как `credBits`)
    uint256 internal monNetB; //                       доплативший (позиция + 1), чей зачёт начат и не кончен прежней пачкой

    /// @dev Адрес PoolLedgerViews: туда fallback отдаёт витрины через delegatecall (та же память).
    address internal viewsImpl;
    /// @dev Адрес PoolLedgerMonday: недельный расчёт исполняется там делегированным вызовом на ЭТОЙ памяти (ред. 9: с
    /// разделом недостачи PoolLedger не помещается в EIP-170 целиком). Передаётся конструктору, как и PoolLedgerViews.
    address internal mondayImpl;
    /// @dev Адрес PoolLedgerProj: проекции «как если бы расчёт прошёл сейчас по маркам» (`holdCtx`) — делегированным вызовом
    /// на ЭТОЙ памяти через статический вызов бухгалтерии самой себя (`_holdCtx`). Передаётся конструктору.
    address internal projImpl;
    /// @dev Адрес PoolLedgerEmergency (ред. 9.4): заморозка, проход итогов снимка и этап MS_SNAP — делегированным вызовом на
    /// ЭТОЙ памяти. Передаётся конструктору, как и прочие реализации.
    address internal emergencyImpl;

    // --- РЕД. 9.4: ЗАМОРОЖЕННЫЙ ПУЛ (эталон `emergency_freeze`, `_emergency_planes`, спека 8.13) ------------------- //
    // Снимок — итоги и источник долей; доли адреса не копируются: вне открытого расчёта бухгалтерия после заморозки
    // неизменна, и плоскости читаются прямо из неё (O(1)); заморозка посреди расчёта берёт копию MS_SNAP (ниже).
    uint8 internal emState; //   0 — пул живой; 1 — заморожен, идёт проход итогов; 2 — снимок готов, правило E открыто
    bool internal emCopy; //     доли адресов — копия MS_SNAP (заморозка посреди расчёта), иначе — замороженные плоскости
    uint256 internal emCur; //   проход итогов: следующий держатель (`_holderAt`)
    int256 internal emWeek; //   неделя снимка (посреди расчёта — неделя ДО него)
    int256 internal emFT; //     котёл treasury F_T
    int256 internal emH; //      признанный долг пула H (`shortfall`)
    int256 internal emF; //      F_o = Σ f прочих держателей
    int256 internal emS; //      S = Σ s (капитал и его заявки)
    int256 internal emP; //      P = Σ p (веса в снимках живых поколений)
    // MS_SNAP: плоскости держателей на начало расчёта пачками (`mondayBegin`, одной транзакцией) — снимок «до monday» эталона
    int256 internal msFT;
    int256 internal msH;
    int256 internal msF;
    int256 internal msS;
    mapping(address => int256) internal msFv;
    mapping(address => int256) internal msSv;

    // --- ЗАКРЫТЫЕ ЗА НЕДЕЛЮ ОРДЕРА (находка ревью: `_finalizeGenerations` удалял закрытые обходом `orderPids` со сдвигом, и
    // `mondayEnd` рос ~20 тыс. газа на каждый закрытый за неделю ордер — 500 закрытых = 10 млн). Закрытый ордер уходит из
    // `orderPids` сразу (O(1), `orderIx`) в буфер недели со СВОЕЙ длиной; эталон держит его в `orders` до конца расчёта —
    // выгрузка показывает буфер, а конец расчёта обнуляет ДЛИНУ (O(1)). Запись `orders[pid]` закрытого ордера после этого
    // не читает никто: выгрузка идёт по спискам, а pid закрыт навсегда (`closedPid`), и любой вызов книги по нему отклоняется
    // (`size_order: exists`, `order state`) — как у эталона, где pid уже нет в `orders`, но он в `closed_pids`.
    mapping(bytes32 => uint256) internal orderIx; //    позиция ордера в `orderPids` + 1 (0 — не живой)
    mapping(uint256 => bytes32) internal weekClosed; // закрытые с последнего расчёта, [0, weekClosedN)
    uint256 internal weekClosedN;

    // --- РЕД. 9.5: ВНЕОЧЕРЕДНОЙ РАСЧЁТ И АМОРТИЗАЦИЯ ПОКОЛЕНИЙ (эталон `GenLedger(max_gens)`, `monday(calendar)`; спека 8.15) -- //
    // Правила раздела не меняются: всё, что недельный расчёт делал обходом ВСЕХ поколений, ведётся там, где меняется R, марк или
    // состояние ордера, а поколение, ставшее окончательным (не текущее и без живых ордеров — ордер встаёт только в текущее),
    // закрывается в тот же момент: его пыль и R копятся до расчёта. Расчёт обходит только живые поколения.
    uint256 internal maxGens; //       предел поколений между расчётами (0 — правила нет, эталон None); параметр деплоя
    uint256 internal gensSince; //     поколений открыто после последнего расчёта (любого) — эталон `_gens_since`
    bool internal monCal; //           открытый расчёт календарный (сдвинул неделю): иначе внеочередной
    uint256 internal monEpoch; //      номер расчёта — метка буферов фазы 2 (неделя не годится: внеочередной её не сдвигает)
    // ЖИВЫЕ поколения (текущее и с живыми ордерами) — двусвязный список по возрастанию номера (новое — всегда наибольшее)
    mapping(int256 => int256) internal lvNext;
    mapping(int256 => int256) internal lvPrev;
    int256 internal lvHead;
    int256 internal lvTail;
    uint256 internal lvN;
    int256 internal growSum; //        Σ_{g ∈ snaps} max(0, R_g) + genUpos_g        (оценка `_stake_ceiling` эталона)
    uint256 internal lossRN; //        поколений снимков с R_g < rMon_g                (граница `_noProjectedLoss`)
    uint256 internal lossOpenN; //     поколений с genLossOrders_g != 0               (та же граница, бумажная часть)
    int256 internal snapTotalSum; //   Σ_{g ∈ snaps} snapTotal_g                       (P замороженного пула)
    // окончательные с последнего расчёта, ещё не проведённые им: пыль (R − Σ долей), их R, слагаемые growSum и snapTotalSum
    int256 internal dustPending;
    int256 internal closedPending;
    int256 internal growDead;
    int256 internal totalDead;
    // строка должника пачками: должник (позиция + 1), чьи поколения ещё обходятся, и позиция в снимках; единиц строк сделано
    uint256 internal monScan;
    uint256 internal monScanK;
    uint256 internal monRowUnits;
    /// @dev Адрес PoolLedgerBook (ред. 9.5): книга ордеров (fill, cancel, mark, close, reduce) — делегированным вызовом на ЭТОЙ
    /// памяти (в PoolLedgerMonday с амортизацией она не помещается в EIP-170). Передаётся конструктору.
    address internal bookImpl;
    /// @dev Ревью-3b: первая календарная неделя, в которой календарный расчёт ещё допустим (номер `_calWeek()`): календарный
    /// расчёт — не чаще одного за календарную неделю. 0 — расчётов не было.
    uint256 internal calNext;

    /// @dev Селекторы PoolLedgerProj (`holdCtx()`, `weights()`): fallback бухгалтерии отдаёт их проекциям, остальное — витринам.
    bytes4 internal constant SEL_HOLD_CTX = bytes4(keccak256("holdCtx()"));
    bytes4 internal constant SEL_WEIGHTS = bytes4(keccak256("weights()"));

    error Revert(string why);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Revert("owner");
        _;
    }

    /// @dev Ред. 9.4: после заморозки бухгалтерия неизменна — эталонный замок `_atomic`. Все изменяющие методы идут через
    /// `_start()`, кроме шагов расчёта (их судят заглушки PoolLedger) и `initPartner` (закрыт `initialized`, его ставит заморозка).
    function _start() internal {
        if (emState != 0) revert Revert("frozen");
        if (mondayOpen) revert Revert("monday in progress");
        if (!initialized) initialized = true;
    }

    /// @dev Ревью-3b: номер календарной недели — 7 суток от понедельника 00:00 UTC. Unix-эпоха (1970-01-01) — четверг, ближайший
    /// понедельник не позже неё — 1969-12-29, на 3 суток раньше; отсюда `+ 3 days`. Своих чисел нет: только 7 суток и эпоха
    /// понедельника. Неделя сменяется в понедельник 00:00 UTC, расписание keeper'а — понедельник 04:00 UTC.
    function _calWeek() internal view returns (uint256) {
        return (block.timestamp + 3 days) / 7 days;
    }

    // --- арифметика -------------------------------------------------------------------------------------------- //
    function _max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    function _min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /// @dev Округление вверх по НЕОТРИЦАТЕЛЬНЫМ (эталон: `-(-a // b)`). Через uint256: s·notional бывает до 2^256.
    function _ceilDivU(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev floor(a·b/d) без переполнения промежуточного произведения (512 бит); результат обязан помещаться в 256.
    /// Эталон делит питоновскими целыми без границы: `need * w // W` в `_split`, где вес бывает суммой убытков.
    function _mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / d;
            if (d <= prod1) revert Revert("mulDiv");
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            result = prod0 * inverse;
        }
    }

    /// @dev `attr`: доля `s/total` в `pnl`, округление ВСЕГДА против держателя.
    function _attr(int256 s, int256 pnl, int256 total) internal pure returns (int256) {
        if (s < 0) revert Revert("attr: s < 0");
        if (total <= 0) revert Revert("attr: total == 0");
        if (pnl >= 0) {
            return int256((uint256(s) * uint256(pnl)) / uint256(total));
        }
        uint256 neg = uint256(-pnl);
        return -int256((uint256(s) * neg + uint256(total) - 1) / uint256(total));
    }

    function _amount(uint256 x) internal pure returns (int256) {
        if (x > U128_MAX) revert Revert("uint128");
        return int256(x);
    }

    function _signed(int256 x) internal pure returns (int256) {
        if (x > I128_MAX || x < -I128_MAX) revert Revert("int128");
        return x;
    }

    function _id32(bytes32 x) internal pure {
        if (x == bytes32(0)) revert Revert("id32");
    }

    /// @dev Эталон `_addr`: нулевой адрес участником не бывает — это ключ «долг перед пулом» во внешнем виде книги
    /// доплативших и «нет реферала» в `deposit`.
    function _addr(address a) internal pure {
        if (a == address(0)) revert Revert("zero address");
    }

    // --- величины ---------------------------------------------------------------------------------------------- //
    function _venueValue() internal view returns (int256) {
        return venueCash + rAll + uOpen;
    }

    function _freePlane() internal view returns (int256) {
        return spot + evm - claimableSum;
    }

    function _bufferTarget() internal view returns (int256) {
        return (stakeSum * bufferBps) / BPS; // неотрицательно
    }

    function _liquidity() internal view returns (int256) {
        return _max(0, _freePlane() + withdrawable - _bufferTarget());
    }

    function _queuedOf(address a, bool reward) internal view returns (int256) {
        return reward ? queuedRew[a] : queuedInv[a];
    }

    /// @dev ЕДИНСТВЕННЫЙ писатель суммы заявок ключа: держит в согласии `queuedSum`, `queuedInv`, `queuedRew`, `queuedInvSum`.
    function _queueAdd(address a, bool reward, int256 delta) internal {
        queuedSum += delta;
        if (reward) {
            queuedRew[a] += delta;
        } else {
            queuedInv[a] += delta;
            queuedInvSum += delta;
        }
    }

    /// @dev Доля адреса в `amount` поколения; при `amount == 0` — 0 без чтения веса (attr(s, 0, T) = 0 при любом s).
    function _share(address a, int256 g, int256 amount) internal view returns (int256) {
        if (amount == 0) return 0;
        int256 s = snapW[g][a];
        return s != 0 ? _attr(s, amount, snapTotal[g]) : int256(0);
    }

    /// @dev `col[a][g]` эталона уже равен доле текущего R: адрес разнесён строкой ЭТОГО расчёта, а `rMon` ещё прежний
    /// (`rMon` обновляет начало фазы 2). Вне расчёта `col[a][g]` = доля `rMon[g]`. Ред. 9.5: в фазе 2 — тоже доля R: начало фазы 2
    /// пишет `rMon` только ЖИВЫМ поколениям, окончательные закроет конец расчёта, и их `rMon` не читает больше никто.
    function _colIsR(address a) internal view returns (bool) {
        return mondayOpen && (monStage != MS_ROWS || uint256(inv[a].regIndex) < mondayCursor);
    }

    /// @dev Неразнесённый результат адреса Σ_g доля(R_g) − col (эталон `_pending_realized`) — ведущаяся сумма.
    function _pendingRealized(address a) internal view returns (int256) {
        return aggPend[a];
    }

    /// @dev Σ доли upnl открытых ордеров (эталон `unrealized`) — ведущаяся сумма.
    function _unrealized(address a) internal view returns (int256) {
        return aggU[a];
    }

    /// @dev Вклад ордера в ведущиеся суммы адреса с весом `s` (эталон — тело циклов `unrealized`, бумажного убытка и
    /// `exposure_hold`): доля upnl и бумажный убыток — у открытого, удержание — у sized/open, у закрытого — нули.
    function _orderTerms(Order storage o, int256 s) internal view returns (int256 u, int256 pl, int256 ex) {
        uint8 st = o.state;
        if (s == 0 || (st != ST_SIZED && st != ST_OPEN)) return (0, 0, 0);
        int256 T = snapTotal[o.gen];
        int256 upnl = o.upnl;
        if (st == ST_OPEN && upnl != 0) {
            u = _attr(s, upnl, T);
            if (upnl < 0) pl = -u;
        }
        uint256 share = _ceilDivU(uint256(s) * uint256(o.notional), uint256(T));
        int256 byHold = int256(_ceilDivU(share * uint256(holdBps), uint256(BPS)));
        ex = _max(byHold, pl);
    }

    /// @dev ЕДИНСТВЕННЫЙ писатель сумм по ордерам: вклад ордера `o` у всех участников его снимка — прибавить (`add`) или
    /// снять. Писатели ордера (`sizeOrder`, `cancelOrder`, `markPosition`, `closePosition`) снимают вклад ДО изменения ордера и
    /// прибавляют ПОСЛЕ — суммы равны обходу ордеров, который они заменяют, по построению. O(снимка).
    function _aggOrder(Order storage o, bool add) internal {
        mapping(address => int256) storage w = snapW[o.gen];
        uint256 n = snapN[o.gen];
        int256 p = o.partR; // часть бывает только у открытого (sized её не получает, закрытие снимает)
        for (uint256 j = 0; j < n; j++) {
            address a = order[j];
            int256 s = w[a];
            if (s == 0) continue;
            (int256 u, int256 pl, int256 ex) = _orderTerms(o, s);
            if (!add) (u, pl, ex) = (-u, -pl, -ex);
            if (u != 0) aggU[a] += u;
            if (pl != 0) aggPL[a] += pl;
            if (ex != 0) aggEx[a] += ex;
            if (p != 0) _aggPart(a, o, s, add ? u : -u, p, add);
        }
    }

    /// @dev Ред. 9.3.1: вклад ОТКРЫТОГО ордера с частью `p` в суммы базы комиссии адреса (`u` — доля его марка). Тело циклов
    /// эталона `_fee_deferral` (U: доля(upnl + p) вместо доли(upnl)) и `_fee_reserve_base` (часть в минус — ордер открыт,
    /// −доля(p) в базу и доля(upnl + p) в общий бумажный; часть в плюс — ордер закрыт, доля(min(0, upnl)) отдельно).
    /// −доля(p) при p < 0 — `_attr` в uint256 от −p: s·|p| доходит до 2^255 − 2^128 (знаковое произведение не годится).
    function _aggPart(address a, Order storage o, int256 s, int256 u, int256 p, bool add) internal {
        int256 T = snapTotal[o.gen];
        int256 ud = _attr(s, o.upnl + p, T) - u;
        int256 rb;
        int256 ru = ud;
        if (p < 0) {
            rb = -_attr(s, p, T);
        } else {
            rb = o.upnl < 0 ? u : int256(0);
            ru = -u;
        }
        if (!add) (ud, rb, ru) = (-ud, -rb, -ru);
        aggUd[a] += ud;
        aggRb[a] += rb;
        aggRU[a] += ru;
    }

    /// @dev Закрытый результат поколения `g` сдвинулся с `x0` на `x1`: неразнесённое каждого участника снимка — на разницу долей.
    /// Ред. 9.3.1: и D адреса (доля(R) − доля(R − P_g), P_g — части открытых ордеров) при сумме частей `p0` -> `p1`.
    /// Ред. 9.5: та же сумма разниц — в Σ_a доля(R_g) поколения (`shareSum`), без нового обхода.
    function _aggR(int256 g, int256 x0, int256 x1, int256 p0, int256 p1) internal {
        uint256 n = snapN[g];
        int256 sd;
        for (uint256 j = 0; j < n; j++) {
            address a = order[j];
            int256 s1 = _share(a, g, x1);
            int256 s0 = _share(a, g, x0);
            int256 d = s1 - s0;
            if (d != 0) {
                aggPend[a] += d;
                sd += d;
            }
            if (p0 != 0 || p1 != 0) {
                int256 dd = (p1 != 0 ? s1 - _share(a, g, x1 - p1) : int256(0)) - (p0 != 0 ? s0 - _share(a, g, x0 - p0) : int256(0));
                if (dd != 0) aggD[a] += dd;
            }
        }
        if (sd != 0) shareSum[g] += sd;
    }

    /// @dev Ред. 9.3.1 — база комиссии адреса (эталон `_fee_deferral`, `_fee_reserve_base`) сверх `cum_pnl` и неразнесённого:
    /// `near` — ближайший понедельник min(0, U) − D (части открытых ордеров вне базы, вместе с марком остатка — бумажные);
    /// `res` — резерв, ХУДШИЙ для казны порядок закрытий. Без открытых ордеров с частью оба — min(0, unrealized) бит в бит.
    function _feeBase(address a, int256 unre) internal view returns (int256 near, int256 res) {
        if (partOrders == 0) {
            near = _min(0, unre);
            return (near, near);
        }
        near = _min(0, unre + aggUd[a]) - aggD[a];
        res = aggRb[a] + _min(0, unre + aggRU[a]);
    }

    /// @dev СОБСТВЕННЫЕ плоскости адреса (эталон `_own_planes`, ред. 9: вознаграждение — у ВСЕХ, treasury инвестором не бывает).
    function _ownPlanes(address a) internal view returns (int256 own) {
        Investor storage r = inv[a];
        if (r.exists) own = r.stake + _queuedOf(a, false) + claimable[a];
        own += claimableReward[a] + rewardCash[a] + _queuedOf(a, true);
    }

    /// @dev Ред. 9.4 — плоскости адреса для правила E (эталон `_emergency_planes`, ЕДИНСТВЕННЫЙ набор): `s` — КАПИТАЛ (`stake` и
    /// его заявки: заявка стоит залогом в торговле, решение 18.10), `f` — ФИКСИРОВАННОЕ («к получению» и вознаграждение во
    /// всех плоскостях). Неразнесённого результата недели, марок, комиссии, резерва (MX2) и книги доплативших здесь нет.
    function _emLive(address a) internal view returns (int256 f, int256 s) {
        if (inv[a].exists) s = inv[a].stake + queuedInv[a];
        f = claimable[a] + claimableReward[a] + rewardCash[a] + queuedRew[a];
    }

    /// @dev Котёл treasury F_T — всё её вознаграждение в пуле (эталон `_treasury_planes`).
    function _emTreasury() internal view returns (int256) {
        return rewardCash[treasury] + claimableReward[treasury] + queuedRew[treasury];
    }

    struct Proj {
        int256 pend;
        int256 unre;
        int256 pendingLoss;
        int256 feeDue;
        int256 feeAccrued;
        int256 uncovered;
        int256 weight; // капитал после строки расчёта по маркам (`after` эталона), ДО возврата фазы 2 и потолка капиталом
        int256 own;
    }

    /// @dev ЕДИНСТВЕННЫЙ владелец величин «как если бы расчёт прошёл СЕЙЧАС» (эталон `_projected`, ред. 9.2.2).
    /// Гейты (`now_ = false`) судят ХУДШИЙ порядок: закрытая прибыль должника разносится любым ближайшим понедельником и её
    /// положительная часть сначала гасит его долг, поэтому бумажный убыток гасится только max(0, закрытое − гашение долга).
    /// `now_ = true` — тот же расчёт РАЗОМ (бумажный убыток гасится всей закрытой прибылью): его берёт ТОЛЬКО граница доплаты
    /// веса. Вес (ред. 9.2.1) гасит свой долг из результата ПО МАРКАМ; возврат фазы 2 и потолок капиталом прибавляет
    /// вызывающий (`_weightOf`).
    function _projected(address a, bool marks, bool now_) internal view returns (Proj memory P) {
        Investor storage r = inv[a];
        if (!r.exists) return P;
        P.pend = _pendingRealized(a);
        P.unre = _unrealized(a);
        P.pendingLoss = _max(0, -P.pend);
        int256 repay = _min(_max(0, P.pend), r.uncovered);
        if (marks) {
            int256 paperLoss = aggPL[a];
            P.pendingLoss += _max(0, paperLoss - (now_ ? _max(0, P.pend) : _max(0, P.pend) - repay));
            int256 net = P.pend - _min(_max(0, P.pend - paperLoss), r.uncovered) - paperLoss;
            P.weight = _max(0, r.stake + net - (_max(0, r.cumPnl + net - r.hwm) * feeBps) / BPS);
        }
        (int256 near, int256 res) = _feeBase(a, P.unre); // ред. 9.3.1: ближайший понедельник или резерв — большая база
        int256 due = (_max(0, r.cumPnl + P.pend - repay + _max(near, res) - r.hwm) * feeBps) / BPS;
        P.feeDue = _max(0, due - _max(0, P.pend - repay));
        P.feeAccrued = (_max(0, r.cumPnl + P.pend - repay + P.unre - r.hwm) * feeBps) / BPS;
        if (marks) {
            // свои деньги и недостачу читают только проекции по маркам (раздел, гейт депозита); без марок — резерв и витрины
            P.own = _ownPlanes(a);
            P.uncovered = _max(0, P.pendingLoss - P.own);
        }
    }

    /// @dev Убыток адреса по поколениям по маркам (эталон `_loss_by_gen(addr, marks=True)`), в `out[off + k]` — по `_genAt(k)`.
    function _lossByGenInto(address a, int256[] memory out, uint256 off) internal view {
        bool settled = _colIsR(a);
        uint256 G = _snapCount();
        for (uint256 k = 0; k < G && !settled; k++) {
            int256 g = _genAt(k);
            int256 x = R[g];
            int256 y = rMon[g];
            int256 d = x != y ? _share(a, g, x) - _share(a, g, y) : int256(0);
            if (d < 0) out[off + k] = -d;
        }
        for (uint256 i = 0; i < orderPids.length; i++) {
            Order storage o = orders[orderPids[i]];
            if (o.state == ST_OPEN && o.upnl < 0) {
                int256 x = -_share(a, o.gen, o.upnl);
                if (x != 0) out[off + _genIndex(o.gen)] += x;
            }
        }
    }

    /// @dev Число поколений со снимками (`len(snaps)` эталона): пережившие прошлый расчёт и все открытые после него.
    function _snapCount() internal view returns (uint256) {
        return survN + uint256(gen - genBase);
    }

    /// @dev Поколение на позиции `k` снимков (по возрастанию номера): сначала пережившие, затем открытые после расчёта подряд.
    function _genAt(uint256 k) internal view returns (int256) {
        uint256 m = survN;
        return k < m ? surv[k] : genBase + 1 + int256(k - m);
    }

    /// @dev Позиция поколения среди снимков (обратное `_genAt`): открытое после расчёта — арифметикой, пережившее — поиском.
    function _genIndex(int256 g) internal view returns (uint256) {
        uint256 m = survN;
        if (g > genBase) {
            if (g > gen) revert Revert("gen index");
            return m + uint256(g - genBase - 1);
        }
        uint256 lo;
        uint256 hi = m;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (surv[mid] < g) lo = mid + 1;
            else hi = mid;
        }
        if (lo == m || surv[lo] != g) revert Revert("gen index");
        return lo;
    }

    /// @dev Живое поколение — в хвост списка (новое поколение — всегда наибольшее, порядок по возрастанию сохраняется).
    function _lvAppend(int256 g) internal {
        int256 t = lvTail;
        lvPrev[g] = t;
        if (t != 0) lvNext[t] = g;
        else lvHead = g;
        lvTail = g;
        lvN += 1;
    }

    function _lvRemove(int256 g) internal {
        int256 p = lvPrev[g];
        int256 q = lvNext[g];
        if (p != 0) lvNext[p] = q;
        else lvHead = q;
        if (q != 0) lvPrev[q] = p;
        else lvTail = p;
        delete lvPrev[g];
        delete lvNext[g];
        lvN -= 1;
    }

    /// @dev Ред. 9.5: поколение `g` стало ОКОНЧАТЕЛЬНЫМ — не текущее и без живых ордеров: ордер встаёт только в текущее (эталон
    /// `size_order`), значит ни ордера, ни результата в него больше не придёт. То, что `_finalizeGenerations` сделал бы с ним
    /// обходом, считается сейчас и ждёт расчёта: пыль округлений R − Σ долей (`shareSum` = Σ col эталона после строк) — в котёл,
    /// R — в закрытый итог, его слагаемые — из `growSum`/`snapTotalSum`. Снимок, R и rMon остаются: их читают строка должника,
    /// раздел недостачи и выгрузка этого расчёта (эталон держит поколение в `snaps` до конца `monday`). Из живых — сразу.
    function _genDead(int256 g) internal {
        int256 x = R[g];
        int256 s = shareSum[g];
        if (s > x) revert Revert("monday: over-distributed");
        dustPending += x - s;
        closedPending += x;
        growDead += _max(0, x) + genUpos[g];
        totalDead += snapTotal[g];
        _lvRemove(g);
    }

    // --- раздел недостачи (ред. 9) -------------------------------------------------------------------------------- //

    /// @dev Эталон `_split` (ред. 9.1): целое `need` между кандидатами (позиция k — ключ, `w[k]` — вес, `cap[k]` — вместимость;
    /// вес <= 0 исключает кандидата) ОДНИМ кругом: каждому floor(need·w/W), не больше вместимости; пыль округления
    /// (need − Σ floor) — по 1 в порядке списка тем, у кого вместимость осталась. Упёршаяся доля НИКОМУ не перекладывается —
    /// возвращается остатком. `ins[0..nIns)` — порядок, в котором ключи ВПЕРВЫЕ получили долю: это порядок обхода
    /// питоновского словаря-результата, и `_payBack` зачисляет в нём (номера заявок очереди зависят от порядка).
    function _split(int256 need, int256[] memory w, int256[] memory cap)
        internal
        pure
        returns (int256[] memory give, uint256[] memory ins, uint256 nIns, int256 rest)
    {
        uint256 m = w.length;
        give = new int256[](m);
        ins = new uint256[](m);
        (nIns, rest) = _splitInto(need, w, cap, m, give, ins, new int256[](m));
    }

    /// @dev То же правило `_split` на первых `m` кандидатах и в ЧУЖИХ буферах (`give`, `ins`, `left` — не короче `m`): проекция
    /// фазы 2 (`_repayProjection`) зовёт его на каждую работу очереди возвратов, а память в EVM не освобождается — свежие
    /// массивы на каждый вызов стоили бы квадратичного роста памяти. `give[0..m)` переписывается целиком.
    function _splitInto(
        int256 need,
        int256[] memory w,
        int256[] memory cap,
        uint256 m,
        int256[] memory give,
        uint256[] memory ins,
        int256[] memory left
    ) internal pure returns (uint256 nIns, int256 rest) {
        if (w.length < m || cap.length < m || give.length < m || ins.length < m || left.length < m) {
            revert Revert("split: buffer");
        }
        uint256 W;
        assembly {
            for { let o := 0 } lt(o, shl(5, m)) { o := add(o, 32) } {
                mstore(add(add(give, 32), o), 0)
                let wk := mload(add(add(w, 32), o))
                if sgt(wk, 0) {
                    let nw := add(W, wk)
                    if lt(nw, W) { nw := not(0) } // переполнение — в широкий путь, там сумма с проверкой (отказ)
                    W := nw
                }
            }
        }
        if (need <= 0 || W == 0) return (0, _max(0, need));
        if (uint256(need) > U128_MAX || W > U128_MAX) return _splitWide(need, w, cap, m, give, ins, left);
        // need·w < 2^256 (оба в uint128, вес не больше суммы); floor-доли в сумме не больше need, пыль меньше m
        assembly {
            let dust := need
            for { let o := 0 } lt(o, shl(5, m)) { o := add(o, 32) } {
                let wk := mload(add(add(w, 32), o))
                if sgt(wk, 0) {
                    let fl := div(mul(need, wk), W)
                    dust := sub(dust, fl)
                    let ck := mload(add(add(cap, 32), o))
                    if slt(ck, fl) { fl := ck }
                    if fl {
                        mstore(add(add(give, 32), o), fl)
                        mstore(add(add(ins, 32), shl(5, nIns)), shr(5, o))
                        nIns := add(nIns, 1)
                    }
                    mstore(add(add(left, 32), o), sub(ck, fl))
                }
            }
            for { let o := 0 } and(lt(o, shl(5, m)), iszero(iszero(dust))) { o := add(o, 32) } {
                if and(sgt(mload(add(add(w, 32), o)), 0), sgt(mload(add(add(left, 32), o)), 0)) {
                    let g := mload(add(add(give, 32), o))
                    if iszero(g) {
                        mstore(add(add(ins, 32), shl(5, nIns)), shr(5, o))
                        nIns := add(nIns, 1)
                    }
                    mstore(add(add(give, 32), o), add(g, 1))
                    mstore(add(add(left, 32), o), sub(mload(add(add(left, 32), o)), 1))
                    dust := sub(dust, 1)
                }
            }
            rest := need
            for { let o := 0 } lt(o, shl(5, m)) { o := add(o, 32) } {
                rest := sub(rest, mload(add(add(give, 32), o)))
            }
        }
    }

    /// @dev Та же `_splitInto` для сумм вне uint128 (произведение через `_mulDiv`, сумма весов с проверкой переполнения). В
    /// бухгалтерии таких сумм нет — капиталы держит потолок uint128, — путь оставлен, чтобы правило от границы не зависело.
    function _splitWide(
        int256 need,
        int256[] memory w,
        int256[] memory cap,
        uint256 m,
        int256[] memory give,
        uint256[] memory ins,
        int256[] memory left
    ) internal pure returns (uint256 nIns, int256 rest) {
        uint256 W;
        for (uint256 k = 0; k < m; k++) {
            if (w[k] > 0) W += uint256(w[k]);
        }
        int256 dust = need;
        for (uint256 k = 0; k < m; k++) {
            if (w[k] <= 0) continue;
            int256 fl = int256(_mulDiv(uint256(need), uint256(w[k]), W));
            dust -= fl;
            int256 x = _min(cap[k], fl);
            if (x != 0) {
                give[k] = x;
                ins[nIns++] = k;
            }
            left[k] = cap[k] - x;
        }
        rest = need;
        for (uint256 k = 0; k < m && dust != 0; k++) {
            if (w[k] <= 0) continue;
            if (left[k] > 0) {
                if (give[k] == 0) ins[nIns++] = k;
                give[k] += 1;
                left[k] -= 1;
                dust -= 1;
            }
        }
        for (uint256 k = 0; k < m; k++) {
            rest -= give[k];
        }
    }

    /// @dev «Проектного убытка нет НИ У КОГО» за O(1) — тогда недостач по маркам нет. Убыток адреса по маркам
    /// PL_a = max(0, −pend_a) + max(0, бумажный_a − max(0, pend_a)). Бумажного нет, когда ни у одного открытого ордера
    /// upnl < 0 (`genLossOrders`). col[a][g] — доля R поколения на последнем расчёте (`rMon`), поэтому
    /// pend_a = Σ_g [доля(R_g) − доля(rMon_g)], а доля = floor(s·x/T) монотонна по x: при R_g >= rMon_g каждое слагаемое >= 0.
    /// Значит PL_a = 0 у всех, недостач нет, `hold` — нули, `mark_uncovered` — 0. Иначе — честный обход. Ред. 9.5: поколений,
    /// где условие нарушено, ведётся счёт (`lossRN` — R < rMon, `lossOpenN` — бумажный убыток), а не обход.
    function _noProjectedLoss() internal view returns (bool) {
        return lossRN == 0 && lossOpenN == 0;
    }

    /// @dev Всё, из чего эталон `_cover_projection(marks=True)[2]` собирает `hold`, — ОДНИМ обходом проекций на операцию.
    /// Сам `hold` считается по адресу (`_holdAt`) только там, где он нужен: вывод, забор и выплата читают его у одного-двух
    /// адресов, а не у всех. Проектную доплату и дыру эталон тоже считает (`_allocate`), но ред. 9.1 их нигде не читает: вес,
    /// резерв и свободное вычитают `hold`, гейт депозита — `mark_uncovered`; поэтому раздел здесь не исполняется.
    struct HoldCtx {
        bool swept; //       false — `_noProjectedLoss`: недостач нет, `hold` у всех 0, проекции не считались
        int256[] cap; //     по позиции в `order`: max(0, свои деньги − проектный убыток)
        int256[] basis; //   max(0, капитал + свои заявки − проектный убыток)
        int256[] weight; //  вес проекции по маркам (до вычета `hold`)
        uint256 nd; //       должники по маркам (uncovered > 0) в порядке регистрации
        uint256[] dIdx;
        int256[] dAmt;
        uint256[] dOff; //   nd + 1: поколения убытка должника d — записи [dOff[d], dOff[d + 1]) списков dK/dRest
        uint256[] dK; //     позиция поколения убытка в снимках (`_genAt`)
        int256[] dG; //      номер того же поколения (ред. 9.5: `_worstOf` не пересчитывает позицию в номер)
        int256[] dRest; //   вес снимка этого поколения без должника
        int256[] dNg; //     число поколений убытка должника (пыль)
        int256[] wb; //      буфер `_holdAt` по позиции в снимках: вес адреса `wbAddr` в поколении (читается один раз)
        uint256[] wbAt; //   для какого адреса (позиция + 1) записан вес в `wb`
        uint256 wbFor;
        address wbAddr;
        int256 U; //         вся проектная недостача
    }

    /// @dev Контекст `hold` одного состояния — его считает ОДНА реализация, PoolLedgerProj (`_holdCtxLocal`), а остальные
    /// получают его статическим вызовом бухгалтерии самой себя: fallback отдаёт `holdCtx()` проекциям делегированным вызовом
    /// на этой же памяти. Так проекция (ред. 9.2.1/9.2.2 — черновик фазы 2 `_repayProjection`) живёт в одном контракте, а не
    /// в каждой реализации, которой нужен `hold`. Отказ проекции — отказ вызывающего с тем же ответом. Граница «проектного
    /// убытка нет» (`_noProjectedLoss`, O(поколений)) судится ДО вызова: тогда контекст гейтов пуст и вызов не нужен — это
    /// почти каждая операция. Возврат фазы 2 гейты видят только во вместимости и базе раздела (`money`), а раздела без
    /// недостач нет — поэтому граница верна и с ред. 9.2.1. Для ВЕСА она не годится: возврат меняет вес и без проектного
    /// убытка (книга непуста, должник в плюсе) — вес всегда считает PoolLedgerProj (`_weightsRemote`).
    function _holdCtx() internal view returns (HoldCtx memory c) {
        if (_noProjectedLoss()) return c;
        return abi.decode(_projCall(SEL_HOLD_CTX), (HoldCtx));
    }

    /// @dev Веса снимка ордера, рассчитанного СЕЙЧАС (эталон `weights()`), по позиции в `order` — из PoolLedgerProj.
    function _weightsRemote() internal view returns (int256[] memory) {
        return abi.decode(_projCall(SEL_WEIGHTS), (int256[]));
    }

    /// @dev Статический вызов бухгалтерии самой себя селектором проекций (fallback -> PoolLedgerProj делегированным вызовом на
    /// этой памяти); отказ — тот же ответ.
    function _projCall(bytes4 sel) internal view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = address(this).staticcall(abi.encodeWithSelector(sel));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @dev Эталон `_cover_projection(marks=True, ph, repay_cut)` в форме контекста `hold`. `forWeight` — граница доплаты
    /// ВЕСА (`weight_terms`, ред. 9.2.2): проекция адресов — расчёт РАЗОМ (`_projected(now_ = true)`), недостача — за вычетом
    /// той, что погасит пришедший возврат (`ph.cut`). Гейты — худший порядок и прежние недостачи. У обоих раздел идёт ПОСЛЕ
    /// возвратов (ред. 9.2.1): вместимость и база включают возврат, пришедший адресу в капитал и в заявки (`ph.money`).
    function _holdCtxLocal(bool forWeight, RepayProj memory ph) internal view returns (HoldCtx memory c) {
        if (_noProjectedLoss()) return c;
        uint256 n = order.length;
        c.swept = true;
        c.cap = new int256[](n);
        c.basis = new int256[](n);
        c.weight = new int256[](n);
        c.dIdx = new uint256[](n);
        c.dAmt = new int256[](n);
        for (uint256 i = 0; i < n; i++) {
            address a = order[i];
            Proj memory P = _projected(a, true, forWeight);
            int256 money = ph.any ? ph.money[i] : int256(0);
            c.cap[i] = _max(0, P.own - P.pendingLoss) + money;
            c.basis[i] = _max(0, inv[a].stake + queuedInv[a] - P.pendingLoss) + money;
            c.weight[i] = _weightOf(a, P, ph, i);
            // гашение возвратом не больше проектной недостачи: недостача черновика — та же величина без пыли формулы
            // (`_settleDelta`), а `uncovered` проекции округляет против держателя (эталон: ValueError)
            int256 short = P.uncovered - (forWeight && ph.any ? ph.cut[i] : int256(0));
            if (short < 0) revert Revert("_cover_projection: cut");
            if (short > 0) {
                c.dIdx[c.nd] = i;
                c.dAmt[c.nd] = short;
                c.U += short;
                c.nd++;
            }
        }
        if (c.nd == 0) return c;
        uint256 G = _snapCount();
        c.dOff = new uint256[](c.nd + 1);
        c.dK = new uint256[](c.nd * G);
        c.dG = new int256[](c.nd * G);
        c.dRest = new int256[](c.nd * G);
        c.dNg = new int256[](c.nd);
        c.wb = new int256[](G);
        c.wbAt = new uint256[](G);
        int256[] memory loss = new int256[](G);
        uint256 j;
        for (uint256 d = 0; d < c.nd; d++) {
            for (uint256 k = 0; k < G; k++) {
                loss[k] = 0;
            }
            address a = order[c.dIdx[d]];
            _lossByGenInto(a, loss, 0);
            for (uint256 k = 0; k < G; k++) {
                if (loss[k] == 0) continue;
                int256 g = _genAt(k);
                c.dK[j] = k;
                c.dG[j] = g;
                c.dRest[j++] = snapTotal[g] - snapW[g][a];
                c.dNg[d]++;
            }
            c.dOff[d + 1] = j;
        }
    }

    /// @dev Вес проекции адреса ДО вычета `hold` (эталон `_projected(...)["weight"]`, ред. 9.2.1): капитал после строки
    /// расчёта по маркам плюс возврат, который фаза 2 того же расчёта зачислит ему в капитал, — не выше капитала.
    function _weightOf(address a, Proj memory P, RepayProj memory ph, uint256 i) internal view returns (int256) {
        return _min(inv[a].stake, P.weight + (ph.any ? ph.stake[i] : int256(0)));
    }

    /// @dev Эталон `weights()`: веса ВСЕХ адресов одного состояния, по позиции в `order`. Проекция возврата и граница
    /// доплаты веса считаются ОДИН раз на состояние (ред. 9.2.2, п. 5). Нулевой вес проекции `hold` не читает.
    function _weightsLocal() internal view returns (int256[] memory w) {
        RepayProj memory ph = _repayProjection();
        HoldCtx memory c = _holdCtxLocal(true, ph);
        uint256 n = order.length;
        w = new int256[](n);
        for (uint256 i = 0; i < n; i++) {
            address a = order[i];
            int256 pw = c.swept ? c.weight[i] : _weightOf(a, _projected(a, true, false), ph, i);
            if (pw != 0) w[i] = _max(0, pw - _holdAt(c, i));
        }
    }

    // --- проекция фазы 2 возвратов (ред. 9.2.1 / 9.2.2) ------------------------------------------------------------ //

    /// @dev Эталон `_repay_projection`, по позиции в `order`: `stake` — сколько возврат фазы 2 «расчёта сейчас по маркам»
    /// зачислит адресу в капитал; `money` — в капитал и в его заявки (выход, режим выплаты); `cut` — сколько недостачи ЭТОЙ
    /// недели адреса погасит пришедший ему возврат. `any == false` (массивы не выделены) — ни у одного должника нет
    /// положительного результата недели: возврата нет.
    struct RepayProj {
        bool any;
        int256[] stake;
        int256[] money;
        int256[] cut;
    }

    /// @dev Черновик `_pay_back` в памяти (адрес — позиция в `order`). Узел заводится ЛЕНИВО, при первом касании: результат
    /// недели по маркам (`_settleDelta`), долг и свои деньги читаются только у должников в плюсе и у получателей возврата.
    /// Строка книги должника читается из памяти контракта один раз — при его первой работе — и дальше живёт здесь (её меняет
    /// только его же работа). Очередь работ — кольцо на n мест: ждущая работа адреса в нём не больше одной (слияние эталона).
    struct RpMem {
        uint256 n;
        address[] ord;
        bool[] init;
        bool[] toQ; //       выход или режим выплаты: возврат — заявкой, не в капитал
        int256[] unc; //     `uncovered` черновика
        int256[] fresh; //   недостача этой недели, ещё не погашенная возвратом (`pending` эталона)
        int256[] short0;
        uint256[] slot; //   позиция ждущей работы в кольце + 1 (0 — не ждёт)
        uint256[] ringA;
        int256[] ringX;
        uint256 head;
        uint256 cnt;
        uint256[][] rowIdx; // строка книги должника: позиции доплативших по регистрации, последняя (n) — счёт пула
        int256[][] rowAmt;
        int256[] give; //    буферы `_splitInto` (n + 1)
        uint256[] ins;
        int256[] left;
        bool paper; //       поколения с бумажным убытком прочитаны
        int256[] pg; //      номер поколения, R, Σ min(0, upnl) открытых, вес снимка
        int256[] pr;
        int256[] pp;
        int256[] pt;
        uint256 np;
    }

    function _repayProjection() internal view returns (RepayProj memory ph) {
        uint256 n = order.length;
        RpMem memory M;
        M.n = n;
        uint256 first = n;
        // должник в плюсе: долг > 0 и результат недели > 0. Результат по маркам не больше неразнесённого (бумажный убыток
        // только уменьшает долю), поэтому при aggPend <= 0 возврата нет и проекция результата не нужна
        for (uint256 i = 0; i < n && first == n; i++) {
            address a = order[i];
            int256 pend = aggPend[a];
            if (inv[a].uncovered > 0 && pend > 0 && (pend > aggPL[a] || _settleDelta(M, a) > 0)) first = i;
        }
        if (first == n) return ph;
        ph.any = true;
        ph.stake = new int256[](n);
        ph.money = new int256[](n);
        ph.cut = new int256[](n);
        M.ord = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            M.ord[i] = order[i];
        }
        M.init = new bool[](n);
        M.toQ = new bool[](n);
        M.unc = new int256[](n);
        M.fresh = new int256[](n);
        M.short0 = new int256[](n);
        M.slot = new uint256[](n);
        M.ringA = new uint256[](n);
        M.ringX = new int256[](n);
        M.rowIdx = new uint256[][](n);
        M.rowAmt = new int256[][](n);
        M.give = new int256[](n + 1);
        M.ins = new uint256[](n + 1);
        M.left = new int256[](n + 1);
        // фаза 1 черновика (эталон: `M._credit(a, back[a], "debt")` у всех, затем недостача недели в долг): работы — должники
        // в плюсе в порядке регистрации; остальные узлы заводятся при первом касании
        for (uint256 i = first; i < n; i++) {
            address a = M.ord[i];
            if (inv[a].uncovered <= 0 || aggPend[a] <= 0) continue;
            int256 back = _rpInit(M, i);
            if (back > 0) _rpPush(M, i, back);
        }
        while (M.cnt != 0) {
            uint256 ai = M.ringA[M.head];
            int256 x0 = M.ringX[M.head];
            M.head = M.head + 1 == n ? 0 : M.head + 1;
            M.cnt--;
            M.slot[ai] = 0;
            _rpWork(M, ph, ai, x0);
        }
        for (uint256 i = 0; i < n; i++) {
            if (M.short0[i] != 0) ph.cut[i] = M.short0[i] - M.fresh[i];
        }
    }

    /// @dev Одна работа очереди возвратов (эталон — тело цикла `_pay_back`): возврат должника `ai` — доплатившим
    /// пропорционально непогашенному по его строке книги (`_splitInto`, кандидаты по регистрации, счёт пула последним), в
    /// порядке, в котором ключи получили долю; доля счёта пула гасит долг пула и черновику не нужна.
    function _rpWork(RpMem memory M, RepayProj memory ph, uint256 ai, int256 x0) internal view {
        if (M.rowAmt[ai].length == 0) _rpRow(M, ai);
        int256[] memory amt = M.rowAmt[ai];
        (uint256 nIns, int256 rest) = _splitInto(x0, amt, amt, amt.length, M.give, M.ins, M.left);
        if (rest != 0) revert Revert("_pay_back: over debt");
        _rpPay(M, ph, M.rowIdx[ai], amt, nIns);
    }

    /// @dev Доли работы — получателям в порядке `ins` (k < длины строки: его дал `_splitInto`); строка уменьшается на долю.
    function _rpPay(RpMem memory M, RepayProj memory ph, uint256[] memory idx, int256[] memory amt, uint256 nIns)
        internal
        view
    {
        uint256[] memory ins = M.ins;
        int256[] memory give = M.give;
        for (uint256 t = 0; t < nIns;) {
            uint256 b;
            int256 x;
            assembly {
                let ko := add(32, shl(5, mload(add(add(ins, 32), shl(5, t)))))
                x := mload(add(give, ko))
                mstore(add(amt, ko), sub(mload(add(amt, ko)), x))
                b := mload(add(idx, ko))
                t := add(t, 1)
            }
            if (b != M.n) _rpTo(M, ph, b, x);
        }
    }

    /// @dev Результат недели адреса ТОЧНО так, как его дал бы расчёт после закрытия открытых ордеров по текущим маркам с
    /// обнулённой бумажной прибылью (эталон `_settle_delta`): бумажный убыток ложится в результат своего поколения, доля — от
    /// суммы. Неразнесённое (`aggPend`) уже равно Σ_g доля(R_g) − col; поправка — только по поколениям с бумажным убытком.
    function _settleDelta(RpMem memory M, address a) internal view returns (int256 d) {
        if (!M.paper) _rpPaper(M);
        d = aggPend[a];
        for (uint256 j = 0; j < M.np; j++) {
            int256 s = snapW[M.pg[j]][a];
            if (s != 0) d += _attr(s, M.pr[j] + M.pp[j], M.pt[j]) - _attr(s, M.pr[j], M.pt[j]);
        }
    }

    /// @dev Поколения с бумажным убытком — только живые (у окончательного открытых ордеров нет): обход списка живых.
    function _rpPaper(RpMem memory M) internal view {
        uint256 G = lvN;
        M.paper = true;
        M.pg = new int256[](G);
        M.pr = new int256[](G);
        M.pp = new int256[](G);
        M.pt = new int256[](G);
        for (int256 g = lvHead; g != 0; g = lvNext[g]) {
            if (genLossOrders[g] == 0) continue;
            uint256 j = M.np++;
            M.pg[j] = g;
            M.pr[j] = R[g];
            M.pp[j] = genU[g] - genUpos[g];
            M.pt[j] = snapTotal[g];
        }
    }

    /// @dev Узел черновика: гашение своего долга своим результатом (ответ — сумма работы должника в плюсе) и недостача
    /// недели сверх своих денег (комиссии при ней нет — потолок `avail`) — в долг.
    /// Точный результат недели по маркам (`_settleDelta`, чтение веса в каждом поколении с бумажным убытком) нужен, только
    /// когда ответ от него зависит. Границы: pend − aggPL <= результат <= pend. Сверху — доля монотонна, а бумажный убыток
    /// поколения <= 0. Снизу — доля = floor(s·x/T) при любом знаке x (`_attr`), floor(a + b) >= floor(a) + floor(b), поэтому
    /// доля(R + Σ убытков) − доля(R) >= Σ доля(убытка ордера) = −aggPL. Значит: pend <= 0 — возврата нет; pend − aggPL >= долга
    /// — гасится весь долг; pend − aggPL + свои деньги >= 0 — недостачи нет. Иначе — точно.
    function _rpInit(RpMem memory M, uint256 i) internal view returns (int256 back) {
        address a = M.ord[i];
        Investor storage r = inv[a];
        int256 pend = aggPend[a];
        int256 lo = pend - aggPL[a];
        int256 u = r.uncovered;
        int256 delta;
        bool exact;
        if (u > 0 && pend > 0) {
            if (lo >= u) {
                back = u;
            } else {
                delta = _settleDelta(M, a);
                exact = true;
                back = _min(_max(0, delta), u);
            }
        }
        int256 short;
        if (lo < 0) {
            int256 own = _ownPlanes(a);
            if (lo + own < 0) {
                if (!exact) delta = _settleDelta(M, a);
                short = _max(0, -delta - own);
            }
        }
        M.unc[i] = u - back + short;
        M.fresh[i] = short;
        M.short0[i] = short;
        M.toQ[i] = r.exiting || r.payoutMode;
        M.init[i] = true;
    }

    /// @dev Номер младшего единичного бита `x` (x != 0): двоичный поиск по выделенному биту без цикла.
    function _lowBit(uint256 x) internal pure returns (uint256 r) {
        assembly {
            x := and(x, sub(0, x))
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            r := or(r, shl(2, lt(0xf, shr(r, x))))
            r := or(r, shl(1, lt(0x3, shr(r, x))))
            r := or(r, lt(0x1, shr(r, x)))
        }
    }

    function _rpPush(RpMem memory M, uint256 i, int256 x) internal pure {
        uint256 pos = M.head + M.cnt;
        if (pos >= M.n) pos -= M.n;
        M.ringA[pos] = i;
        M.ringX[pos] = x;
        M.slot[i] = pos + 1;
        M.cnt++;
    }

    /// @dev Строка книги должника `i` (эталон: ключи по регистрации, счёт пула последним) — один раз за проекцию.
    function _rpRow(RpMem memory M, uint256 i) internal view {
        address a = M.ord[i];
        uint256 m;
        for (uint256 wi = 0; wi << 8 < M.n; wi++) {
            for (uint256 nb = credBits[a][wi]; nb != 0; nb &= nb - 1) {
                m++;
            }
        }
        uint256[] memory idx = new uint256[](m + 1);
        int256[] memory amt = new int256[](m + 1);
        uint256 k;
        for (uint256 wi = 0; wi << 8 < M.n; wi++) {
            for (uint256 nb = credBits[a][wi]; nb != 0; nb &= nb - 1) {
                uint256 b = (wi << 8) | _lowBit(nb);
                idx[k] = b;
                amt[k++] = cred[a][M.ord[b]];
            }
        }
        idx[m] = M.n;
        amt[m] = credPool[a];
        M.rowIdx[i] = idx;
        M.rowAmt[i] = amt;
    }

    /// @dev Один получатель `b` возврата `x` (эталон — тело `_pay_back`): записанный долг (дальше по цепочке — прибавка к
    /// ждущей работе или новая работа), затем его недостача этой недели, остаток — в капитал или заявкой.
    function _rpTo(RpMem memory M, RepayProj memory ph, uint256 b, int256 x) internal view {
        if (b >= M.n) revert Revert("_pay_back: index");
        if (!M.init[b]) _rpInit(M, b);
        int256[] memory unc = M.unc;
        int256[] memory fresh = M.fresh;
        uint256[] memory slot = M.slot;
        int256[] memory ringX = M.ringX;
        int256 back;
        int256 rest;
        bool push;
        // back = min(x, записанный долг = unc − fresh), к ждущей работе получателя — прибавкой (слияние), иначе новая
        // работа; cut = min(x − back, fresh); unc −= back + cut; fresh −= cut; остаток — в капитал или заявкой. Суммы в
        // uint128, разности неотрицательны (fresh <= unc); позиция кольца < n.
        assembly {
            let o := add(32, shl(5, b))
            let u := mload(add(unc, o))
            let f := mload(add(fresh, o))
            back := sub(u, f)
            if slt(x, back) { back := x }
            rest := sub(x, back)
            let cut := f
            if slt(rest, cut) { cut := rest }
            mstore(add(unc, o), sub(sub(u, back), cut))
            mstore(add(fresh, o), sub(f, cut))
            rest := sub(rest, cut)
            if back {
                let sl := mload(add(slot, o))
                switch sl
                case 0 { push := 1 }
                default {
                    let p := add(ringX, shl(5, sl))
                    mstore(p, add(mload(p), back))
                }
            }
        }
        if (push) _rpPush(M, b, back);
        if (rest != 0) {
            ph.money[b] += rest;
            if (!M.toQ[b]) ph.stake[b] += rest;
        }
    }

    /// @dev `hold` участника на позиции `i` (эталон `_cover_projection(marks=True)[2]`): ВЕРХНЯЯ граница доплаты при любой
    /// раскладке убытка должника по поколениям — худшая доля по общим поколениям вверх + пыль по поколению, плюс под «весь
    /// пул» min(basis, U) + 1; не больше U + пыль и вместимости. Ответ — min(Σ слагаемых, граница): слагаемые неотрицательны,
    /// поэтому сумма, дошедшая до границы, дальше не считается (у держателя небольших денег или при заметной недостаче это
    /// первый же должник). Иначе — O(должников × их поколений убытка) в памяти; вес адреса в поколении читается один раз.
    /// Ред. 9.5: и внутри должника — `_worstOf` останавливается, как только сумма дошла до границы.
    function _holdAt(HoldCtx memory c, uint256 i) internal view returns (int256 h) {
        if (c.nd == 0 || c.cap[i] <= 0) return 0;
        int256 dust = int256(c.nd * (_snapCount() + 1) + 1);
        int256 bound = _min(c.U + dust, c.cap[i]);
        if (c.basis[i] != 0) h += _min(c.basis[i], c.U) + 1;
        (c.wbFor, c.wbAddr) = (i + 1, order[i]);
        for (uint256 d = 0; d < c.nd && h < bound; d++) {
            if (c.dIdx[d] != i) h += _worstOf(c, d, bound - h);
        }
        return _min(h, bound);
    }

    /// @dev Худшая доля адреса `c.wbAddr` в недостаче должника `d` по его поколениям убытка, вверх, плюс пыль по поколению
    /// (0 — общих поколений нет). Вес адреса в поколении читается один раз на адрес (`c.wb`, `c.wbAt`).
    /// Ред. 9.5 — ОСТАНОВКА НА ГРАНИЦЕ: `need` — сколько не хватает сумме `_holdAt` до её границы. Максимум по поколениям
    /// только растёт, поэтому, как только worst + пыль >= need, ответ `_holdAt` — граница при любом остатке обхода, и обход
    /// кончается (ответ меньше полного максимума, но сумма уже на границе; следующих должников `_holdAt` не читает). Без этого
    /// первый должник стоил n·G чтений веса — 164 тыс. газа на поколение снимков при n = 43 (README «Ред. 9.5: предел»).
    function _worstOf(HoldCtx memory c, uint256 d, int256 need) internal view returns (int256) {
        int256 worst;
        uint256[] memory dK = c.dK;
        int256[] memory dRest = c.dRest;
        int256[] memory w = c.wb;
        uint256[] memory seen = c.wbAt;
        for (uint256 j = c.dOff[d]; j < c.dOff[d + 1]; j++) {
            uint256 k = dK[j];
            if (seen[k] != c.wbFor) (w[k], seen[k]) = (snapW[c.dG[j]][c.wbAddr], c.wbFor);
            int256 wb = w[k];
            int256 rest = dRest[j];
            if (wb != 0 && rest != 0) {
                worst = _max(worst, _mulDivUp(c.dAmt[d], wb, rest));
                if (worst + c.dNg[d] >= need) break;
            }
        }
        return worst != 0 ? worst + c.dNg[d] : int256(0);
    }

    function _holdOf(address a, HoldCtx memory c) internal view returns (int256) {
        Investor storage r = inv[a];
        return r.exists ? _holdAt(c, uint256(r.regIndex)) : int256(0);
    }

    /// @dev ceil(a·b/d) по неотрицательным; оба множителя в uint128 — произведение помещается в 256 бит, без `_mulDiv`.
    function _mulDivUp(int256 a, int256 b, int256 d) internal pure returns (int256) {
        uint256 x = uint256(a);
        uint256 y = uint256(b);
        uint256 z = uint256(d);
        if (x <= U128_MAX && y <= U128_MAX) {
            uint256 p = x * y;
            return int256(p / z + (p % z != 0 ? 1 : 0));
        }
        uint256 q = _mulDiv(x, y, z);
        return int256(mulmod(x, y, z) != 0 ? q + 1 : q);
    }

    /// @dev Эталон `projected_shortfall` (ред. 9.1): признанный долг + ВСЯ проектная недостача по маркам (`mark_uncovered`).
    function _projectedShortfall() internal view returns (int256 t) {
        t = shortfall;
        if (_noProjectedLoss()) return t;
        for (uint256 i = 0; i < order.length; i++) {
            t += _projected(order[i], true, false).uncovered;
        }
    }

    /// @dev Эталон `exposure_hold`: Σ по ордерам sized/open max(удержание доли нотионала, бумажный убыток) — ведущаяся сумма.
    function _exposureHold(address a) internal view returns (int256) {
        return aggEx[a];
    }

    /// @dev Эталон `_reserve`; `hold` — его `hold` раздела по маркам (`_holdAt`; контекст считает вызывающий).
    function _reserve(address a, int256 hold) internal view returns (int256) {
        Proj memory P = _projected(a, false, false);
        return _exposureHold(a) + P.pendingLoss + P.feeDue + hold;
    }

    function _room(address a, int256 hold) internal view returns (int256) {
        Investor storage r = inv[a];
        if (!r.exists) revert Revert("room: not investor");
        return _max(0, r.stake + _queuedOf(a, false) - _reserve(a, hold));
    }

    function _claimRoom(address a) internal view returns (int256) {
        if (!inv[a].exists) return claimable[a] + claimableReward[a];
        return _max(0, _ownPlanes(a) - _reserve(a, _holdOf(a, _holdCtx())));
    }

    function _claimNow(address a) internal view returns (int256 pi, int256 pr) {
        int256 room_ = _claimRoom(a);
        pi = _min(claimable[a], room_);
        pr = _min(claimableReward[a], room_ - pi);
    }

    // --- торговля -------------------------------------------------------------------------------------------- //

    /// @dev Веса `w` (по позиции в `order`, только неотрицательные) — те же, что у снимка `g`: вес вне снимка — 0.
    function _snapEquals(int256 g, int256[] memory w) internal view returns (bool) {
        if (!snapExists[g]) return false;
        mapping(address => int256) storage sw = snapW[g];
        for (uint256 i = 0; i < order.length; i++) {
            if (sw[order[i]] != w[i]) return false;
        }
        return true;
    }

    function _order(bytes32 pid, uint8 state) internal view returns (Order storage o) {
        _id32(pid);
        o = orders[pid];
        if (o.state != state) revert Revert("order state");
    }

    /// @dev Отмена: ордера больше нет (эталон удаляет его из `orders`; pid можно рассчитать снова).
    function _deleteOrder(bytes32 pid) internal {
        delete orders[pid];
        _unlistOrder(pid);
    }

    /// @dev Живой ордер — в `orderPids` (позиция в `orderIx`).
    function _listOrder(bytes32 pid) internal {
        orderPids.push(pid);
        orderIx[pid] = orderPids.length;
    }

    /// @dev Ордер выходит из `orderPids` за O(1): на его место встаёт последний (находка ревью LOW #10 — сдвиг всего массива).
    function _unlistOrder(bytes32 pid) internal {
        uint256 i = orderIx[pid] - 1; // живой ордер в списке есть всегда: иначе — переполнение вниз, отказ
        uint256 last = orderPids.length - 1;
        if (i != last) {
            bytes32 moved = orderPids[last];
            orderPids[i] = moved;
            orderIx[moved] = i + 1;
        }
        orderPids.pop();
        delete orderIx[pid];
    }

    /// @dev ЕДИНСТВЕННЫЙ писатель марка открытого ордера: держит `uOpen`, `genU`, `genUpos`, `genLossOrders`, а с ред. 9.5 — и
    /// их следы в ведущихся суммах снимков (`growSum`, `lossOpenN`).
    function _setUpnl(Order storage o, int256 upnl) internal {
        int256 g = o.gen;
        int256 u0 = o.upnl;
        uOpen += upnl - u0;
        genU[g] += upnl - u0;
        int256 dp = _max(0, upnl) - _max(0, u0);
        genUpos[g] += dp;
        growSum += dp;
        int256 l0 = genLossOrders[g];
        int256 l1 = l0 + (upnl < 0 ? int256(1) : int256(0)) - (u0 < 0 ? int256(1) : int256(0));
        genLossOrders[g] = l1;
        if ((l0 != 0) != (l1 != 0)) l1 != 0 ? lossOpenN++ : lossOpenN--;
        o.upnl = upnl;
    }

    /// @dev Эталон `_stake_ceiling`: Σ капиталов + вносимое + Σ по снимкам max(0, R_g) + положительных марков — ведущаяся сумма
    /// `growSum` (ред. 9.5; раньше — обход поколений на каждом марке, закрытии и депозите).
    function _stakeCeiling(int256 extra) internal view {
        if (stakeSum + extra + growSum > int256(U128_MAX)) revert Revert("stake ceiling");
    }

    // --- действия инвестора ---------------------------------------------------------------------------------- //
    function _rec(address a) internal returns (Investor storage r) {
        r = inv[a];
        if (!r.exists) {
            r.exists = true;
            r.firstWeek = week;
            r.regIndex = int256(order.length);
            order.push(a);
        }
    }

    /// @dev Держатель плоскостей, не инвестор, — в `known` (инвесторов выгрузка и проход очереди читают по `order`).
    function _touch(address a) internal {
        if (inv[a].exists) return;
        if (!isKnown[a]) {
            isKnown[a] = true;
            known.push(a);
        }
    }

    function _takeIn(uint256 amount, uint8 path, bytes32 ref) internal {
        if (path == PATH_SPOT) {
            _burnRef(ref);
            spot += int256(amount);
        } else if (path == PATH_EVM) {
            evm += int256(amount);
        } else {
            revert Revert("path");
        }
    }

    /// @dev ЕДИНСТВЕННЫЙ писатель пространства записей леджера венью (эталон `ledger_refs`): зачтённый депозит, `coverShortfall`
    /// и возврат `refundRef` сжигают ref в одном пространстве — один перевод нельзя ни вернуть дважды, ни вернуть и зачесть.
    function _burnRef(bytes32 ref) internal {
        _id32(ref);
        if (ledgerRef[ref]) revert Revert("ledger_ref used");
        ledgerRef[ref] = true;
        ledgerRefList.push(ref);
    }

    function _refRate(address referrer, address invitee) internal view returns (int256) {
        Partner storage p = partners[referrer];
        if (p.state == P_NONE) return openRefShareBps;
        int256 first = inv[invitee].firstWeek;
        if (week > _max(first, p.sinceWeek) + partnerTermWeeks) return openRefShareBps;
        if (p.state == P_ACTIVE) return refShareBps;
        if (p.state == P_REVOKED && inv[invitee].regIndex < p.revokedAtOrder) return refShareBps;
        return openRefShareBps;
    }

    function _freeStake(address a, bool reward) internal view returns (int256) {
        if (reward) return rewardCash[a];
        if (!inv[a].exists) return 0;
        return _freeStakeWith(a, _holdCtx());
    }

    function _freeStakeWith(address a, HoldCtx memory c) internal view returns (int256) {
        Investor storage r = inv[a];
        Proj memory P = _projected(a, false, false);
        return _max(0, r.stake - P.pendingLoss - P.feeDue - _holdAt(c, uint256(r.regIndex)));
    }

    /// @dev Эталон `withdraw`. Обход проекций — один на вызов: его считает `free_stake`, и тот же контекст получает проход
    /// очереди. Между ними капитал переходит в заявку того же адреса (вознаграждение — в его reward-заявку): свои деньги,
    /// база «всего пула», проектный убыток и недостача у всех те же, поэтому `hold` каждого тот же, что эталон посчитал бы заново.
    function _withdraw(address a, uint256 amount, bool reward) internal returns (uint8, int256, int256) {
        HoldCtx memory c;
        bool have;
        int256 free;
        if (reward) {
            free = rewardCash[a];
        } else if (inv[a].exists) {
            c = _holdCtx();
            have = true;
            free = _freeStakeWith(a, c);
        }
        if (amount > U128_MAX) return (W_RANGE, 0, 0);
        int256 amt = int256(amount);
        if (amt == 0 || amt > free) return (W_AMOUNT, 0, 0);
        if (reward) {
            _takeFrom(rewardCash, a, amt);
        } else {
            Investor storage r = inv[a];
            r.stake -= amt;
            stakeSum -= amt;
            if (r.stake == 0) r.exiting = true;
        }
        int256 qid = _enqueue(a, amt, reward);
        _payFifoWith(c, have);
        int256 rest = _qRest(a, reward, qid);
        return (W_OK, amt - rest, rest);
    }

    /// @dev Сколько осталось в заявке `qid` — НОВЕЙШЕЙ записи ключа (выплата снимает только с головы, хвост не трогает).
    function _qRest(address a, bool reward, int256 qid) internal view returns (int256) {
        int256 q = _queuedOf(a, reward);
        if (q == 0) return 0;
        QHead storage h = qh[a][reward];
        uint256 j = uint256(h.len) - 1;
        if (qE[a][reward][j] & Q_ID != uint256(qid)) return 0;
        return h.P + q - (j > h.head ? _qEnd(a, reward, j - 1) : h.P);
    }

    function _u128(int256 x) internal pure returns (uint256) {
        if (x < 0 || x > int256(U128_MAX)) revert Revert("uint128");
        return uint256(x);
    }

    /// @dev Конец записи i ключа (накопленная сумма полосы).
    function _qEnd(address a, bool reward, uint256 i) internal view returns (int256) {
        return int256(qE[a][reward][i] >> 64);
    }

    /// @dev Первая запись ключа в [lo, hi) с end > x (hi — нет такой); ends ключа строго возрастают.
    function _qEndAbove(address a, bool reward, uint256 lo, uint256 hi, int256 x) internal view returns (uint256) {
        mapping(uint256 => uint256) storage e = qE[a][reward];
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (int256(e[mid] >> 64) > x) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    /// @dev Первая запись ключа в [lo, hi) с id >= id (hi — нет такой); id ключа возрастают. Первые пробы — догадка `guess`
    /// и её сосед (при перемешанных по id ключах ответ почти всегда там — два чтения вместо log), дальше — середина; ответ
    /// от догадки не зависит.
    function _qIdAtLeast(address a, bool reward, uint256 lo, uint256 hi, uint256 id, uint256 guess)
        internal
        view
        returns (uint256)
    {
        mapping(uint256 => uint256) storage e = qE[a][reward];
        // инвариант: ответ в [lo, hi]; проба — любой индекс из [lo, hi): первая — догадка, вторая — её сосед со стороны
        // ответа, дальше — середина. Сравнение одно на все пробы.
        uint256 step;
        bool down;
        while (lo < hi) {
            uint256 mid = step == 0 ? (guess < lo ? lo : guess >= hi ? hi - 1 : guess) : step == 1 ? (down ? hi - 1 : lo) : (lo + hi) >> 1;
            step++;
            down = e[mid] & Q_ID >= id;
            if (down) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    /// @dev Последняя живая запись ключа (end >= P + queued); ключ не пуст.
    function _qTail(address a, bool reward, QHead storage h, int256 L) internal view returns (uint256) {
        uint256 len = h.len;
        if (_qEnd(a, reward, len - 1) == L) return len - 1;
        return _qEndAbove(a, reward, h.head, len, L - 1);
    }

    /// @dev Эталон `_enqueue`: заявка встаёт в хвост ключа. Пустой ключ начинает полосу заново; если хвост сняли каскадом,
    /// мёртвые записи за живой границей отбрасываются, а граничная обрезается по ней — новая запись начинается с неё.
    function _enqueue(address a, int256 amount, bool reward) internal returns (int256 qid) {
        qid = nextQid;
        nextQid += 1;
        QHead storage h = qh[a][reward];
        int256 q = _queuedOf(a, reward);
        uint256 i;
        int256 L;
        if (q == 0) {
            if (h.P != 0) h.P = 0;
            h.head = 0;
        } else {
            L = h.P + q;
            i = h.len;
            uint256 t = _qTail(a, reward, h, L);
            if (t + 1 != i || _qEnd(a, reward, t) != L) {
                qE[a][reward][t] = (uint256(L) << 64) | (qE[a][reward][t] & Q_ID);
                i = t + 1;
            }
        }
        int256 end = L + amount;
        if (end >= int256(1 << 191) || qid >= int256(1 << 64)) revert Revert("queue range");
        qE[a][reward][i] = (uint256(end) << 64) | uint256(qid);
        qWeek[a][reward][i] = week;
        h.len = uint128(i + 1);
        _queueAdd(a, reward, amount);
    }

    /// @dev Выплата `x` с ГОЛОВЫ ключа (заявки по порядку id): деньги — в «к получению». `_fundClaimable` — у вызывающего,
    /// одним разом на проход (от нарезки выплат она не зависит). `hint` — вероятная новая голова (проверяется; иначе поиск).
    function _qPayHead(address a, bool reward, int256 x, uint256 hint) internal {
        _touch(a);
        if (reward) claimableReward[a] += x;
        else claimable[a] += x;
        claimableSum += x;
        _queueAdd(a, reward, -x);
        QHead storage h = qh[a][reward];
        int256 P = h.P + x;
        h.P = int192(P);
        if (_queuedOf(a, reward) == 0) return;
        uint256 hd = h.head;
        if (hint < h.len && hint >= hd && _qEnd(a, reward, hint) > P && (hint == hd || _qEnd(a, reward, hint - 1) <= P)) {
            if (hint != hd) h.head = uint64(hint);
        } else {
            h.head = uint64(_qEndAbove(a, reward, hd, h.len, P));
        }
    }
    function _payFifo() internal {
        HoldCtx memory c;
        _payFifoWith(c, false);
    }

    /// @dev Эталон `_pay_fifo`: ДВА ПРОХОДА по заявкам в порядке id — инвесторы (каждой min(заявка, `_room` адреса), стоп,
    /// когда ликвидность кончилась), затем reward-заявки сверх непогашенного остатка инвесторов. Обход ПО ЗАЯВКАМ не нужен:
    /// выплата адресу снижает только его `_room` и ровно на выплаченное (заявка переходит в «к получению», резерв тот же),
    /// ликвидность падает ровно на выплаченное, а `_fundClaimable` от нарезки выплат не зависит (снять x1, затем x2 — то же,
    /// что x1 + x2). Значит, каждому адресу выплачивается голова его заявок длиной min(заявки, `_room`), а если на всех не
    /// хватает — голова ОБЩЕГО потока по id до заявки, на которой он упирается в ликвидность (`_fifoPay`). Стоимость — по
    /// адресам, а не по заявкам. `hold` — один контекст на проход (`have` — посчитан вызывающим на этом же состоянии):
    /// выплата переносит деньги адреса из заявки в «к получению» — свои деньги, проектный убыток и недостача у всех те же,
    /// `hold` других тот же; у самого адреса падает база «всего пула», но при базе <= U его `_room` и так 0 (`hold` >= базы),
    /// а при базе > U слагаемое min(база, U) не меняется — ответ тот же, что у эталона, зовущего раздел на каждой заявке.
    function _payFifoWith(HoldCtx memory c, bool have) internal {
        int256 liq = _liquidity();
        if (liq > 0 && queuedInvSum > 0) {
            if (!have) c = _holdCtx();
            (address[] memory ks, int256[] memory cap, uint256 m, int256 total) = _fifoInvestors(c);
            _fifoPay(ks, cap, m, false, liq, total);
        }
        // второй проход — reward-заявки (treasury наравне с рефералами), только сверх непогашенного остатка инвесторов
        int256 unpaid = queuedInvSum;
        int256 rq = queuedSum - unpaid;
        if (rq == 0) return;
        liq = _liquidity();
        if (liq <= unpaid) return;
        (address[] memory rk, int256[] memory rc, uint256 mr) = _fifoRewards();
        _fifoPay(rk, rc, mr, true, liq - unpaid, rq);
    }

    /// @dev Ключи первого прохода: инвесторы с заявками, у каждого — сколько ему можно выплатить: min(заявки, `_room`).
    function _fifoInvestors(HoldCtx memory c)
        internal
        view
        returns (address[] memory ks, int256[] memory cap, uint256 m, int256 total)
    {
        uint256 n = order.length;
        ks = new address[](n);
        cap = new int256[](n);
        for (uint256 i = 0; i < n; i++) {
            address a = order[i];
            int256 q = queuedInv[a];
            if (q == 0) continue;
            int256 r = _room(a, 0);
            if (r == 0) continue; // без `hold` места нет — с ним тем более (hold >= 0)
            int256 h = _holdAt(c, i);
            r = _min(q, h == 0 ? r : _room(a, h));
            if (r == 0) continue;
            ks[m] = a;
            cap[m++] = r;
            total += r;
        }
    }

    /// @dev Ключи второго прохода: reward-заявки (держатели — инвесторы и `known`), каждому — все его заявки.
    function _fifoRewards() internal view returns (address[] memory rk, int256[] memory rc, uint256 mr) {
        uint256 n = order.length;
        uint256 nk = known.length;
        rk = new address[](n + nk);
        rc = new int256[](n + nk);
        for (uint256 i = 0; i < n + nk; i++) {
            address a = _holderAt(i);
            if (a == address(0)) continue;
            int256 q = queuedRew[a];
            if (q == 0) continue;
            rk[mr] = a;
            rc[mr++] = q;
        }
    }

    /// @dev Все держатели плоскостей без повторов: инвесторы (`order`), затем `known` без инвесторов (нулевой адрес — пропуск).
    /// Инвестор в `known` не вносится (`_touch`), но мог попасть туда раньше, чем стал инвестором.
    function _holderAt(uint256 i) internal view returns (address) {
        uint256 n = order.length;
        if (i < n) return order[i];
        address a = known[i - n];
        return inv[a].exists ? address(0) : a;
    }

    /// @dev Память поиска точки упора по ключам `ks` (каждому не больше `cap`): начало и конец живой части, голова; сколько
    /// записей от головы лежит ниже границ поиска `lo`/`hi` и сколько по ним выплачивается.
    struct Cut {
        address[] ks;
        int256[] cap;
        bool reward;
        uint256 lo; //      границы поиска по id: F(lo) <= budget < F(hi)
        uint256 hi;
        int256 fLo;
        int256 fHi;
        int256[] P;
        int256[] L;
        uint256[] head;
        uint256[] cLo;
        uint256[] cHi;
        int256[] aLo;
        int256[] aHi;
    }

    /// @dev Выплата голов ключей `ks[0..m)` (каждому не больше `cap`) в общем порядке id в пределах `budget`. Хватает на всех —
    /// каждому его `cap`. Иначе — двоичный поиск по id: F(u) = Σ min(cap, живое ключа с id < u) монотонна; ищется
    /// наименьшее u с F(u) > budget, заявка id = u − 1 — та, на которой эталон упирается в ликвидность: до неё всем по F,
    /// её владельцу — ещё остаток бюджета, дальше — никому.
    function _fifoPay(address[] memory ks, int256[] memory cap, uint256 m, bool reward, int256 budget, int256 total)
        internal
    {
        if (total <= budget) {
            _fundClaimable(total);
            for (uint256 k = 0; k < m; k++) {
                _qPayHead(ks[k], reward, cap[k], type(uint256).max);
            }
            return;
        }
        Cut memory S;
        (S.ks, S.cap, S.reward) = (ks, cap, reward);
        (S.P, S.L, S.aLo, S.aHi) = (new int256[](m), new int256[](m), new int256[](m), new int256[](m));
        (S.head, S.cLo, S.cHi) = (new uint256[](m), new uint256[](m), new uint256[](m));
        (S.lo, S.hi) = _cutLoad(S, m);
        // F(lo) = 0 <= budget < total = F(hi)
        uint256[] memory cMid = new uint256[](m);
        int256[] memory aMid = new int256[](m);
        S.fHi = total;
        for (uint256 round = 0; S.hi - S.lo > 1; round++) {
            uint256 mid = _cutMid(S, budget, m, round);
            int256 f = _cutAt(S, m, mid, cMid, aMid);
            if (f > budget) {
                (S.hi, S.fHi) = (mid, f);
                (S.cHi, cMid) = (cMid, S.cHi);
                (S.aHi, aMid) = (aMid, S.aHi);
            } else {
                (S.lo, S.fLo) = (mid, f);
                (S.cLo, cMid) = (cMid, S.cLo);
                (S.aLo, aMid) = (aMid, S.aLo);
            }
        }
        int256 rest = budget;
        for (uint256 k = 0; k < m; k++) {
            rest -= S.aLo[k];
        }
        _fundClaimable(budget); // выплачивается ровно бюджет: Σ по F(lo) плюс остаток владельцу
        for (uint256 k = 0; k < m; k++) {
            int256 x = S.aLo[k];
            if (S.aHi[k] > x) x += rest; // владелец заявки id = lo: на ней поток упирается в бюджет
            if (x != 0) _qPayHead(ks[k], reward, x, S.head[k] + S.cLo[k]);
        }
    }

    /// @dev Живые части ключей и границы поиска: lo — наименьший id голов (ниже него F = 0), hi — наибольший id хвостов + 1.
    function _cutLoad(Cut memory S, uint256 m) internal view returns (uint256 lo, uint256 hi) {
        lo = type(uint256).max;
        bool reward = S.reward;
        for (uint256 k = 0; k < m; k++) {
            address a = S.ks[k];
            QHead storage h = qh[a][reward];
            int256 L = h.P + _queuedOf(a, reward);
            uint256 hd = h.head;
            uint256 t = _qTail(a, reward, h, L);
            S.P[k] = h.P;
            S.L[k] = L;
            S.head[k] = hd;
            S.cHi[k] = t - hd + 1;
            S.aHi[k] = S.cap[k];
            uint256 id0 = qE[a][reward][hd] & Q_ID;
            uint256 id1 = (qE[a][reward][t] & Q_ID) + 1;
            if (id0 < lo) lo = id0;
            if (id1 > hi) hi = id1;
        }
    }

    /// @dev Следующая проба поиска точки упора. Первые две — по обе стороны от линейной оценки F между границами (с запасом в
    /// m id): при перемешанных ключах точка упора между ними, и диапазон сразу сужается до ~2m id, где у каждого ключа одна-две
    /// записи; дальше — пополам. Ответ от выбора проб не зависит: каждая проба лишь сдвигает одну из границ.
    function _cutMid(Cut memory S, int256 budget, uint256 m, uint256 round) internal pure returns (uint256 mid) {
        uint256 lo = S.lo;
        uint256 hi = S.hi;
        if (round < 2) {
            uint256 est = lo + uint256(((budget - S.fLo) * int256(hi - lo)) / (S.fHi - S.fLo));
            mid = round == 0 ? (est > lo + m ? est - m : lo + 1) : est + m;
        } else {
            mid = (lo + hi) >> 1;
        }
        if (mid <= lo) mid = lo + 1;
        if (mid >= hi) mid = hi - 1;
    }

    /// @dev F(mid): по каждому ключу — записи с id < mid (поиск внутри уже суженного [cLo, cHi)) и выплачиваемое по ним.
    function _cutAt(Cut memory S, uint256 m, uint256 mid, uint256[] memory cMid, int256[] memory aMid)
        internal
        view
        returns (int256 f)
    {
        for (uint256 k = 0; k < m; k++) {
            if (S.cLo[k] == S.cHi[k]) (cMid[k], aMid[k]) = (S.cLo[k], S.aLo[k]);
            else (cMid[k], aMid[k]) = _cutKey(S, k, mid);
            f += aMid[k];
        }
    }

    /// @dev Ключ k: сколько его живых записей от головы с id < mid и сколько по ним выплачивается (не больше `cap`).
    function _cutKey(Cut memory S, uint256 k, uint256 mid) internal view returns (uint256 c, int256 amt) {
        address a = S.ks[k];
        uint256 hd = S.head[k];
        uint256 cl = S.cLo[k];
        uint256 ch = S.cHi[k];
        // догадка — та же доля диапазона индексов, что mid в диапазоне id
        uint256 g = hd + cl + ((mid - S.lo) * (ch - cl)) / (S.hi - S.lo);
        c = _qIdAtLeast(a, S.reward, hd + cl, hd + ch, mid, g) - hd;
        if (c != 0) amt = _min(S.cap[k], _min(_qEnd(a, S.reward, hd + c - 1), S.L[k]) - S.P[k]);
    }

    function _fundClaimable(int256 need) internal {
        int256 short = need - _freePlane();
        if (short > 0) {
            if (short > withdrawable) revert Revert("liquidity: withdrawable");
            withdrawable -= short;
            venueCash -= short;
            evm += short;
        }
        int256 take = _min(spot, _max(0, claimableSum + need - evm));
        spot -= take;
        evm += take;
    }

    // --- понедельник --------------------------------------------------------------------------------------- //

    /// @dev Ред. 9.5: `calendar` — календарный расчёт (неделя + 1); внеочередной (`false`) неделю не сдвигает — срок партнёра,
    /// `first_week`, возраст заявок и `sized_week` считаются неделями календаря, а не числом расчётов (эталон `monday(calendar)`).
    /// Метки буферов фазы 2 — номер расчёта `monEpoch`: при двух расчётах одной недели метка недели сочла бы чужие записи своими.
    function _mondayBegin(bool calendar) internal {
        _start();
        if (calendar) {
            // ревью-3b: календарный расчёт — не чаще одного за календарную неделю (свойство контракта; времени в эталоне нет).
            // Без этого keeper фиксировал бы комиссию на пике и сжигал срок партнёра, проводя расчёты подряд в одном блоке.
            uint256 cw = _calWeek();
            if (cw < calNext) revert Revert("monday: calendar week already settled");
            calNext = cw + 1;
            week += 1;
        }
        monCal = calendar;
        monEpoch += 1;
        gensSince = 0;
        mondayOpen = true;
        mondayCursor = 0;
        monStage = MS_ROWS;
        monCur = 0;
        // буферы фазы 2 — только длины: слова прежней недели за длиной не читаются, метки недели у `monDebtPos`/`monGive` чужие
        monRepayN = 0;
        monRefN = 0;
        monDebtN = 0;
        monUnits = 0;
        monUnitsDone = 0;
        monGenCur = 0;
        monC = 0;
        monLossN = 0;
        monScan = 0;
        monRowUnits = 0;
    }

    /// @dev Конец пачки от `from`: не дальше `len` (`k` бывает type(uint256).max — атомарный расчёт).
    function _batchEnd(uint256 from, uint256 k, uint256 len) internal pure returns (uint256) {
        return len - from <= k ? len : from + k;
    }

    /// @dev Одна пачка ТЕКУЩЕГО этапа: до `k` единиц (единица этапа — у констант MS_*). Пачка не переходит через границу
    /// этапа; пустые этапы проходятся сразу. Возвращает, сколько единиц осталось у этапа, на котором расчёт стоит после
    /// пачки (0 — осталось только `mondayEnd`). Исход не зависит от нарезки на пачки: каждая пачка продолжает ровно с того
    /// места, где остановилась предыдущая, а входы, которые эталон берёт на начало раздела (база «всего пула»), — снимок.
    function _mondayStep(uint256 k) internal returns (uint256) {
        uint8 s = monStage;
        if (s == MS_ROWS) {
            // единица — строка адреса или одно поколение строки должника (ред. 9.5: убыток должника по поколениям — пачками,
            // `_scanLoss`; строку не-должника поколения не читают вовсе)
            uint256 n = order.length;
            while (k != 0) {
                if (monScan != 0) {
                    k = _scanLoss(k);
                    continue;
                }
                uint256 i = mondayCursor;
                if (i == n) break;
                mondayCursor = i + 1;
                _settle(order[i]);
                k--;
            }
            if (mondayCursor < n || monScan != 0) return _stageLeft();
            _phase2Begin();
            return _advance(MS_REFS);
        }
        if (s == MS_REFS) {
            uint256 end = _batchEnd(monCur, k, monRefN);
            for (uint256 i = monCur; i < end; i++) {
                _credit(monRefA[i], monRefX[i], PL_REWARD);
            }
            monCur = end;
            if (end < monRefN) return monRefN - end;
            return _advance(MS_REPAY);
        }
        if (s == MS_REPAY) {
            // очередь работ растёт по ходу (цепочка): пачка — `k` работ от курсора, новые встают в хвост
            uint256 i = monCur;
            for (uint256 done = 0; done < k && i < monRepayN; done++) {
                _repayItem(i++);
            }
            monCur = i;
            if (i < monRepayN) return monRepayN - i;
            return _advance(MS_MATES);
        }
        if (s == MS_MATES) {
            _matesStep(k);
            if (monCur < monDebtN) return _stageLeft();
            return _advance(MS_POOL);
        }
        if (s == MS_POOL) return _advance(_poolBegin() ? MS_TABLE : MS_NET);
        if (s == MS_TABLE) {
            uint256 end = _batchEnd(monCur, k, monDebtN);
            _tableBatch(monCur, end);
            monCur = end;
            if (end < monDebtN) return monDebtN - end;
            return _advance(MS_NET);
        }
        if (s == MS_NET) {
            _netStep(k);
            if (monCur < monDebtN) return _stageLeft();
            return _advance(MS_DONE);
        }
        return 0;
    }

    /// @dev Переход к этапу `s`; пустые проходятся сразу (без должников нет ни соучастников, ни «всего пула»).
    function _advance(uint8 s) internal returns (uint256) {
        monCur = 0;
        if (s == MS_REFS && monRefN == 0) s = MS_REPAY;
        if (s == MS_REPAY && monRepayN == 0) s = MS_MATES;
        if (s == MS_MATES && monDebtN == 0) s = MS_DONE;
        if (s == MS_NET) monUnitsDone = 0; // счётчик единиц этапа соучастников больше не нужен — теперь это единицы зачёта
        monStage = s;
        return _stageLeft();
    }

    /// @dev Сколько единиц осталось у текущего этапа (`POOL` — один вызов, `DONE` — 0).
    function _stageLeft() internal view returns (uint256) {
        uint8 s = monStage;
        if (s == MS_ROWS) return order.length - mondayCursor + (monScan != 0 ? _snapCount() - monScanK : 0);
        if (s == MS_REFS) return monRefN - monCur;
        if (s == MS_REPAY) return monRepayN - monCur;
        if (s == MS_MATES) return monUnits - monUnitsDone;
        if (s == MS_TABLE || s == MS_NET) return monDebtN - monCur; // зачёт: должников, чьи доли ещё не все в книге
        return s == MS_POOL ? 1 : 0;
    }

    /// @dev Начало ФАЗЫ 2 (эталон — сразу после цикла строк): граница `_noProjectedLoss` и проверка разноса. O(живых поколений):
    /// col каждого адреса теперь равен его доле R (rMon := R; окончательным — `_colIsR`), разнесённое по поколению после строк —
    /// Σ_a доля(R_g) (`shareSum`); у окончательных проверка прошла, когда они стали окончательными (`_genDead`).
    function _phase2Begin() internal {
        for (int256 g = lvHead; g != 0; g = lvNext[g]) {
            int256 x = R[g];
            if (rMon[g] != x) rMon[g] = x;
            if (shareSum[g] > x) revert Revert("monday: over-distributed");
        }
        lossRN = 0; // R = col у всех поколений снимков
    }

    /// @dev Конец расчёта (эталон — хвост `monday`): поколения закрываются; проход очереди — следом, в PoolLedger
    /// (`monday`/`mondayEnd` зовут `_payFifo` сразу после этой реализации: код очереди живёт в одном контракте). Служебная
    /// память фазы 2 не стирается — её длины обнулит следующий `_mondayBegin`.
    function _mondayEnd() internal {
        if (monStage != MS_DONE) revert Revert("monday: not all settled");
        mondayOpen = false;
        monStage = MS_ROWS;
        _finalizeGenerations();
    }

    /// @dev Позиция должника недели в буфере + 1 (0 — не должник ЭТОЙ недели: метка чужой недели не считается).
    function _debtPos(address a) internal view returns (uint256) {
        uint256 v = monDebtPos[a];
        return v >> 128 == monEpoch ? v & U128_MAX : 0;
    }

    /// @dev Новая работа возврата в хвост очереди; её позиция — адресу (слияние, `_repayTo`).
    function _pushRepay(address a, int256 x) internal {
        uint256 j = monRepayN++;
        monRepayA[j] = a;
        monRepayX[j] = x;
        monRepayPos[a] = (monEpoch << 128) | (j + 1);
    }

    /// @dev ЕДИНСТВЕННЫЙ писатель книги доплативших между инвесторами: сумма и бит ребра (`credBits`) меняются вместе.
    /// `yi` — позиция доплативших `y` в `order`.
    function _credAdd(address x, address y, uint256 yi, int256 d) internal {
        int256 v0 = cred[x][y];
        int256 v1 = v0 + d;
        if (v1 < 0) revert Revert("cred < 0");
        cred[x][y] = v1;
        if ((v0 > 0) != (v1 > 0)) credBits[x][yi >> 8] ^= 1 << (yi & 255);
    }

    /// @dev floor(log2 x), x > 0.
    function _log2(uint256 x) internal pure returns (uint256 r) {
        for (uint256 s = 128; s != 0; s >>= 1) {
            if (x >> s != 0) {
                x >>= s;
                r += s;
            }
        }
    }

    /// @dev ФАЗА 1: своя строка адреса (эталон — тело цикла `monday`). Ред. 9.5: результат недели — ведущаяся сумма
    /// `aggPend` = Σ_g [доля(R_g) − col] (её пишет `_aggR` на каждом изменении R), поколения строка не обходит; разнесённое по
    /// поколению после строк — `shareSum`. Убыток по поколениям нужен только должнику — его читает `_scanLoss` пачками.
    function _settle(address a) internal {
        Investor storage r = inv[a];
        int256 delta = aggPend[a];
        if (delta != 0) aggPend[a] = 0;
        settledR += delta;
        r.cumPnl += delta;
        int256 back = _credit(a, _min(_max(0, delta), r.uncovered), PL_DEBT); // сначала его долг (ДО комиссии)
        if (back != 0) _pushRepay(a, back);
        delta -= back;
        (int256 near,) = _feeBase(a, _unrealized(a)); // ред. 9.3.1: часть открытого ордера — в базе вместе с марком остатка
        int256 prudent = r.cumPnl + near;
        int256 base = prudent - r.hwm;
        int256 fee;
        if (base > 0) {
            int256 avail = _max(0, _ownPlanes(a) + delta - _exposureHold(a));
            int256 full = (base * feeBps) / BPS;
            fee = _min(full, avail);
            r.hwm += fee == full ? base : _min(base, (fee * BPS) / feeBps);
        }
        r.feesPaid += fee;
        int256 ref;
        if (fee != 0 && r.referrer != address(0)) ref = (fee * _refRate(r.referrer, a)) / BPS;
        if (ref != 0 && r.referrer != treasury) {
            uint256 j = monRefN++; // зачисление — после всех строк (находка CR-1, стенд R6)
            monRefA[j] = r.referrer;
            monRefX[j] = ref;
        } else {
            ref = 0;
        }
        _credit(treasury, fee - ref, PL_POT);
        int256 net = delta - fee;
        if (net >= 0) {
            _credit(a, net, r.exiting || r.payoutMode ? PL_QUEUE : PL_STAKE);
        } else {
            int256 short = _takeOwn(a, -net); // каскад убытка — ТОЛЬКО свои плоскости (эталон `_absorb_loss`)
            if (short != 0) {
                r.cumPnl += short;
                r.uncovered += short;
                _pushDebt(a, short);
            }
        }
    }

    /// @dev Должник недели: недостача; его убыток по поколениям (пары `monLossG/V`) читает `_scanLoss` следующими единицами
    /// строк — до строки следующего адреса (строки R и rMon не меняют, поэтому порядок чтения исхода не меняет).
    function _pushDebt(address a, int256 short) internal {
        uint256 d = monDebtN++;
        monDebtA[d] = a;
        monDebtX[d] = short;
        monDebtPos[a] = (monEpoch << 128) | (d + 1);
        monDebtOff[d] = monLossN;
        monScan = d + 1;
        monScanK = 0;
    }

    /// @dev Убыток должника `monScan` по поколениям снимков (эталон `d_gen` строки: доля(R_g) − col, col — доля rMon_g), пачка
    /// до `k` ПОКОЛЕНИЙ от `monScanK`; ненулевые убытки — парами по возрастанию поколения, каждая — единица этапа
    /// соучастников. Поколение с R = rMon результата не даёт — вес не читается. Возвращает неистраченные единицы пачки.
    function _scanLoss(uint256 k) internal returns (uint256) {
        address a = monDebtA[monScan - 1];
        uint256 G = _snapCount();
        uint256 j = monScanK;
        uint256 j0 = j;
        uint256 u = monLossN;
        for (; j < G && k != 0; j++) {
            k--;
            int256 g = _genAt(j);
            int256 x = R[g];
            int256 y = rMon[g];
            if (x == y) continue;
            int256 v = _share(a, g, y) - _share(a, g, x);
            if (v <= 0) continue;
            monLossG[u] = g;
            monLossV[u++] = v;
        }
        monUnits += u - monLossN;
        monLossN = u;
        monRowUnits += j - j0;
        if (j == G) monScan = 0;
        else monScanK = j;
        return k;
    }

    /// @dev Эталон `_pay_back` (ред. 9.1), ОДНА работа очереди возвратов: возврат должника — доплатившим пропорционально
    /// непогашенному (кандидаты — по порядку регистрации, счёт пула последним), в порядке, в котором `_split` дал им долю.
    /// ЦЕПОЧКА: у получателя возврат сначала гасит его ЗАПИСАННЫЙ долг (uncovered − недостача этой недели; погашенное встаёт
    /// в хвост работ — дальше по цепочке), затем его недостачу этой недели (`monDebtX` уменьшается — разделу останется
    /// меньше), остаток — в капитал/заявку. Очередь работ — сам `monRepayA/X`, обход идёт до конца растущего списка.
    function _repayItem(uint256 i) internal {
        uint256 n = order.length;
        address a = monRepayA[i];
        int256[] memory w = new int256[](n + 1);
        for (uint256 wi = 0; wi << 8 < n; wi++) {
            // только существующие рёбра (бит книги); у остальных вес 0 — `_split` их пропускает так же
            for (uint256 nb = credBits[a][wi]; nb != 0; nb &= nb - 1) {
                uint256 b = (wi << 8) | _log2(nb & (~nb + 1));
                w[b] = cred[a][order[b]];
            }
        }
        w[n] = credPool[a];
        (int256[] memory parts, uint256[] memory ins, uint256 nIns, int256 rest) = _split(monRepayX[i], w, w);
        if (rest != 0) revert Revert("_pay_back: over debt");
        for (uint256 t = 0; t < nIns; t++) {
            uint256 k = ins[t];
            int256 x = parts[k];
            if (k == n) {
                credPool[a] -= x;
                int256 tt = _min(x, shortfall);
                shortfall -= tt;
                if (x - tt != 0) _credit(treasury, x - tt, PL_POT);
                continue;
            }
            address b = order[k];
            _credAdd(a, b, k, -x);
            _repayTo(b, x, i);
        }
    }

    /// @dev Один получатель возврата `x` (в работе `i`): его записанный долг, затем его недостача недели, остаток — ему.
    /// Ред. 9.2: погашенное получателем, чья работа ещё СТОИТ в очереди (позиция дальше `i`), прибавляется к ней — в очереди
    /// адрес не больше одного раза за волну, и работ не больше n² (книга ациклична — этап зачёта `_netStep`).
    function _repayTo(address b, int256 x, uint256 i) internal {
        Investor storage rb = inv[b];
        rb.cumPnl += x;
        uint256 p = _debtPos(b);
        int256 fresh = p != 0 ? monDebtX[p - 1] : int256(0);
        int256 back = _credit(b, _min(x, rb.uncovered - fresh), PL_DEBT); // записанный долг — раньше всего
        if (back != 0) {
            uint256 v = monRepayPos[b];
            if (v >> 128 == monEpoch && (v & U128_MAX) > i + 1) {
                monRepayX[(v & U128_MAX) - 1] += back; // уже ждёт: та же работа, больше сумма
            } else {
                _pushRepay(b, back); // дальше по цепочке
            }
        }
        int256 cut = _credit(b, _min(x - back, fresh), PL_DEBT); // затем его недостача этой недели
        if (cut != 0) monDebtX[p - 1] -= cut;
        back += cut;
        if (x - back != 0) _credit(b, x - back, rb.exiting || rb.payoutMode ? PL_QUEUE : PL_STAKE);
    }

    /// @dev Память пачки соучастников (по позиции в `order`): вместимость (`seen` — уже прочитана), доплачено в пачке,
    /// строка книги текущего должника, веса снимка поколения.
    struct MatesBuf {
        int256[] cap;
        bool[] seen;
        int256[] paid;
        int256[] row;
        int256[] w;
    }

    /// @dev Эталон `_allocate`, шаг 1 (соучастники), пачка до `k` ЕДИНИЦ — (должник, поколение его убытка), от курсора
    /// (`monCur`, `monGenCur`). Недостача должника — по поколениям его убытка (`_split` по весу убытка; пересчитывается в
    /// каждой пачке из неизменных входов — недостачи и строки убытка), часть поколения — между остальными участниками снимка
    /// ОДНИМ кругом по весу снимка, не больше вместимости. Вместимость (эталон: свои деньги на начало раздела минус уже
    /// доплаченное) — текущие свои деньги минус доплаченное в ЭТОЙ пачке: доплаты прежних пачек уже сняты с плоскостей.
    /// Невместившееся должника (`rest_by`) копится в `monMatesR` и по последнему его поколению встаёт в `monDebtX[d]`;
    /// доплата — долг должника перед доплатившим (`cred`, строка сбрасывается в конце должника или пачки) и снятие у
    /// доплатившего в конце пачки.
    function _matesStep(uint256 k) internal {
        uint256 n = order.length;
        uint256 nd = monDebtN;
        MatesBuf memory B;
        B.cap = new int256[](n);
        B.seen = new bool[](n);
        B.paid = new int256[](n);
        B.row = new int256[](n);
        B.w = new int256[](n);
        uint256 d = monCur;
        uint256 kg = monGenCur;
        uint256 done = monUnitsDone;
        while (d < nd) {
            address a = monDebtA[d];
            (int256[] memory parts, int256 r, uint256 off) = _matesParts(d, nd);
            if (kg != 0) r = monMatesR; // должник начат прежней пачкой: её остаток уже включает долю split
            uint256 ai = uint256(inv[a].regIndex);
            uint256 G = parts.length;
            for (; kg < G; kg++) {
                if (k == 0) break;
                k--;
                done++;
                if (parts[kg] != 0) r += _matesGen(B, ai, monLossG[off + kg], parts[kg]);
            }
            for (uint256 b = 0; b < n; b++) {
                if (B.row[b] == 0) continue;
                _pendAdd(a, b, B.row[b]); // в книгу — этапом зачёта (ред. 9.2)
                B.row[b] = 0;
            }
            if (kg < G) {
                monMatesR = r;
                break;
            }
            monDebtX[d] = r;
            kg = 0;
            d++;
        }
        monCur = d;
        monGenCur = kg;
        monUnitsDone = done;
        _payCover(B.paid, true);
    }

    /// @dev Недостача должника `d` по его парам убытка (`_split` по весу убытка, вместимость — вся недостача) и начало пар.
    /// Пары ред. 9.5 — только ненулевые, по возрастанию поколения: тот же порядок кандидатов `_split`, что у прежних G слов с
    /// нулями (вес 0 кандидатом не бывает).
    function _matesParts(uint256 d, uint256 nd) internal view returns (int256[] memory parts, int256 r, uint256 off) {
        int256 amt = monDebtX[d];
        off = monDebtOff[d];
        uint256 G = (d + 1 < nd ? monDebtOff[d + 1] : monLossN) - off;
        int256[] memory lw = new int256[](G);
        int256[] memory lc = new int256[](G);
        for (uint256 j = 0; j < G; j++) {
            lw[j] = monLossV[off + j];
            lc[j] = amt;
        }
        (parts,,, r) = _split(amt, lw, lc);
    }

    /// @dev Часть `part` недостачи должника `ai` в поколении `g`: остальные участники снимка одним кругом по весу снимка, не
    /// больше вместимости. Возвращает невместившееся.
    function _matesGen(MatesBuf memory B, uint256 ai, int256 g, int256 part) internal view returns (int256 need) {
        uint256 n = B.w.length;
        for (uint256 b = 0; b < n; b++) {
            int256 wb = b != ai ? snapW[g][order[b]] : int256(0);
            B.w[b] = wb;
            if (wb > 0 && !B.seen[b]) {
                B.cap[b] = _ownPlanes(order[b]);
                B.seen[b] = true;
            }
        }
        int256[] memory got;
        (got,,, need) = _split(part, B.w, B.cap);
        for (uint256 b = 0; b < n; b++) {
            if (got[b] == 0) continue;
            B.cap[b] -= got[b];
            B.paid[b] += got[b];
            B.row[b] += got[b];
        }
    }

    /// @dev Снятие доплат пачки одним каскадом на плательщика (каскад жадный по одному порядку плоскостей: снять x1, потом x2 —
    /// то же, что x1 + x2), это его реализованный убыток. `snap` — этап соучастников: перед первым снятием у адреса его база
    /// «всего пула» запоминается — эталон берёт её на начало раздела, а снятие её уменьшает.
    function _payCover(int256[] memory paid, bool snap) internal {
        for (uint256 b = 0; b < paid.length; b++) {
            int256 x = paid[b];
            if (x == 0) continue;
            address cb = order[b];
            if (snap && monBasis1[cb] == 0) monBasis1[cb] = inv[cb].stake + queuedInv[cb] + 1;
            if (_takeOwn(cb, x) != 0) revert Revert("_cover: short of capacity");
            inv[cb].cumPnl -= x;
        }
    }

    /// @dev Доля «всего пула» плательщика `b` этой недели (метка чужой недели — 0).
    function _giveOf(uint256 b) internal view returns (int256) {
        uint256 v = monGive[b];
        return v >> 128 == monEpoch ? int256(v & U128_MAX) : int256(0);
    }

    /// @dev Эталон `_allocate`, шаг 2 — начало: невместившееся у соучастников всех должников — одна потребность S; доли
    /// плательщиков `give` — одним разом по min(база, S) с потолком min(база, вместимость) между теми, у кого остатка нет;
    /// покрытое у должников `cov` — пропорцией остатков. База — снимок на начало раздела (`monBasis1`; у нетронутых
    /// соучастниками — текущая, она с начала раздела не менялась), вместимость — текущие свои деньги (после соучастников).
    /// Возвращает, нужна ли таблица.
    function _poolBegin() internal returns (bool table) {
        uint256 n = order.length;
        uint256 nd = monDebtN;
        int256 S;
        int256[] memory restBy = new int256[](nd);
        for (uint256 d = 0; d < nd; d++) {
            restBy[d] = monDebtX[d];
            S += restBy[d];
        }
        if (S != 0) {
            int256[] memory w = new int256[](n);
            int256[] memory c = new int256[](n);
            for (uint256 b = 0; b < n; b++) {
                address cb = order[b];
                int256 s1 = monBasis1[cb];
                int256 basis = s1 != 0 ? s1 - 1 : inv[cb].stake + queuedInv[cb];
                w[b] = _min(basis, S);
                c[b] = _min(basis, _ownPlanes(cb));
            }
            for (uint256 d = 0; d < nd; d++) {
                if (restBy[d] != 0) w[uint256(inv[monDebtA[d]].regIndex)] = 0; // должник с остатком «весь пул» не платит
            }
            (int256[] memory give,,,) = _split(S, w, c);
            int256 C;
            for (uint256 b = 0; b < n; b++) {
                if (give[b] == 0) continue;
                monGive[b] = (monEpoch << 128) | _u128(give[b]);
                C += give[b];
            }
            (int256[] memory cov,,,) = _split(C, restBy, restBy);
            for (uint256 d = 0; d < nd; d++) {
                monCov[d] = cov[d];
            }
            monC = C;
            table = true;
        }
        for (uint256 b = 0; b < n; b++) {
            if (monBasis1[order[b]] != 0) delete monBasis1[order[b]]; // снимок базы больше не нужен
        }
    }

    /// @dev Эталон `_allocate`, шаг 2 — строки таблицы «весь пул» (должник × плательщик) для должников [from, to): пропорция
    /// cov·give/C вниз, затем добор по порядку регистрации (должник, потом плательщик); невместившееся у должника — счёт пула.
    /// Остатки столбцов перед строкой зависят от пропорций ВСЕХ строк и от добора строк ДО неё: пачка пересчитывает их в памяти
    /// из `monGive`/`monCov` (добор прежних строк уже применён прежними пачками — здесь только его след в остатках).
    function _tableBatch(uint256 from, uint256 to) internal {
        uint256 n = order.length;
        uint256 nd = monDebtN;
        int256 C = monC;
        int256[] memory give = new int256[](n);
        int256[] memory colLeft = new int256[](n);
        if (C != 0) {
            for (uint256 b = 0; b < n; b++) {
                give[b] = _giveOf(b);
                colLeft[b] = give[b];
            }
        }
        int256[] memory cov = new int256[](nd);
        int256[] memory rowLeft = new int256[](nd);
        for (uint256 d = 0; d < nd; d++) {
            cov[d] = monCov[d];
            rowLeft[d] = cov[d];
            if (C == 0 || monDebtX[d] == 0) continue;
            for (uint256 b = 0; b < n; b++) {
                if (give[b] == 0) continue;
                int256 x = int256(_mulDiv(uint256(cov[d]), uint256(give[b]), uint256(C)));
                rowLeft[d] -= x;
                colLeft[b] -= x;
            }
        }
        int256[] memory row = new int256[](n);
        for (uint256 d = 0; d < from; d++) {
            _tableGreedy(rowLeft, colLeft, d, row);
        }
        int256[] memory paid = new int256[](n);
        for (uint256 d = from; d < to; d++) {
            int256 rb = monDebtX[d];
            if (rb == 0) continue;
            for (uint256 b = 0; b < n; b++) {
                row[b] = give[b] != 0 ? int256(_mulDiv(uint256(cov[d]), uint256(give[b]), uint256(C))) : int256(0);
            }
            _tableGreedy(rowLeft, colLeft, d, row);
            address a = monDebtA[d];
            for (uint256 b = 0; b < n; b++) {
                if (row[b] == 0) continue;
                _pendAdd(a, b, row[b]); // в книгу — этапом зачёта (ред. 9.2)
                paid[b] += row[b];
            }
            int256 h = rb - cov[d];
            if (h != 0) {
                shortfall += h;
                credPool[a] += h;
            }
        }
        _payCover(paid, false);
    }

    /// @dev Добор строки d таблицы по порядку регистрации плательщиков: min(остаток строки, остаток столбца), в `row`.
    /// Остатки не бывают отрицательными (Σ пропорций строки <= cov, столбца <= give), поэтому пропуск — только по нулю.
    function _tableGreedy(int256[] memory rowLeft, int256[] memory colLeft, uint256 d, int256[] memory row)
        internal
        pure
    {
        for (uint256 b = 0; b < colLeft.length; b++) {
            if (rowLeft[d] == 0) return;
            if (colLeft[b] == 0) continue;
            int256 x = _min(rowLeft[d], colLeft[b]);
            row[b] += x;
            rowLeft[d] -= x;
            colLeft[b] -= x;
        }
    }

    // --- ред. 9.2: зачёт циклов книги доплативших (эталон `_cover` -> `_net_cycles`, спека 8.10) ------------------------ //

    uint256 internal constant B96 = (1 << 96) - 1;

    /// @dev Доля раздела `x` > 0 должника `a` доплатившему `order[b]` — ждёт записи в книгу на этапе зачёта.
    function _pendAdd(address a, uint256 b, int256 x) internal {
        monPend[a][order[b]] += x;
        monPendBits[a][b >> 8] |= 1 << (b & 255);
    }

    /// @dev Этап зачёта (эталон `_cover`, ред. 9.2), пачка до `k` единиц от курсора (`monCur` — должник, `monNetB` —
    /// доплативший с начатым зачётом). Доли пишутся в книгу в порядке эталона — должники по регистрации, доплатившие одного
    /// должника по АДРЕСУ (эталон сортирует ключи книги строкой адреса, а адрес в нижнем регистре — тот же порядок, что
    /// число) — и за каждой записью a -> b идёт `_net_cycles(a, b)`: пока a должен b, у b есть свои долги перед
    /// инвесторами и путь b -> … -> a есть, цикл уменьшается на свой минимум. Единица — запись доли или один поиск пути
    /// (O(посещённых × слов) чтений, см. `_debtPath`); проверка «своих долгов нет» — O(слов) и единицей не считается.
    /// Исход от нарезки не зависит: зачёт без состояния — каждая пачка ищет путь по текущей книге, а записанные доли сняты
    /// из ожидания (`monPendBits`).
    function _netStep(uint256 k) internal {
        uint256 nd = monDebtN;
        uint256 d = monCur;
        uint256 nb = monNetB;
        uint256 units = monUnitsDone;
        while (d < nd) {
            address a = monDebtA[d];
            uint256 ai = uint256(inv[a].regIndex);
            uint256[] memory keys = _pendSorted(a);
            uint256 t;
            while (true) {
                if (nb != 0) {
                    address b = order[nb - 1];
                    if (cred[a][b] > 0 && _hasInvDebt(b)) {
                        if (k < 1) break;
                        k--;
                        units++;
                        if (_netOnce(a, ai, b, nb - 1)) continue;
                    }
                    nb = 0; // a больше не должен b, у b нет своих долгов или пути нет — зачёт записи кончен
                }
                if (t == keys.length || k == 0) break;
                k--;
                units++;
                uint256 bi = keys[t++] & B96;
                _pendApply(a, bi);
                nb = bi + 1;
            }
            if (k == 0 && (nb != 0 || t < keys.length)) break;
            d++;
        }
        monCur = d;
        monNetB = nb;
        monUnitsDone = units;
    }

    /// @dev Ждущие доли должника `a` — ключи (адрес << 96 | позиция) по возрастанию адреса.
    function _pendSorted(address a) internal view returns (uint256[] memory keys) {
        uint256 n = order.length;
        keys = new uint256[](n);
        uint256 m;
        for (uint256 wi = 0; wi << 8 < n; wi++) {
            for (uint256 nb = monPendBits[a][wi]; nb != 0; nb &= nb - 1) {
                uint256 b = (wi << 8) | _log2(nb & (~nb + 1));
                keys[m++] = (uint256(uint160(order[b])) << 96) | b;
            }
        }
        assembly {
            mstore(keys, m)
        }
        // пирамидальная сортировка: O(m log m) при любом порядке регистрации
        for (uint256 i = m / 2; i > 0; i--) {
            _siftDown(keys, i - 1, m);
        }
        for (uint256 end = m; end > 1; end--) {
            (keys[0], keys[end - 1]) = (keys[end - 1], keys[0]);
            _siftDown(keys, 0, end - 1);
        }
    }

    function _siftDown(uint256[] memory h, uint256 i, uint256 m) internal pure {
        while (true) {
            uint256 c = 2 * i + 1;
            if (c >= m) return;
            if (c + 1 < m && h[c + 1] > h[c]) c++;
            if (h[i] >= h[c]) return;
            (h[i], h[c]) = (h[c], h[i]);
            i = c;
        }
    }

    /// @dev Запись ждущей доли должника `a` доплатившему `order[bi]` в книгу (эталон `book[b] += x` в `_cover`).
    function _pendApply(address a, uint256 bi) internal {
        address b = order[bi];
        int256 x = monPend[a][b];
        monPend[a][b] = 0;
        monPendBits[a][bi >> 8] &= ~(uint256(1) << (bi & 255));
        _credAdd(a, b, bi, x);
    }

    /// @dev У `b` есть записанные долги перед ИНВЕСТОРАМИ (счёт пула — не вершина: у пула долгов нет, через него цикл не
    /// проходит). O(слов битовой строки) — одно чтение при n <= 256.
    function _hasInvDebt(address b) internal view returns (bool) {
        uint256 n = order.length;
        for (uint256 wi = 0; wi << 8 < n; wi++) {
            if (credBits[b][wi] != 0) return true;
        }
        return false;
    }

    /// @dev Эталон `_debt_path`: кратчайший путь долга src -> … -> dst (позиции в `order`), обход в ширину, соседи — в
    /// порядке регистрации (младший бит раньше). Посещённые — битовая строка в памяти, поэтому раскрытие вершины — O(слов)
    /// чтений её `credBits`, а не O(адресов): весь поиск — O(посещённых × ⌈n/256⌉) чтений хранилища. Пусто — пути нет.
    function _debtPath(uint256 src, uint256 dst) internal view returns (uint256[] memory) {
        uint256[] memory vis = new uint256[]((order.length + 255) >> 8);
        uint256[] memory prev = new uint256[](order.length);
        uint256[] memory q = new uint256[](order.length + 1); // q[0] — длина очереди, дальше — вершины по порядку открытия
        q[0] = 1;
        q[1] = src;
        vis[src >> 8] = 1 << (src & 255);
        for (uint256 j = 1; j <= q[0]; j++) {
            if (_expand(q[j], dst, vis, prev, q)) return _pathTo(prev, src, dst);
        }
        return new uint256[](0);
    }

    /// @dev Раскрытие вершины `x` поиска `_debtPath`: новые соседи — по порядку регистрации в хвост очереди; true — среди них
    /// `dst` (его `prev` записан).
    function _expand(uint256 x, uint256 dst, uint256[] memory vis, uint256[] memory prev, uint256[] memory q)
        internal
        view
        returns (bool)
    {
        mapping(uint256 => uint256) storage bits = credBits[order[x]];
        for (uint256 wi = 0; wi < vis.length; wi++) {
            uint256 nb = bits[wi] & ~vis[wi];
            vis[wi] |= nb;
            while (nb != 0) {
                uint256 bit = nb & (~nb + 1); // младший бит — раньше зарегистрированный сосед
                nb ^= bit;
                uint256 y = (wi << 8) | _log2(bit);
                prev[y] = x;
                if (y == dst) return true;
                q[++q[0]] = y;
            }
        }
        return false;
    }

    function _pathTo(uint256[] memory prev, uint256 src, uint256 dst) internal pure returns (uint256[] memory path) {
        uint256 len = 1;
        for (uint256 v = dst; v != src; v = prev[v]) {
            len++;
        }
        path = new uint256[](len);
        uint256 u = dst;
        for (uint256 j = len; j > 0; j--) {
            path[j - 1] = u;
            if (u != src) u = prev[u];
        }
    }

    /// @dev Один шаг эталона `_net_cycles` для записи a -> b: путь b -> … -> a и вычет минимума по циклу b -> … -> a -> b.
    /// У каждого участника цикла требование и обязательство гасятся ОДНОЙ суммой: деньги и `cumPnl` не двигаются,
    /// `uncovered` падает. false — пути нет.
    function _netOnce(address a, uint256 ai, address b, uint256 bi) internal returns (bool) {
        uint256[] memory path = _debtPath(bi, ai);
        uint256 len = path.length;
        if (len == 0) return false;
        int256 t = cred[a][b];
        for (uint256 j = 0; j + 1 < len; j++) {
            t = _min(t, cred[order[path[j]]][order[path[j + 1]]]);
        }
        if (t <= 0) revert Revert("_net_cycles: zero edge"); // ребро без суммы — бит книги разошёлся с `cred`
        for (uint256 j = 0; j + 1 < len; j++) {
            _netEdge(order[path[j]], path[j + 1], t);
        }
        _netEdge(a, bi, t);
        return true;
    }

    function _netEdge(address x, uint256 yi, int256 t) internal {
        _credAdd(x, order[yi], yi, -t);
        inv[x].uncovered -= t;
    }

    /// @dev ЕДИНСТВЕННАЯ точка входа денег адреса (эталон `_credit`, ред. 9): `debt` гасит долг ТОЛЬКО из результата недели
    /// самого должника (лишнее — revert); депозит, реферальная доля и прочее долг не гасят; `pot` — целиком treasury.
    function _credit(address a, int256 amount, uint8 plane) internal returns (int256 back) {
        if (amount < 0) revert Revert("_credit: negative");
        if (amount == 0) return 0;
        Investor storage r = inv[a];
        if (plane == PL_DEBT) {
            back = r.exists ? _min(amount, r.uncovered) : int256(0);
            if (back != 0) {
                r.uncovered -= back;
                r.cumPnl -= back;
            }
            if (amount - back != 0) revert Revert("_credit: debt");
            return back;
        }
        if (plane == PL_POT) {
            _touch(treasury);
            rewardCash[treasury] += amount;
        } else if (plane == PL_STAKE) {
            r.stake += amount;
            stakeSum += amount;
        } else if (plane == PL_QUEUE) {
            _enqueue(a, amount, false);
        } else if (plane == PL_REWARD) {
            _touch(a);
            rewardCash[a] += amount;
        } else {
            revert Revert("_credit: plane");
        }
    }

    function _takeFrom(mapping(address => int256) storage book, address key, int256 need) internal returns (int256) {
        int256 t = _min(need, book[key]);
        if (t != 0) book[key] -= t;
        return need - t;
    }

    /// @dev Снятие с плоскостей «к получению»: та же `_takeFrom`, плюс ведущаяся `claimableSum`.
    function _takeClaim(mapping(address => int256) storage book, address key, int256 need) internal returns (int256) {
        int256 rest = _takeFrom(book, key, need);
        claimableSum -= need - rest;
        return rest;
    }

    /// @dev Эталон `_take_from_queue`: снять до `need` с заявок ключа, НОВЕЙШИЕ первыми. Новейшие лежат в хвосте полосы ключа
    /// (`QHead`), поэтому снятие — сдвиг её конца: записи за ним мертвы, граничная укорочена. O(1), сколько бы заявок ни было.
    function _takeFromQueue(address a, bool reward, int256 need) internal returns (int256) {
        if (need == 0) return 0;
        int256 t = _min(need, _queuedOf(a, reward));
        if (t != 0) _queueAdd(a, reward, -t);
        return need - t;
    }

    /// @dev ЕДИНСТВЕННЫЙ порядок снятия денег адреса (эталон `_take_own`); он же каскад убытка `_absorb_loss` ред. 9.
    function _takeOwn(address a, int256 need) internal returns (int256) {
        Investor storage r = inv[a];
        if (r.exists) {
            int256 take = _min(need, r.stake);
            r.stake -= take;
            stakeSum -= take;
            need -= take;
        }
        need = _takeFromQueue(a, false, need);
        need = _takeClaim(claimable, a, need);
        need = _takeClaim(claimableReward, a, need);
        need = _takeFrom(rewardCash, a, need);
        return _takeFromQueue(a, true, need);
    }

    /// @dev Эталон `_finalize_generations`: поколение без живых ордеров (`genLive`) закрывается — остаток округлений
    /// (R − Σ разнесённого) в котёл. Ред. 9.5 — O(живых поколений), без обхода окончательных: каждое из них уже посчитано
    /// (`_genDead`) и ждёт здесь одной суммой — пыль в котёл (эталон зачисляет её по поколению: зачисление в котёл аддитивно,
    /// пыль неотрицательна, значит сумма та же и ноль — ровно когда нули все), R — в закрытый итог. Обходятся только живые:
    /// без ордеров среди них бывает лишь ТЕКУЩЕЕ (иначе поколение стало окончательным и ушло из списка; не ушло — отказ), оно
    /// закрывается тем же `_genDead`. Пережившие становятся префиксом снимков (`surv`), новые поколения — после `gen`.
    /// Слова закрытых поколений не стираются: номер поколения не повторяется, а читают их только по снимкам; `snapExists`
    /// текущего снимается — следующий `sizeOrder` откроет новое.
    function _finalizeGenerations() internal {
        uint256 k;
        for (int256 g = lvHead; g != 0;) {
            int256 nx = lvNext[g];
            if (genLive[g] == 0) {
                if (g != gen) revert Revert("monday: dead generation left live");
                _genDead(g);
                delete snapExists[g];
            } else {
                if (surv[k] != g) surv[k] = g;
                k++;
            }
            g = nx;
        }
        survN = k;
        genBase = gen;
        int256 dust = dustPending;
        if (dust != 0) {
            _credit(treasury, dust, PL_POT);
            settledR += dust;
        }
        closedR += closedPending;
        growSum -= growDead;
        snapTotalSum -= totalDead;
        (dustPending, closedPending, growDead, totalDead) = (0, 0, 0, 0);
        weekClosedN = 0; // закрытые ордера уходят из книги (из `orderPids` они ушли при закрытии), O(1)
    }
}

// @notice Изменяющие операции бухгалтерии. Витрины — через fallback в PoolLedgerViews.
/// @dev ВЛАДЕЛЕЦ — аргумент конструктора, а не развёртывающий (КЕ10): бухгалтерия деплоится ДО хранилища, на его вычисленный
/// адрес (CREATE того же деплойера, следующий nonce после ног), и конструктор `PoolVault` сверяет, что владелец — он сам.
/// Сеттера владельца нет: пока хранилища нет, по этому адресу нет кода и ключа, и вызвать `onlyOwner` некому.
contract PoolLedger is PoolLedgerBase {
    /// @notice Параметры конструктора (эталон `GenLedger(...)`). Кортеж только из статических полей кодируется в ABI ровно
    /// как плоский список аргументов — структура нужна лишь потому, что 13 аргументов не помещаются в стек декодера.
    struct Init {
        address treasury;
        uint256 bufferBps;
        uint256 feeBps;
        uint256 refShareBps;
        uint256 holdBps;
        uint256 openRefShareBps;
        uint256 partnerTermWeeks;
        uint256 minDeposit;
        uint256 maxInvestors;
        address viewsImpl;
        address mondayImpl;
        address projImpl;
        address emergencyImpl;
        address owner;
        address bookImpl; //   ред. 9.5: книга ордеров (PoolLedgerBook)
        uint256 maxGens; //    ред. 9.5: предел поколений между расчётами, 0 — правила нет (эталон None); не выше MAX_GENS_BOUND
    }

    constructor(Init memory p) {
        if (p.viewsImpl.code.length == 0) revert Revert("views: no code");
        if (p.mondayImpl.code.length == 0) revert Revert("monday: no code");
        if (p.projImpl.code.length == 0) revert Revert("proj: no code");
        if (p.emergencyImpl.code.length == 0) revert Revert("emergency: no code");
        if (p.bookImpl.code.length == 0) revert Revert("book: no code");
        if (p.maxGens > MAX_GENS_BOUND) revert Revert("max_gens");
        bookImpl = p.bookImpl;
        maxGens = p.maxGens;
        viewsImpl = p.viewsImpl;
        mondayImpl = p.mondayImpl;
        projImpl = p.projImpl;
        emergencyImpl = p.emergencyImpl;
        if (
            p.bufferBps > 10_000 || p.feeBps > 10_000 || p.refShareBps > 10_000 || p.holdBps > 10_000
                || p.openRefShareBps > 10_000
        ) revert Revert("bps > BPS");
        if (p.partnerTermWeeks == 0) revert Revert("partner_term_weeks == 0");
        // эталон: max_investors == 0 — пул, в который нельзя войти никому (ValueError); в контракте предел обязателен и не
        // выше границы из замера газа (None эталона — `MAX_INVESTORS_BOUND`, кодек дифференциала)
        if (p.maxInvestors == 0 || p.maxInvestors > MAX_INVESTORS_BOUND) revert Revert("max_investors");
        minDeposit = _amount(p.minDeposit);
        maxInvestors = p.maxInvestors;
        _addr(p.treasury);
        _addr(p.owner);
        owner = p.owner;
        treasury = p.treasury;
        bufferBps = int256(p.bufferBps);
        feeBps = int256(p.feeBps);
        refShareBps = int256(p.refShareBps);
        holdBps = int256(p.holdBps);
        openRefShareBps = int256(p.openRefShareBps);
        partnerTermWeeks = int256(p.partnerTermWeeks);
    }

    /// @notice Начальные партнёры — до первой операции (в эталоне — аргумент конструктора).
    function initPartner(address a) external onlyOwner {
        if (initialized) revert Revert("init closed");
        _addr(a);
        if (partners[a].state != P_NONE) return;
        partners[a] = Partner(P_ACTIVE, 0, false, 0);
        partnerList.push(a);
    }

    function sizeOrder(bytes32 pid, uint256 notional) external onlyOwner returns (int256) {
        _start();
        _id32(pid);
        if (orders[pid].state != ST_NONE) revert Revert("size_order: exists");
        if (closedPid[pid]) revert Revert("size_order: closed pid");
        int256 n = _amount(notional);
        if (n == 0) revert Revert("size_order: zero");
        // вектор весов в порядке регистрации (эталон `weights()`): проекция возврата и раздел — одни на все веса, их считает
        // PoolLedgerProj (ред. 9.2.1: возврат меняет вес и без проектного убытка)
        uint256 cnt;
        int256[] memory w = _weightsRemote();
        for (uint256 i = 0; i < w.length; i++) {
            if (w[i] > 0) cnt++;
        }
        if (cnt == 0) revert Revert("size_order: no capital");
        if (!_snapEquals(gen, w)) {
            // ред. 9.5: НОВОЕ поколение сверх предела — отказ, keeper проводит внеочередной расчёт `monday(false)` и повторяет;
            // ордер при тех же весах встаёт в текущее и пределом не режется (эталон `size_order`)
            if (maxGens != 0 && gensSince >= maxGens) revert Revert("size_order: max_gens");
            gensSince += 1;
            int256 g0 = gen;
            gen = g0 + 1;
            int256 total;
            for (uint256 i = 0; i < order.length; i++) {
                if (w[i] > 0) {
                    snapW[gen][order[i]] = w[i];
                    total += w[i];
                }
            }
            snapN[gen] = order.length;
            snapExists[gen] = true;
            snapTotal[gen] = total;
            R[gen] = 0;
            snapTotalSum += total;
            _lvAppend(gen);
            // прежнее текущее без живых ордеров стало окончательным: ордер в него больше не встанет
            if (snapExists[g0] && genLive[g0] == 0) _genDead(g0);
        }
        orders[pid] = Order(ST_SIZED, gen, n, 0, week, 0);
        _listOrder(pid);
        genLive[gen] += 1;
        _aggOrder(orders[pid], true);
        return gen;
    }

    /// @notice Книга ордеров (fill, cancel, mark, close, reduce) — в PoolLedgerBook делегированным вызовом на этой памяти: им
    /// нужны писатели ведущихся сумм по ордерам, и в EIP-170 PoolLedger с ними не помещается (ред. 9.5: и PoolLedgerMonday).
    function fillOrder(bytes32) external onlyOwner {
        _delegate(bookImpl);
    }

    function cancelOrder(bytes32) external onlyOwner {
        _delegate(bookImpl);
    }

    function markPosition(bytes32, int256) external onlyOwner {
        _delegate(bookImpl);
    }

    function closePosition(bytes32, int256) external onlyOwner {
        _delegate(bookImpl);
    }

    function reducePosition(bytes32, int256, uint256, int256) external onlyOwner {
        _delegate(bookImpl);
    }

    function setWithdrawable(uint256 amount) external onlyOwner {
        _start();
        int256 a = _amount(amount);
        if (a > _max(0, _venueValue())) revert Revert("withdrawable > value");
        withdrawable = a;
    }

    function sweepToPerp() external onlyOwner returns (int256) {
        _start();
        int256 move = _freePlane() - _bufferTarget() - queuedSum;
        if (move <= 0) return 0;
        int256 take = _min(move, spot);
        spot -= take;
        evm -= move - take;
        venueCash += move;
        withdrawable += move;
        return move;
    }

    /// @param payout 0 — не задан (None), 1 — false, 2 — true.
    function deposit(address a, uint256 amount, address referrer, uint8 payout, uint8 path, bytes32 ref)
        external
        onlyOwner
    {
        _start();
        _addr(a);
        if (a == treasury) revert Revert("deposit: treasury is not an investor");
        int256 amt = _amount(amount);
        if (amt == 0) revert Revert("deposit: zero");
        // П1: минимум — на КАЖДЫЙ депозит, включая пополнение; до `_takeIn` — ref не сгорает, keeper возвращает Send `refundRef`
        if (amt < minDeposit) revert Revert("deposit: below min");
        // П2: предел — по ЗАРЕГИСТРИРОВАННЫМ (`order` пожизненный); пополнение существующего принимается и на пределе
        if (!inv[a].exists && order.length >= maxInvestors) revert Revert("deposit: investor limit");
        _stakeCeiling(amt);
        if (referrer != address(0) && referrer == a) revert Revert("deposit: self referrer");
        if (payout > 2) revert Revert("deposit: payout");
        _takeIn(amount, path, ref);
        Investor storage r = _rec(a);
        if (r.ever && referrer != address(0) && r.referrer != referrer) revert Revert("deposit: referrer only first");
        if (r.ever && payout != 0 && (payout == 2) != r.payoutMode) revert Revert("deposit: payout mode");
        if (!r.ever) {
            r.referrer = referrer;
            r.ever = true;
            r.payoutMode = payout == 2;
        }
        _credit(a, amt, PL_STAKE); // ред. 9: депозит долг НЕ гасит
        r.deposited += amt;
        r.exiting = false;
        if (_projectedShortfall() > 0) revert Revert("deposit: pool debt");
    }

    function setPayoutMode(address a, bool payout) external onlyOwner {
        _start();
        _addr(a);
        Investor storage r = inv[a];
        if (!r.exists) revert Revert("set_payout_mode: unknown");
        r.payoutMode = payout;
    }

    function setPartner(address a, uint8 status) external onlyOwner {
        _start();
        _addr(a);
        if (status < P_ACTIVE || status > P_REVOKED_CAUSE) revert Revert("set_partner: status");
        Partner storage p = partners[a];
        if (p.state == P_NONE) {
            if (status != P_ACTIVE) revert Revert("set_partner: never partner");
            partners[a] = Partner(P_ACTIVE, week, false, 0);
            partnerList.push(a);
            return;
        }
        if (p.state == status) revert Revert("set_partner: same");
        if (p.state == P_REVOKED_CAUSE && status == P_REVOKED) revert Revert("set_partner: no softening");
        if (status == P_ACTIVE) {
            p.hasRevokedAt = false;
            p.revokedAtOrder = 0;
        } else if (p.state == P_ACTIVE) {
            p.hasRevokedAt = true;
            p.revokedAtOrder = int256(order.length);
        }
        p.state = status;
    }

    /// @notice Вывод (эталон `withdraw`). `status` — `W_OK`, либо бизнес-отказ эталона кодом (`W_AMOUNT`, `W_RANGE`): тогда
    /// состояние не тронуто, а `paid`/`queued` — нули. Прочие отказы эталона (адрес, заморозка, открытый расчёт) и любой сбой
    /// (газ на любой глубине, инвариант) — отказ транзакции.
    function withdraw(address a, uint256 amount, bool reward)
        external
        onlyOwner
        returns (uint8 status, int256 paid, int256 queued)
    {
        _start();
        _addr(a);
        return _withdraw(a, amount, reward);
    }

    function payQueue() external onlyOwner {
        _start();
        _payFifo();
    }

    /// @notice Недельный автовывод комиссии (ред. 9: уходит ВЕСЬ котёл, подушки нет). Ноль — штатный исход.
    function treasuryPayout() external onlyOwner returns (int256 paid, int256 queued) {
        _start();
        int256 amount = _freeStake(treasury, true);
        if (amount == 0) return (0, 0);
        uint8 st;
        (st, paid, queued) = _withdraw(treasury, uint256(amount), true);
        if (st != W_OK) revert Revert("treasury_payout"); // сумма — ровно свободная доля: отказа быть не может
    }

    function claim(address a) external onlyOwner returns (int256) {
        _start();
        _addr(a);
        (int256 pi, int256 pr) = _claimNow(a);
        if (pi == 0 && pr == 0) revert Revert("claim: nothing");
        _takeClaim(claimable, a, pi);
        _takeClaim(claimableReward, a, pr);
        evm -= pi + pr;
        if (pi != 0 && inv[a].exists) inv[a].withdrawn += pi;
        if (pr != 0) {
            _touch(a);
            withdrawnReward[a] += pr;
        }
        return pi + pr;
    }

    /// @notice П3 (эталон `refund_deposit`): Send на счёт хранилища ВОЗВРАЩЁН отправителю — его ref сгорает в общем пространстве
    /// депозитов и `coverShortfall`. Плоскости не меняются: деньги в бухгалтерию не входили.
    function refundRef(bytes32 ref) external onlyOwner {
        _start();
        _burnRef(ref);
    }

    /// @notice A9: предел адресов поднимается владельцем (хранилище — только по своему таймлоку) ТОЛЬКО вверх и не выше
    /// `MAX_INVESTORS_BOUND` (замер газа). Правило П2 то же; меняется лишь его параметр — пожизненный предел остаётся
    /// пожизненным (слоты вышедших не освобождаются). Ред. 9.4: после заморозки — отказ (бухгалтерия неизменна целиком);
    /// мимо `_start()`: хранилище для беты подъём в открытом расчёте не запрещало, и это правило слияние не меняет.
    function raiseMaxInvestors(uint256 n) external onlyOwner {
        if (emState != 0) revert Revert("frozen");
        if (n <= maxInvestors || n > MAX_INVESTORS_BOUND) revert Revert("max_investors");
        maxInvestors = n;
    }

    function coverShortfall(uint256 amount, uint8 path, bytes32 ref) external onlyOwner returns (int256) {
        _start();
        int256 amt = _amount(amount);
        if (amt == 0 || amt > shortfall) revert Revert("cover_shortfall: amount");
        _takeIn(amount, path, ref);
        shortfall -= amt;
        return shortfall;
    }

    /// @notice Недельный расчёт: тело — в PoolLedgerMonday, исполняется делегированным вызовом на памяти этого контракта;
    /// его хвост — проход очереди (эталон: `_finalize_generations`, затем `_pay_fifo`) — здесь.
    function monday() external onlyOwner {
        _delegateCall(mondayImpl);
        _payFifo();
    }

    /// @notice Ред. 9.5 — `monday(true)` — календарный расчёт (то же, что `monday()`), `monday(false)` — ВНЕОЧЕРЕДНОЙ: тот же
    /// расчёт, неделя не сдвигается (эталон `monday(calendar=False)`). Внеочередной расчёт фиксирует комиссию чаще — это власть
    /// keeper'а над деньгами инвесторов, поэтому он принимается ТОЛЬКО по одному из двух условий спеки 8.15 (`_extraAllowed`).
    function monday(bool calendar) external onlyOwner {
        if (!calendar) _extraAllowed();
        _delegateCall(mondayImpl);
        _payFifo();
    }

    /// @notice Недельный расчёт пачками: `mondayBegin`, затем `mondayStep(k)` до конца списка (ФАЗА 1 — строки адресов),
    /// затем `mondayEnd` (ФАЗА 2 — доли рефералов, возвраты, раздел недостачи). Исход тот же, что у `monday()`.
    /// Ред. 9.4: в той же транзакции — MS_SNAP (PoolLedgerEmergency): копия плоскостей держателей ДО первой записи расчёта.
    function mondayBegin() external onlyOwner {
        _delegateCall(mondayImpl);
        _delegate(emergencyImpl);
    }

    /// @notice Ред. 9.5: тот же расчёт пачками; `false` — внеочередной (условие — как у `monday(false)`).
    function mondayBegin(bool calendar) external onlyOwner {
        if (!calendar) _extraAllowed();
        _delegateCall(mondayImpl);
        _delegate(emergencyImpl);
    }

    /// @dev ПРАВО НА ВНЕОЧЕРЕДНОЙ РАСЧЁТ (спека 8.15, «доверие к keeper'у»): открыто поколений с последнего расчёта не меньше
    /// ⌊maxGens/2⌋ (клапан предела: `sizeOrder` нового поколения сверх `maxGens` — отказ) ИЛИ в этом блоке есть должник по
    /// маркам — адрес с проектной недостачей (`_projectedShortfall` сверх признанного долга; та же величина, что у гейта
    /// депозита, O(адресов), без раздела). `maxGens == 0` — предела нет (эталон None), условие пусто: правило эталона, где
    /// внеочередной расчёт — политика keeper'а, а не бухгалтерии. Иначе — отказ, состояние не тронуто.
    /// Ревью-3b (LOW): сначала замки `_start()` — на замороженном пуле и в открытом расчёте причина «frozen» / «monday in
    /// progress», а не «extra settle not allowed». Запись `initialized` откатывается вместе с отказом.
    function _extraAllowed() internal {
        _start();
        if (gensSince >= maxGens / 2) return;
        if (_projectedShortfall() > shortfall) return;
        revert Revert("monday: extra settle not allowed");
    }

    /// @dev Ред. 9.4: шаги расчёта идут мимо `_start()` — заморозку посреди расчёта судят здесь.
    function mondayStep(uint256) external onlyOwner returns (uint256) {
        if (emState != 0) revert Revert("frozen");
        _delegate(mondayImpl);
    }

    function mondayEnd() external onlyOwner {
        if (emState != 0) revert Revert("frozen");
        _delegateCall(mondayImpl);
        _payFifo();
    }

    /// @notice РЕД. 9.4 — ЗАМОРОЖЕННЫЙ ПУЛ (эталон `emergency_freeze`): необратимо; после неё каждая изменяющая операция —
    /// отказ. Итоги снимка — `emergencySnapStep(k)` пачками до готовности; доли — правило E (`emergencyDue`, витрина).
    function emergencyFreeze() external onlyOwner {
        _delegate(emergencyImpl);
    }

    function emergencySnapStep(uint256) external onlyOwner returns (uint256) {
        _delegate(emergencyImpl);
    }

    /// @notice Витрины и выгрузка живут в PoolLedgerViews, проекции (`holdCtx()`) — в PoolLedgerProj; обе исполняются здесь
    /// через delegatecall — на ЭТОЙ памяти. Там только view-функции (судит selftest дифференциала по ABI), поэтому записать
    /// в память через fallback нечем.
    fallback() external {
        _delegate(msg.sig == SEL_HOLD_CTX || msg.sig == SEL_WEIGHTS ? projImpl : viewsImpl);
    }

    /// @dev Тот же calldata — в реализацию делегированным вызовом; её отказ — отказ этого вызова, при успехе исполнение идёт дальше.
    function _delegateCall(address impl) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            if iszero(delegatecall(gas(), impl, 0, calldatasize(), 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /// @dev Тот же calldata — в реализацию делегированным вызовом; её ответ или отказ — ответ этого вызова.
    function _delegate(address impl) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @notice Недельный расчёт и книга ордеров (fill, cancel, mark, close). Вызывается ТОЛЬКО делегированным вызовом из
/// PoolLedger (своей памяти у него нет: прямой вызов читает пустого владельца и отклоняется `onlyOwner`).
contract PoolLedgerMonday is PoolLedgerBase {
    function monday() external onlyOwner {
        _mondayRun(true);
    }

    /// @notice Ред. 9.5: `false` — внеочередной расчёт (неделя не сдвигается; право судит PoolLedger до вызова).
    function monday(bool calendar) external onlyOwner {
        _mondayRun(calendar);
    }

    function _mondayRun(bool calendar) internal {
        _mondayBegin(calendar);
        while (_mondayStep(type(uint256).max) != 0) {}
        _mondayEnd();
    }

    function mondayBegin() external onlyOwner {
        _mondayBegin(true);
    }

    function mondayBegin(bool calendar) external onlyOwner {
        _mondayBegin(calendar);
    }

    function mondayStep(uint256 k) external onlyOwner returns (uint256 left) {
        if (!mondayOpen) revert Revert("monday not open");
        if (k == 0) revert Revert("mondayStep: k == 0"); // пачка без единиц стояла бы на месте молча
        return _mondayStep(k);
    }

    function mondayEnd() external onlyOwner {
        if (!mondayOpen) revert Revert("monday not open");
        _mondayEnd();
    }
}

/// @notice Ред. 9.5 — КНИГА ОРДЕРОВ (fill, cancel, mark, close, reduce): писатели ведущихся сумм по ордерам и поколениям и
/// закрытие поколения, ставшего окончательным. Вызывается ТОЛЬКО делегированным вызовом из PoolLedger (своей памяти у неё нет:
/// прямой вызов читает пустого владельца и отклоняется `onlyOwner`). МЕСТО — вывод из бюджета EIP-170: в PoolLedgerMonday
/// книга с амортизацией поколений не помещается (README «Ред. 9.5: размеры»).
contract PoolLedgerBook is PoolLedgerBase {
    function fillOrder(bytes32 pid) external onlyOwner {
        _start();
        _order(pid, ST_SIZED).state = ST_OPEN;
    }

    function cancelOrder(bytes32 pid) external onlyOwner {
        _start();
        Order storage o = _order(pid, ST_SIZED);
        int256 g = o.gen;
        genLive[g] -= 1;
        _aggOrder(o, false);
        _deleteOrder(pid);
        _maybeDead(g);
    }

    /// @dev Ред. 9.5: последний живой ордер не текущего поколения ушёл — поколение окончательно (`_genDead`).
    function _maybeDead(int256 g) internal {
        if (genLive[g] == 0 && g != gen) _genDead(g);
    }

    function markPosition(bytes32 pid, int256 upnl) external onlyOwner {
        _start();
        Order storage o = _order(pid, ST_OPEN);
        _aggOrder(o, false);
        _setUpnl(o, _signed(upnl));
        _aggOrder(o, true);
        _signed(R[o.gen] + genU[o.gen]);
        _signed(o.upnl + o.partR); // ред. 9.3.1, `_part_bounds` эталона (R − P_g марк не меняет — см. `_realize`)
        int256 vv = _venueValue();
        if (vv < 0) revert Revert("mark_position: value < 0");
        _stakeCeiling(0);
        withdrawable = _min(withdrawable, vv);
    }

    function closePosition(bytes32 pid, int256 realized) external onlyOwner {
        _start();
        _realize(_order(pid, ST_OPEN), pid, realized, 0, 0, true);
    }

    /// @notice РЕД. 9.3 — ЧАСТИЧНОЕ ЗАКРЫТИЕ (эталон `reduce_position`): результат части — в `R[g]` поколения ордера, нотионал и
    /// марк — ОСТАТКА; ордер открыт, поколение живо, `pid` в закрытые не попадает. Нотионал остатка в (0, прежний): повтор той
    /// же транзакции отклоняется, а не удваивает; `trim` недолитого входа — `reducePosition(pid, 0, исполненное, марк)`.
    function reducePosition(bytes32 pid, int256 realized, uint256 notional, int256 upnl) external onlyOwner {
        _start();
        Order storage o = _order(pid, ST_OPEN);
        int256 n = _amount(notional);
        if (n == 0 || n >= o.notional) revert Revert("reduce_position: notional");
        _realize(o, pid, realized, n, upnl, false);
    }

    /// @dev ЕДИНСТВЕННЫЙ писатель R поколения после его открытия: сумма адресов (`_aggR`), R, `rAll` и — ред. 9.5 — след R в
    /// ведущихся суммах снимков: оценке потолка капитала (`growSum`) и границе «проектного убытка нет» (`lossRN`).
    function _moveR(int256 g, int256 r, int256 p0, int256 p1) internal {
        int256 x0 = R[g];
        int256 x1 = x0 + r;
        _aggR(g, x0, x1, p0, p1);
        R[g] = x1;
        rAll += r;
        growSum += _max(0, x1) - _max(0, x0);
        int256 y = rMon[g];
        if ((x0 < y) != (x1 < y)) x1 < y ? lossRN++ : lossRN--;
    }

    /// @dev ОБЩЕЕ ТЕЛО закрытия и части (эталон `_realize`): результат — в `R[g]`; `closing` — ордер закрыт (нотионал и марк 0,
    /// `pid` в закрытых), иначе нотионал и марк — остатка. Ред. 9.3.1: часть копится в `partR` (закрытие её снимает), `genP` —
    /// сумма частей поколения. Границы эталона `_part_bounds` судятся по ИЗМЕНЁННЫМ величинам: `upnl + partR` прочих ордеров
    /// и `R − P_g` других поколений этот вызов не трогает, а каждый писатель, их меняющий, их и проверяет (марк — свой ордер,
    /// часть и закрытие — свой ордер и своё поколение) — значит, отказ тот же, что у обхода эталона.
    function _realize(Order storage o, bytes32 pid, int256 realized, int256 notional, int256 upnl, bool closing) internal {
        int256 g = o.gen;
        int256 r = _signed(realized);
        int256 q0 = o.partR;
        int256 q1 = closing ? int256(0) : q0 + r;
        int256 p0 = genP[g];
        int256 p1 = p0 - q0 + q1;
        _aggOrder(o, false); // вклад ордера снимается до изменения (закрытый выходит из сумм адресов целиком)
        _moveR(g, r, p0, p1);
        genP[g] = p1;
        if ((q0 != 0) != (q1 != 0)) q1 != 0 ? partOrders++ : partOrders--;
        o.partR = q1;
        if (closing) {
            _setUpnl(o, 0); // закрытый ордер выходит из сумм открытых ДО смены состояния
            o.state = ST_CLOSED;
            genLive[g] -= 1;
            o.notional = 0;
            closedPidList.push(pid);
            closedPid[pid] = true;
            _unlistOrder(pid); // из живых — сразу, O(1); в книге до конца расчёта — буфером недели
            weekClosed[weekClosedN++] = pid;
            _maybeDead(g);
        } else {
            _setUpnl(o, _signed(upnl));
            o.notional = notional;
            _aggOrder(o, true);
            _signed(o.upnl + q1);
        }
        _signed(R[g] - p1);
        _signed(R[g] + genU[g]);
        _signed(R[g]);
        int256 vv = _venueValue();
        if (vv < 0) revert Revert("realize: value < 0");
        _stakeCeiling(0);
        withdrawable = _min(withdrawable, vv);
    }
}

/// @notice РЕД. 9.4 — ЗАМОРОЖЕННЫЙ ПУЛ (эталон `emergency_freeze`, `_emergency_planes`; спека 8.13, 8.14): заморозка, проход
/// итогов снимка пачками и этап MS_SNAP недельного расчёта. Вызывается ТОЛЬКО делегированным вызовом из PoolLedger (прямой
/// вызов читает пустого владельца и отклоняется `onlyOwner`).
/// МЕСТО — отдельная реализация, и это вывод из бюджета EIP-170 (замер `forge build --sizes`, HEAD 0e689c59): у
/// PoolLedgerMonday запас 370 Б — этап копии с её записями туда не помещается; PoolLedgerViews и PoolLedgerProj судятся
/// «только view» (их ABI не вправе писать в память бухгалтерии, selftest дифференциала); запас PoolLedger (2 861 Б) отведён
/// пакету и `mondayAbort`. Здесь — только записи; правило E (чтение) — витрина `emergencyDue` в PoolLedgerViews.
/// СНИМОК ДО MONDAY (заморозка посреди расчёта): эталон считает расчёт атомарным, и его снимок — состояние ДО `monday`. Строки
/// и фаза 2 переписывают плоскости и котёл, поэтому `mondayBegin` в той же транзакции копирует `f`, `s` каждого держателя и
/// итоги (MS_SNAP); веса поколений `p` расчёт до `mondayEnd` не трогает (`_finalizeGenerations` — в нём же) и читаются вживую.
/// Одной транзакцией, а не этапом пачек: этап до строк менял бы ход шагов (`mondayProgress`, число пачек) у keeper'а и
/// стендов, а держателей при границе адресов 43 — не больше ~87 (инвесторы, их рефералы, treasury); газ — стенд
/// `test_rev94_ms_snap_at_bound_under_25m`. Поднимать границу адресов — вместе с пачками здесь.
contract PoolLedgerEmergency is PoolLedgerBase {
    function emergencyFreeze() external onlyOwner {
        if (emState != 0) revert Revert("frozen");
        initialized = true; // `initPartner` закрыт навсегда
        // Σ весов поколений снимков = Σ p держателей (в снимок входит всякий, у кого p != 0) — ведущаяся сумма (ред. 9.5)
        emP = snapTotalSum;
        // неделя ДО расчёта: календарный открытый расчёт её уже сдвинул, внеочередной — нет (ред. 9.5)
        emWeek = mondayOpen && monCal ? week - 1 : week;
        if (mondayOpen) {
            (emCopy, emFT, emH, emF, emS, emState) = (true, msFT, msH, msF, msS, 2);
            return;
        }
        emFT = _emTreasury();
        emH = shortfall;
        emState = 1;
    }

    /// @notice Проход итогов снимка: `k` держателей за вызов; 0 — снимок готов.
    function emergencySnapStep(uint256 k) external onlyOwner returns (uint256) {
        if (emState != 1) revert Revert("emergency: no pass");
        if (k == 0) revert Revert("emergencySnapStep: k == 0");
        uint256 n = order.length + known.length;
        (uint256 end, int256 f, int256 s) = _snapBatch(emCur, k, emF, emS, false);
        (emCur, emF, emS) = (end, f, s);
        if (end < n) return n - end;
        emState = 2;
        return 0;
    }

    /// @notice MS_SNAP (заглушка `mondayBegin` PoolLedger зовёт сюда сразу после открытия расчёта, до первой строки): копия
    /// плоскостей держателей и итогов на начало расчёта.
    function mondayBegin() external onlyOwner {
        _msSnap();
    }

    /// @notice Ред. 9.5: та же копия для расчёта, открытого `mondayBegin(bool)` (заглушка PoolLedger отдаёт сюда тот же calldata).
    function mondayBegin(bool) external onlyOwner {
        _msSnap();
    }

    function _msSnap() internal {
        (, int256 f, int256 s) = _snapBatch(0, type(uint256).max, 0, 0, true);
        (msFT, msH, msF, msS) = (_emTreasury(), shortfall, f, s);
    }

    /// @dev Держатели [cur, cur + k): суммы `f`, `s` прочих (treasury — котёл, отдельно); `copy` — и копия адреса (MS_SNAP,
    /// пишется и ноль: адрес, у которого плоскости ушли, не несёт копию прошлой недели).
    function _snapBatch(uint256 cur, uint256 k, int256 f, int256 s, bool copy) internal returns (uint256 end, int256, int256) {
        end = _batchEnd(cur, k, order.length + known.length);
        for (uint256 i = cur; i < end; i++) {
            address a = _holderAt(i);
            if (a == address(0) || a == treasury) continue;
            (int256 fa, int256 sa) = _emLive(a);
            if (copy) (msFv[a], msSv[a]) = (fa, sa);
            f += fa;
            s += sa;
        }
        return (end, f, s);
    }
}

/// @notice ПРОЕКЦИИ «как если бы расчёт прошёл сейчас по маркам»: контекст `hold` (`_holdCtxLocal` — веса проекции,
/// вместимости, базы и должники раздела). Вызывается ТОЛЬКО через fallback PoolLedger (delegatecall) — статическим вызовом
/// бухгалтерии самой себя из `_holdCtx` любой реализации; прямой вызов читает пустую память и отдаёт пустой контекст.
/// Здесь живёт проекция веса (`sizeOrder`) и контекст `hold` гейтов — и её рост ред. 9.2.1/9.2.2 (черновик `_pay_back`
/// фазы 2) ложится только сюда. Только view (судит selftest дифференциала по ABI, как у витрин).
contract PoolLedgerProj is PoolLedgerBase {
    /// @notice Контекст `hold` гейтов (вывод, забор, выплата очереди, витрины): худший порядок, раздел после возвратов.
    function holdCtx() external view returns (HoldCtx memory c) {
        if (_noProjectedLoss()) return c;
        return _holdCtxLocal(false, _repayProjection());
    }

    /// @notice Веса снимка ордера, рассчитанного сейчас (эталон `weights()`), по позиции в `order`.
    function weights() external view returns (int256[] memory) {
        return _weightsLocal();
    }
}

/// @notice Витрины, геттеры и выгрузка. Вызываются ТОЛЬКО через fallback PoolLedger (delegatecall).
contract PoolLedgerViews is PoolLedgerBase {
    /// @notice Без `safe_now`: эталон считает его выводом на копии; дифференциал берёт его `eth_call` вывода.
    function investorView(address a) external view returns (int256[11] memory v) {
        _addr(a);
        Investor storage r = inv[a];
        if (!r.exists) revert Revert("investor_view: unknown");
        Proj memory P = _projected(a, false, false);
        int256 queued = _queuedOf(a, false);
        int256 gross = r.cumPnl + P.pend + P.unre;
        int256 cl = claimable[a];
        int256 value =
            _max(0, r.stake + queued + cl + _max(0, P.pend) - P.pendingLoss + P.unre - P.feeAccrued - r.uncovered);
        int256 openN;
        int256 mineN;
        for (uint256 i = 0; i < orderPids.length; i++) {
            Order storage o = orders[orderPids[i]];
            if (o.state == ST_OPEN) {
                openN += o.notional;
                mineN += _share(a, o.gen, o.notional);
            }
        }
        (int256 cnow,) = _claimNow(a);
        v[0] = r.deposited;
        v[1] = r.withdrawn;
        v[2] = value;
        v[3] = value + r.withdrawn - r.deposited;
        v[4] = cl;
        v[5] = cnow;
        v[6] = queued;
        v[7] = _max(0, r.hwm - gross + r.uncovered);
        v[8] = openN != 0 ? (mineN * BPS) / openN : int256(0);
        v[9] = r.payoutMode ? int256(1) : int256(0);
        v[10] = _projectedShortfall();
    }

    function referrerView(address a) external view returns (int256[6] memory v) {
        _addr(a);
        (, int256 rnow) = _claimNow(a);
        int256 invited;
        for (uint256 i = 0; i < order.length; i++) {
            if (inv[order[i]].referrer == a) invited++;
        }
        v[0] = rewardCash[a];
        v[1] = _queuedOf(a, true);
        v[2] = claimableReward[a];
        v[3] = rnow;
        v[4] = withdrawnReward[a];
        v[5] = invited;
    }

    function freeStake(address a, bool reward) external view returns (int256) {
        _addr(a);
        return _freeStake(a, reward);
    }

    /// @notice Зарегистрирован ли инвестор (`a in inv` эталона) — O(1). Хранилище решает по нему, первый ли это депозит адреса
    /// (реферал и режим выплат — только с первым); полная витрина `investorView` считала бы для этого проекцию.
    function isInvestor(address a) external view returns (bool) {
        return inv[a].exists;
    }

    /// @notice Ревью-2, #1: число поколений со снимками (`len(snaps)` эталона: до конца расчёта окончательное поколение остаётся в
    /// снимках). Ред. 9.5: газ расчёта и операций книги от него больше не растёт — его несут только строка должника (пачками) и
    /// проекции при должниках по маркам. O(1).
    function liveGenCount() external view returns (uint256) {
        return _snapCount();
    }

    /// @notice Ред. 9.5: (предел поколений `maxGens`, 0 — нет; поколений открыто с последнего расчёта; ЖИВЫХ — текущее и с
    /// живыми ордерами). Keeper проводит внеочередной расчёт `monday(false)`, когда второе дошло до ⌊maxGens/2⌋. O(1).
    function genLimits() external view returns (uint256, uint256, uint256) {
        return (maxGens, gensSince, lvN);
    }

    /// @notice Ревью-2, #3: история закрытых pid постранично — (всего, записи [from, from + n) с насыщением по длине); `from`
    /// за концом — пустая страница. Порядок — порядок закрытия (тот же, что в `dump()`).
    function closedPids(uint256 from, uint256 n) external view returns (uint256 total, bytes32[] memory page) {
        return _page(closedPidList, from, n);
    }

    /// @notice Ревью-2, #3: сожжённые записи леджера венью (депозиты, `coverShortfall`, возвраты) постранично — как `closedPids`.
    function ledgerRefs(uint256 from, uint256 n) external view returns (uint256 total, bytes32[] memory page) {
        return _page(ledgerRefList, from, n);
    }

    /// @notice Закрыт ли pid навсегда (`closedPid`) — O(1): keeper проверяет закрытие без чтения истории.
    function isClosedPid(bytes32 pid) external view returns (bool) {
        return closedPid[pid];
    }

    /// @notice Сожжена ли запись леджера венью (`ledgerRef`) — O(1).
    function isLedgerRef(bytes32 ref) external view returns (bool) {
        return ledgerRef[ref];
    }

    function _page(bytes32[] storage l, uint256 from, uint256 n)
        internal
        view
        returns (uint256 total, bytes32[] memory page)
    {
        total = l.length;
        uint256 k = from >= total ? 0 : (total - from <= n ? total - from : n);
        page = new bytes32[](k);
        for (uint256 i = 0; i < k; i++) {
            page[i] = l[from + i];
        }
    }

    function projectedShortfall() external view returns (int256) {
        return _projectedShortfall();
    }

    function sizingCapital() external view returns (int256 t) {
        int256[] memory w = _weightsRemote();
        for (uint256 i = 0; i < w.length; i++) {
            t += w[i];
        }
    }

    function weight(address a) external view returns (int256) {
        if (!inv[a].exists) return 0;
        return _weightsRemote()[uint256(inv[a].regIndex)];
    }

    /// @notice Всё состояние одним массивом int256; раскладку читает `contracts/diff/pool_ledger_diff.pytxt`.
    function dump() external view returns (int256[] memory out) {
        return _dump(closedPidList.length + ledgerRefList.length, true);
    }

    /// @notice Ревью-2, #3: то же состояние той же раскладкой, но БЕЗ растущей истории — длины списков закрытых pid и
    /// записей леджера = 0 (их читают постранично: `closedPids`, `ledgerRefs`). Газ не растёт с историей пула.
    function dumpState() external view returns (int256[] memory out) {
        return _dump(0, false);
    }

    /// @dev Голова (счётчики, инвесторы, держатели, поколения) и хвост (книга, история, очередь, партнёры, доплатившие) —
    /// разными функциями: у одной не хватает стека. `extra` — слов истории в выделяемом массиве (0 у `dumpState`).
    function _dump(uint256 extra, bool history) internal view returns (int256[] memory out) {
        uint256 p;
        uint256 nCred;
        (out, p, nCred) = _dumpHead(extra);
        p = _dumpTail(out, p, nCred, history);
        assembly {
            mstore(out, p)
        }
    }

    function _dumpHead(uint256 extra) internal view returns (int256[] memory out, uint256 p, uint256 nCred) {
        for (uint256 i = 0; i < order.length; i++) {
            address a = order[i];
            for (uint256 j = 0; j < order.length; j++) {
                if (cred[a][order[j]] != 0) nCred++;
            }
            if (credPool[a] != 0) nCred++;
        }
        uint256 nh = _holders();
        {
            uint256 cap = 24 + order.length * 15 + nh * 5 + partnerList.length * 4 + (orderPids.length + weekClosedN)
                * 7 + extra + _qCount() * 5 + nCred * 3;
            cap += _snapCount() * (4 + order.length * 5);
            out = new int256[](cap);
        }
        out[p++] = week;
        out[p++] = gen;
        out[p++] = nextQid;
        out[p++] = closedR;
        out[p++] = settledR;
        out[p++] = shortfall;
        out[p++] = spot;
        out[p++] = evm;
        out[p++] = venueCash;
        out[p++] = withdrawable;
        out[p++] = int256(order.length);
        for (uint256 i = 0; i < order.length; i++) {
            address a = order[i];
            Investor storage r = inv[a];
            out[p++] = int256(uint256(uint160(a)));
            out[p++] = r.stake;
            out[p++] = int256(uint256(uint160(r.referrer)));
            out[p++] = r.ever ? int256(1) : int256(0);
            out[p++] = r.payoutMode ? int256(1) : int256(0);
            out[p++] = r.exiting ? int256(1) : int256(0);
            out[p++] = r.deposited;
            out[p++] = r.withdrawn;
            out[p++] = r.cumPnl;
            out[p++] = r.hwm;
            out[p++] = r.firstWeek;
            out[p++] = r.regIndex;
            out[p++] = r.feesPaid;
            out[p++] = r.uncovered;
        }
        // плоскости держателей: инвесторы, затем остальные из `known` (нормальная форма дифференциала — словарь по адресу)
        out[p++] = int256(nh);
        for (uint256 i = 0; i < order.length + known.length; i++) {
            address a = _holderAt(i);
            if (a == address(0)) continue;
            out[p++] = int256(uint256(uint160(a)));
            out[p++] = claimable[a];
            out[p++] = claimableReward[a];
            out[p++] = rewardCash[a];
            out[p++] = withdrawnReward[a];
        }
        uint256 G = _snapCount();
        out[p++] = int256(G);
        for (uint256 i = 0; i < G; i++) {
            int256 g = _genAt(i);
            out[p++] = g;
            out[p++] = snapTotal[g];
            out[p++] = R[g];
            uint256 nsPos = p++;
            int256 ns;
            for (uint256 j = 0; j < snapN[g]; j++) {
                int256 w = snapW[g][order[j]];
                if (w == 0) continue;
                out[p++] = int256(uint256(uint160(order[j])));
                out[p++] = w;
                ns++;
            }
            out[nsPos] = ns;
            uint256 ncPos = p++;
            int256 nc;
            for (uint256 j = 0; j < order.length; j++) {
                address a = order[j];
                int256 v = _share(a, g, _colIsR(a) ? R[g] : rMon[g]); // `col` эталона (см. `shareSum`)
                if (v != 0) {
                    out[p++] = int256(uint256(uint160(order[j])));
                    out[p++] = v;
                    nc++;
                }
            }
            out[ncPos] = nc;
        }
    }

    function _dumpTail(int256[] memory out, uint256 p, uint256 nCred, bool history) internal view returns (uint256) {
        // книга эталона: живые ордера, затем закрытые с последнего расчёта (эталон держит их в `orders` до его конца)
        uint256 nLive = orderPids.length;
        out[p++] = int256(nLive + weekClosedN);
        for (uint256 i = 0; i < nLive + weekClosedN; i++) {
            bytes32 pid = i < nLive ? orderPids[i] : weekClosed[i - nLive];
            Order storage o = orders[pid];
            out[p++] = int256(uint256(pid));
            out[p++] = o.gen;
            out[p++] = int256(uint256(o.state));
            out[p++] = o.notional;
            out[p++] = o.upnl;
            out[p++] = o.sizedWeek;
            out[p++] = o.partR;
        }
        p = _dumpIds(out, p, closedPidList, history);
        p = _dumpIds(out, p, ledgerRefList, history);
        // очередь: заявки по ключам (инвесторы в порядке регистрации, затем reward-заявки держателей); порядок FIFO — id
        out[p++] = int256(_qCount());
        for (uint256 i = 0; i < order.length; i++) {
            p = _qDump(out, p, order[i], false);
        }
        for (uint256 i = 0; i < order.length + known.length; i++) {
            address a = _holderAt(i);
            if (a != address(0)) p = _qDump(out, p, a, true);
        }
        out[p++] = int256(partnerList.length);
        for (uint256 i = 0; i < partnerList.length; i++) {
            Partner storage q = partners[partnerList[i]];
            out[p++] = int256(uint256(uint160(partnerList[i])));
            out[p++] = int256(uint256(q.state));
            out[p++] = q.sinceWeek;
            out[p++] = q.hasRevokedAt ? q.revokedAtOrder : int256(-1);
        }
        // книга доплативших: (должник, доплативший, сумма); доплативший — нулевой адрес = счёт пула
        out[p++] = int256(nCred);
        for (uint256 i = 0; i < order.length; i++) {
            address a = order[i];
            for (uint256 j = 0; j < order.length; j++) {
                int256 x = cred[a][order[j]];
                if (x != 0) {
                    out[p++] = int256(uint256(uint160(a)));
                    out[p++] = int256(uint256(uint160(order[j])));
                    out[p++] = x;
                }
            }
            if (credPool[a] != 0) {
                out[p++] = int256(uint256(uint160(a)));
                out[p++] = 0;
                out[p++] = credPool[a];
            }
        }
        return p;
    }

    /// @dev Список истории в выгрузку: длина и записи; `on = false` — длина 0 (`dumpState`).
    function _dumpIds(int256[] memory out, uint256 p, bytes32[] storage l, bool on) internal view returns (uint256) {
        uint256 n = on ? l.length : 0;
        out[p++] = int256(n);
        for (uint256 i = 0; i < n; i++) {
            out[p++] = int256(uint256(l[i]));
        }
        return p;
    }

    /// @notice Ред. 9.4: готовый снимок замороженного пула одним массивом — ключ `emergency` эталона: неделя, F_T, H, E, S, P,
    /// число держателей и по каждому (адрес, f, s, p). Отдельно от `dump()`: раскладку той читают по хвосту стенды и keeper.
    function emergencyDump() external view returns (int256[] memory out) {
        if (emState != 2) revert Revert("emergency: no snapshot");
        out = new int256[](7 + (order.length + known.length) * 4);
        uint256 p;
        out[p++] = emWeek;
        out[p++] = emFT;
        out[p++] = emH;
        out[p++] = emF + emS;
        out[p++] = emS;
        out[p++] = emP;
        uint256 nPos = p++;
        int256 c;
        for (uint256 i = 0; i < order.length + known.length; i++) {
            address a = _holderAt(i);
            if (a == address(0) || a == treasury) continue;
            (int256 f, int256 s) = _emPlanes(a);
            int256 w = _emPart(a);
            if (f == 0 && s == 0 && w == 0) continue;
            out[p++] = int256(uint256(uint160(a)));
            out[p++] = f;
            out[p++] = s;
            out[p++] = w;
            c++;
        }
        out[nPos] = c;
        assembly {
            mstore(out, p)
        }
    }

    // --- ред. 9.4: правило E ---------------------------------------------------------------------------------------- //
    /// @notice ПРАВИЛО E (эталон `emergency_split`, ЕДИНСТВЕННЫЙ владелец формулы в контракте): сколько адресу `a` причитается
    /// ВСЕГО при накопленных деньгах раздачи `m` (микро, `M_cum` хранилища). Котёл treasury — первым против убытка, который
    /// вмещает капитал прочих, но младше дыры пула и фиксированных плоскостей прочих (КЕ13′):
    /// due_T = max(0, min(F_T − H, M − F_o)); остаток r = M − due_T против E = Σ(f + s): r <= E — убыток пропорционально всем
    /// плоскостям, floor(r·(f + s)/E); r > E — прибыль только капиталу, f + s + floor((r − E)·s/S); S = 0 — по весу в живых
    /// поколениях (p/P); нет и их — излишек котлу. Адрес вне снимка — 0. Округление вниз, `mulDiv` 512-битный. Минимумов нет
    /// (MX3). Монотонна по `m`: тянущая раздача «заплатить due − выплаченное» от порядка не зависит.
    function emergencyDue(address a, uint256 m) external view returns (uint256) {
        if (emState != 2) revert Revert("emergency: no snapshot");
        _addr(a);
        int256 M = _amount(m);
        int256 S = emS;
        int256 E = emF + S;
        int256 t = _max(0, _min(emFT - emH, M - emF));
        int256 r = M - t; // >= 0: t <= max(0, M − F_o) <= M
        if (a == treasury) return uint256(S != 0 || emP != 0 || r <= E ? t : M - E);
        (int256 f, int256 s) = _emPlanes(a);
        if (r <= E) return E == 0 ? 0 : _mulDiv(uint256(r), uint256(f + s), uint256(E));
        uint256 base = uint256(f + s);
        if (S != 0) return base + _mulDiv(uint256(r - E), uint256(s), uint256(S));
        return emP == 0 ? base : base + _mulDiv(uint256(r - E), uint256(_emPart(a)), uint256(emP));
    }

    /// @notice Доли адреса в снимке: (f, s, p) — `emergency_planes` витрины эталона.
    function emergencyPlanes(address a) external view returns (int256 f, int256 s, int256 p) {
        if (emState != 2) revert Revert("emergency: no snapshot");
        _addr(a);
        if (a == treasury) return (0, 0, 0);
        (f, s) = _emPlanes(a);
        p = _emPart(a);
    }

    /// @notice Состояние аварии: [0] 0 живой / 1 идёт проход итогов / 2 снимок готов, [1] доли из копии MS_SNAP, [2] пройдено
    /// держателей, [3] неделя снимка, [4] F_T, [5] H, [6] E, [7] S, [8] P.
    function emergencyTotals() external view returns (int256[9] memory v) {
        (v[0], v[1], v[2], v[3]) = (int256(uint256(emState)), emCopy ? int256(1) : int256(0), int256(emCur), emWeek);
        (v[4], v[5], v[6], v[7], v[8]) = (emFT, emH, emF + emS, emS, emP);
    }

    /// @notice В7′: id старейшей живой заявки ИНВЕСТОРА в очереди бухгалтерии (эталон `serve_starved` — голова заявок
    /// инвесторов); −1 — заявок нет. Время подачи по id ведёт хранилище (журнал `qStamps`).
    function oldestQueued() external view returns (int256 id) {
        id = -1;
        for (uint256 i = 0; i < order.length; i++) {
            address a = order[i];
            if (queuedInv[a] == 0) continue;
            int256 q = int256(qE[a][false][qh[a][false].head] & Q_ID);
            if (id < 0 || q < id) id = q;
        }
    }

    /// @dev Доли адреса: копия MS_SNAP при заморозке посреди расчёта, иначе — замороженные плоскости.
    function _emPlanes(address a) internal view returns (int256, int256) {
        return emCopy ? (msFv[a], msSv[a]) : _emLive(a);
    }

    /// @dev Участие `p`: сумма весов адреса в снимках поколений (их расчёт до `mondayEnd` не трогает).
    function _emPart(address a) internal view returns (int256 w) {
        uint256 G = _snapCount();
        for (uint256 i = 0; i < G; i++) {
            w += snapW[_genAt(i)][a];
        }
    }

    function _qCount() internal view returns (uint256 c) {
        for (uint256 i = 0; i < order.length; i++) {
            c += _qLen(order[i], false);
        }
        for (uint256 i = 0; i < order.length + known.length; i++) {
            address a = _holderAt(i);
            if (a != address(0)) c += _qLen(a, true);
        }
    }

    function _holders() internal view returns (uint256 c) {
        for (uint256 i = 0; i < order.length + known.length; i++) {
            if (_holderAt(i) != address(0)) c++;
        }
    }

    /// @dev Живых заявок ключа: от головы до хвоста полосы.
    function _qLen(address a, bool reward) internal view returns (uint256) {
        int256 q = _queuedOf(a, reward);
        if (q == 0) return 0;
        QHead storage h = qh[a][reward];
        return _qTail(a, reward, h, h.P + q) - h.head + 1;
    }

    /// @dev Живые заявки ключа (id, адрес, остаток, reward, неделя): остаток записи — её часть полосы в (P, P + queued].
    function _qDump(int256[] memory out, uint256 p, address a, bool reward) internal view returns (uint256) {
        int256 q = _queuedOf(a, reward);
        if (q == 0) return p;
        QHead storage h = qh[a][reward];
        int256 P = h.P;
        int256 L = P + q;
        uint256 t = _qTail(a, reward, h, L);
        for (uint256 i = h.head; i <= t; i++) {
            int256 lo = i == h.head ? P : _qEnd(a, reward, i - 1);
            out[p++] = int256(qE[a][reward][i] & Q_ID);
            out[p++] = int256(uint256(uint160(a)));
            out[p++] = _min(_qEnd(a, reward, i), L) - lo;
            out[p++] = reward ? int256(1) : int256(0);
            out[p++] = qWeek[a][reward][i];
        }
        return p;
    }

    /// @notice Ход недельного расчёта для keeper'а: этап (0 строки, 1 реферальные доли, 2 возвраты, 3 соучастники, 4 «весь
    /// пул», 5 таблица «весь пул», 6 — осталось `mondayEnd`), сколько единиц этапа сделано и осталось, открыт ли расчёт.
    /// У возвратов «осталось» может не убывать: работа цепочки дописывает новые в хвост.
    function mondayProgress() external view returns (uint256 stage, uint256 done, uint256 left, bool open) {
        uint8 s = monStage;
        return (s, s == MS_ROWS ? mondayCursor + monRowUnits : s == MS_MATES || s == MS_NET ? monUnitsDone : monCur, _stageLeft(),
            mondayOpen);
    }

    /// @notice Параметры: owner, treasury, bufferBps, feeBps, refShareBps, holdBps, openRefShareBps, partnerTermWeeks.
    function params() external view returns (address, address, int256, int256, int256, int256, int256, int256) {
        return (owner, treasury, bufferBps, feeBps, refShareBps, holdBps, openRefShareBps, partnerTermWeeks);
    }

    /// @notice Правила пакета безопасности: минимум депозита (микро) и предел адресов.
    function limits() external view returns (int256, uint256) {
        return (minDeposit, maxInvestors);
    }

    /// @notice Капитал под управлением (Σ капитала инвесторов, микро; эталон `total_stake`) — мера лимита TVL хранилища
    /// (A10: «капитал + депозит»). Одно чтение памяти.
    function totalStake() external view returns (int256) {
        return stakeSum;
    }

    /// @notice Счётчики массивом: initialized, week, gen, closedR, settledR, shortfall, nextQid, spot, evm, venueCash, withdrawable, mondayOpen, mondayCursor.
    function status() external view returns (int256[13] memory v) {
        v[0] = initialized ? int256(1) : int256(0);
        v[1] = week;
        v[2] = gen;
        v[3] = closedR;
        v[4] = settledR;
        v[5] = shortfall;
        v[6] = nextQid;
        v[7] = spot;
        v[8] = evm;
        v[9] = venueCash;
        v[10] = withdrawable;
        v[11] = mondayOpen ? int256(1) : int256(0);
        v[12] = int256(mondayCursor);
    }
}
