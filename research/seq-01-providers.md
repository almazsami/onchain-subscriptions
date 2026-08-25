# Блок 1. Как устроены существующие решения рекуррентных платежей на EVM

Материал собран поиском в сети. Каждый содержательный тезис снабжен ссылкой.
Там, где надежного источника найти не удалось, стоит пометка **не подтверждено**.

Дата сбора: 25 августа 2026.

---

## Сводная таблица

| Решение | Модель | Кто инициирует перевод | За чей газ | Как отзывается разрешение |
|---|---|---|---|---|
| Sablier Lockup | Предоплата: отправитель запирает всю сумму в контракте, получатель тянет по чуть-чуть | Получатель (`withdraw`) | Того, кто вызывает `withdraw` | Разрешение не нужно: деньги уже в контракте. Отправитель делает `cancel` и забирает неотстримленный остаток |
| Sablier Flow | Долговая: поток без предоплаты, контракт учитывает долг | Получатель (`withdraw`, функция публичная) | Того, кто вызывает | Отправитель ставит `pause` или `void` |
| Superfluid | Непрерывный поток Super Token, баланс считается формулой | Никто: баланс меняется без транзакций | Разовый газ на открытие/закрытие потока | Отправитель (или получатель) закрывает поток; при неплатежеспособности поток закрывает Sentinel |
| Loop Crypto | Pull через ERC-20 `approve` | Компания-получатель через инфраструктуру Loop | Не подтверждено | Пользователь меняет/обнуляет allowance |
| Spritz (SMARTPay) | Одна подпись на год вперед, USDC на Polygon | Сервис Spritz | Spritz (для пользователя «gasless») | Не подтверждено |
| Request Network | EIP-712 permit на серию платежей + allowance на контракт | Request Network API по расписанию | Не подтверждено (в документации отсутствует) | Отзыв allowance ломает списание; штатно — `cancel` через API |

---

## 1. Sablier

### Модель Lockup (закрытые потоки)

