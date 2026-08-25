# Кто в реальности вызывает списание в рекуррентных платежах on-chain

Исследовательская записка. Дата сбора материала: 2026-08-25.

Назначение: разобраться, какие механизмы запуска периодического списания
существуют в проде, чем они платят за надежность и что из этого имеет смысл
для локального учебного стенда.

Дисциплина источников: каждый содержательный тезис снабжен URL. Там, где
надежного источника не нашлось, стоит прямая пометка **не подтверждено** —
цифры и тарифы в таких местах не додумывались.

---

## 0. Исходная посылка: контракт не запускает себя сам

Базовое ограничение EVM: у контракта нет собственного таймера или планировщика.

> «Smart contracts do not run automatically... an externally owned account (EOA),
> or another contract account, must trigger the right functions to execute the
> contract's code.»
> — https://ethereum.org/developers/docs/smart-contracts/

То есть в любой схеме рекуррентного платежа есть **отправитель транзакции**,
который платит газ и берет на себя ответственность за то, что вызов вообще
произойдет вовремя. Весь дальнейший разбор — про то, кто это лицо и на каких
условиях оно работает.

Вторая посылка — pull-модель. Плательщик заранее выдает `approve` на контракт
подписки, а списание идет через `transferFrom`. Значит, вызывающий не обязан
быть плательщиком: он лишь «дергает ручку», а деньги двигаются между
плательщиком и получателем. Это разъединение вызова и оплаты и порождает все
описанные ниже варианты.

---

## 1. Keeper-сети (внешняя децентрализованная автоматизация)

### 1.1 Chainlink Automation (бывш. Chainlink Keepers)

**Модель регистрации.** Разработчик регистрирует *upkeep*: указывает адрес
целевого контракта, тип триггера, имя, адрес администратора, лимит газа и
стартовый баланс в LINK.
— https://docs.chain.link/chainlink-automation/overview/getting-started

Поддерживаются три типа триггеров:

- **Time-based** — по расписанию, задается CRON-выражением;
- **Custom logic** — Solidity-логика, которую узлы сети вычисляют off-chain;
- **Log trigger** — событие лога как триггер и как входные данные.

— https://docs.chain.link/chainlink-automation/overview/getting-started

**Интерфейс.** Контракт реализует `AutomationCompatibleInterface`:

```solidity
function checkUpkeep(bytes calldata checkData)
    external view returns (bool upkeepNeeded, bytes memory performData);

function performUpkeep(bytes calldata performData) external;
```

— https://docs.chain.link/chainlink-automation/reference/automation-interfaces

`checkUpkeep` «contains the logic that will be executed offchain to see if
`performUpkeep` should be executed», а `performUpkeep` «will be executed onchain
when `checkUpkeep` returns `true`».
— https://docs.chain.link/chainlink-automation/guides/compatible-contracts

Ключевая деталь для подписок: `checkUpkeep` симулируется бесплатно, вне цепочки,
и там можно проводить дорогие вычисления (например, обход списка подписок и
поиск тех, у кого истек период), передавая результат в `performUpkeep` через
`performData`.
— https://docs.chain.link/chainlink-automation/guides/compatible-contracts

**Кто фактически шлет транзакцию.** Узлы Automation образуют p2p-сеть на
протоколе OCR3, локально симулируют `checkUpkeep`, приходят к консенсусу по
списку upkeep'ов, подписывают отчет; отчет проверяется реестром (Registry) перед
исполнением on-chain. Реестр же и платит узлам за успешно выполненный upkeep.
— https://docs.chain.link/chainlink-automation/concepts/automation-architecture

**Кто платит газ.** Формально газ платит узел Automation, но экономически —
владелец upkeep'а из его баланса в LINK (или в нативном токене). Формула из
документации:

```
FeeLINK   = [tx.gasPriceNative_WEI * gasUsed * (1 + premium%)
             + (gasOverhead * tx.gasPriceNative_WEI)] / LINK_NativeRate_WEI

FeeNative = tx.gasPriceNative_WEI * gasUsed * (1 + premium%)
             + (gasOverhead * tx.gasPriceNative_WEI)
```

— https://docs.chain.link/chainlink-automation/overview/automation-economics

Там же: `gasOverhead` — фиксированная надбавка, «typically 80,000 gas»,
описывается как газ между сетью и реестром; процентная премия «compensates the
Automation Network for monitoring and performing your upkeep». Поддерживается
минимальный баланс с запасом на скачки цены газа; при отмене upkeep'а с
пожизненными тратами менее 0.1 LINK удерживается 0.1 LINK как антиспам-мера.

Конкретные значения премии (таблица supported networks):

| Сеть | Payment Premium % | Perform Gas Limit |
|---|---|---|
| Ethereum Mainnet | 20 | 5 000 000 |
| Arbitrum One | 50 | 5 000 000 |
| Optimism Mainnet | 50 | 5 000 000 |
| Base Mainnet | 50 | 5 000 000 |
| Polygon Mainnet | 70 | 5 000 000 |

— https://docs.chain.link/chainlink-automation/overview/supported-networks

Отсюда практический вывод для подписок: **стоимость одного списания через
Chainlink Automation ≈ (газ вызова × 1.2 + 80 000) × цена газа** на Ethereum.
Надбавка в 80 000 газа сопоставима с самим списанием (см. раздел 5), то есть
автоматизация может удвоить стоимость операции. Это оценка на основе формулы из
документации, не измерение.

