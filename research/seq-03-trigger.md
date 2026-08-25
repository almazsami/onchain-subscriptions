# Блок 3. Кто в реальности вызывает списание

Транзакцию `transferFrom` кто-то должен отправить и за нее заплатить.
Разрешение само по себе денег не двигает. Этот блок — про то, кто нажимает
на кнопку и за чей счет.

Дата сбора: 25 августа 2026.

---

## Постановка задачи

Pull-модель на allowance не самоисполняема. Формулировка из отраслевого
обзора прямая: для approve-модели требуется «a keeper or cron-like service that
triggers the `transferFrom()` call at each billing interval»
([Spark Research: Recurring Stablecoin Payments](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).

Это отличает pull-подписку от стриминга: у Superfluid «a single on-chain
transaction opens the stream, and it persists until canceled» — периодических
вызовов нет вообще (там же). Плата за это — обертка токена и другая модель
хранения средств (см. блок 1).

Дальше — четыре варианта, кто может быть этим вызывающим.

---

## Вариант 1. Keeper-сеть: Chainlink Automation

### Как устроено

Разработчик регистрирует upkeep: контракт реализует `checkUpkeep` (исполняется
офчейн) и `performUpkeep` (исполняется ончейн). «The Chainlink Automation Network
frequently simulates your `checkUpkeep` offchain to determine if conditions are
met. When `checkUpkeep` returns `true`, the Chainlink Automation Network calls
`performUpkeep` onchain», причем результат `checkUpkeep` передается в
`performUpkeep` как `performData`
([Chainlink Docs: Automation Interfaces](https://docs.chain.link/chainlink-automation/reference/automation-interfaces)).

Для подписки с фиксированным периодом подходит вариант проще — **time-based
(cron) upkeep**: расписание задается CRON-выражением с полями минута, час,
день месяца, месяц, день недели по UTC, и Chainlink разворачивает служебный
контракт `CronUpkeep`, который дергает выбранную функцию по расписанию.
Специальной Automation-совместимости целевого контракта при этом не требуется
([Chainlink Docs: Time-based Upkeeps](https://docs.chain.link/chainlink-automation/guides/job-scheduler)).

Минимальная гранулярность расписания — минута, поскольку младшее поле CRON —
минуты (следует из синтаксиса, описанного там же).

### Экономика

Плата берется с LINK-баланса upkeep'а: «Upkeeps have a LINK (ERC-677) balance.
Every time an onchain transaction is performed for your upkeep, its LINK balance
will be reduced by the LINK fee»
([Chainlink Docs: Automation Billing and Costs](https://docs.chain.link/chainlink-automation/overview/automation-economics)).

Формула:

```
FeeLINK = [tx.gasPriceNative WEI x gasUsed x (1 + premium%)
           + (gasOverhead x tx.gasPriceNative WEI)] / [LINK/NativeRate in WEI]
```
(там же)

Ключевые числа оттуда же:
- `gasOverhead` — фиксированные **80 000** единиц газа;
- **premium** зависит от сети; в приведенном примере для Polygon — **70%**;
- реальный пример: gas price 182 723 799 380 wei, расход 110 051 газа,
  премия 70% → **0.008077 LINK** комиссии;
- за офчейн-вычисления и за регистрацию платы нет: «There is no registration
  fee or other fees for any offchain computation»
  ([Chainlink Docs: Managing Upkeeps](https://docs.chain.link/chainlink-automation/guides/manage-upkeeps)).

Отдельно — **минимальный баланс**: «If the Upkeep LINK balance drops below the
minimum balance, the Chainlink Automation Network will not perform the Upkeep»;
считается он от текущей быстрой цены газа, заданного лимита газа, множителя
и курса LINK/Native (там же).

Обертка `CronUpkeep` добавляет накладные расходы: «this contract uses roughly
110K gas per call, it is recommended to add 150K additional gas to the gas limit»
([Chainlink Docs: Time-based Upkeeps](https://docs.chain.link/chainlink-automation/guides/job-scheduler)).

### Что это значит

Газ платит **владелец подписочного сервиса**, заранее, в LINK, с наценкой
оператору ноды. Плюс: не надо держать свою инфраструктуру и следить за
приватным ключом отправителя. Минус: к стоимости газа добавляется премия
(в примере — 70%) и фиксированный overhead в 80 000 газа на каждое исполнение,
который при мелких платежах может доминировать.

---

## Вариант 2. Keeper-сеть: Gelato

### Как устроено

Gelato Web3 Functions — три компонента: Typescript Functions (офчейн-данные и
вычисления), Solidity Functions (ончейн-логика) и Automated Transactions
(прямые вызовы контракта с предопределенными входами). Исполняет их
децентрализованная сеть киперов
([Gelato Docs: Web3 Functions](https://docs.gelato.cloud/web3-services/web3-functions)).

Триггеры трех типов: **time-based** (по интервалу), **event-based** (по событию)
и **block-based** (каждый блок или через N блоков) (там же).

Требование к целевому контракту важное: функции должны быть public или external
и без ограничивающего доступа, если адрес автоматизации не в белом списке; это
функции, «usually called by the development team or external keepers, not
'user facing' functions» (там же).

### Экономика

Две составляющие: **Gas Fees** (сетевая комиссия) и **Gelato Fee** (комиссия
за автоматизацию), обе оплачиваются предоплатой через **1Balance** (там же).
1Balance пополняется, например, USDC на Polygon и покрывает исполнение задач
([Pyth Docs: Using Gelato](https://docs.pyth.network/price-feeds/core/schedule-price-updates/using-gelato)).

То есть модель та же, что у Chainlink: платит создатель задачи, вперед,
из своего депозита.

---

## Вариант 3. Собственный сервис

### Как устроено

Свой бот с приватным ключом, который по расписанию шлет `charge()` в контракт.
Именно так работают продуктовые провайдеры из блока 1: у Loop Crypto компания
после получения авторизации создает transfer request автоматически по частоте
тарифа, и «Once you have authorization to bill a customer, you can then schedule
payments»
([Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions));
у Request Network API берет на себя «the scheduling and triggering of these
payments»
([Request Network Docs: Recurring payments](https://docs.request.network/request-network-api/recurring-payments));
у Spritz списание в назначенный день делает сам сервис, а пользователь платит
ноль газа — «Users pay ZERO gas fees on SMARTPay transactions»
([Spritz Blog: Introducing SMARTPay](https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments)).

### Экономика

Нет премии кипер-сети, но появляется собственная инфраструктура: горячий ключ
с балансом нативного токена, мониторинг, ретраи, дежурство. Кто именно
оплачивает газ у Loop и Request — **не подтверждено**: в их документации это
не раскрыто (см. блок 1).

Общий для всей категории способ убрать газ с пользователя — **paymaster**:
«Paymasters (under ERC-4337) can abstract gas entirely, letting users pay fees
in the stablecoin itself», но с честной оговоркой — «the cost is still borne
somewhere in the system»
([Spark Research](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).

---

## Вариант 4. Сам получатель

Самый простой случай: получатель денег и есть тот, кто нажимает кнопку.

Именно так устроен Sablier: `withdraw` вызывает получатель, и он же платит газ.
В Sablier Flow функция `withdraw` вообще публичная, но средства уходят на адрес
получателя ([Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)).

Плюс: нулевая инфраструктура, никакой премии, никакого доверенного третьего
лица. Минус: платеж происходит не «раз в период», а «когда получатель
вспомнил». Для стенда с минутным периодом это, кстати, вполне рабочий режим —
кнопка в интерфейсе.

---

## Вариант 5. Стимулирование сторонних вызывающих

Идея: сделать функцию списания публичной и заплатить тому, кто ее вызовет.
Тогда газ платит случайный бот, а не сервис.

### Как это работает в живых системах

**Superfluid Sentinels.** Потоки неплатежеспособных аккаунтов закрывает кто
угодно, и вознаграждение берется из буфера, внесенного при открытии потока.
Роли разведены по времени: Patrician (PIC) получает награду в 30-минутный
Patrician Period, Plebs — позже, Pirates — на стадии полной неплатежеспособности.
«Платит газ тот, кто отправляет транзакцию закрытия», роль PIC разыгрывается
через аукцион TOGA со stake и slashing
([Superfluid Docs: Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)).

**MakerDAO Liquidations 2.0.** Награда киперу состоит из двух частей:
**tip** — «a flat fee to suck from vow to incentivize keepers when liquidating
a vault or resetting an already existing auction», и **chip** — процент от
`tab` (в конфигурации 0.02 WAD, то есть 2%)
([Maker Protocol Docs: Liquidation 2.0 Module](https://docs.makerdao.com/smart-contract-modules/dog-and-clipper-detailed-documentation)).

Смысл фиксированной части ровно наш: «The constant component of the reward can
be used to cover gas costs (which are per-Vault for liquidators) or to allow MKR
holders to effectively pay Keepers to clear small Vaults that would otherwise
not be attractive for liquidation» (там же).

Академическая проверка это подтверждает: «it is more cost-effective to increase
the constant fee, as opposed to the proportional fee, in order to decrease the
time it takes for keepers to liquidate vaults»
([StableSims, arXiv:2201.03519](https://arxiv.org/abs/2201.03519)).

### Чем платит эта схема

Открытая награда порождает конкуренцию за нее: «The primary issue with bounties
is that nodes end up engaging in direct competition for the winner-takes-all
reward, driving priority gas auction (PGA) bidding wars», и «Under some market
conditions, being a Keeper can result in a net loss over many game iterations»
([B.Protocol: The Keeper's Dilemma](https://medium.com/b-protocol/the-keepers-dilemma-game-theoretic-analysis-of-liquidation-incentives-with-preliminary-b588e82e4d67)).

Для подписки на $9.99 в месяц награда, достаточная чтобы бот вообще заметил
задачу, съедает заметную долю платежа. Это не отменяет схему, но делает ее
разумной только там, где либо суммы велики, либо газ дешев.

---

## Экономика газа: голые числа

**Стоимость самого списания.** Перевод ERC-20 требует примерно
**45 000–65 000 газа** в зависимости от сложности контракта; разброс — из-за
того, что реализации `transferFrom()` неодинаковы
([KuCoin Learn: Understanding Ethereum Gas Fees](https://www.kucoin.com/learn/web3/understanding-ethereum-gas-fees),
[TokenHook, arXiv:2107.02997](https://arxiv.org/pdf/2107.02997)).
К этому в подписочном контракте добавится своя логика: проверка периода,
запись состояния, событие.

**Волатильность — главная проблема, а не средняя цена.** «A recurring payment
that costs $0.50 in gas during low congestion might cost $15 during a fee spike.
For a $9.99/month subscription, unpredictable gas can exceed the payment itself»
([Spark Research](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).

В карточном мире комиссия эквайринга — предсказуемый процент. Здесь —
фиксированная сумма в единицах, курс которых скачет независимо от размера
платежа. Экономика подписки на цепочке ломается не тогда, когда газ дорогой,
а тогда, когда он **непредсказуемый**.

**L2 как ответ.** «Layer 2 networks like Base, Arbitrum, and Optimism reduce
gas to sub-cent levels, but introduce bridging complexity» (там же).
Это, судя по всему, и есть фактический отраслевой ответ: Loop Crypto отдельно
объявляла запуск на Base
([Loop Crypto: Live on Base](https://www.loopcrypto.xyz/blog/loop-crypto-is-live-on-base)),
Spritz работает с USDC на Polygon
([Spritz Help Center](https://help.spritz.finance/en/articles/7065236-how-does-smartpay-work)).

---

## Сводная таблица

| Кто вызывает | Кто платит газ | Наценка сверху | Что нужно поднять | Слабое место |
|---|---|---|---|---|
| Chainlink Automation | Владелец upkeep (LINK) | Premium оператора (в примере 70%) + 80k gas overhead | Регистрация upkeep, пополнение LINK | Падение баланса ниже минимума останавливает исполнение |
| Gelato | Создатель задачи (1Balance) | Gelato Fee | Депозит 1Balance | Функция должна быть открыта для адреса Gelato |
| Свой сервис | Сервис | Нет | Бот, горячий ключ, мониторинг | Централизация, ключ, дежурство |
| Получатель | Получатель | Нет | Ничего | Платеж «когда вспомнил», не по расписанию |
| Стимулированный третий | Случайный бот | Награда (tip + chip) | Логика награды в контракте | PGA-войны, при малых суммах никто не придет |

---

## Что из этого важно для стенда

Автоматический шедулер прямо назван нецелью в AGENTS.md, и материал этого блока
объясняет, почему это правильное решение для учебной задачи: любой кипер — это
внешняя зависимость, депозит и отдельная экономика, которая к механике
рекуррентного платежа отношения не имеет.

Для стенда остается вариант 4 — списание вызывает получатель (или мы руками
из скрипта). Это честно воспроизводит суть pull-модели: **контракт не
самоисполняем, кто-то должен прийти и попросить**. Минутный период как раз
делает это наблюдаемым за пять минут.

Отдельно стоит зафиксировать в объяснении стенда: газ платит **вызывающий**,
а не владелец разрешения. Это неинтуитивно для человека с карточным опытом,
где комиссию платит мерчант через эквайрера, и это одно из главных отличий,
которое стенд может показать наглядно.

---

## Источники

- [Spark Research: Recurring Stablecoin Payments — Building Subscription Infrastructure On-Chain](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)
- [Chainlink Docs: Automation Billing and Costs](https://docs.chain.link/chainlink-automation/overview/automation-economics)
- [Chainlink Docs: Automation Interfaces](https://docs.chain.link/chainlink-automation/reference/automation-interfaces)
- [Chainlink Docs: Time-based Upkeeps (Job Scheduler)](https://docs.chain.link/chainlink-automation/guides/job-scheduler)
- [Chainlink Docs: Managing Upkeeps](https://docs.chain.link/chainlink-automation/guides/manage-upkeeps)
- [Gelato Docs: Web3 Functions](https://docs.gelato.cloud/web3-services/web3-functions)
- [Pyth Docs: Using Gelato](https://docs.pyth.network/price-feeds/core/schedule-price-updates/using-gelato)
- [Superfluid Docs: Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)
- [Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)
- [Maker Protocol Docs: Liquidation 2.0 Module](https://docs.makerdao.com/smart-contract-modules/dog-and-clipper-detailed-documentation)
- [StableSims: Optimizing MakerDAO Liquidations 2.0 Incentives (arXiv:2201.03519)](https://arxiv.org/abs/2201.03519)
- [B.Protocol: The Keeper's Dilemma](https://medium.com/b-protocol/the-keepers-dilemma-game-theoretic-analysis-of-liquidation-incentives-with-preliminary-b588e82e4d67)
- [KuCoin Learn: Understanding Ethereum Gas Fees](https://www.kucoin.com/learn/web3/understanding-ethereum-gas-fees)
- [TokenHook: Secure ERC-20 smart contract (arXiv:2107.02997)](https://arxiv.org/pdf/2107.02997)
- [Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)
- [Loop Crypto: Live on Base](https://www.loopcrypto.xyz/blog/loop-crypto-is-live-on-base)
- [Request Network Docs: Recurring payments](https://docs.request.network/request-network-api/recurring-payments)
- [Spritz Blog: Introducing SMARTPay](https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments)
- [Spritz Help Center: How does SMARTPay work?](https://help.spritz.finance/en/articles/7065236-how-does-smartpay-work)