Отправитель депонирует сумму целиком: протокол позволяет «lock a specified amount
of funds in a smart contract», после чего токены становятся доступны получателю
непрерывно, буквально посекундно
([Sablier Docs: Streaming](https://github.com/sablier-labs/docs/blob/main/docs/concepts/02-streaming.md),
[Sablier Docs: Token Distribution](https://docs.sablier.com/concepts/streaming)).

Это принципиально другая модель, чем pull через `approve`: **разрешения не
существует, потому что деньги уже не у плательщика**. Отзывать нечего.
Отменить можно сам поток: «you can cancel the stream and reclaim any unstreamed
funds» — при отмене контракт считает, сколько уже «настримилось» получателю,
и возвращает остаток отправителю
([Sablier Docs: Streaming](https://github.com/sablier-labs/docs/blob/main/docs/concepts/02-streaming.md)).

Каждый Lockup-поток минтится как ERC-721 NFT, что делает позицию передаваемой
и торгуемой ([Sablier Docs: Types of Streams](https://docs.sablier.com/concepts/protocol/stream-types)).

Цена модели — заморозка капитала: «The sender needs to deposit a large amount
of ERC-20 tokens upfront»
([Sablier Blog: An Overview of Token Streaming Models](https://blog.sablier.com/overview-token-streaming-models)).
Зато нет внешних зависимостей: «no off-chain components are required» (там же).

### Модель Flow (открытые потоки)

Flow отслеживает **долг** между двумя сторонами. Поток описывается ставкой
в секунду (rps), долг = rps x прошедшее время. Предоплаты нет: «there are no
upfront deposit requirements, and a stream can be funded with any amount,
at any time, by anyone, in full or partially»
([Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)).

Ключевое понятие — **uncovered debt**: часть долга, не покрытая балансом потока.
Отправитель может поставить поток на паузу и позже перезапустить «without losing
track of previously accrued debt»; `void` делает перезапуск невозможным, причем
«voiding an insolvent stream forfeits the uncovered debt» (там же).

Функция `withdraw` публичная, но средства уходят на адрес получателя
(там же). То есть газ платит вызывающий, а выгоду получает получатель —
это уже мостик к блоку 3 про стимулирование сторонних вызывающих.

Позиционирование Flow прямо включает подписки: «payroll, subscriptions, grant
distributions, insurance premiums, loans interest, and token ESOPs»
([Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)).

---

## 2. Superfluid

### Модель

Money Streaming — «a continuous transfer of tokens from a sender to a receiver
at a defined per-second rate», поток живет, пока его не закроет одна из сторон
или пока не кончится баланс Super Token отправителя
([Superfluid Docs: Money Streaming](https://docs.superfluid.org/docs/concepts/overview/money-streaming)).

Поток задается тремя параметрами: Sender, Receiver, FlowRate (в wei в секунду)
([Superfluid Blog: Superfluid Streams](https://medium.com/superfluid-blog/superfluid-streams-5cc5141dd8a7)).

Самое важное отличие от pull-модели: **транзакций на каждый период нет**.
«Creating a stream is a one-time action. The balance is dynamically calculated
and does not require continuous transactions». Баланс = Static Balance +
Netflow Rate x секунды с последнего обновления
([Superfluid Docs: Money Streaming](https://docs.superfluid.org/docs/concepts/overview/money-streaming)).

Работает это только с Super Token — обернутой версией обычного ERC-20.
Wrapping/unwrapping — разовые операции, влияющие только на Static Balance
(там же).

### Кто инициирует и за чей газ

Никто и никак: между открытием и закрытием потока транзакций не нужно.
Газ тратится один раз на `createFlow` и один раз на `deleteFlow`.
«Streams can be created, updated, or deleted at any time by the sender»
([Superfluid Docs: Money Streaming Overview](https://docs.superfluid.org/docs/protocol/money-streaming/overview)).

### Отзыв разрешения и делегирование

Прямого аналога `approve` нет — вместо него есть **ACL (Access Control List)**:
любой аккаунт может выдать другому адресу права create/update/delete на свои
потоки плюс `flowRateAllowance` — суммарный прирост ставки потока, который
оператор вправе сделать. Права выдаются через `updateFlowOperatorPermissions`
(значение прав — uint256 от 1 до 7), оператор действует через
`createFlowByOperator`
([Superfluid Docs: CFA Access Control List](https://github.com/superfluid-finance/docs/blob/main/developers/constant-flow-agreement-cfa/cfa-access-control-list-acl/README.md),
[Superfluid Wiki: About CFA ACL Feature](https://github.com/superfluid-finance/protocol-monorepo/wiki/About-CFA-ACL-Feature)).

Отзыв — это вызов того же `updateFlowOperatorPermissions` с обнуленными правами,
либо просто закрытие потока отправителем.

### Как решается неплатежеспособность

При открытии потока протокол берет **buffer** (депозит), обычно порядка четырех
часов потока. Три состояния аккаунта: solvent (баланс > 0), critical (баланс = 0,
поток идет за счет буфера), insolvent (буфер исчерпан)
([Superfluid Docs: Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)).

Закрывают такие потоки внешние акторы — **Sentinels**, и им за это платят из
буфера. Роли разведены по времени: Patrician (PIC) получает награду в течение
30-минутного Patrician Period, Plebs — позже, Pirates — на стадии полной
неплатежеспособности (там же). Роль PIC разыгрывается через TOGA (Transparent
OnGoing Auction): претендент вносит stake, более высокая ставка вытесняет
текущего PIC; при инсольвентности PIC теряет из ставки slashing fee размером
с дефицит (там же).

Газ платит тот, кто отправил транзакцию закрытия, — это может быть кто угодно
(там же). Это готовый пример «стимулирования сторонних вызывающих» из блока 3.

---

## 3. Loop Crypto

### Модель

Классический pull через ERC-20 `approve`, максимально похожий на карточный
рекуррент. «A customer authorizes their wallet to be charged, and each billing
period the wallet is charged without the end customer having to take action»
([Loop Crypto: SaaS](https://www.loopcrypto.xyz/saas)).

При покупке пользователь «sign[s] a transaction from their wallet providing the
business with authorization and approval to charge them for a specific token on
a specific network»
([Loop Crypto Docs](https://docs.loopcrypto.xyz)).

Loop прямо формулирует смысл allowance: «Setting this allowance does not mean
you are giving your tokens to the 3rd party. All it means is you are willingly
allowing the smart contract to transfer up-to a specified amount of a token on
your behalf»
([Loop Crypto Blog: Updating your spend allowance](https://www.loopcrypto.xyz/blog/updating-your-spend-allowance-on-loops-customer-portal)).

### Размер разрешения

Бесконечное разрешение сознательно не используется. По умолчанию Loop предлагает
**13-кратную сумму подписки** для месячных подписок (первый платеж + год) и
однократную сумму для разовых платежей; компания может переопределить дефолт,
но «end customers always maintain control over the final allowance amount»
([Loop Crypto Docs: Checkout widget](https://loop-crypto.gitbook.io/old-loop-crypto/technical-docs/archeticture/collecting-authorization/checkout-widget)).

Утверждение, что в контрактах Loop «there are no infinite allowance functions
that can be used to empty a wallet's balance» и что списывать может только
контрагент-компания, встречается в обзоре инвестора, а не в самой документации
([VeradiVerdict: Loop — Web3 Payment Rail](https://www.veradiverdict.com/p/web3-payment-rail)).
Считать это первичным источником нельзя.

### Кто инициирует перевод

Компания-получатель: после получения авторизации она создает transfer request
(счет) — автоматически по частоте тарифа или вручную. «Once you have
authorization to bill a customer, you can then schedule payments»
([Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)).

Событийная модель разводит авторизацию и оплату: `AgreementSignedUp` означает
только что кошелек выставил allowance, «it does not mean you have been paid yet»;
факт оплаты — это `TransferProcessed`, и между ними есть задержка, «as the
transaction must be confirmed on-chain» (там же).

### За чей газ

**Не подтверждено.** В доступной документации Loop вопрос газа не раскрыт.
Известно только, что Loop берет комиссию с платежа: «Loop takes a small fee from
each payment as it orchestrates payment from the customer to the merchant»
([Loop Crypto](https://www.loopcrypto.xyz/)).

### Отзыв разрешения

Через портал покупателя: allowance можно поменять или обнулить в любой момент,
«you can limit the most a company can charge and can revoke this amount at any
time»
([Loop Crypto Blog: Updating your spend allowance](https://www.loopcrypto.xyz/blog/updating-your-spend-allowance-on-loops-customer-portal)).
Если allowance не хватает, платеж просто не проходит — среди причин отсутствия
`TransferProcessed` документация называет «The wallet does not have enough token
allowance to cover the payment»
([Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)).

---

## 4. Spritz (SMARTPay)

### Модель

Spritz — не подписка на сервис, а оплата реальных счетов криптой; рекуррентную
часть закрывает функция SMARTPay. «SMARTPay lets you set up recurring payments
using your crypto with the click of a button, and sign just one transaction for
up to a year's worth of planned monthly payments to your billing account»
([Spritz Help Center: How does SMARTPay work?](https://help.spritz.finance/en/articles/7065236-how-does-smartpay-work)).

Пользователь задает сумму, день месяца и количество повторов, затем подписывает
одну транзакцию
([Spritz Blog: Introducing SMARTPay](https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments)).

Ограничение: только USDC в сети Polygon
([Spritz Help Center](https://help.spritz.finance/en/articles/7065236-how-does-smartpay-work)).

### Кто инициирует и за чей газ

Инициирует сам сервис в назначенную дату, без участия пользователя. Газ на
пользователя не перекладывается: «Users pay ZERO gas fees on SMARTPay
transactions», сами транзакции описаны как «gasless, monthly transactions»
([Spritz Blog: Introducing SMARTPay](https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments)).

Кто именно оплачивает газ технически (релеер Spritz, meta-transaction, что-то
еще) — **не подтверждено**, в доступных материалах не раскрыто.

### Отзыв разрешения

**Не подтверждено.** Процедура отмены и поведение при нехватке баланса в
справке, которую удалось прочитать, не описаны — статья прямо отсылает
в поддержку.

---

## 5. Request Network

### Модель

«Approve once, set and forget», все on-chain и аудируемо
([Request Network Docs: Recurring payments](https://docs.request.network/request-network-api/recurring-payments)).

Авторизация двухчастная:

1. **ERC-20 allowance**: «For the first payment, the payer may also need to
   approve a token allowance for the recurring payment contract» и «approve the
   recurring payment contract to spend the required token amount (if not already
   approved)» (там же).
2. **EIP-712 payment permit**: плательщик подписывает типизированные данные с
   получателем, суммой, расписанием (старт, частота, число платежей) и сроком
   истечения — «The payer signs the payment permit with an EIP-712 signature»
   (там же).

Контракт при каждом списании проверяет валидность подписи, что платеж не был
выполнен ранее и что платежи идут в правильном порядке (там же).

### Кто инициирует

Request Network API: «the API handling the scheduling and triggering of these
payments to automate regular transfers» (там же).

### За чей газ

**Не подтверждено.** В тексте документации по рекуррентным платежам слова
gas, relayer, executor отсутствуют.

### Сбои и отмена

При неудаче расписание встает на паузу: «If a payment fails (for example due to
insufficient funds), the schedule is paused» — после устранения причины
расписание снимается с паузы (там же).

Штатная отмена — через PATCH-эндпоинт с действием cancel, который останавливает
все будущие платежи (там же).

Отзыв allowance плательщиком технически ломает списание — контракт перестает
получать доступ к токенам; отдельного описания этого сценария как
пользовательского пути в документации нет.

---

## Что из этого важно для стенда

Три принципиально разные модели, а не три реализации одной:

1. **Предоплата (Sablier Lockup)** — деньги уходят из кошелька плательщика
   сразу. Отзывать разрешение нечего, но капитал заморожен.
2. **Непрерывный поток (Superfluid)** — нет ни разрешения, ни периодических
   транзакций, но требуется обертка токена и целая экономика ликвидаторов,
   чтобы поток не ушел в минус.
3. **Pull через allowance (Loop, Request, отчасти Spritz)** — ровно та модель,
   которую воспроизводит наш стенд: `approve` от пользователя, `transferFrom`
   от контракта раз в период, инициатор — получатель или его инфраструктура.

Общая для pull-моделей развилка, которую придется решать и нам: **разрешение
отзываемо в одностороннем порядке и в любой момент**, и ни один из провайдеров
не может этому помешать. Loop честно делает отзыв частью пользовательского
интерфейса, Request переводит расписание в паузу. Подробнее — в блоке 4.

---

## Источники

- [Sablier Docs: Streaming (GitHub)](https://github.com/sablier-labs/docs/blob/main/docs/concepts/02-streaming.md)
- [Sablier Docs: Token Distribution](https://docs.sablier.com/concepts/streaming)
- [Sablier Docs: Types of Streams](https://docs.sablier.com/concepts/protocol/stream-types)
- [Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)
- [Sablier Blog: An Overview of Token Streaming Models](https://blog.sablier.com/overview-token-streaming-models)
- [Superfluid Docs: Money Streaming (concepts)](https://docs.superfluid.org/docs/concepts/overview/money-streaming)
- [Superfluid Docs: Money Streaming Overview (protocol)](https://docs.superfluid.org/docs/protocol/money-streaming/overview)
- [Superfluid Docs: Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)
- [Superfluid Docs: CFA Access Control List (GitHub)](https://github.com/superfluid-finance/docs/blob/main/developers/constant-flow-agreement-cfa/cfa-access-control-list-acl/README.md)
- [Superfluid Wiki: About CFA ACL Feature](https://github.com/superfluid-finance/protocol-monorepo/wiki/About-CFA-ACL-Feature)
- [Superfluid Blog: Superfluid Streams](https://medium.com/superfluid-blog/superfluid-streams-5cc5141dd8a7)
- [Loop Crypto Docs](https://docs.loopcrypto.xyz)
- [Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)
- [Loop Crypto Docs: Checkout widget](https://loop-crypto.gitbook.io/old-loop-crypto/technical-docs/archeticture/collecting-authorization/checkout-widget)
- [Loop Crypto Blog: Updating your spend allowance](https://www.loopcrypto.xyz/blog/updating-your-spend-allowance-on-loops-customer-portal)
- [Loop Crypto: SaaS](https://www.loopcrypto.xyz/saas)
- [VeradiVerdict: Loop — Web3 Payment Rail](https://www.veradiverdict.com/p/web3-payment-rail)
- [Spritz Help Center: How does SMARTPay work?](https://help.spritz.finance/en/articles/7065236-how-does-smartpay-work)
- [Spritz Blog: Introducing SMARTPay](https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments)
- [Request Network Docs: Recurring payments](https://docs.request.network/request-network-api/recurring-payments)