**Кто гарантирует вызов.** Явной гарантии исполнения в документации нет.
Заявлены механизмы надежности: тот же transaction manager, что у Data Feeds,
устойчивость к скачкам газа и реоргам, избыточность узлов.
— https://docs.chain.link/chainlink-automation/concepts/automation-architecture

Но best practices прямо предупреждают о «мерцающих» (flickering) upkeep'ах —
когда условие быстро переключается true/false, «your upkeep is at risk of not
being performed»; между наблюдением состояния, консенсусом и подтверждением
транзакции есть задержка. Рекомендуется перепроверять условие внутри
`performUpkeep` и делать его идемпотентным.
— https://docs.chain.link/chainlink-automation/concepts/best-practice

**Безопасность вызова.** По умолчанию `performUpkeep` открыт для кого угодно.
Для каждого зарегистрированного upkeep'а разворачивается персональный контракт
Forwarder; чтобы ограничить вызывающего, в контракт добавляют

```solidity
require(msg.sender == s_forwarderAddress, "This address does not have permission");
```

— https://docs.chain.link/chainlink-automation/guides/forwarder

Для подписки это важный выбор: если `charge()` открыт всем, keeper-сеть
становится удобным, но не единственным способом вызова (см. раздел 4); если
закрыт форвардером — вы жестко привязаны к одному провайдеру.

Общее позиционирование сервиса — снять с разработчика «setup cost, ongoing
maintenance, and risks associated with a centralized automation stack».
— https://docs.chain.link/chainlink-automation

### 1.2 Gelato Network — Web3 Functions / Automate

