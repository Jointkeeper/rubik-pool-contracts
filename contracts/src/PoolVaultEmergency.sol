// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {CoreWriterLib} from "hyper-evm-lib/CoreWriterLib.sol";
import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";
import {PoolLedger, PoolLedgerViews} from "./PoolLedger.sol";
import {TradingLeg} from "./TradingLeg.sol";

/// @dev Память модуля в памяти ХРАНИЛИЩА — отдельным слотом (по образцу EIP-7201), а не общей раскладкой: хранилище и модуль
/// не делят переменных, и раскладка `PoolVault` (её правят и другие планы) модулю безразлична. Хранилище читает отсюда ровно
/// одно — младший байт слова (`state`): замок аварии в своих входах.
bytes32 constant EMERGENCY_SLOT = bytes32(uint256(keccak256("rubik.pool.vault.emergency.v1")) - 1);
/// @dev Объявление аварии admin'ом — вид предложения общего таймлока хранилища и его хеш. Пространство видов одно на всё
/// хранилище (таблица — `PoolVault`, README «Таймлок: виды предложений»): 3 и 4 — agent-ключи ног, 5 — доля ног, 6 — предел
/// адресов, поэтому авария — 7.
uint256 constant P_EMERGENCY = 7;
bytes32 constant EMERGENCY_HASH = keccak256("rubik.pool.vault.emergency.announce");

/// @dev Адрес, который не может быть ни рефералом, ни получателем денег пула (ревью 20.10, F3; ЕДИНСТВЕННЫЙ владелец набора —
/// его зовут `PoolVault.register`, `PoolVault.refundDeposit` и `emergencyClaim`): само хранилище, его ноги и бухгалтерия
/// (выплата на ногу или хранилище возвращается сбором `emergencyCollect` и считалась бы в M_cum дважды — уже выплаченной и
/// снова на счёте; у бухгалтерии ключа нет), системные адреса токенов Core (`0x20…` + индекс, у HYPE — `0x2222…`: `spotSend`
/// на них переводит деньги на EVM-сторону отправителя мимо бухгалтерии). Treasury законна: доля реферала-treasury уходит в
/// котёл (эталон), в аварии котёл — получатель по правилу E.
function poolSink(address a, address vault, address legA, address legB, address ledger) pure returns (bool) {
    return a == vault || a == legA || a == legB || a == ledger || uint160(a) >> 64 == uint160(0x20) << 88
        || a == 0x2222222222222222222222222222222222222222;
}

/// @dev Часы триггеров аварии — одно слово памяти хранилища (пишет `PoolVault`, читает модуль через `emergencyClock`).
struct EmergencyClock {
    uint64 keeperAt; //      последняя успешная операция keeper'а
    uint64 mondayBeganAt; // открытие недельного расчёта пачками
    uint64 mondayEndAt; //   последний закрытый расчёт; до первого — первый депозит; 0 — денег в пуле ещё не было
    uint64 qSeen; //         `nextQid` бухгалтерии после последней операции keeper'а
}

/// @notice Что модуль читает у хранилища — внешним вызовом хранилища самого себя (модуль исполняется на его памяти, но
/// своих immutable хранилища не видит: у делегированного кода они свои).
interface IPoolVaultForEmergency {
    function ledger() external view returns (PoolLedger);
    function legA() external view returns (TradingLeg);
    function legB() external view returns (TradingLeg);
    function windows(uint256) external view returns (uint64, uint64, uint64, bool);
    function confirmLegSend(uint256 leg) external;
    function confirmSweep() external;
    /// @dev U_s на заморозке: излишек со ЗНАКОМ не разнесённого с ног (ревью F2, эталон `emergency_foreign`).
    function vaultSlackSigned() external view returns (int256);
    function proposals(uint256) external view returns (bytes32, uint256);
    function qStamps(uint256) external view returns (uint256);
    function emergencyClock()
        external
        view
        returns (EmergencyClock memory c, uint256 oldestIntentAt, uint256 outPendingWei, uint256 nStamps);
    /// @dev G2 хранилища. Триггер аварии её НЕ читает (ревью 20.10): объявлена для мутанта «вернуть условие ликвидности».
    function physicalWithdrawable() external view returns (uint256);
}

