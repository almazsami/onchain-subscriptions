// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockUSDT} from "../src/MockUSDT.sol";
import {Subscription} from "../src/Subscription.sol";

/// @title Тесты стенда «Минута»
/// @notice Раздел 12 спецификации — по тесту на контрольное значение.
///         Раздел 13 — по тесту на обязательный сценарий, границы обеими
///         точками. Числа взяты из спецификации, код под них не подгонялся.
contract SubscriptionTest is Test {
    // --- Числа из спецификации ---

    /// Длина периода, раздел 7 (о. 59).
    uint256 constant PERIOD = 60;
    /// К1. Цена периода — 1 токен при шести знаках.
    uint256 constant PRICE = 1_000_000;
    /// К2. Стартовый баланс подписчика — 10 токенов.
    uint256 constant START_BALANCE = 10_000_000;
    /// К11. Стартовое разрешение — 5 токенов.
    uint256 constant START_ALLOWANCE = 5_000_000;
    /// Длина data/facts.json, раздел 10 (о. 53).
    uint256 constant FACTS = 12;
    /// Предел просрочки, раздел 7.
    uint256 constant OVERDUE_LIMIT = 6;

    // Причины неудачи, раздел 4 (о. 52).
    uint8 constant REASON_NONE = 0;
    uint8 constant REASON_ALLOWANCE = 1;
    uint8 constant REASON_BALANCE = 2;

    // --- События, раздел 9 ---

    event Subscribed(address subscriber, uint256 startedAt, uint256 paidUntil);
    event ChargeSucceeded(
        address subscriber, address caller, uint256 amount, uint256 periodNumber, uint256 newPaidUntil
    );
    event ChargeFailed(address subscriber, address caller, uint8 reason, uint256 attemptNumber, uint256 debtPeriods);
    event CanceledBySubscriber(address subscriber, uint256 paidUntil);
    event TerminatedForOverdue(address subscriber, uint256 debtPeriods);

    // --- Стенд ---

    MockUSDT token;
    Subscription sub;

    address subscriber = makeAddr("subscriber");
    address recipient = makeAddr("recipient");
    address outsider = makeAddr("outsider");

    /// @dev Состояние после деплой-скрипта, раздел 11: контракты развернуты,
    ///      у подписчика 10 токенов и разрешение на 5 периодов, у получателя
    ///      и постороннего — ноль, подписки нет.
    function setUp() public {
        vm.warp(1_000_000);

        token = new MockUSDT();
        sub = new Subscription(IERC20(address(token)), recipient, PRICE, PERIOD);

        token.mint(subscriber, START_BALANCE);

        vm.prank(subscriber);
        token.approve(address(sub), START_ALLOWANCE);
    }

    // --- Помощники ---

    function _subscribe() internal {
        vm.prank(subscriber);
        sub.subscribe();
    }

    function _charge(address caller) internal {
        vm.prank(caller);
        sub.charge(subscriber);
    }

    function _cancel() internal {
        vm.prank(subscriber);
        sub.cancel();
    }

    /// @dev Перематывает время ровно на срок следующего списания.
    function _warpToDue() internal {
        vm.warp(_paidUntil(subscriber));
    }

    /// @dev Закрывает `count` следующих периодов по сетке, без просрочки.
    function _chargeNextPeriods(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            _warpToDue();
            _charge(subscriber);
        }
    }

    function _exists(address who) internal view returns (bool value) {
        (value,,,,,,) = sub.subscriptions(who);
    }

    function _canceled(address who) internal view returns (bool value) {
        (, value,,,,,) = sub.subscriptions(who);
    }

    function _startedAt(address who) internal view returns (uint256 value) {
        (,, value,,,,) = sub.subscriptions(who);
    }

    function _paidUntil(address who) internal view returns (uint256 value) {
        (,,, value,,,) = sub.subscriptions(who);
    }

    function _periodsPaid(address who) internal view returns (uint256 value) {
        (,,,, value,,) = sub.subscriptions(who);
    }

    function _failedAttempts(address who) internal view returns (uint256 value) {
        (,,,,, value,) = sub.subscriptions(who);
    }

    function _lastFailureReason(address who) internal view returns (uint8 value) {
        (,,,,,, value) = sub.subscriptions(who);
    }

    /// @dev Индекс факта минуты, раздел 10 (о. 53).
    function _factIndex(address who) internal view returns (uint256) {
        return _periodsPaid(who) % FACTS;
    }

    // =====================================================================
    // Раздел 12. Контрольные значения
    // =====================================================================

    /// К1. Цена периода — 1 токен, то есть 1 000 000 базовых единиц
    /// при шести знаках после запятой.
    function test_K1_periodCostsOneTokenAtSixDecimals() public view {
        assertEq(token.decimals(), 6, unicode"знаков после запятой");
        assertEq(sub.periodPrice(), PRICE, unicode"цена периода в базовых единицах");
        assertEq(sub.periodPrice(), 1 * 10 ** token.decimals(), unicode"цена периода в токенах");
        assertEq(sub.periodLength(), PERIOD, unicode"длина периода");
    }

    /// К2. Стартовый баланс подписчика — 10 токенов, ровно на десять
    /// успешных списаний.
    function test_K2_startBalanceCoversExactlyTenPeriods() public view {
        assertEq(token.balanceOf(subscriber), START_BALANCE, unicode"стартовый баланс");
        assertEq(
            token.balanceOf(subscriber) / sub.periodPrice(),
            10,
            unicode"сколько периодов покрывает"
        );
        assertEq(
            token.balanceOf(subscriber) % sub.periodPrice(),
            0,
            unicode"остаток от деления на цену"
        );
        assertEq(token.balanceOf(recipient), 0, unicode"получатель стартует с нуля");
        assertEq(token.balanceOf(outsider), 0, unicode"посторонний стартует с нуля");
    }

    /// К3. После оформления: periodsPaid = 1, баланс подписчика 9 токенов,
    /// баланс получателя 1 токен, failedAttempts = 0.
    function test_K3_subscriptionStartsPaidForItsFirstPeriod() public {
        _subscribe();

        assertEq(_periodsPaid(subscriber), 1, "periodsPaid");
        assertEq(token.balanceOf(subscriber), 9_000_000, unicode"баланс подписчика");
        assertEq(token.balanceOf(recipient), 1_000_000, unicode"баланс получателя");
        assertEq(_failedAttempts(subscriber), 0, "failedAttempts");
        assertEq(_lastFailureReason(subscriber), REASON_NONE, "lastFailureReason");
        assertTrue(_exists(subscriber), "exists");
        assertFalse(_canceled(subscriber), "canceled");
        assertEq(_startedAt(subscriber), block.timestamp, "startedAt");
        assertEq(_paidUntil(subscriber), block.timestamp + PERIOD, "paidUntil");
    }

    /// К4. Разрешение поднято руками выше стартовых пяти периодов: после
    /// десятого успешного списания periodsPaid = 10, баланс подписчика 0,
    /// баланс получателя 10 токенов. Следующий вызов по сроку идет путем 5
    /// с причиной «не хватает баланса».
    function test_K4_whenBalanceRunsOutChargeFailsWithBalanceReason() public {
        _subscribe();

        // Разрешение поднято руками, чтобы предел разрешения не наступил
        // раньше предела баланса.
        vm.prank(subscriber);
        token.approve(address(sub), 20_000_000);

        _chargeNextPeriods(9);

        assertEq(_periodsPaid(subscriber), 10, "periodsPaid");
        assertEq(token.balanceOf(subscriber), 0, unicode"баланс подписчика");
        assertEq(token.balanceOf(recipient), 10_000_000, unicode"баланс получателя");

        _warpToDue();
        _charge(subscriber);

        assertEq(_periodsPaid(subscriber), 10, unicode"перевода не было");
        assertEq(token.balanceOf(recipient), 10_000_000, unicode"получателю ничего не пришло");
        assertEq(_failedAttempts(subscriber), 1, "failedAttempts");
        assertEq(_lastFailureReason(subscriber), REASON_BALANCE, "lastFailureReason");
        assertFalse(_canceled(subscriber), unicode"подписка не прекращена");
    }

    /// К5. В секунду текущее_время == paidUntil: доступа уже нет,
    /// debtPeriods = 1, списание уже возможно.
    function test_K5_atExpiryAccessIsGoneAndOnePeriodIsDue() public {
        _subscribe();

        vm.warp(_paidUntil(subscriber));

        assertFalse(sub.hasAccess(subscriber), unicode"доступа уже нет");
        assertEq(sub.debtPeriods(subscriber), 1, "debtPeriods");

        _charge(subscriber);

        assertEq(_periodsPaid(subscriber), 2, unicode"списание уже возможно");
    }

    /// К6. Граница предела просрочки в секундах: при разнице от 240 до 299
    /// включительно debtPeriods = 5; при разнице от 300 секунд — 6.
    function test_K6_overdueLimitIsSixPeriods() public {
        _subscribe();
        uint256 paidUntil = _paidUntil(subscriber);

        vm.warp(paidUntil + 240);
        assertEq(sub.debtPeriods(subscriber), 5, unicode"нижняя граница пяти периодов");

        vm.warp(paidUntil + 299);
        assertEq(sub.debtPeriods(subscriber), 5, unicode"верхняя граница пяти периодов");

        vm.warp(paidUntil + 300);
        assertEq(sub.debtPeriods(subscriber), 6, unicode"нижняя граница шести периодов");
        assertEq(
            sub.debtPeriods(subscriber), OVERDUE_LIMIT, unicode"предел просрочки достигнут"
        );
    }

    /// К7. Три пропущенных периода (разница от 120 до 179 секунд):
    /// debtPeriods = 3. После первого успешного списания — 2, после
    /// второго — 1, после третьего paidUntil уходит в будущее и доступ открыт.
    function test_K7_debtShrinksByOnePerCharge() public {
        _subscribe();
        uint256 paidUntil = _paidUntil(subscriber);

        vm.warp(paidUntil + 120);
        assertEq(sub.debtPeriods(subscriber), 3, unicode"нижняя граница трех периодов");

        vm.warp(paidUntil + 179);
        assertEq(sub.debtPeriods(subscriber), 3, unicode"верхняя граница трех периодов");

        vm.warp(paidUntil + 120);

        _charge(subscriber);
        assertEq(sub.debtPeriods(subscriber), 2, unicode"после первого списания");
        assertFalse(sub.hasAccess(subscriber), unicode"доступа еще нет");

        _charge(subscriber);
        assertEq(sub.debtPeriods(subscriber), 1, unicode"после второго списания");
        assertFalse(sub.hasAccess(subscriber), unicode"доступа еще нет");

        _charge(subscriber);
        assertTrue(sub.hasAccess(subscriber), unicode"после третьего доступ открыт");
        assertGt(_paidUntil(subscriber), block.timestamp, unicode"paidUntil ушел в будущее");
    }

    /// К8. Тот же сценарий по деньгам: три догоняющих списания уводят
    /// с баланса 3 токена и добавляют получателю 3 токена.
    function test_K8_catchingUpPaysForPeriodsAlreadyGone() public {
        _subscribe();

        uint256 balanceBefore = token.balanceOf(subscriber);
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.warp(_paidUntil(subscriber) + 120);
        assertEq(sub.debtPeriods(subscriber), 3, unicode"три пропущенных периода");

        _charge(subscriber);
        _charge(subscriber);
        _charge(subscriber);

        assertEq(balanceBefore - token.balanceOf(subscriber), 3_000_000, unicode"ушло с баланса");
        assertEq(token.balanceOf(recipient) - recipientBefore, 3_000_000, unicode"пришло получателю");

        // Два из трех периодов оплачены постфактум, доступа в них не было.
        assertEq(_periodsPaid(subscriber), 4, unicode"оплаченных периодов всего");
    }

    /// К9. Отмена и повторное оформление в одной минуте: списаний 2,
    /// с баланса ушло 2 токена за одну минуту; у новой записи
    /// periodsPaid = 1, счетчики прошлой записи не переносятся.
    function test_K9_resubscribingInSameMinutePaysTwice() public {
        uint256 minuteStart = block.timestamp;

        _subscribe();
        _cancel();
        _subscribe();

        assertEq(block.timestamp, minuteStart, unicode"все уложилось в одну минуту");
        assertEq(token.balanceOf(subscriber), START_BALANCE - 2_000_000, unicode"ушло два токена");
        assertEq(token.balanceOf(recipient), 2_000_000, unicode"получателю пришло два токена");

        assertEq(_periodsPaid(subscriber), 1, unicode"счетчик новой записи начат с нуля");
        assertEq(_failedAttempts(subscriber), 0, unicode"failedAttempts новой записи");
        assertEq(_lastFailureReason(subscriber), REASON_NONE, unicode"lastFailureReason новой записи");
        assertFalse(_canceled(subscriber), unicode"новая запись не отменена");
        assertEq(_startedAt(subscriber), minuteStart, unicode"startedAt новой записи");
    }

    /// К10. Индекс факта равен periodsPaid по модулю 12: при periodsPaid
    /// = 1, 2, 3 индексы равны 1, 2, 3; при 10 индекс равен 10; при 12 —
    /// индекс 0.
    function test_K10_factIndexIsPeriodsPaidModuloTwelve() public {
        // Двенадцать периодов на стартовом балансе недостижимы (К2),
        // поэтому баланс и разрешение подняты специально для этой проверки.
        token.mint(subscriber, 2_000_000);
        vm.prank(subscriber);
        token.approve(address(sub), 12_000_000);

        _subscribe();
        assertEq(_periodsPaid(subscriber), 1, "periodsPaid");
        assertEq(_factIndex(subscriber), 1, unicode"индекс факта на первом периоде");

        _chargeNextPeriods(1);
        assertEq(_factIndex(subscriber), 2, unicode"индекс факта на втором периоде");

        _chargeNextPeriods(1);
        assertEq(_factIndex(subscriber), 3, unicode"индекс факта на третьем периоде");

        _chargeNextPeriods(7);
        assertEq(_periodsPaid(subscriber), 10, "periodsPaid");
        assertEq(_factIndex(subscriber), 10, unicode"индекс факта на десятом периоде");

        _chargeNextPeriods(2);
        assertEq(_periodsPaid(subscriber), 12, "periodsPaid");
        assertEq(
            _factIndex(subscriber),
            0,
            unicode"на двенадцатом периоде список пошел по кругу"
        );
    }

    /// К11. Оформление тратит первый период, остаток разрешения — 4 токена.
    /// После пятого успешного списания остаток 0, periodsPaid = 5, баланс
    /// подписчика 5 токенов, получателя 5 токенов. Шестой вызов по сроку
    /// идет путем 5 с причиной «не хватает разрешения».
    function test_K11_whenAllowanceRunsOutChargeFailsWithAllowanceReason() public {
        assertEq(
            token.allowance(subscriber, address(sub)), START_ALLOWANCE, unicode"стартовое разрешение"
        );

        _subscribe();
        assertEq(
            token.allowance(subscriber, address(sub)),
            4_000_000,
            unicode"остаток после оформления"
        );

        _chargeNextPeriods(4);

        assertEq(token.allowance(subscriber, address(sub)), 0, unicode"остаток разрешения");
        assertEq(_periodsPaid(subscriber), 5, "periodsPaid");
        assertEq(token.balanceOf(subscriber), 5_000_000, unicode"баланс подписчика");
        assertEq(token.balanceOf(recipient), 5_000_000, unicode"баланс получателя");

        _warpToDue();
        _charge(subscriber);

        assertEq(_periodsPaid(subscriber), 5, unicode"перевода не было");
        assertEq(_failedAttempts(subscriber), 1, "failedAttempts");
        assertEq(_lastFailureReason(subscriber), REASON_ALLOWANCE, "lastFailureReason");

        // Эта точка наступает раньше исчерпания баланса (К2).
        assertGt(token.balanceOf(subscriber), 0, unicode"баланс еще не исчерпан");
    }

    // =====================================================================
    // Раздел 13. Обязательные к воспроизведению сценарии
    // =====================================================================

    /// Сценарий 1. Отозванное разрешение: approve в ноль, следующий вызов
    /// идет путем 5, подписка становится просроченной. Отзыв разрешения
    /// отменой подписки не является (о. 28).
    function test_S1_revokedAllowanceStopsPaymentWithoutCancelling() public {
        _subscribe();

        vm.prank(subscriber);
        token.approve(address(sub), 0);

        uint256 balanceBefore = token.balanceOf(subscriber);
        _warpToDue();

        vm.expectEmit(true, true, true, true, address(sub));
        emit ChargeFailed(subscriber, subscriber, REASON_ALLOWANCE, 1, 1);
        _charge(subscriber);

        assertEq(token.balanceOf(subscriber), balanceBefore, unicode"перевода не было");
        assertEq(_failedAttempts(subscriber), 1, "failedAttempts");
        assertEq(_lastFailureReason(subscriber), REASON_ALLOWANCE, "lastFailureReason");

        // Просрочена, но не отменена.
        assertFalse(_canceled(subscriber), unicode"подписка не отменена");
        assertTrue(_exists(subscriber), unicode"запись на месте");
        assertFalse(sub.hasAccess(subscriber), unicode"доступа нет");
    }

    /// Сценарий 2. Исчерпанный баланс: после десяти списаний денег нет,
    /// вызов идет путем 5 с причиной «не хватает баланса».
    function test_S2_exhaustedBalanceStopsPaymentWithoutCancelling() public {
        _subscribe();

        vm.prank(subscriber);
        token.approve(address(sub), 20_000_000);

        _chargeNextPeriods(9);
        assertEq(token.balanceOf(subscriber), 0, unicode"денег нет");

        _warpToDue();

        vm.expectEmit(true, true, true, true, address(sub));
        emit ChargeFailed(subscriber, subscriber, REASON_BALANCE, 1, 1);
        _charge(subscriber);

        assertEq(_lastFailureReason(subscriber), REASON_BALANCE, "lastFailureReason");
        assertFalse(_canceled(subscriber), unicode"подписка не отменена");
        assertFalse(sub.hasAccess(subscriber), unicode"доступа нет");
    }

    /// Сценарий 3. Списание раньше срока — revert (путь 3). Предоплата
    /// вперед не предусмотрена (о. 16).
    function test_S3_payingAheadOfScheduleIsRefused() public {
        _subscribe();

        vm.expectRevert("period not due yet");
        _charge(subscriber);

        // И за секунду до срока — тоже.
        vm.warp(_paidUntil(subscriber) - 1);
        vm.expectRevert("period not due yet");
        _charge(subscriber);

        assertEq(_periodsPaid(subscriber), 1, unicode"ничего не изменилось");
    }

    /// Сценарий 4. Списание посторонним адресом проходит успешно; это
    /// поведение, а не сбой (о. 12). Поле caller показывает это в логах.
    function test_S4_anyoneMayTriggerSomeoneElsesCharge() public {
        _subscribe();
        _warpToDue();

        uint256 newPaidUntil = _paidUntil(subscriber) + PERIOD;

        vm.expectEmit(true, true, true, true, address(sub));
        emit ChargeSucceeded(subscriber, outsider, PRICE, 2, newPaidUntil);
        _charge(outsider);

        assertEq(_periodsPaid(subscriber), 2, unicode"списание прошло");
        assertEq(token.balanceOf(recipient), 2_000_000, unicode"деньги ушли получателю");
        // Платит по-прежнему подписчик, а не вызывающий.
        assertEq(token.balanceOf(outsider), 0, unicode"посторонний ничего не заплатил");
    }

    /// Сценарий 5, нижняя точка границы. При debtPeriods = 5 списание
    /// еще выполняется (К6).
    function test_S5_atFiveOverduePeriodsChargeStillGoesThrough() public {
        _subscribe();
        uint256 paidUntil = _paidUntil(subscriber);

        vm.warp(paidUntil + 299);
        assertEq(sub.debtPeriods(subscriber), 5, unicode"пять неоплаченных периодов");

        _charge(subscriber);

        assertEq(_periodsPaid(subscriber), 2, unicode"списание выполнено");
        assertEq(token.balanceOf(recipient), 2_000_000, unicode"деньги ушли получателю");
        assertFalse(_canceled(subscriber), unicode"подписка не прекращена");
    }

    /// Сценарий 5, верхняя точка границы. При debtPeriods = 6 подписка
    /// прекращается путем 4: вызов успешен, перевода нет, разрешение
    /// и баланс не проверяются вообще (К6, о. 47).
    function test_S5_atSixOverduePeriodsSubscriptionIsTerminated() public {
        _subscribe();
        uint256 paidUntil = _paidUntil(subscriber);

        uint256 balanceBefore = token.balanceOf(subscriber);
        uint256 allowanceBefore = token.allowance(subscriber, address(sub));

        vm.warp(paidUntil + 300);
        assertEq(sub.debtPeriods(subscriber), 6, unicode"шесть неоплаченных периодов");

        vm.expectEmit(true, true, true, true, address(sub));
        emit TerminatedForOverdue(subscriber, 6);
        _charge(subscriber);

        assertTrue(_canceled(subscriber), unicode"подписка прекращена");
        assertEq(_periodsPaid(subscriber), 1, unicode"перевода не было");
        // Денег и разрешения хватало, и это не помогло.
        assertEq(token.balanceOf(subscriber), balanceBefore, unicode"баланс не тронут");
        assertEq(
            token.allowance(subscriber, address(sub)),
            allowanceBefore,
            unicode"разрешение не тронуто"
        );
        assertGt(balanceBefore, PRICE, unicode"денег хватало");
        assertGt(allowanceBefore, PRICE, unicode"разрешения хватало");

        // Повторный вызов дает revert, а не второе событие прекращения.
        vm.expectRevert("subscription canceled");
        _charge(subscriber);
    }

    /// Сценарий 6. Оформление при уже активной подписке — revert (о. 41).
    function test_S6_secondSubscriptionOnActiveRecordIsRefused() public {
        _subscribe();

        vm.expectRevert("subscription already active");
        vm.prank(subscriber);
        sub.subscribe();

        // И на просроченной, пока она не отменена, — тоже.
        vm.warp(_paidUntil(subscriber) + PERIOD);
        vm.expectRevert("subscription already active");
        vm.prank(subscriber);
        sub.subscribe();

        assertEq(_periodsPaid(subscriber), 1, unicode"второго списания не было");
    }

    /// Сценарий 7. Отмена и повторное оформление в том же периоде дают
    /// двойное списание. Отмена денег не возвращает, новая подписка —
    /// новая оплата (о. 40).
    function test_S7_cancelAndResubscribeInSameMinuteChargesTwice() public {
        _subscribe();
        uint256 paidUntil = _paidUntil(subscriber);

        vm.expectEmit(true, true, true, true, address(sub));
        emit CanceledBySubscriber(subscriber, paidUntil);
        _cancel();

        assertEq(token.balanceOf(subscriber), 9_000_000, unicode"отмена денег не вернула");

        vm.expectEmit(true, true, true, true, address(sub));
        emit Subscribed(subscriber, block.timestamp, block.timestamp + PERIOD);
        _subscribe();

        assertEq(
            token.balanceOf(subscriber), 8_000_000, unicode"заплачено дважды за одну минуту"
        );
        assertEq(token.balanceOf(recipient), 2_000_000, unicode"получателю пришло дважды");
        assertEq(
            _periodsPaid(subscriber), 1, unicode"у новой записи счетчик начат заново"
        );
    }

    /// Сценарий 8. Доступ есть строго при текущее_время < paidUntil;
    /// льготного интервала нет, секунда просрочки — доступа нет (о. 20).
    function test_S8_accessEndsExactlyAtPaidUntil() public {
        _subscribe();
        uint256 paidUntil = _paidUntil(subscriber);

        vm.warp(paidUntil - 1);
        assertTrue(
            sub.hasAccess(subscriber), unicode"за секунду до истечения доступ есть"
        );

        vm.warp(paidUntil);
        assertFalse(
            sub.hasAccess(subscriber), unicode"в секунду истечения доступа уже нет"
        );

        vm.warp(paidUntil + 1);
        assertFalse(sub.hasAccess(subscriber), unicode"секундой позже доступа нет");
    }

    /// Сценарий 9. Погашение долга: три пропущенных периода закрываются
    /// тремя вызовами. До последнего вызова витрина показывает экран
    /// «погашение долга» (failedAttempts = 0) с уменьшающимся счетчиком,
    /// после — доступ открыт и факт минуты сменился.
    function test_S9_debtIsClearedOneChargeAtATime() public {
        _subscribe();
        uint256 factBefore = _factIndex(subscriber);

        vm.warp(_paidUntil(subscriber) + 120);
        assertEq(sub.debtPeriods(subscriber), 3, unicode"осталось догнать три периода");

        _charge(subscriber);
        assertEq(sub.debtPeriods(subscriber), 2, unicode"осталось догнать два периода");
        assertEq(
            _failedAttempts(subscriber),
            0,
            unicode"экран погашения долга, а не просрочки"
        );
        assertFalse(sub.hasAccess(subscriber), unicode"заплатил, а доступа нет");

        _charge(subscriber);
        assertEq(sub.debtPeriods(subscriber), 1, unicode"остался один период");
        assertEq(
            _failedAttempts(subscriber),
            0,
            unicode"экран погашения долга, а не просрочки"
        );
        assertFalse(sub.hasAccess(subscriber), unicode"заплатил, а доступа нет");

        _charge(subscriber);
        assertTrue(sub.hasAccess(subscriber), unicode"доступ открыт");
        assertEq(sub.debtPeriods(subscriber), 0, unicode"долга нет");
        assertEq(_factIndex(subscriber), 4, unicode"факт минуты сменился");
        assertTrue(_factIndex(subscriber) != factBefore, unicode"факт не тот, что был");
    }

    /// Сценарий 10. Отмена сразу после оформления: доступ сохраняется
    /// до конца уже оплаченного периода, затем пропадает. Отмена не
    /// отбирает оплаченный период (о. 37).
    function test_S10_cancelKeepsAccessUntilPaidPeriodEnds() public {
        _subscribe();
        _cancel();

        uint256 paidUntil = _paidUntil(subscriber);

        // До границы: экран 2 с плашкой об отмене — доступ есть при
        // canceled == true.
        assertTrue(sub.hasAccess(subscriber), unicode"доступ сохраняется");
        assertTrue(_canceled(subscriber), unicode"подписка отменена");

        vm.warp(paidUntil - 1);
        assertTrue(
            sub.hasAccess(subscriber), unicode"за секунду до истечения доступ есть"
        );

        // За границей: экран 3 «подписка отменена».
        vm.warp(paidUntil);
        assertFalse(sub.hasAccess(subscriber), unicode"в секунду истечения доступа нет");
        assertTrue(_canceled(subscriber), unicode"подписка отменена");

        // Списаний по отмененной подписке нет: долг сгорел вместе с отменой.
        vm.expectRevert("subscription canceled");
        _charge(subscriber);
    }

    // =====================================================================
    // Границы, зафиксированные ответами 60 и 62
    // =====================================================================

    /// О. 62. Граница применимости: контракт корректен для токена, у которого
    /// перевод не может провалиться по причинам, отличным от разрешения
    /// и баланса. С адресом без кода в конструкторе платящие вызовы падают,
    /// а функции чтения состояния, токена не касающиеся, работают.
    function test_O62_tokenWithoutCodeMakesEveryPayingCallFail() public {
        address emptyToken = address(0xDEAD);
        assertEq(emptyToken.code.length, 0, unicode"по адресу нет кода");

        Subscription broken = new Subscription(IERC20(emptyToken), recipient, PRICE, PERIOD);

        vm.expectRevert();
        vm.prank(subscriber);
        broken.subscribe();

        // Записи так и не появилось, поэтому дойти до charge нечем:
        // зависимость от токена начинается на оформлении.
        (bool exists,,,,,,) = broken.subscriptions(subscriber);
        assertFalse(exists, unicode"записи нет");

        // Чтение состояния токена не касается и не падает.
        assertFalse(broken.hasAccess(subscriber), unicode"hasAccess работает");
        assertEq(broken.debtPeriods(subscriber), 0, unicode"debtPeriods работает");
    }

    /// О. 60. debtPeriods возвращает 0 вне области определения величины —
    /// когда записи нет и когда оплаченный период еще не истек — и не
    /// откатывается: витрина вызывает функцию в любом состоянии.
    function test_O60_debtPeriodsReturnsZeroWhenNothingIsOwed() public {
        // Записи нет.
        assertEq(sub.debtPeriods(subscriber), 0, unicode"записи нет");
        assertEq(sub.debtPeriods(outsider), 0, unicode"у постороннего записи нет");

        _subscribe();

        // Доступ открыт.
        assertEq(sub.debtPeriods(subscriber), 0, unicode"в секунду оформления");

        vm.warp(_paidUntil(subscriber) - 1);
        assertEq(sub.debtPeriods(subscriber), 0, unicode"за секунду до истечения");

        // И только с истечением периода появляется долг.
        vm.warp(_paidUntil(subscriber));
        assertEq(sub.debtPeriods(subscriber), 1, unicode"в секунду истечения");
    }
}