**Модель.** Web3 Functions — задачи (tasks) с тремя типами триггеров: **Time**
(по расписанию), **Event** (по событию on-chain), **Every block**.
Логика может быть написана как TypeScript-функция, как Solidity-функция
(«checker»/resolver) или задана как Automated Transaction с фиксированными
аргументами.
— https://docs.gelato.cloud/web3-services/web3-services/web3-functions
(навигация: https://docs.gelato.cloud/web3-services/web3-functions)

Важно для нашей темы: **рекуррентные платежи названы штатным сценарием
использования** Automated Transactions — «Recurring payments (subscriptions,
payroll)».
— https://docs.gelato.cloud/web3-functions/introduction/automated-transactions

Web3Functions «run as stateless scripts in a new and empty memory context on
every execution» — то есть состояние держать негде, все существенное должно
жить в контракте.
— https://docs.gelato.cloud/web3-services/web3-functions/quick-start/writing-typescript-functions

**Оплата: 1Balance (Gas Tank).** Единый кросс-чейн баланс: «pay all of your costs
across all the networks that you are using from one single easy-to-manage
balance». Основной токен пополнения — **USDC**, с поддержкой кросс-чейн
депозитов через Circle CCTP. Перед исполнением Gelato «will query their Gas Tank
to see if they possess enough equivalent USDC to cover the costs», а после —
«can use the transaction receipts to charge you exactly the amount that the
transaction costs plus a nominal fee».
— https://docs.gelato.cloud/web3-services/1balance

Отдельная модель для Relay — **SyncFee**: комиссия платится синхронно внутри
самой транзакции, в нативном или ERC-20 токене (`callWithSyncFee`,
`callWithSyncFeeERC2771`).
— https://docs.gelato.cloud/Relay/Subscription-and-payments/SyncFee-payment-tokens

Для подписки это концептуально интересно: SyncFee-подобная схема позволяет
контракту подписки **самому оплатить исполнителя из списанных средств**, а не из
предоплаченного баланса разработчика.

**Безопасность вызова: dedicated msg.sender.** При создании первой задачи
пользователю разворачивается персональный прокси-контракт. Модификатор
`onlyDedicatedMsgSender` из `AutomateReady` «restricts msg.sender to only task
executions created by taskCreator defined in the constructor». Ограничение
ставится на исполняемую функцию, **не** на checker-функцию; адрес dedicated
msg.sender различается по сетям.
— https://docs.gelato.cloud/web3-functions/security-considerations/dedicated-msg-sender
— https://github.com/gelatodigital/automate/blob/master/contracts/integrations/AutomateReady.sol

Это прямой аналог Forwarder'а у Chainlink.

**Отличия от Chainlink (по существу источников):**

| Ось | Chainlink Automation | Gelato Web3 Functions |
|---|---|---|
| Валюта оплаты | LINK или нативный токен, баланс на upkeep | USDC в 1Balance (кросс-чейн), либо SyncFee внутри транзакции |
| Модель списания | премия % от газа + фиксированный overhead | по факту чека транзакции + «nominal fee» |
| Off-chain логика | `checkUpkeep` — только Solidity, симулируется узлами | TypeScript или Solidity checker |
| Ограничение вызывающего | Forwarder | dedicated msg.sender |
| Триггеры | time / custom logic / log | time / event / every block |

Маркетинговый материал самого Gelato противопоставляет «worker model»
(«functions run off-chain at intervals and only post on-chain if needed»)
request/response-модели и утверждает «gas + computation (paid in stable USDC),
no registry fee» против «three fees: gas, computation, and registry (all paid in
volatile LINK)».
— https://gelato.cloud/blog/gelato-functions-vs-chainlink-functions

Оговорка: это **вендорский материал**, и сравнивает он с Chainlink *Functions*
(вычисления), а не с Chainlink *Automation*. Приведенные там цифры экономии
($7.2/день против $288/день, «97.5% cheaper») относятся к оракульному сценарию,
не к подпискам, и независимо не проверены — **не подтверждено**.

**Точный процент сервисной комиссии Gelato поверх газа — не подтверждено.**
В доступной документации формулировка остается качественной («nominal fee»,
«percentage of total gas cost», выше на дешевых сетях и ниже на дорогих);
числового тарифа на страницах docs.gelato.cloud найти не удалось. Поиск
дополнительно засоряется одноименной типографской компанией Gelato.

**Степень децентрализации исполнителей Gelato — не подтверждено.** Документация
описывает механику задач и оплаты, но состав и число исполнителей, а также
процедура консенсуса между ними на найденных страницах не раскрыты (в отличие от
Chainlink, где явно назван OCR3).

### 1.3 OpenZeppelin Defender — Actions + Relayers

Промежуточный вариант: не децентрализованная keeper-сеть, а управляемый
хостинг-исполнитель.

**Actions** — «автоматизированные фрагменты кода на JavaScript, выполняемые по
триггерам». Триггеры: **Schedule** (в том числе cron-выражения), **Webhook**
(POST на выданный URL), **Monitor** (алерт от модуля мониторинга).
Среда: Node.js 20, 256 MB RAM, таймаут до 5 минут.
— https://docs.openzeppelin.com/defender/module/actions

Исторически это называлось Autotasks; в текущей документации — Actions.
— https://docs.openzeppelin.com/defender/module/actions

**Relayers** отправляют транзакции. Приватные ключи хранятся в AWS KMS: «Keys
are generated within the KMS and never leave it, i.e., all sign operations are
executed within the KMS». При подключении action к relayer «Defender
автоматически внедряет временные учетные данные», так что ключ не попадает в код.
— https://docs.openzeppelin.com/defender/module/relayers
— https://docs.openzeppelin.com/defender/module/actions

Отдельно ценны инженерные детали, которые обычно и оказываются больным местом
самодельного исполнителя: relayer «validates the request, atomically assigns it
a nonce, reserves balance for paying for its gas fees, resolves its speed to a
gasPrice or maxFeePerGas/maxPriorityFeePerGas», следит за незамайненными
транзакциями каждую минуту и переотправляет их «with a 10% increase in their
respective transaction type pricing», вплоть до 150% исходной цены.
— https://docs.openzeppelin.com/defender/module/relayers

Газ здесь платится с баланса релеера, то есть напрямую владельцем сервиса.
**Тарифы Defender — не подтверждено** (страницы с ценами не проверялись).

### 1.4 Keep3r Network

Модель принципиально иная: не «вы нанимаете провайдера», а «открытый рынок
исполнителей».

Keeper — «внешний адрес, который выполняет job»; контракты регистрируются как
jobs, а keeper'ы — как доступные исполнители, каждый со своей инфраструктурой и
собственными правилами прибыльности.
— https://docs.keep3r.network/core/jobs

Job'у нужен кредит, чтобы платить keeper'ам, и получить его можно двумя путями:

1. **Credit Mining** — кто угодно поставляет ликвидность в пул Keep3r (kLP) и
   стейкает kLP-токены; job начинает «намайнивать» кредиты KP3R, которые
   «can be collected only by keepers as rewards for working the job» и не могут
   быть выведены.
2. **Token Payments** — кто угодно депонирует ERC-20 и задает ставку выплат
   (`directTokenPayment()`, `worked()`), позволяя протоколу рассчитывать выплату
   в зависимости от фактически потраченного газа.

— https://docs.keep3r.network/tokenomics/job-payment-mechanisms
— https://docs.keep3r.network/tokenomics/job-payment-mechanisms/token-payments
— https://docs.keep3r.network/tokenomics/job-payment-mechanisms/credit-mining

Кредиты могут быть срезаны через Slasher или Governance.

Для подписок это ближе всего к разделу 4 (стимулирование сторонних вызывающих),
только оформленное как отдельный протокол-посредник.
**Текущая активность и объемы сети Keep3r не проверялись — не подтверждено.**

---

## 2. Собственный сервис-исполнитель (свой бэкенд, горячий ключ, крон)

Самый очевидный и самый распространенный вариант на практике: сервер с cron,
приватным ключом и RPC-эндпоинтом, который раз в период дергает `charge()`.

**Что дает:**

- Полный контроль над логикой отбора: кого списывать, в каком порядке, что
  делать при неудаче. Никакого ограничения вида «`checkUpkeep` должен быть
  `view`».
- Отсутствие премии посредника: платится ровно газ и ничего сверху (сравните с
  +20…+70% и +80 000 газа у Chainlink, раздел 1.1).
- Мгновенная реакция на инцидент: остановить крон проще, чем отменять upkeep.
- Возможность делать retry по своей политике, батчить списания, откладывать при
  дорогом газе.

**Чем платит:**

- **Горячий ключ.** Ключ должен быть доступен процессу в момент подписи. Именно
  ради снятия этой проблемы Defender явно рекомендует relayer вместо хранения
  ключа в коде и держит ключи в KMS без возможности экспорта
  (https://docs.openzeppelin.com/defender/module/relayers). Если вы делаете свое,
  KMS/HSM и ротацию ключей придется строить самому.
- **Доступность.** Крон, упавший на сутки, — это сутки непрошедших списаний. У
  keeper-сети избыточность узлов заявлена как встроенное свойство
  (https://docs.chain.link/chainlink-automation/concepts/automation-architecture);
  у одного сервера ее нет.
- **Nonce и переотправка.** Это не мелочь: атомарная выдача nonce, резервирование
  баланса под газ, отслеживание зависших транзакций и bump цены на 10% —
  реальный объем работы, который Defender описывает как отдельную подсистему
  (https://docs.openzeppelin.com/defender/module/relayers).
- **Централизация.** Оператор бэкенда становится единственной точкой отказа и
  единственной точкой доверия: он решает, кого и когда списать. Chainlink прямо
  продает свой сервис как избавление от «risks associated with a centralized
  automation stack» (https://docs.chain.link/chainlink-automation).
- **Баланс на газ.** Кошелек исполнителя надо пополнять; при пустом балансе
  подписки молча перестают списываться.

Промежуточный вывод: разница между «своим сервисом» и keeper-сетью — это не
разница в возможностях, а разница в том, кому вы отдаете операционный риск и
сколько за это платите.

---

## 3. Вызов самим получателем платежа (merchant-initiated pull)

Модель, наиболее близкая к привычным карточным подпискам: списание инициирует
тот, кто получает деньги.

Канонический пример спецификации — **ERC-1337 «Subscriptions on the
blockchain»** (из рабочей группы ERC-948), статус **Stagnant**, создан в августе
2018 года.
— https://eips.ethereum.org/EIPS/eip-1337

Механика: плательщик один раз подписывает off-chain мета-транзакцию, хеш которой
собран из параметров платежа; получатель хранит подпись у себя и периодически
переотправляет ее в блокчейн:

> «the owner would sign this hash and then provide it to the party for execution
> at a later date»

Подписываемые параметры `executeSubscription`: `to`, `value`, `data`,
`operation`, `txGas`, `dataGas`, `gasPrice`, `gasToken`, а также массив `meta`
с `refundAddress`, `period`, `offChainID`, `expiration`.
— https://eips.ethereum.org/EIPS/eip-1337

Стандарт мотивирует это тем, что рекуррентные платежи — «bedrock of SaaS and
countless other businesses», и что общая спецификация дает интероперабельность:
кошелек может распознать контракт подписки и показать пользователю понятный
интерфейс управления и отмены.
— https://eips.ethereum.org/EIPS/eip-1337

**Плюсы merchant-initiated:**

- Стимул к вызову совпадает с интересом: получателю деньги нужны, значит он
  вызовет. Не нужна ни премия постороннему, ни подписка на keeper-сеть.
- Никакого нового доверенного лица: получатель и так сторона договора.
- Естественная политика повтора: не списалось сегодня — попробует завтра,
  никакого внешнего SLA не требуется.

**Минусы:**

- Газ платит получатель, и он платит его **до** того, как убедится, что списание
  пройдет: если у плательщика не хватило баланса или он отозвал allowance,
  транзакция ревертится, а газ сгорает. ERC-1337 решает это на своем уровне:
  «a failed execution will still pay the issuer of the transaction for their gas
  costs» (https://eips.ethereum.org/EIPS/eip-1337) — то есть исполнителю
  компенсируют газ даже при неуспехе, что само по себе создает риск
  злоупотребления при плохой валидации.
- Точность периода зависит от дисциплины получателя. «Раз в минуту» превращается
  в «когда бэкенд получателя дошел до этой подписки».
- Для получателя это тот же «свой сервис-исполнитель» из раздела 2 со всеми его
  проблемами — просто ответственность назначена явно.
- При большом числе подписчиков получатель несет весь газ, а значит имеет стимул
  батчить и откладывать списания, что размывает понятие «периода».

---

## 4. Стимулирование сторонних вызывающих (открытый `charge()` с наградой)

Схема: функция списания открыта для кого угодно, а контракт из списанной суммы
выплачивает вызывающему вознаграждение — фиксированное, процентное или в размере
возмещения газа плюс премия. Экономически это то же, что делает Keep3r
(раздел 1.4), только без отдельного протокола.

**Кто платит награду.** Варианта два, и выбор между ними — продуктовое решение,
а не техническое:

1. **Плательщик** — награда вычитается сверх суммы подписки, allowance должен ее
   покрывать. Плательщик платит за автоматизацию своей же подписки.
2. **Получатель** — награда вычитается из суммы, доходящей до получателя. Тогда
   реальная выручка получателя плавает вместе с ценой газа.

Смешанная схема (награда = газ по факту, сверху фиксированный процент) — это
ровно то, что делает `worked()` в Keep3r, рассчитывая выплату «в зависимости от
объема газа, затраченного на конкретную транзакцию»
(https://docs.keep3r.network/tokenomics/job-payment-mechanisms).

**Риски.**

*Гонка за вызов и сожженный газ.* Как только вызов становится прибыльным, за
него начинают конкурировать боты. Это классический MEV-сценарий, ближайший
аналог — ликвидации в лендинге:

> «Searchers engage in gas-price auctions, progressively raising gas costs to
> guarantee transaction inclusion. This raises network fees for regular users…»
> — https://ethereum.org/developers/docs/mev/

Исходное академическое описание механики — *Flash Boys 2.0* (Daian et al., 2019,
IEEE S&P 2020): боты «competitively bidding up transaction fees in order to
obtain priority ordering», используя механизм замены транзакций и p2p-сеть.
— https://arxiv.org/abs/1904.05234

Практическое следствие для подписки: победитель забирает награду, а все
проигравшие транзакции ревертятся, но их **газ все равно оплачен и включен в
блок**. С точки зрения сети это чистые потери, с точки зрения контракта —
шум в логах и переменная задержка списания.

*Экономически невыгодные вызовы.* Если награда меньше стоимости газа, никто не
вызовет — подписка просто не спишется. Проблема острая именно для мелких
платежей: награда должна покрывать газ (раздел 5), а газ на L1 сопоставим с
самим платежом. Это делает схему нестабильной: при росте цены газа система
самопроизвольно останавливается, причем молча.

*Дублирование и порядок.* Открытая функция должна быть идемпотентной и
перепроверять условие внутри себя — ровно то, что Chainlink требует от
`performUpkeep`: перепроверять условия из `checkUpkeep` и не допускать повторного
выполнения одной и той же работы
(https://docs.chain.link/chainlink-automation/concepts/best-practice,
https://docs.chain.link/chainlink-automation/guides/compatible-contracts).

*Grief-вектор.* Если вознаграждение выплачивается и при неуспешном списании (как
предусматривает ERC-1337 для своего исполнителя), появляется стимул вызывать
заведомо провальные списания ради компенсации газа. Логика выплаты должна
различать «списание прошло» и «попытка была».

*Утечка приватности.* Открытый `charge()` означает, что расписание всех подписок
публично и наблюдаемо — по нему видно, кто, кому и сколько платит и когда.
Это не уязвимость, но проектное свойство, о котором стоит знать.

---

## 5. Экономика газа

### 5.1 Из чего складывается стоимость одного списания

Все константы ниже — из спецификации исполнения Ethereum (файл `gas.py`, форк
Cancun), она же машиночитаемая версия газовой таблицы Yellow Paper:
— https://github.com/ethereum/execution-specs/blob/master/src/ethereum/forks/cancun/vm/gas.py

| Константа | Значение | Что это |
|---|---|---|
| `TX_BASE` | 21 000 | базовая стоимость любой транзакции |
| `TX_DATA_PER_NON_ZERO` | 16 | за каждый ненулевой байт calldata |
| `TX_DATA_PER_ZERO` | 4 | за каждый нулевой байт calldata |
| `WARM_ACCESS` | 100 | «теплый» доступ к слоту/аккаунту |
| `COLD_STORAGE_ACCESS` | 2 100 | первый (холодный) `SLOAD` слота |
| `COLD_ACCOUNT_ACCESS` | 2 600 | первое обращение к чужому аккаунту (внешний `CALL`) |
| `STORAGE_SET` | 20 000 | запись в слот, который был нулевым |
| `COLD_STORAGE_WRITE` | 5 000 | перезапись ненулевого слота при холодном доступе |
| `REFUND_STORAGE_CLEAR` | 4 800 | возврат за обнуление слота |
| `OPCODE_LOG_BASE` | 375 | база события |
| `OPCODE_LOG_TOPIC` | 375 | за каждый topic события |
| `OPCODE_LOG_DATA_PER_BYTE` | 8 | за байт данных события |

Первоисточники по правилам warm/cold и SSTORE:
— https://eips.ethereum.org/EIPS/eip-2929 (`COLD_SLOAD_COST` 2100,
  `WARM_STORAGE_READ_COST` 100, `COLD_ACCOUNT_ACCESS_COST` 2600,
  `SSTORE_RESET_GAS` 5000 → 2900 плюс холодная надбавка 2100)
— https://eips.ethereum.org/EIPS/eip-2200 (`SSTORE_SET_GAS` 20 000)
— https://eips.ethereum.org/EIPS/eip-3529 (`SSTORE_CLEARS_SCHEDULE` снижен с
  15 000 до 4 800; максимальный рефанд ограничен `gas_used // 5`)

Комиссия по EIP-1559: **Total Fee = Units of Gas Used × (Base Fee + Priority
Fee)**, base fee сжигается и меняется максимум на 12.5% за блок.
— https://ethereum.org/en/developers/docs/gas/

### 5.2 Порядок газа для `transferFrom`

Измеренные значения (Foundry, минимальные реализации, Solidity 0.8.26):

| Операция | OpenZeppelin | Solmate |
|---|---|---|
| `approve` | 32 599 | 32 787 |
| `transfer` (получатель с ненулевым балансом) | 20 666 | 20 913 |
| `transfer` (получатель с нулевым балансом) | 37 744 | 37 991 |
| `transferFrom` (получатель с ненулевым балансом) | 28 152 | 26 573 |
| `transferFrom` (получатель с нулевым балансом) | 45 274 | 43 695 |

— https://github.com/alephao/solidity-benchmarks/blob/main/benchmarks/0.8.26/ERC20.md

**Существенная оговорка от автора бенчмарка:** «газ, показанный в бенчмарках, не
учитывает 21k газа, добавляемого к каждой транзакции Ethereum», а сами замеры
«не на 100% точны, но достаточны для сравнения реализаций».
— https://github.com/alephao/solidity-benchmarks

Отсюда **оценка** полной стоимости одиночного `transferFrom`, отправленного EOA
напрямую в токен: 21 000 + 28 000…45 000 ≈ **49 000…66 000 газа**. Разброс
почти двукратный и определяется одной вещью: был ли баланс получателя ненулевым
(перезапись слота 5 000 против записи в нулевой слот 20 000).

Для подписки это означает, что **первое списание в адрес нового получателя
заметно дороже последующих** — и что «средняя» цифра газа обманчива.

### 5.3 Надстройка контракта подписки

Контракт подписки добавляет к `transferFrom` свою работу. Ориентировочный состав
(оценка на основе таблицы констант выше, не измерение):

- холодное чтение записи подписки: 1–3 × `COLD_STORAGE_ACCESS` = 2 100…6 300;
- обновление «времени следующего списания» / счетчика периодов: `COLD_STORAGE_WRITE`
  ≈ 5 000 за слот (или 20 000, если слот был нулевым — первое списание);
- внешний `CALL` в контракт токена: `COLD_ACCOUNT_ACCESS` = 2 600;
- событие вида `Charged(address indexed payer, address indexed merchant, uint256 amount)`:
  375 + 2 × 375 + 8 × 32 ≈ 1 380;
- calldata вызова (селектор + пара адресов/идентификаторов): порядка нескольких
  сотен газа при `TX_DATA_PER_NON_ZERO` = 16;
- проверки (период истек, подписка активна, не отменена) — единицы сотен газа.

Суммарная **оценка одного списания «контракт подписки → ERC-20 transferFrom»:
порядка 70 000…110 000 газа**, с верхней границей на первом списании и на
«холодном» состоянии. Это порядок величины, выведенный из газовой таблицы, а не
результат замера конкретного контракта. Замер на стенде даст точную цифру.

Если списание идет через keeper-сеть, к этому добавляется премия сети. Для
Chainlink на Ethereum: `gasUsed × 1.2 + 80 000` — то есть при 90 000 газа
эффективно оплачивается около **188 000 газа**, вдвое больше самой работы
(расчет по формуле из
https://docs.chain.link/chainlink-automation/overview/automation-economics
и таблице премий
https://docs.chain.link/chainlink-automation/overview/supported-networks;
это арифметика по документированной формуле, не измерение).

### 5.4 Как это соотносится с размером платежа

Здесь важна методика, а не конкретная цифра: цена газа плавает, и любая
абсолютная сумма устаревает за часы.

Метод: `доля_газа = газ_списания × цена_газа_в_валюте_платежа / сумма_платежа`.

Иллюстрация на снимке публичного агрегатора (проверено 2024-08-25 по адресу
https://l2fees.info/; **на странице нет временной метки**, значения меняются
непрерывно, поэтому все выводимые ниже суммы — иллюстрация метода, а не
утверждение о текущих ценах):

| Сеть | Send ETH (21 000 газа) |
|---|---|
| Ethereum L1 | $1.10 |
| Arbitrum One | $0.09 |
| Optimism | $0.09 |

Из строки L1: стоимость единицы газа ≈ $1.10 / 21 000 ≈ $0.0000524. Тогда:

- списание на 70 000 газа ≈ **$3.7**;
- списание на 110 000 газа ≈ **$5.8**;
- то же через Chainlink Automation (188 000 газа-эквивалента) ≈ **$9.8**.

Все три числа — **оценка**, производная от снимка выше.

Практические следствия (при этом порядке цен):

- Подписка на **$5/мес** на L1 съедается газом целиком или почти целиком. Схема
  бессмысленна.
- Подписка на **$10/мес** отдает газу от трети до половины; через keeper-сеть —
  практически всю сумму. Тоже нежизнеспособно.
- Подписка становится осмысленной на L1 примерно от **$100+ за период**, когда
  газ уходит в единицы процентов. Это и объясняет, почему on-chain подписки за
  условные $9.99 в месяц на L1 в проде не встречаются.
- Чем **чаще период**, тем хуже: минутный период на L1 — это ~43 200 списаний в
  месяц, каждое со своей полной стоимостью. Порядок расходов на газ за месяц при
  минутном периоде на L1 получается абсурдным (сотни тысяч долларов по оценке
  выше) — это не инженерная проблема, а арифметический запрет.

### 5.5 Роль L2

L2 не делает выполнение дешевле — оно делает дешевле **публикацию данных**.
На OP Stack комиссия складывается из трех частей:

> «totalFee = operatorFee + gasUsed * (baseFee + priorityFee) + l1Fee»

— https://docs.optimism.io/stack/transactions/fees

Ключевое для оценок: «gas used by a transaction on OP Mainnet is exactly the
same as the gas used by the same transaction on Ethereum» — то есть все расчеты
раздела 5.2–5.3 переносятся на L2 без изменений, меняется только цена газа и
добавляется L1 data fee.

После обновления Ecotone батчи публикуются в **blob'ах** (EIP-4844), и формула
взвешенной цены становится:

> «weighted_gas_price = 16*base_fee_scalar*base_fee + blob_base_fee_scalar*blob_base_fee»

для blob-сетей «current Ethereum blob data gas price will largely determine the
L1 Data Fee». Обновление Fjord добавило оценку сжатого размера через FastLZ.
— https://docs.optimism.io/stack/transactions/fees

Практические выводы для подписок:

- **L1 data fee зависит от размера транзакции, а не от потраченного газа.** Это
  ломает линейную экстраполяцию «стоимость ∝ газ», которой я пользовался в 5.4:
  на L2 компактный calldata важнее числа операций. Батчинг многих списаний в
  одну транзакцию на L2 выгоден дважды — экономит и 21 000 базовых, и место в
  блобе.
- По снимку l2fees.info разница L1 и L2 составляет порядка **10–12 раз** для
  простой отправки ETH ($1.10 против $0.09). Это сдвигает порог осмысленности
  подписки примерно на порядок вниз — с сотен долларов к десяткам. Оценка,
  производная от снимка без временной метки.
- Премия keeper-сети на L2, наоборот, **выше**: 50% на Arbitrum/Optimism/Base и
  70% на Polygon против 20% на Ethereum
  (https://docs.chain.link/chainlink-automation/overview/supported-networks).
  Но 50% от дешевого газа все равно дешевле 20% от дорогого.
- Абсолютные цифры «сколько стоит подписка на L2 сегодня» — **не подтверждено**:
  для этого нужен свежий замер, а не ссылка на страницу без временной метки.

---

## 6. Сравнительная таблица

| Вариант | Кто отправляет транзакцию | Кто платит газ | Гарантии доставки | Централизация |
|---|---|---|---|---|
| **Chainlink Automation** | узлы сети Automation, через Registry и Forwarder ([арх.](https://docs.chain.link/chainlink-automation/concepts/automation-architecture)) | владелец upkeep'а из баланса LINK/native: `gasUsed × (1+premium%) + gasOverhead` ([экономика](https://docs.chain.link/chainlink-automation/overview/automation-economics)) | явной гарантии нет; заявлены избыточность узлов и transaction manager, но документация предупреждает о риске непроведения при «мерцающих» условиях ([best practices](https://docs.chain.link/chainlink-automation/concepts/best-practice)) | низкая на уровне исполнения (сеть узлов, OCR3), но зависимость от одного провайдера и от LINK |
| **Gelato Web3 Functions** | исполнители Gelato через dedicated msg.sender ([док](https://docs.gelato.cloud/web3-functions/security-considerations/dedicated-msg-sender)) | владелец задачи из 1Balance в USDC, по факту чека + «nominal fee» ([1Balance](https://docs.gelato.cloud/web3-services/1balance)); либо SyncFee внутри транзакции ([SyncFee](https://docs.gelato.cloud/Relay/Subscription-and-payments/SyncFee-payment-tokens)) | явной гарантии в найденной документации нет — **не подтверждено** | состав исполнителей и механизм консенсуса не раскрыты — **не подтверждено**; зависимость от одного провайдера |
| **OZ Defender Actions + Relayer** | релеер OpenZeppelin, ключ в AWS KMS ([док](https://docs.openzeppelin.com/defender/module/relayers)) | владелец релеера со своего баланса | нет гарантии; есть автоматическая переотправка с bump +10% до 150% ([док](https://docs.openzeppelin.com/defender/module/relayers)) | высокая: один управляемый провайдер, один аккаунт-отправитель |
| **Keep3r Network** | произвольный keeper, зарегистрированный в сети ([док](https://docs.keep3r.network/core/jobs)) | keeper авансом, компенсируется из кредитов job'а ([док](https://docs.keep3r.network/tokenomics/job-payment-mechanisms)) | нет: вызов происходит, только если keeper'у выгодно | низкая на уровне исполнителей, но добавляется зависимость от токена KP3R и governance/slasher |
| **Свой бэкенд с горячим ключом** | ваш сервер | вы, со своего кошелька | нет: ровно ваш uptime, ваш баланс, ваша политика retry | максимальная: одна точка отказа и одна точка доверия |
| **Получатель платежа (merchant-initiated)** | получатель ([ERC-1337](https://eips.ethereum.org/EIPS/eip-1337)) | получатель, включая газ на неуспешных попытках | нет; но стимул совпадает с интересом — получатель хочет получить деньги | средняя: доверенное лицо и так сторона договора, нового доверия не вводится |
| **Открытый вызов с наградой** | кто угодно | вызывающий авансом, компенсируется наградой из платежа | нет и в худшем виде: при невыгодности вызова система молча останавливается | минимальная по доверию; взамен — гонка за вызов, MEV, сожженный газ проигравших ([MEV](https://ethereum.org/developers/docs/mev/), [Flash Boys 2.0](https://arxiv.org/abs/1904.05234)) |

Сквозное наблюдение: **ни один из вариантов не дает гарантии доставки в
криптографическом смысле.** Все они дают либо экономический стимул, либо
операционное обязательство провайдера. Единственное, что контракт может
гарантировать сам, — это что списание *не произойдет* раньше срока и не
произойдет дважды. Идемпотентность и перепроверка условия внутри функции списания
поэтому не «хорошая практика», а единственная часть схемы, которая держится на
самом контракте.

---

## 7. Что применимо к локальному учебному стенду

На стенде автоматический шедулер сознательно не используется: списание запускает
человек (или скрипт по явной команде). С точки зрения этого исследования такой
выбор не «упрощение ради лени», а **вырожденный случай раздела 2** — свой
исполнитель, у которого крон заменен на руку оператора. Это дает четыре вещи:

1. **Роль вызывающего остается отдельной и явной.** Контракт все равно должен
   отвечать на вопрос «кто имеет право вызвать `charge()`»: только получатель,
   только назначенный оператор, или кто угодно. Это тот же выбор, что стоит перед
   Forwarder'ом Chainlink и dedicated msg.sender у Gelato — на стенде он просто
   решается без внешнего провайдера. Стоит зафиксировать решение сознательно, а
   не по умолчанию.

2. **Идемпотентность и перепроверка условия обязательны и на стенде.** Ручной
   вызов не спасает от двойного списания: оператор может нажать дважды. Требование
   Chainlink «revalidate the conditions specified in `checkUpkeep` in your
   `performUpkeep` function» и «performUpkeep should be idempotent»
   (https://docs.chain.link/chainlink-automation/concepts/best-practice,
   https://docs.chain.link/chainlink-automation/guides/compatible-contracts)
   переносится один в один. Это, пожалуй, главный переносимый вывод.

3. **Разделение «можно ли списать» и «списать» имеет смысл сохранить.** Пара
   view-функция + транзакция (по образцу `checkUpkeep`/`performUpkeep` или
   Gelato checker/exec) на стенде полезна сама по себе: view-функция дает UI
   ответ «пора или нет» без транзакции и делает состояние наблюдаемым. При этом
   реализовывать интерфейс `AutomationCompatibleInterface` не нужно — это была бы
   работа под несуществующего на стенде провайдера.

4. **Замер газа — самая ценная часть, которую стенд может дать честно.**
   Оценка 70 000…110 000 газа из раздела 5.3 выведена из газовой таблицы, а не
   измерена. Foundry дает точную цифру для конкретного контракта. Замер одного
   списания на стенде превращает всю арифметику раздела 5.4 из литературной
   оценки в проверяемое число — и это единственное место, где локальный стенд
   говорит о реальности больше, чем документация.

Чего **не** стоит тащить на стенд:

- Интеграцию с любой keeper-сетью — это сетевой вызов наружу и зависимость от
  внешнего провайдера.
- Вознаграждение стороннему вызывающему — оно осмысленно только там, где есть
  конкуренция исполнителей и реальная цена газа; на локальном узле с бесплатным
  газом эта механика вырождается и учит неправильному.
- Оптимизацию газа под L2-специфику (компактный calldata ради blob'ов) — она
  относится к конкретной сети, которой на стенде нет.

Отдельно: минутный период на стенде — это осознанное искажение ради наблюдаемости
(увидеть несколько периодов за сеанс). Раздел 5.4 показывает, что в реальной
экономике L1 минутный период невозможен ни при каких суммах. Стоит держать это
различие в голове и не переносить со стенда вывод «минута работает».

---

## 8. Сводка неподтвержденного

Чтобы не выдавать оценки за факты, перечисляю явно:

- **Точный процент сервисной комиссии Gelato** поверх газа для Web3 Functions —
  в документации только качественные формулировки («nominal fee», «percentage of
  total gas cost»); числа не найдены.
- **Степень децентрализации исполнителей Gelato** — число, состав и механизм
  консенсуса между исполнителями в найденной документации не описаны.
- **SLA/формальная гарантия исполнения** ни у Chainlink Automation, ни у Gelato,
  ни у Defender — в документации не обнаружена. У Chainlink есть прямое
  предупреждение о риске непроведения upkeep'а.
- **Цифры экономии из вендорского блога Gelato** ($7.2/день против $288/день,
  «97.5% cheaper») — маркетинговый материал, сравнивающий с Chainlink *Functions*,
  а не *Automation*; независимо не проверено.
- **Тарифы OpenZeppelin Defender** — не проверялись.
- **Текущее состояние и активность Keep3r Network** — не проверялись; описана
  только механика по документации.
- **Актуальные цены газа и все производные от них долларовые суммы** — снимок
  https://l2fees.info/ без временной метки, проверен 2026-08-25. Все суммы в
  разделе 5.4 — иллюстрация метода, а не утверждение о ценах.
- **Оценка 70 000…110 000 газа** на одно списание — арифметика по газовой
  таблице, не измерение. Подлежит проверке замером на стенде.
- **Оценка 49 000…66 000 газа** на одиночный `transferFrom` — сумма измеренного
  бенчмарка и `TX_BASE` = 21 000; бенчмарк сделан на минимальных реализациях и
  по признанию автора «не на 100% точен».

---

## Источники

Ethereum, базовая механика и газ:
- https://ethereum.org/developers/docs/smart-contracts/
- https://ethereum.org/en/developers/docs/gas/
- https://ethereum.org/developers/docs/mev/
- https://github.com/ethereum/execution-specs/blob/master/src/ethereum/forks/cancun/vm/gas.py
- https://eips.ethereum.org/EIPS/eip-2200
- https://eips.ethereum.org/EIPS/eip-2929
- https://eips.ethereum.org/EIPS/eip-3529
- https://eips.ethereum.org/EIPS/eip-1337
- https://arxiv.org/abs/1904.05234

Chainlink Automation:
- https://docs.chain.link/chainlink-automation
- https://docs.chain.link/chainlink-automation/overview/getting-started
- https://docs.chain.link/chainlink-automation/overview/automation-economics
- https://docs.chain.link/chainlink-automation/overview/supported-networks
- https://docs.chain.link/chainlink-automation/concepts/automation-architecture
- https://docs.chain.link/chainlink-automation/concepts/best-practice
- https://docs.chain.link/chainlink-automation/guides/compatible-contracts
- https://docs.chain.link/chainlink-automation/guides/forwarder
- https://docs.chain.link/chainlink-automation/reference/automation-interfaces

Gelato:
- https://docs.gelato.cloud/web3-services/web3-functions
- https://docs.gelato.cloud/web3-functions/introduction/automated-transactions
- https://docs.gelato.cloud/web3-services/1balance
- https://docs.gelato.cloud/web3-functions/security-considerations/dedicated-msg-sender
- https://docs.gelato.cloud/Relay/Subscription-and-payments/SyncFee-payment-tokens
- https://docs.gelato.cloud/web3-services/web3-functions/quick-start/writing-typescript-functions
- https://github.com/gelatodigital/automate
- https://github.com/gelatodigital/automate/blob/master/contracts/integrations/AutomateReady.sol
- https://gelato.cloud/blog/gelato-functions-vs-chainlink-functions (вендорский материал)

OpenZeppelin Defender:
- https://docs.openzeppelin.com/defender/module/actions
- https://docs.openzeppelin.com/defender/module/relayers

Keep3r Network:
- https://docs.keep3r.network/
- https://docs.keep3r.network/core/jobs
- https://docs.keep3r.network/tokenomics/job-payment-mechanisms
- https://docs.keep3r.network/tokenomics/job-payment-mechanisms/token-payments
- https://docs.keep3r.network/tokenomics/job-payment-mechanisms/credit-mining

L2 и стоимость:
- https://docs.optimism.io/stack/transactions/fees
- https://l2fees.info/ (без временной метки, значения плавают)
- https://github.com/alephao/solidity-benchmarks
- https://github.com/alephao/solidity-benchmarks/blob/main/benchmarks/0.8.26/ERC20.md
