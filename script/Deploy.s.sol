// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {MockUSDT} from "../src/MockUSDT.sol";
import {Subscription} from "../src/Subscription.sol";

/// @title Deploy — развертывание стенда «Минута»
/// @notice Раздел 11 спецификации, четыре шага и ни одного сверх: токен,
///         контракт подписки, стартовый баланс подписчику, разрешение
///         на пять периодов.
/// @dev Подписку скрипт не оформляет намеренно (о. 57): оформление —
///      первое действие, которое пользователь делает руками на витрине,
///      и отдавать его скрипту значит спрятать самое интересное.
///
///      Запуск на поднятом anvil:
///          forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
///
///      Ключ подписан в константе ниже, отдельный флаг не нужен. Это
///      дефолтный ключ локального anvil: публичный, общеизвестный и
///      никакой ценности не имеющий (раздел 14, допущение 8).
contract Deploy is Script {
    // --- Числа из спецификации (раздел 12) ---

    /// Длина периода в секундах, раздел 7 (о. 59).
    uint256 constant PERIOD_LENGTH = 60;
    /// К1. Цена периода — 1 токен, 1 000 000 базовых единиц при шести знаках.
    uint256 constant PERIOD_PRICE = 1_000_000;
    /// К2. Стартовый баланс подписчика — 10 токенов, ровно на десять списаний.
    uint256 constant START_BALANCE = 10_000_000;
    /// К11. Стартовое разрешение — 5 токенов, на пять периодов.
    uint256 constant START_ALLOWANCE = 5_000_000;

    // --- Аккаунты стенда (раздел 2) ---
    //
    // Дефолтные аккаунты локального anvil, первые три по порядку.
    // Роли закреплены здесь и повторены в web/config.js.

    /// Подписчик — anvil #0. Он же разворачивает контракты: владельца
    /// у них нет, и на поведение стенда личность деплойщика не влияет,
    /// зато `approve` уходит от нужного адреса без второй трансляции.
    address constant SUBSCRIBER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 constant SUBSCRIBER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// Получатель платежа — anvil #1. Фиксируется при деплое и не меняется.
    address constant RECIPIENT = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    /// Посторонний адрес — anvil #2. Ни подписчик, ни получатель; нужен,
    /// чтобы показать, что списание может вызвать кто угодно (о. 12).
    address constant OUTSIDER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function run() external {
        vm.startBroadcast(SUBSCRIBER_KEY);

        // 1. Токен стенда: «Mock USDT», «mUSDT», шесть знаков после запятой.
        MockUSDT token = new MockUSDT();

        // 2. Контракт подписки. Токен, получатель, цена периода и длина
        //    периода фиксируются при деплое и позже не меняются (о. 4).
        Subscription sub = new Subscription(token, RECIPIENT, PERIOD_PRICE, PERIOD_LENGTH);

        // 3. Стартовый баланс подписчику. Получатель и посторонний адрес
        //    остаются с нулем: нулевой баланс получателя делает наглядным
        //    приход средств при первом же списании.
        token.mint(SUBSCRIBER, START_BALANCE);

        // 4. Разрешение на пять периодов — и на этом остановка.
        //    Разрешения хватает на 5 периодов, а баланса на 10, поэтому
        //    «не хватает разрешения» (К11) наступит раньше, чем
        //    «не хватает баланса» (К4). Оба сбоя приходят сами.
        token.approve(address(sub), START_ALLOWANCE);

        vm.stopBroadcast();

        _report(address(token), address(sub));
    }

    /// @dev Адреса контрактов переносятся руками в web/config.js: витрина
    ///      читает их оттуда, а сетевых вызовов наружу у стенда нет.
    function _report(address token, address sub) private view {
        console2.log("");
        console2.log(unicode"=== Стенд Минута развернут ===");
        console2.log("");
        console2.log(unicode"Контракты (перенести в web/config.js):");
        console2.log("  MockUSDT     ", token);
        console2.log("  Subscription ", sub);
        console2.log("");
        console2.log(unicode"Аккаунты стенда:");
        console2.log(unicode"  Подписчик    ", SUBSCRIBER);
        console2.log(unicode"  Получатель   ", RECIPIENT);
        console2.log(unicode"  Посторонний  ", OUTSIDER);
        console2.log("");
        console2.log(unicode"Подписки нет: оформляем руками на витрине.");
        console2.log(unicode"  Баланс подписчика  ", MockUSDT(token).balanceOf(SUBSCRIBER));
        console2.log(unicode"  Баланс получателя  ", MockUSDT(token).balanceOf(RECIPIENT));
        console2.log(unicode"  Разрешение на списание", MockUSDT(token).allowance(SUBSCRIBER, sub));
        console2.log("");
    }
}
