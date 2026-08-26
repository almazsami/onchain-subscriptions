// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Subscription — контракт подписки стенда «Минута»
/// @notice Pull-модель: подписчик выдает разрешение (`approve`), контракт по
///         вызову извне забирает фиксированную сумму за один период и сразу
///         переводит ее получателю. Реализует разделы 3-9 спецификации.
/// @dev Учебный стенд, а не продакшн. Контракт средств не хранит, функции
///      вывода нет, владельца нет.
contract Subscription {
    using SafeERC20 for IERC20;

    // --- Хранение (раздел 4) ---

    /// @notice Запись подписки по адресу подписчика.
    /// @dev Имена полей — ровно как в разделе 4 спецификации. Тип назван
    ///      `SubscriptionRecord`, а не `Subscription`: имя `Subscription`
    ///      уже занято самим контрактом.
    struct SubscriptionRecord {
        /// Запись по этому адресу когда-либо создавалась. Состояния
        /// подписки не описывает.
        bool exists;
        /// Подписка прекращена — подписчиком или по пределу просрочки.
        bool canceled;
        /// Момент оформления подписки.
        uint256 startedAt;
        /// Граница оплаченного периода: до этого момента есть доступ,
        /// с этого момента можно списывать.
        uint256 paidUntil;
        /// Сколько списаний прошло успешно.
        uint256 periodsPaid;
        /// Длина текущей серии неудачных попыток; успешное списание
        /// обнуляет счетчик.
        uint256 failedAttempts;
        /// Причина последней неудачи: 0 — отсутствует, 1 — не хватает
        /// разрешения, 2 — не хватает баланса. Успешное списание обнуляет.
        uint8 lastFailureReason;
    }

    /// @notice Записи подписок по адресу подписчика. Контракт один на всех.
    mapping(address => SubscriptionRecord) public subscriptions;

    // --- Причины неудачи (раздел 4) ---

    uint8 public constant REASON_NONE = 0;
    uint8 public constant REASON_ALLOWANCE = 1;
    uint8 public constant REASON_BALANCE = 2;

    // --- Предел просрочки (раздел 7) ---

    /// @notice При `debtPeriods >= 6` списание не выполняется ни при каких
    ///         условиях, подписка прекращается.
    uint256 public constant MAX_DEBT_PERIODS = 6;

    // --- Параметры, фиксируемые при деплое (разделы 2, 7, 11) ---

    /// @notice Токен стенда. Фиксируется при деплое и не меняется.
    IERC20 public immutable token;
    /// @notice Адрес, на который уходят деньги при списании. Фиксируется
    ///         при деплое и не меняется.
    address public immutable recipient;
    /// @notice Цена одного периода в базовых единицах токена.
    uint256 public immutable periodPrice;
    /// @notice Длина периода в секундах — 60. Фиксируется при деплое.
    uint256 public immutable periodLength;

    // --- События (раздел 9) ---

    event Subscribed(address subscriber, uint256 startedAt, uint256 paidUntil);

    event ChargeSucceeded(
        address subscriber, address caller, uint256 amount, uint256 periodNumber, uint256 newPaidUntil
    );

    event ChargeFailed(address subscriber, address caller, uint8 reason, uint256 attemptNumber, uint256 debtPeriods);

    event CanceledBySubscriber(address subscriber, uint256 paidUntil);

    event TerminatedForOverdue(address subscriber, uint256 debtPeriods);

    constructor(IERC20 token_, address recipient_, uint256 periodPrice_, uint256 periodLength_) {
        token = token_;
        recipient = recipient_;
        periodPrice = periodPrice_;
        periodLength = periodLength_;
    }

    // --- Оформление (раздел 8) ---

    /// @notice Оформляет подписку и сразу делает первое списание: это один
    ///         вызов. Не прошло списание — подписки нет.
    /// @dev Повторная подписка тем же адресом пишет запись с нуля, счетчики
    ///      прошлой записи не переносятся.
    function subscribe() external {
        SubscriptionRecord storage record = subscriptions[msg.sender];

        // Попытка оформить подписку адресом, у которого уже есть
        // неотмененная подписка, откатывается.
        require(!record.exists || record.canceled, "subscription already active");

        // При оформлении проверяется, что разрешения хватает минимум
        // на один период, иначе оформление откатывается. Разрешение
        // на несколько периодов вперед не требуется.
        require(token.allowance(msg.sender, address(this)) >= periodPrice, "allowance below period price");

        uint256 startedAt = block.timestamp;
        uint256 paidUntil = startedAt + periodLength;

        record.exists = true;
        record.canceled = false;
        record.startedAt = startedAt;
        record.paidUntil = paidUntil;
        record.periodsPaid = 1;
        record.failedAttempts = 0;
        record.lastFailureReason = REASON_NONE;

        // Нехватка баланса откатывает весь вызов, и записи не остается:
        // состояния с periodsPaid = 0 не существует.
        token.safeTransferFrom(msg.sender, recipient, periodPrice);

        // Оформление содержит первое списание, и оно должно быть видно
        // в логах наравне со всеми остальными: сначала Subscribed,
        // затем ChargeSucceeded с periodNumber = 1.
        emit Subscribed(msg.sender, startedAt, paidUntil);
        emit ChargeSucceeded(msg.sender, msg.sender, periodPrice, 1, paidUntil);
    }

    // --- Списание (раздел 6) ---

    /// @notice Списывает ровно один период по подписке указанного адреса.
    ///         Вызвать может любой адрес, без ограничений.
    /// @dev Проверки идут строго сверху вниз, первое совпавшее условие
    ///      определяет исход, дальше проверки не идут. Порядок — раздел 6
    ///      спецификации, пути 1-6.
    function charge(address subscriber) external {
        SubscriptionRecord storage record = subscriptions[subscriber];

        // Путь 1: записи нет.
        require(record.exists, "no subscription");

        // Путь 2: подписка прекращена. Выше проверки предела просрочки,
        // поэтому повторный вызов по прекращенной подписке дает revert,
        // а не второе событие прекращения.
        require(!record.canceled, "subscription canceled");

        // Путь 3: срок еще не наступил. Предоплата вперед не предусмотрена.
        // Вызов ровно в секунду наступления срока успешен.
        require(block.timestamp >= record.paidUntil, "period not due yet");

        // Проверка срока выше проверки предела, поэтому debtPeriods
        // считается только там, где paidUntil <= текущее_время,
        // и меньше единицы быть не может.
        uint256 debtPeriods_ = _debtPeriods(record.paidUntil);

        // Путь 4: предел просрочки. Разрешение и баланс здесь не проверяются
        // вообще: подписка прекращается, даже если денег хватало.
        if (debtPeriods_ >= MAX_DEBT_PERIODS) {
            record.canceled = true;
            emit TerminatedForOverdue(subscriber, debtPeriods_);
            return;
        }

        // Путь 5: не хватает разрешения или баланса. Причины проверяются
        // в порядке «разрешение, затем баланс»: если не хватает и того
        // и другого, записывается 1 — не хватает разрешения.
        uint8 reason = REASON_NONE;
        if (token.allowance(subscriber, address(this)) < periodPrice) {
            reason = REASON_ALLOWANCE;
        } else if (token.balanceOf(subscriber) < periodPrice) {
            reason = REASON_BALANCE;
        }

        if (reason != REASON_NONE) {
            record.failedAttempts += 1;
            record.lastFailureReason = reason;
            emit ChargeFailed(subscriber, msg.sender, reason, record.failedAttempts, debtPeriods_);
            return;
        }

        // Путь 6: списание проходит. paidUntil увеличивается на длину
        // периода, а не приравнивается к текущему времени: расписание
        // не дрейфует.
        uint256 newPaidUntil = record.paidUntil + periodLength;
        uint256 periodNumber = record.periodsPaid + 1;

        record.paidUntil = newPaidUntil;
        record.periodsPaid = periodNumber;
        record.failedAttempts = 0;
        record.lastFailureReason = REASON_NONE;

        token.safeTransferFrom(subscriber, recipient, periodPrice);

        emit ChargeSucceeded(subscriber, msg.sender, periodPrice, periodNumber, newPaidUntil);
    }

    // --- Отмена (раздел 8) ---

    /// @notice Отменяет подписку вызывающего. Отменить может только сам
    ///         подписчик.
    /// @dev Отмена немедленно закрывает возможность списаний, но доступ
    ///      сохраняется до конца уже оплаченного периода. Долг после
    ///      отмены сгорает: списания по отмененной подписке запрещены.
    function cancel() external {
        SubscriptionRecord storage record = subscriptions[msg.sender];

        require(record.exists, "no subscription");
        require(!record.canceled, "subscription already canceled");

        record.canceled = true;

        emit CanceledBySubscriber(msg.sender, record.paidUntil);
    }

    // --- Чтение состояния (разделы 5, 7) ---

    /// @notice Есть ли у адреса доступ к фиду.
    /// @dev Доступ определяется одним условием: текущее_время < paidUntil.
    ///      Ни флаг отмены, ни счетчик неудач в это условие не входят.
    ///      Функция только читает состояние.
    function hasAccess(address subscriber) external view returns (bool) {
        return block.timestamp < subscriptions[subscriber].paidUntil;
    }

    /// @notice Число неоплаченных периодов: сколько раз нужно вызвать
    ///         списание, чтобы доступ открылся.
    /// @dev Минимальное значение долга — 1, сразу в секунду истечения
    ///      оплаченного периода. Вне области определения величины — записи
    ///      нет или оплаченный период еще не истек — функция возвращает 0
    ///      и не откатывается: витрина вызывает ее в любом состоянии,
    ///      а откат заставил бы фронт держать копию правила и проверять
    ///      условие перед каждым вызовом. Ноль со значениями величины
    ///      не пересекается и читается однозначно: долга нет.
    function debtPeriods(address subscriber) external view returns (uint256) {
        SubscriptionRecord storage record = subscriptions[subscriber];

        if (!record.exists || block.timestamp < record.paidUntil) {
            return 0;
        }

        return _debtPeriods(record.paidUntil);
    }

    /// @dev debtPeriods = (текущее_время - paidUntil) / длина_периода + 1,
    ///      деление целочисленное (раздел 7).
    function _debtPeriods(uint256 paidUntil) internal view returns (uint256) {
        return (block.timestamp - paidUntil) / periodLength + 1;
    }
}
