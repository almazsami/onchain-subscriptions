# Блок 4. Сбойные сценарии рекуррентных платежей на цепочке

Что ломается в подписке на цепочке и как с этим живут существующие решения.

Дата сбора: 25 августа 2026.

---

## Главный вывод блока

Общего стандарта нет. Формулировка отраслевого обзора буквальная:
**«There is no universal standard for retry logic in on-chain billing»**, а то,
что делают провайдеры, — «Platforms like Loop and Spritz are building retry and
webhook infrastructure, but it is proprietary rather than standardized»
([Spark Research: Recurring Stablecoin Payments](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).

Полный список причин сбоя оттуда же: «Insufficient balance, revoked approvals,
wallet migration, and contract upgrades can all cause failures» (там же).

Для сравнения, в карточном мире есть отработанный dunning: «when a card charge
fails, the merchant retries using established dunning sequences: retry on day 3,
again on day 7, send a notification, downgrade the account» (там же).
На цепочке этого слоя просто нет — его каждый достраивает сам, офчейн.

---

## Сценарий 1. Отозванное разрешение

### Что происходит

`transferFrom` откатывается. Контракт не может ни помешать отзыву, ни узнать
о нем заранее — allowance меняется в контракте токена, а не в контракте
подписки.

Отзыв односторонний и мгновенный: пользователь «can limit the most a company
can charge and can revoke this amount at any time»
([Loop Crypto Blog: Updating your spend allowance](https://www.loopcrypto.xyz/blog/updating-your-spend-allowance-on-loops-customer-portal)).

### Как обрабатывают

**Loop Crypto** — как одну из четырех причин отсутствия события оплаты.
Дословный список причин, по которым не приходит `TransferProcessed`:

> «The wallet does not have enough balance to cover the payment»
> «The wallet does not have enough token allowance to cover the payment»
> «The transaction is stuck in the mempool»
> «Loop's relay network is down»

([Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions))

Обратите внимание: недостаток allowance и недостаток баланса — **разные
причины с одинаковым результатом**. Их стоит различать и в стенде.

Реакция у Loop — не автоматика в контракте, а событийная модель наружу:
компании получают вебхуки и сами решают, «how "aggressive" they want to be
about payment confirmation» — отложить доступ или показать предупреждение
(там же).

**Request Network** переводит расписание в паузу: «If a payment fails (for
example due to insufficient funds), the schedule is paused» — после устранения
причины расписание снимается с паузы
([Request Network Docs: Recurring payments](https://docs.request.network/request-network-api/recurring-payments)).

**Модели без allowance** этот сценарий не имеют вовсе: у Sablier деньги уже
в контракте, у Superfluid они уже в Super Token. Отзывать нечего — можно только
остановить сам поток.

### Что показать на стенде

Отзыв разрешения — это не «взлом» и не ошибка, а штатное право плательщика.
Хороший демо-шаг: `approve(subscription, 0)`, затем попытка списания —
и наблюдаемый отказ. Витрина при этом должна перестать показывать «факт минуты».

---

## Сценарий 2. Нехватка баланса

### Что происходит

Разрешение есть, денег нет. `transferFrom` откатывается по той же причине —
недостаточный баланс `from`.

С точки зрения контракта подписки этот случай **неотличим по последствиям**
от отозванного разрешения, но отличим по диагностике: allowance можно
прочитать, баланс тоже.

### Как обрабатывают

**Loop** — отдельная причина в списке выше
([Loop Crypto Docs](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)).

**Request Network** — прямо назван как пример: «due to insufficient funds»,
расписание встает на паузу
([Request Network Docs](https://docs.request.network/request-network-api/recurring-payments)).

**Superfluid** — единственная модель, где нехватка баланса имеет ончейн-развязку.
При открытии потока берется **buffer** (порядка четырех часов потока), и аккаунт
проходит три состояния: solvent (баланс > 0), critical (баланс = 0, поток идет
за счет буфера), insolvent (буфер исчерпан). Поток закрывают внешние акторы
— Sentinels, забирая буфер как вознаграждение; роли разведены по времени
(Patrician в первые 30 минут, Plebs, Pirates)
([Superfluid Docs: Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)).

То есть у Superfluid нехватка баланса стоит отправителю денег — он теряет
буфер. Это плата за то, что получатель все это время получал средства
без единой транзакции.

**Sablier Flow** нехватку баланса не считает сбоем, а превращает в **долг**:
uncovered debt — это часть общего долга, не покрытая балансом потока
([Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)).
Поток продолжает начислять, пока его не поставят на паузу.

### Что показать на стенде

Различать в интерфейсе три причины отказа: нет разрешения, не хватает
разрешения, не хватает баланса. Это ровно то, что скрыто в карточной фразе
«платеж отклонен».

---

## Сценарий 3. Пропущенные периоды

### Суть проблемы

Списание не самоисполняемо (см. блок 3). Если вызывающий не пришел вовремя,
период проходит «вхолостую». Дальше есть развилка:

- **Догонять** — списать за все пропущенные периоды сразу;
- **Не догонять** — считать пропущенный период потерянным;
- **Копить долг** — фиксировать задолженность и брать ее позже.

### Как решают

**Sablier Flow — копит долг.** Именно этому и посвящена модель: rps x время
дает общий долг, и поток можно поставить на паузу и позже перезапустить
«without losing track of previously accrued debt». Финансировать поток при
этом можно «with any amount, at any time, by anyone, in full or partially» —
то есть догон происходит пополнением, а не отдельным «списанием за прошлое»
([Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)).

Жесткий вариант — `void`: «voiding an insolvent stream forfeits the uncovered
debt» (там же). Долг просто списывается в ноль.

**Superfluid — понятия пропущенного периода нет.** Баланс считается формулой
«Static Balance + Netflow Rate x seconds since last update», и «Creating a
stream is a one-time action. The balance is dynamically calculated and does not
require continuous transactions»
([Superfluid Docs: Money Streaming](https://docs.superfluid.org/docs/concepts/overview/money-streaming)).
Нечего пропускать — некому опаздывать.

**Loop — счета не исчезают.** При отмене «all future scheduled invoices will be
cancelled but any currently due invoices will not be»
([Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)).
То есть уже наступивший, но неоплаченный период остается долгом.

**Request — пауза, а не пропуск.** Неудачный платеж останавливает расписание;
пока оно на паузе, новые платежи не наступают
([Request Network Docs](https://docs.request.network/request-network-api/recurring-payments)).

**Простые реализации на allowance догон не описывают.** В учебном PoC на
`approve` + timelocked `transferFrom` есть `subscriptionTimeRemaining()` и
проверка оплаченности текущего периода, но отдельной логики для пропущенных
циклов нет
([Jon-Becker/ethereum-recurring-payments](https://github.com/Jon-Becker/ethereum-recurring-payments)).

### Скрытая опасность догона

Если контракт умеет списывать «за все пропущенные периоды сразу», то долгое
отсутствие вызывающего превращается в один крупный неожиданный списание.
Для пользователя это выглядит как несанкционированный платеж, хотя формально
разрешение было. Явного источника, обсуждающего именно этот риск, найти не
удалось — **не подтверждено**, но развилка реальна и требует решения в
спецификации.

---

## Сценарий 4. Отмена

### Кто может отменить

Здесь модели расходятся сильнее всего.

**Sablier Lockup — только создатель потока.** «The stream can be stopped at any
time by the stream creator, with the unstreamed funds being returned over to the
stream creator»; получатель отменить не может. Поток можно создать
неотменяемым, и тогда «recipients are guaranteed to receive all funds». Перевод
отменяемого потока в неотменяемый возможен, обратный — нет
([Sablier Docs: Cancelability](https://docs.sablier.com/concepts/cancelability)).

**Sablier Flow — отмены нет вообще**, есть пауза с возможностью возобновления
(там же) и `void` как окончательное прекращение
([Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)).

**Superfluid — обе стороны.** Поток «persists until it's canceled by either the
sender or the receiver, or until the sender's Super Token balance is depleted»
([Superfluid Docs: Money Streaming](https://docs.superfluid.org/docs/concepts/overview/money-streaming)).
Плюс третья категория — Sentinels при неплатежеспособности
([Superfluid Docs: Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)).

**Loop — отмена на стороне компании плюс отзыв allowance на стороне
пользователя.** Компания отменяет запланированные платежи через дашборд,
контракт эмитит `AgreementCancelled`, «that can be used to manage the end
customer's access»
([Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)).
Пользователь же всегда может отозвать разрешение
([Loop Crypto Blog](https://www.loopcrypto.xyz/blog/updating-your-spend-allowance-on-loops-customer-portal)).

**Request — API-действие cancel**, которое «stops all future payments»
([Request Network Docs](https://docs.request.network/request-network-api/recurring-payments)).

**Учебный PoC — обе стороны**: «Subscriptions can be cancelled at any time,
by either the `_spender` or the `_payee`»
([Jon-Becker/ethereum-recurring-payments](https://github.com/Jon-Becker/ethereum-recurring-payments)).

### Что происходит с деньгами при отмене

Для предоплаченных моделей (Sablier Lockup) есть три разных исхода:

- отмена **до старта** — весь депозит возвращается отправителю;
- отмена **во время** потока — контракт считает, сколько уже доступно
  получателю, и возвращает остаток отправителю; получатель затем забирает
  свою часть;
- отмена **после окончания** — все оставшиеся средства уходят получателю
  ([Sablier Docs: Streaming](https://github.com/sablier-labs/docs/blob/main/docs/concepts/02-streaming.md)).

Для pull-моделей вопроса возврата при отмене не возникает: деньги не уходили
из кошелька, отмена просто прекращает будущие списания. Ровно поэтому
пропорциональный перерасчет при отмене — нецель в AGENTS.md: в pull-модели
он попросту не нужен, если период короткий.

---

## Сценарий 5. Возвраты

### Фундаментальное ограничение

Возврата в смысле карточного chargeback на цепочке не существует.
«On-chain payments are final by design. Recurring stablecoin payments create
ambiguity around refund rights, billing disputes, and regulatory compliance»
([Spark Research](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).

Возврат — это **новая транзакция в обратную сторону**: «A merchant can issue a
refund for a crypto transaction, but this must come in the form of a separate
transaction for the same amount as the transaction being "reversed." The initial
transfer of cryptocurrency is non-reversible»
([Chargebacks911: Crypto Chargebacks](https://chargebacks911.com/crypto-chargebacks/)).

Следствие: «the dispute usually shifts from a network reversal process to a
merchant-side refund, review, or support workflow»
([Chargeback.io: Crypto Payment Chargebacks](https://www.chargeback.io/blog/what-to-know-about-crypto-chargebacks)).

То есть спор переезжает целиком в офчейн, к получателю денег. Никакого
арбитра со стороны сети нет.

### Единственное исключение — предоплаченные модели

У Sablier «возврат» встроен, потому что деньги еще не ушли получателю: отмена
возвращает неотстримленную часть отправителю
([Sablier Docs: Cancelability](https://docs.sablier.com/concepts/cancelability)).
Это не возврат платежа, а невыдача еще не выданного — принципиально другая
вещь.

---

## Сценарий 6. Инфраструктурные сбои

Отдельная категория, которую легко забыть, потому что она не про деньги.

Loop честно перечисляет ее в тех же четырех причинах:
«The transaction is stuck in the mempool» и «Loop's relay network is down»
([Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)).

У Chainlink Automation аналог — исчерпание баланса upkeep: «If the Upkeep LINK
balance drops below the minimum balance, the Chainlink Automation Network will
not perform the Upkeep»
([Chainlink Docs: Automation Billing and Costs](https://docs.chain.link/chainlink-automation/overview/automation-economics)).

Плюс упомянутые в общем списке «wallet migration, and contract upgrades»
([Spark Research](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).

Важное следствие: **отсутствие платежа не означает отказ плательщика**.
Loop поэтому разводит «нет события» и «отказ» и оставляет решение компании:
насколько агрессивно интерпретировать молчание
([Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)).

---

## Сводная таблица

| Сбой | Sablier Lockup | Sablier Flow | Superfluid | Loop | Request |
|---|---|---|---|---|---|
| Отозвано разрешение | Неприменимо | Неприменимо | Неприменимо | Причина неоплаты, вебхук | Списание невозможно |
| Нет баланса | Неприменимо | Копится uncovered debt | Critical → Insolvent, Sentinel закрывает, буфер теряется | Причина неоплаты, вебхук | Расписание на паузе |
| Пропущенный период | Не бывает | Копится в долг | Не бывает | Счет остается должным | Не наступает, пока пауза |
| Отмена | Только отправитель, возврат неотстримленного | Pause / void | Любая из сторон | Компания (`AgreementCancelled`) + отзыв allowance | API cancel |
| Возврат | Встроен как возврат остатка | Через void | Через закрытие потока | Только новой транзакцией | Только новой транзакцией |
| Инфраструктура упала | Нет зависимости | Нет зависимости | Нет зависимости | «relay network is down» | Не подтверждено |

---

## Что из этого стоит воспроизвести на стенде

Стенд работает в pull-модели, поэтому его сбойные сценарии — левый столбец
Loop и Request:

1. **Отозванное разрешение** — `approve(sub, 0)`, попытка списания, отказ.
2. **Недостаточное разрешение** — `approve` на 3 периода, четвертое списание
   не проходит. Это отдельный случай, не путать с п. 1.
3. **Нехватка баланса** — разрешение есть, токенов нет.
4. **Пропущенный период** — никто не вызвал списание минуту. Решение о том,
   догонять или нет, — вопрос к спецификации, а не к коду.
5. **Отмена** — кто имеет право, и что происходит с уже наступившим периодом.

Возвраты воспроизводить нечем и незачем: на цепочке они существуют только как
обратный перевод, а это уже не механика подписки.

Главное, что стенд может показать честнее любой статьи: **отказ в списании —
это нормальное состояние системы, а не авария**. Разрешение отзываемо,
баланс может кончиться, вызывающий может не прийти. Витрина, которая гаснет,
когда «факт минуты» не оплачен, — и есть визуализация этого факта.

---

## Источники

- [Spark Research: Recurring Stablecoin Payments — Building Subscription Infrastructure On-Chain](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)
- [Loop Crypto Docs: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)
- [Loop Crypto Blog: Updating your spend allowance](https://www.loopcrypto.xyz/blog/updating-your-spend-allowance-on-loops-customer-portal)
- [Request Network Docs: Recurring payments](https://docs.request.network/request-network-api/recurring-payments)
- [Sablier Docs: Cancelability](https://docs.sablier.com/concepts/cancelability)
- [Sablier Docs: Flow Overview](https://docs.sablier.com/concepts/flow/overview)
- [Sablier Docs: Streaming (GitHub)](https://github.com/sablier-labs/docs/blob/main/docs/concepts/02-streaming.md)
- [Superfluid Docs: Money Streaming](https://docs.superfluid.org/docs/concepts/overview/money-streaming)
- [Superfluid Docs: Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)
- [Chainlink Docs: Automation Billing and Costs](https://docs.chain.link/chainlink-automation/overview/automation-economics)
- [Chargebacks911: Crypto Chargebacks — Are Crypto Payments Reversible?](https://chargebacks911.com/crypto-chargebacks/)
- [Chargeback.io: Crypto Payment Chargebacks — What Merchants Should Know](https://www.chargeback.io/blog/what-to-know-about-crypto-chargebacks)
- [Jon-Becker/ethereum-recurring-payments](https://github.com/Jon-Becker/ethereum-recurring-payments)