/// @title PoolVaultEmergency — аварийный выход пула «замороженный пул» (ред. 9.4, план доверия §4.3, спека 8.13-8.14).
/// @notice Делегированный модуль хранилища (КЕ10): исполняется `delegatecall` из `PoolVault` (fallback) на ЕГО памяти — та же
/// модель, что `PoolLedgerMonday` у бухгалтерии. Прямой вызов модуля отклоняется: у него нет ни бухгалтерии, ни ног (вызов
/// хранилища самого себя упадёт на первом же геттере).
///
/// ТРИГГЕРЫ (любой; заморозка необратима; сроки — immutable конструктора из параметров деплоя, умолчаний нет):
///   1 `T_stuck` — открытый расчёт пачками старше срока;  2 `T_dead` — ни одной успешной операции keeper'а за срок;
///   3 `T_nomonday` — нет закрытого расчёта за срок (отсчёт от первого депозита до первого расчёта);
///   4 `T_serve` — старейшая неисполненная заявка хранилища (`intents[nextIntent]`) старше срока;
///   (1-4 — только после первого зачисленного депозита: пул без денег бездействием не замораживается; расчёт до него часов
///   не запускает — ревью 20.10, R6)
///   5 В7′ — старейшая заявка ИНВЕСТОРА в очереди бухгалтерии старше `T_queue_max` (ревью 20.10: БЕЗ сравнения
///     `withdrawable` с физически выводимым — ту величину двигают посторонний донатом на ногу и торговый ключ удержанием
///     spot/маржи). Честный keeper обязан обслужить очередь до срока, при необходимости частично закрывая позиции;
///   6 объявление admin'а через общий таймлок хранилища (`proposeEmergency`, `DELAY`; guardian вправе отменить в окне).
/// Вызвать `emergencyFreeze` может любой: триггер судит контракт, а не вызывающий.
///
/// ДЕНЬГИ (эталон `EmergencyVault`): U_s = core − outPending − held − fromLegsArrived фиксируется на заморозке (`vaultSlackSigned`
/// хранилища: излишек G1, но не разнесённое с ног — со знаком, без обрезки нулём; ревью F2); M_cum = core − outPending + paidTotal − U_s; `emergencyClaim(a)` — любой за любого,
/// деньги только на `a`: `due(a, M_cum) − paid_a` по правилу E бухгалтерии (`emergencyDue`). Внутри блока выплаты M_cum не
/// меняется (В4: `− outPending`), растёт только приходом денег — итог от порядка и группировки забираний не зависит.
contract PoolVaultEmergency {
    uint64 internal constant USDC = 0;
    uint256 internal constant WEI_PER_MICRO = 100;

    uint8 internal constant W_STUCK = 1;
    uint8 internal constant W_DEAD = 2;
    uint8 internal constant W_NOMONDAY = 3;
    uint8 internal constant W_INTENT = 4;
    uint8 internal constant W_QUEUE = 5;
    uint8 internal constant W_ANNOUNCED = 6;

    /// @notice Сроки триггеров (секунды) — параметры деплоя (`deploy/params.*.json`), конструктор хранилища требует каждый
    /// не меньше `2·DELAY` (ревью-2, #5: замена keeper'а таймлоком обязана успеть до аварии с запасом).
    uint256 public immutable T_STUCK;
    uint256 public immutable T_DEAD;
    uint256 public immutable T_NOMONDAY;
    uint256 public immutable T_SERVE;
    /// @notice В7′: предельный возраст заявки инвестора в очереди бухгалтерии (ревью 20.10).
    uint256 public immutable T_QUEUE_MAX;

    struct Store {
        uint8 state; //       0 — пул живой, 1 — заморожен (младший байт слова читает хранилище)
        uint8 why; //         сработавший триггер
        uint64 frozenAt;
        uint64 outBlock; //   исходящие выплаты модуля в блоке `outBlock` (прекомпайл их ещё видит)
        uint256 outWei;
        uint256 foreign; //   U_s, wei: чужое на хранилище на момент заморозки
        uint256 paidTotal; // выплачено всего, микро
        mapping(address => uint256) paid; // выплачено адресу, микро
    }

    event EmergencyFrozen(uint8 indexed why, int256 slackWei, uint256 foreignWei);
    event EmergencyPaid(address indexed to, uint256 amount, uint256 mCum);
    event EmergencyCollected(uint256 indexed leg, uint64 toSpotUsd, uint64 toVaultWei);

    error ZeroTerm();
    error Frozen();
    error NotFrozen();
    error NoTrigger();
    error NotActivated(address account);
    error BadLeg(uint256 leg);
    error BadRecipient(address to);

    constructor(uint256 tStuck, uint256 tDead, uint256 tNomonday, uint256 tServe, uint256 tQueueMax) {
        if (tStuck == 0 || tDead == 0 || tNomonday == 0 || tServe == 0 || tQueueMax == 0) revert ZeroTerm();
        (T_STUCK, T_DEAD, T_NOMONDAY, T_SERVE, T_QUEUE_MAX) = (tStuck, tDead, tNomonday, tServe, tQueueMax);
    }

    /// @notice Наименьший срок — его сверяет с `2·DELAY` конструктор хранилища.
    function minTerm() external view returns (uint256 m) {
        m = T_STUCK;
        if (T_DEAD < m) m = T_DEAD;
        if (T_NOMONDAY < m) m = T_NOMONDAY;
        if (T_SERVE < m) m = T_SERVE;
        if (T_QUEUE_MAX < m) m = T_QUEUE_MAX;
    }

    function _st() internal pure returns (Store storage s) {
        bytes32 slot = EMERGENCY_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function _vault() internal view returns (IPoolVaultForEmergency) {
        return IPoolVaultForEmergency(address(this));
    }

    // --- триггеры ----------------------------------------------------------------------------------------------------- //
    /// @notice Какой триггер аварии верен сейчас (0 — ни один). Порядок проверки — порядок номеров.
    function emergencyTrigger() public view returns (uint8) {
        IPoolVaultForEmergency V = _vault();
        (EmergencyClock memory c, uint256 oldestIntentAt,, uint256 nStamps) = V.emergencyClock();
        int256[13] memory s = PoolLedgerViews(address(V.ledger())).status();
        uint256 now_ = block.timestamp;
        // пул без денег (до первого зачисленного депозита) не замораживается ни одним сроком: иначе любой запер бы ещё не
        // запущенный пул (ревью 20.10, R6: и расчёт, и его открытие до первого депозита часов не запускают)
        bool started = c.mondayEndAt != 0;
        if (started && s[11] != 0 && c.mondayBeganAt != 0 && now_ >= c.mondayBeganAt + T_STUCK) return W_STUCK;
        if (started && now_ >= c.keeperAt + T_DEAD) return W_DEAD;
        if (started && now_ >= c.mondayEndAt + T_NOMONDAY) return W_NOMONDAY;
        if (started && oldestIntentAt != 0 && now_ >= oldestIntentAt + T_SERVE) return W_INTENT;
        if (_queueOverdue(V, nStamps, now_)) return W_QUEUE;
        (bytes32 h, uint256 eta) = V.proposals(P_EMERGENCY);
        if (h == EMERGENCY_HASH && now_ >= eta) return W_ANNOUNCED;
        return 0;
    }

    /// @dev В7′: время подачи старейшей заявки инвестора — по журналу хранилища `qStamps` (слово = первый id операции << 64 |
    /// время; заявки бухгалтерии рождаются только в операциях keeper'а, и журнал пишется после каждой). Последняя запись с
    /// первым id <= искомого — двоичным поиском. Прекомпайлов ветка не читает: ни касса ног, ни их активация на Core на
    /// триггер не влияют (ревью 20.10, R7).
    function _queueOverdue(IPoolVaultForEmergency V, uint256 n, uint256 now_) internal view returns (bool) {
        int256 q = PoolLedgerViews(address(V.ledger())).oldestQueued();
        if (q < 0 || n == 0) return false;
        uint256 lo;
        uint256 hi = n;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (V.qStamps(mid) >> 64 <= uint256(q)) lo = mid;
            else hi = mid;
        }
        return now_ >= uint64(V.qStamps(lo)) + T_QUEUE_MAX;
    }

    // --- заморозка ---------------------------------------------------------------------------------------------------- //
    /// @notice Заморозка (любой вызывающий при верном триггере): окна переводов ног прежних блоков подтверждаются (их деньги
    /// либо пришли и принадлежат держателям, либо остались на ноге), бухгалтерия замораживается, U_s фиксируется. Окно ТЕКУЩЕГО
    /// блока не подтверждается: его перевод ещё в пути — исходящий уже в `outPending`, входящий придёт и поднимет M_cum.
    function emergencyFreeze() external returns (uint8 why) {
        Store storage st = _st();
        if (st.state != 0) revert Frozen();
        why = emergencyTrigger();
        if (why == 0) revert NoTrigger();
        IPoolVaultForEmergency V = _vault();
        for (uint256 i = 0; i < 2; i++) {
            (uint64 b,,, bool fromLeg) = V.windows(i);
            if (b == 0 || b >= block.number) continue;
            if (fromLeg) V.confirmLegSend(i);
            else V.confirmSweep();
        }
        V.ledger().emergencyFreeze();
        // U_s — со знаком не разнесённого с ног (F2): вывод, оплаченный из ликвидности ног до прихода денег с них, не делает
        // чужой незачтённый Send деньгами держателей. Излишек < 0 — Core списал с хранилища мимо бухгалтерии: выход не
        // запирается, держатели получат пропорционально меньше, событие называет недостачу
        int256 slack = V.vaultSlackSigned();
        st.foreign = slack > 0 ? uint256(slack) : 0;
        (st.state, st.why, st.frozenAt) = (1, why, uint64(block.timestamp));
        emit EmergencyFrozen(why, slack, st.foreign);
    }

    /// @notice Проход итогов снимка бухгалтерии (любой вызывающий): `k` держателей; 0 — снимок готов, забирания открыты.
    function emergencySnapStep(uint256 k) external returns (uint256) {
        if (_st().state == 0) revert NotFrozen();
        return _vault().ledger().emergencySnapStep(k);
    }

    // --- раздача ------------------------------------------------------------------------------------------------------ //
    /// @dev M_cum (микро) с исправлением В4: прекомпайл видит баланс начала блока, исходящие блока (хранилища до заморозки и
    /// выплаты модуля) уже в `paidTotal`, поэтому вычитаются. Чужое U_s не раздаётся никогда.
    function _mCum(Store storage st, uint256 vaultOut) internal view returns (uint256) {
        uint256 out = vaultOut + (st.outBlock == block.number ? st.outWei : 0);
        int256 w = int256(uint256(PrecompileLib.spotBalance(address(this), USDC).total)) - int256(out)
            + int256(st.paidTotal * WEI_PER_MICRO) - int256(st.foreign);
        return w > 0 ? uint256(w) / WEI_PER_MICRO : 0;
    }

    function _due(Store storage st, address a) internal view returns (uint256 m, uint256 due) {
        IPoolVaultForEmergency V = _vault();
        (,, uint256 vaultOut,) = V.emergencyClock();
        m = _mCum(st, vaultOut);
        due = PoolLedgerViews(address(V.ledger())).emergencyDue(a, m);
    }

    /// @notice Забрать долю за `a` (любой вызывающий, деньги — только на `a`): `due(a, M_cum) − выплаченное`. Минимумов нет
    /// (MX3). Адрес не на Core — отказ (комиссия активации легла бы на хранилище); активировать его может любой перевод.
    function emergencyClaim(address a) external returns (uint256 pay) {
        Store storage st = _st();
        if (st.state == 0) revert NotFrozen();
        IPoolVaultForEmergency V = _vault();
        if (poolSink(a, address(this), address(V.legA()), address(V.legB()), address(V.ledger()))) {
            revert BadRecipient(a);
        }
        if (!PrecompileLib.coreUserExists(a)) revert NotActivated(a);
        (uint256 m, uint256 due) = _due(st, a);
        uint256 paid = st.paid[a];
        if (due <= paid) return 0;
        pay = due - paid;
        st.paid[a] = due;
        st.paidTotal += pay;
        uint256 w = pay * WEI_PER_MICRO;
        uint256 cur = st.outBlock == block.number ? st.outWei : 0;
        (st.outBlock, st.outWei) = (uint64(block.number), cur + w);
        CoreWriterLib.spotSend(a, USDC, uint64(w)); // w <= баланс хранилища (uint64 Core): Σ due <= M_cum
        emit EmergencyPaid(a, pay, m);
    }

    /// @notice Витрина: (M_cum, доля адреса при нём, выплачено адресу), микро.
    function emergencyStatus(address a) external view returns (uint256 mCum, uint256 due, uint256 paid) {
        Store storage st = _st();
        if (st.state == 0) revert NotFrozen();
        (mCum, due) = _due(st, a);
        paid = st.paid[a];
    }

    /// @notice Итоги хранилища в аварии: (состояние, триггер, время заморозки, U_s wei, выплачено всего микро).
    function emergencyState() external view returns (uint8, uint8, uint64, uint256, uint256) {
        Store storage st = _st();
        return (st.state, st.why, st.frozenAt, st.foreign, st.paidTotal);
    }

    /// @notice Деньги ног — на хранилище (любой вызывающий, после заморозки): выводимое perp ноги — на её spot, свободный spot —
    /// хранилищу. Действия CoreWriter исполняются после блока: perp, переведённый в этом блоке, уйдёт следующим вызовом.
    /// Пришедшее поднимает M_cum, и каждый дотягивает разницу. Закрытие позиций ног (ликвидация) — НЕ здесь (не перенесено).
    function emergencyCollect(uint256 leg) external {
        if (_st().state == 0) revert NotFrozen();
        if (leg > 1) revert BadLeg(leg);
        TradingLeg l = leg == 0 ? _vault().legA() : _vault().legB();
        // нога не на Core денег не имеет — пустой проход без чтения её прекомпайлов (ревью 20.10, R7)
        if (!PrecompileLib.coreUserExists(address(l))) {
            emit EmergencyCollected(leg, 0, 0);
            return;
        }
        uint64 w = PrecompileLib.withdrawable(address(l));
        if (w != 0) l.toSpot(w);
        PrecompileLib.SpotBalance memory b = PrecompileLib.spotBalance(address(l), USDC);
        uint64 free = b.total > b.hold ? b.total - b.hold : 0;
        if (free != 0) l.sendToVault(free);
        emit EmergencyCollected(leg, w, free);
    }
}
