# Рекуррентные платежи на цепочке: что можно построить и чем за это платят

Сводный документ по материалам `research/`. Источник каждого содержательного
тезиса указан ссылкой. Тезис без источника помечен как **не подтверждено** —
это означает «в просмотренных материалах источник не найден», а не «скорее
всего неверно».

Исходные материалы собраны 25 августа 2026 двумя независимыми прогонами:
последовательным (`seq-01`…`seq-04`) и параллельным (`providers`, `allowance`,
`trigger`, `failures`). Там, где два файла по одной теме расходятся, расхождение
названо в тексте, а не разрешено молча.

---

## 1. Вопрос исследования

Можно ли построить рекуррентные платежи на цепочке так, чтобы они работали
без офчейн-сервиса, и чем приходится платить.

Ответ упирается в базовое свойство EVM: у контракта нет собственного таймера.

> «Smart contracts do not run automatically... an externally owned account (EOA),
> or another contract account, must trigger the right functions to execute the
> contract's code.»
> — [ethereum.org: Smart contracts](https://ethereum.org/developers/docs/smart-contracts/)

Значит, в любой схеме периодического платежа есть кто-то, кто отправляет
транзакцию и платит за нее газ. Вопрос «без офчейн-сервиса» распадается на два:
можно ли обойтись без внешнего исполнителя (раздел 5) и можно ли обойтись
без внешней логики обработки сбоев (раздел 6). Ответы на них разные.

---

## 2. Три модели

### 2.1. Предоплата с разблокировкой по времени (Sablier Lockup)

Отправитель вносит всю сумму в контракт заранее; получателю она становится
доступна непрерывно, «малыми порциями токенов, высвобождаемыми от отправителя
к получателю каждую секунду»
([Sablier: Streaming](https://docs.sablier.com/concepts/streaming),
[GitHub](https://github.com/sablier-labs/docs/blob/main/docs/concepts/02-streaming.md)).
Канонический пример документации: Алиса вносит 3000 DAI до 1 января с концом
1 февраля, к 10 января Бобу начислено около 1000 DAI. На цепочке происходит
эскроу с линейной разблокировкой, а не перевод по расписанию.

Разрешения в этой модели не существует: деньги уже не у плательщика, отзывать
нечего. Отменить можно сам поток, и только если он создан отменяемым: «Only the
stream creator can cancel a stream. Recipients do not have the ability to cancel
a stream» ([Cancelability](https://docs.sablier.com/concepts/cancelability)).
Отменяемый поток можно необратимо сделать неотменяемым (`renounce`), обратно —
нельзя (там же,
[reference](https://docs.sablier.com/reference/lockup/contracts/contract.SablierLockup)).
Каждый поток минтится как ERC-721 NFT, что делает позицию передаваемой
([Types of Streams](https://docs.sablier.com/concepts/protocol/stream-types)).

Цена модели — заморозка капитала: «The sender needs to deposit a large amount
of ERC-20 tokens upfront»
([Sablier Blog](https://blog.sablier.com/overview-token-streaming-models)).
Зато нет внешних зависимостей: «no off-chain components are required» (там же).

### 2.2. Непрерывный поток (Superfluid; долговой вариант — Sablier Flow)

**Superfluid.** Отправитель задает получателя и flow rate в токенах в секунду,
после чего балансы считаются формулой: Static Balance + Netflow Rate × секунды
с последнего обновления. Дискретных переводов не происходит вообще, «Creating
a stream is a one-time action. The balance is dynamically calculated and does
not require continuous transactions»
([Money Streaming](https://docs.superfluid.org/docs/concepts/overview/money-streaming)).
Работает только с Super Token — оберткой над обычным ERC-20
([Super Tokens](https://docs.superfluid.org/docs/concepts/overview/super-tokens)),
то есть перед подпиской нужен отдельный шаг обертывания.

Аналога `approve` нет; вместо него ACL: владелец выдает оператору права
create/update/delete плюс `flowRateAllowance` через `updateFlowOperatorPermissions`
и отзывает их тем же вызовом с обнуленными правами
([CFA ACL](https://github.com/superfluid-finance/docs/blob/main/developers/constant-flow-agreement-cfa/cfa-access-control-list-acl/README.md),
[Wiki](https://github.com/superfluid-finance/protocol-monorepo/wiki/About-CFA-ACL-Feature)).

Неплатежеспособность решается буфером и внешними ликвидаторами — см. 6.2.

**Sablier Flow** — та же непрерывность, но без предоплаты: протокол учета долга,
`amount owed = rps × elapsed time`, «there are no upfront deposit requirements,
and a stream can be funded with any amount, at any time, by anyone, in full or
partially» ([Flow Overview](https://docs.sablier.com/concepts/flow/overview)).
Различаются покрытый долг (есть баланс в потоке) и **uncovered debt**
(отправитель должен, но не внес). Отмены нет: есть `pause` с возможностью
возобновления «without losing track of previously accrued debt» и `void`, причем
«voiding an insolvent stream forfeits the uncovered debt» (там же,
[stream management](https://docs.sablier.com/guides/flow/examples/stream-management)).
Функция вывода публична при условии, что `to` равен получателю (там же) —
то есть роль стороннего вызывающего здесь разрешена по построению.

### 2.3. Pull через разрешение (Loop Crypto, Spritz, Request Network)

Плательщик выдает ERC-20 `approve` контракту/процессору, тот раз в период
вызывает `transferFrom`. Аналогия из документации Loop — кредитная карта:
«A customer authorizes their wallet to be charged, and each billing period the
wallet is charged without the end customer having to take action»
([Loop: SaaS](https://www.loopcrypto.xyz/saas)). Средства не блокируются: Loop
«никогда не хранит средства» ([docs](https://docs.loopcrypto.xyz)), у Spritz
«средства до момента каждого списания остаются в кошельке пользователя»
([Spritz Blog](https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments)).

Внутри модели есть варианты авторизации:
Loop — обычный `approve` с ограниченным лимитом (по умолчанию 13-кратная сумма
месячной подписки: первый платеж плюс год,
[Checkout widget](https://loop-crypto.gitbook.io/old-loop-crypto/technical-docs/archeticture/collecting-authorization/checkout-widget));
Spritz — «накопительный» approve на число платежей вперед, «когда одобрение
исчерпано, расписание SMARTPay истекает»
([Spritz Help](https://help.spritz.finance/en/articles/7236067-when-you-sign-off-on-a-transaction-with-spritz-are-you-giving-it-a-one-time-allowance-or-an-enduring-one));
Request — allowance плюс одна подпись EIP-712 на всю серию, где зафиксированы
получатель, сумма, старт, частота и число платежей, а контракт «отклоняет
повторные и внеочередные попытки» и не дает исполнить платеж раньше срока
([Request Docs](https://docs.request.network/request-network-api/recurring-payments)).

### 2.4. Сравнение

| Ось | Предоплата (Sablier Lockup) | Непрерывный поток (Superfluid) | Долговой поток (Sablier Flow) | Pull через разрешение (Loop / Spritz / Request) |
|---|---|---|---|---|
| Где деньги до платежа | В контракте, внесены целиком заранее | В Super Token отправителя (обернутый ERC-20) | В кошельке; в потоке — только внесенная часть | В кошельке плательщика |
| Кто инициирует перевод | Получатель (или одобренная им сторона) вызывает `withdraw` | Никто: баланс меняется формулой, транзакций нет | Любой, если `to` = получатель | Получатель или его инфраструктура (процессор, бэкенд API) |
| За чей газ | Отправитель — за создание; вызывающий `withdraw` — за вывод (плюс fee в `msg.value`) | Отправитель — за open/update/close; сентинел — за ликвидацию | Отправитель — за изменение rps; вызывающий — за вывод | Плательщик — только за управление разрешением; за списание — получатель/сервис |
| Что при отзыве разрешения | Отзывать нечего; отмена — только создателем, возвращается непротекшее | Прямого отзыва нет; аналог — закрытие потока или отзыв прав оператора в ACL | Отзыва нет; `pause` / `void`, void прощает непокрытый долг | Списание перестает проходить немедленно и односторонне |
| Гарантия получателю | Максимальная; у неотменяемого потока — абсолютная | На объем буфера (порядка 4 часов потока), дальше риск получателя | Только на объем уже внесенных средств | Никаких; только офчейн-реакция (ретраи, вебхуки) |
| Внешние зависимости | Нет | Обертка токена + экономика ликвидаторов | Нет | Исполнитель списания обязателен |

Расхождение по газу у pull-провайдеров названо в 5.6.

---

## 3. Почему pull

Для подписочного биллинга берут именно pull-модель по трем причинам,
прямо названным в материалах.

**Не требует эскроу.** Loop описывает себя как «первое решение на
смарт-контрактах, позволяющее автоматические рекуррентные крипто-платежи
без блокировки средств — autopay для web3»
([Loop Medium](https://loopcrypto.medium.com/introducing-loop-crypto-e2579d81006f)).
Плательщик не замораживает капитал, в отличие от 2.1.

**Не требует ничего от токена.** Работает любой ERC-20 без обертки и без
расширений — в отличие от Super Token (2.2) и от `permit` (4.3).

**Совпадает с привычной карточной механикой.** Разрешение живет между
транзакциями: пользователь не должен быть онлайн в момент списания.

Что модель при этом наследует:

1. **Разрешение — потолок, а не расписание.** «Allowance работает как
   единовременный потолок, а не как повторяющееся расписание. Не существует
   нативного понятия „100 USDC в месяц“: контракт с одобрением на 1200 USDC
   может вывести всю сумму одним вызовом»
   ([spark.money](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).
   Период, сумму и счетчик обязан проверять контракт подписки, потому что токен
   об этом ничего не знает.
2. **Разрешение отзываемо в одностороннем порядке и мгновенно.** Ни один
   провайдер не может этому помешать; Loop подает отзыв как достоинство
   продукта: «you can limit the most a company can charge and can revoke this
   amount at any time»
   ([Loop Blog](https://www.loopcrypto.xyz/blog/updating-your-spend-allowance-on-loops-customer-portal)).
   Отзыв действует только вперед: «Revoking an approval stops future spending
   only. It does not recover tokens that already left your wallet»
   ([revoke.cash](https://revoke.cash/learn/approvals/how-to-revoke-token-approvals)).
3. **Нужен вызывающий.** Для approve-модели требуется «a keeper or cron-like
   service that triggers the `transferFrom()` call at each billing interval»
   ([spark.money](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).
   Это раздел 5.
4. **Гарантий получателю нет.** Единственные известные способы что-то
   гарантировать требуют денег на цепочке заранее: эскроу (2.1) или буфер
   с ликвидацией (2.2). В pull-модели их нет по построению.
5. **Стандарта нет.** Попытка стандартизировать ровно эту модель — ERC-948
   и затем EIP-1337 — осталась в статусе Stagnant
   ([EIP-1337](https://eips.ethereum.org/EIPS/eip-1337),
   [issue 948](https://github.com/ethereum/EIPs/issues/948),
   PoC: [token-subscription](https://github.com/austintgriffith/token-subscription)).
   Поэтому каждое решение городит свое.

---

## 4. Механика разрешений

### 4.1. Базовый `approve` / `transferFrom`

Спецификация EIP-20 определяет `approve` («Allows `_spender` to withdraw from
your account multiple times, up to the `_value` amount»), `allowance`
и `transferFrom` ([EIP-20](https://eips.ethereum.org/EIPS/eip-20)). Разрешение
хранится в контракте токена парой (owner, spender) и уменьшается при списании
(`_spendAllowance` в
[OpenZeppelin ERC20](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol)).

**Дает:** универсальность (любой ERC-20), простоту, pull без участия плательщика
в момент платежа, тривиальный отзыв через `approve(spender, 0)`.

**Платит:**

- *Гонка при изменении ненулевого разрешения.* Сам EIP рекомендует «set the
  allowance first to `0` before setting it to another value for the same
  spender», но перекладывает это на интерфейс клиента: «the contract itself
  shouldn't enforce it, to allow backwards compatibility» (там же). Механика
  атаки: spender видит `approve(M)` в мемпуле, обгоняет ее `transferFrom` на
  старые N, итого тратит N + M
  ([Zokyo](https://zokyo-auditing-tutorials.gitbook.io/zokyo-tutorials/tutorials/tutorial-3-approvals-and-safe-approvals/vulnerability-examples/erc20-approve-race-condition-vulnerability),
  [SWC-114](http://swcregistry.io/docs/SWC-114/)). Схема «сначала 0» — две
  транзакции, и между ними тоже есть окно.
- *Две транзакции и газ плательщика.* «Current EIP-20 requires two transactions
  to use tokens in contracts» ([EIP-2612](https://eips.ethereum.org/EIPS/eip-2612)).
- *Ни срока, ни периода, ни лимита на один платеж.*
- *Разнобой реализаций.* Каталог [weird-erc20](https://github.com/d-xo/weird-erc20)
  перечисляет токены без возвращаемого значения (`USDT`, `BNB`, `OMG`),
  с комиссией на перевод (`STA`, `PAXG`), с паузой и черным списком (`BNB`,
  `ZIL`, `USDC`, `USDT`), ревертящие на `approve(0)` (`BNB`) и не дающие
  выставить M > 0 поверх N > 0 (`USDT`, `KNC`). Для рекуррентных списаний это
  значит, что «списание прошло» и «получатель получил ровно сумму» — разные
  утверждения.

**`increaseAllowance` / `decreaseAllowance` — тупиковая ветка.** Функции не
входят в EIP-20 и удалены из OpenZeppelin Contracts 5.0: они «not part of the
EIP-20 specs», «may allow for further phishing possibilities» (в обсуждении
приводится инцидент с потерей 24 млн долларов после подписи вредоносного
`increaseAllowance`), а `decreaseAllowance` сам фронтранится
([issue 4583](https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4583),
[PR 4585](https://github.com/OpenZeppelin/openzeppelin-contracts/pull/4585),
[changelog](https://docs.openzeppelin.com/contracts/5.x/changelog)).

> **Расхождение между файлами.** `seq-02-allowance.md` и `allowance.md` сходятся
> на том, что это антипаттерн. `failures.md` в разделе про отзыв называет
> `increaseAllowance`/`decreaseAllowance` типовым смягчением гонки, ссылаясь на
> документацию OpenZeppelin 3.x
> ([OZ 3.x](https://docs.openzeppelin.com/contracts/3.x/api/token/erc20)).
> Противоречие объясняется возрастом источника: рекомендация верна для 3.x
> и отменена в 5.0.

### 4.2. Бесконечное разрешение

`approve(spender, type(uint256).max)`. Практика живая: учебная реализация
рекуррентных платежей использует именно ее — «an unlimited allowance (2^256-1)
is approved to the subscription contract address»
([Jon-Becker](https://github.com/Jon-Becker/ethereum-recurring-payments)).
Второй мотив — экономия газа: при безлимите вычитание из `allowed` на каждом
`transferFrom` бессмысленно и тратит газ на запись
([EIP issue 717](https://github.com/ethereum/EIPs/issues/717)).

**Дает:** одно подтверждение на все время жизни подписки, отсутствие повторных
approve (а значит и повторного попадания в гонку), экономию газа там, где токен
пропускает вычитание.

**Платит:** максимальный размер ущерба равен не сумме подписки, а всему балансу
плательщика по токену, сейчас и в будущем: «Over-permissioned or infinite
allowances can pose a risk if the spender contract is compromised or malicious»
([Utila](https://utila.io/blog/understanding-token-approvals-on-evm-tron)).
Разрешение переживает обновление контракта-получателя через прокси. При
реализации в стиле OpenZeppelin `allowance` всегда показывает max, и по нему
невозможно понять, сколько уже списано («Does not update the allowance value in
case of infinite allowance»,
[ERC20.sol](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol)).
Поведение при max не единообразно между токенами, то есть «безлимит» — не
переносимая абстракция.

Практика провайдеров это подтверждает: Loop сознательно предлагает не
бесконечность, а 13-кратную сумму месячной подписки, и «end customers always
maintain control over the final allowance amount»
([Checkout widget](https://loop-crypto.gitbook.io/old-loop-crypto/technical-docs/archeticture/collecting-authorization/checkout-widget)).
Это готовый ответ на вопрос о разумном размере разрешения: N периодов вперед.

### 4.3. EIP-2612 (`permit`)

Расширение ERC-20: функция выставляет allowance по подписи EIP-712, а не по
`msg.sender`. Подписываются `owner`, `spender`, `value`, `nonce`, `deadline`
плюс домен (name, version, chainId, адрес контракта)
([EIP-2612](https://eips.ethereum.org/EIPS/eip-2612)).

**Дает:** убирает вторую транзакцию; плательщику не нужен ETH — цель стандарта
«ability to interact with Ethereum without holding any ETH»; газ платит тот, кто
отправляет транзакцию; `deadline` ограничивает срок жизни подписи и служит
средством против цензуры релеера.

**Платит:** поддержка требуется от самого токена, для произвольного ERC-20
недоступна. Экосистема фрагментирована: USDC реализует стандарт
([EIP2612.sol](https://github.com/circlefin/stablecoin-evm/blob/master/contracts/v2/EIP2612.sol),
плюс перегрузка с `bytes signature` для ERC-1271, которой нет в самом EIP),
а DAI имеет несовместимый вариант — вместо `value` булев `allowed`, вместо
`deadline` — `expiry`, nonce передается явно
([dai.sol](https://github.com/makerdao/dss/blob/master/src/dai.sol)), то есть
интегратору нужна отдельная кодовая ветка. Nonce строго последовательный —
параллельно живущие подписи инвалидируют друг друга. Из Security
Considerations самого EIP: «the standard EIP-20 approve race condition remains
applicable», фронтраннинг отправки permit, silent failure of `ecrecover`,
цензура релеером, replay при форке цепи с иммутабельным `DOMAIN_SEPARATOR`.

Главное для нашей темы: permit **не решает рекуррентность**. Он делает выдачу
разрешения дешевле, но на выходе — обычный бессрочный allowance.

### 4.4. Permit2

Отдельный контракт-посредник Uniswap поверх любого ERC-20, развернутый
детерминированно по адресу `0x000000000022D473030F116dDEE9F6B43aC78BA3`
([etherscan](https://etherscan.io/address/0x000000000022d473030f116ddee9f6b43ac78ba3)).
Два механизма ([permit2](https://github.com/Uniswap/permit2)):

- **AllowanceTransfer** — хранимое разрешение `{token, amount uint160,
  expiration uint48, nonce uint48}`; при переводе проверяется
  `if (block.timestamp > allowed.expiration) revert AllowanceExpired(...)`
  ([AllowanceTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/AllowanceTransfer.sol),
  [IAllowanceTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/interfaces/IAllowanceTransfer.sol)).
  `amount = type(uint160).max` — безлимит, и он тоже не вычитается.
- **SignatureTransfer** — разрешения не остается вовсе: «an allowance on the
  token is bypassed and permissions to the spender only last for the duration of
  the transaction that the one-time signature is spent»
  ([README](https://github.com/Uniswap/permit2/blob/main/README.md)).

**Дает:** работает с любым ERC-20, включая токены без `permit`; срок годности
у самого разрешения, а не только у подписи (два разных срока: `expiration`
у разрешения и `sigDeadline` у подписи); массовый отзыв `lockdown` по массиву
пар «токен-спендер» и `invalidateNonces` для подписей; батчи и witness-привязка
(`permitWitnessTransferFrom`).

**Платит:** чтобы пользоваться Permit2, надо один раз сделать обычный, как
правило безлимитный, `approve` на сам Permit2 — риск не исчезает, а
концентрируется на одном сильно используемом контракте. Плюс сложность
интеграции (две модели, две структуры сроков, EIP-712 типы, разрядность
uint160/uint48), необходимость компиляции `viaIR` и собственные известные
нюансы ([issue 163](https://github.com/Uniswap/permit2/issues/163),
«Can set expired allowances»). И главное: разрешение все равно **не
периодическое** — `expiration` это «действует до», а не «X в минуту».

> **Расхождения между файлами.** Два места.
> (1) `expiration = 0`: `seq-02-allowance.md` читает это как «делает разрешение
> недействительным немедленно», `allowance.md` — как «If the inputted expiration
> is 0, the allowance only lasts the duration of the block», то есть действует
> до конца текущего блока
> ([Allowance.sol](https://github.com/Uniswap/permit2/blob/main/src/libraries/Allowance.sol)).
> (2) Порядок nonce: `seq-02-allowance.md` приписывает неупорядоченные nonce
> всему Permit2, `allowance.md` разделяет — в AllowanceTransfer nonce
> инкрементный uint48 на тройку (owner, token, spender), неупорядоченный bitmap
> только в SignatureTransfer. Вторая версия детальнее и подтверждена
> исходниками обоих интерфейсов.

### 4.5. EIP-3009 (перевод по авторизации)

Не разрешение, а подписанный конкретный перевод: `transferWithAuthorization`
с полями `from`, `to`, `value`, `validAfter`, `validBefore`, `nonce` и подписью;
`nonce` — случайные 32 байта, а не счетчик, чтобы авторизации можно было
создавать параллельно ([EIP-3009](https://eips.ethereum.org/EIPS/eip-3009),
[разбор](https://hackmd.io/@Extropy/EIP3009)). Стандарт нативно реализован
в USDC ([Circle](https://www.circle.com/blog/four-ways-to-authorize-usdc-smart-contract-interactions-with-circle-sdk)).

**Дает:** длящегося разрешения нет вообще — каждая подпись это ровно один
перевод конкретному получателю на конкретную сумму в конкретном окне; газ платит
получатель («The customer signs a `transferWithAuthorization` message; the
merchant's relayer submits it on-chain, paying gas»,
[Eco](https://eco.com/support/en/articles/14796369-eip-3009-authorization-transfer-for-stablecoins));
отзыв без гонки через `cancelAuthorization` по конкретному nonce; защита
от фронтраннинга через `receiveWithAuthorization`.

**Платит:** шаг назад по автономности. Подпись на каждый период надо получить
заранее: либо пользователь подписывает пачку на год вперед (и это превращается
в расписание, которое надо где-то хранить), либо каждый период требует его
участия. Поэтому подход хорош «for checkout or payment flows where you want
gasless user experience without persistent allowances» (Eco), а не для подписки.

### 4.6. EIP-7702 (делегирование аккаунта)

Новый тип транзакции (`0x04`, SET_CODE_TX_TYPE), позволяющий EOA задать себе
код: в состояние аккаунта пишется делегационный индикатор `0xef0100 || address`,
и исполнение идет по этому адресу
([EIP-7702](https://eips.ethereum.org/EIPS/eip-7702),
[OpenZeppelin](https://docs.openzeppelin.com/contracts/5.x/eoa-delegation)).
`seq-02-allowance.md` привязывает это к хардфорку Pectra 7 мая 2025
([Eco](https://eco.com/support/en/articles/14796249-eip-7702-explained-account-abstraction-for-eoas)).

**Дает:** батчинг, спонсирование газа через paymaster и **privilege
de-escalation** — подключи с урезанными правами, то есть концептуально ближе
всего к «разрешению списывать N раз по M токенов», причем без миграции
на смарт-аккаунт.

**Платит:** радиус поражения — весь аккаунт. Плохо написанный делегат позволяет
«a malicious actor to take near complete control over a signer's EOA»
(OpenZeppelin). Плюс коллизии хранилища при смене делегата (требуется
namespaced storage по ERC-7201), кросс-чейн авторизация при `chain_id = 0`,
поломка проверок вида `require(tx.origin == msg.sender)` и рекомендация узлам
ограничивать число pending-транзакций от делегированных EOA. Отзыв делегации —
отдельная транзакция на нулевой адрес, при этом storage не очищается.

Насколько 7702 фактически используется провайдерами подписок — **не
подтверждено**.

### 4.7. Смежное, найденное только в одном файле

`allowance.md` дополнительно разбирает три подхода, которых нет в
`seq-02-allowance.md`:

- **ERC-4337 + session keys.** Важная оговорка из источника: «в тексте самого
  ERC-4337 нет упоминаний session keys и рекуррентных платежей»
  ([EIP-4337](https://eips.ethereum.org/EIPS/eip-4337)) — это паттерн поверх
  стандарта. Стандартизуют его черновики ERC-7715 (метод
  `wallet_requestExecutionPermissions`, ранее `wallet_grantPermissions`,
  с `ExpiryRule`) и ERC-7710 (DelegationManager, `redeemDelegations`)
  ([7715](https://github.com/ethereum/ERCs/blob/master/ERCS/erc-7715.md),
  [7710](https://github.com/ethereum/ERCs/blob/master/ERCS/erc-7710.md),
  [MetaMask](https://docs.metamask.io/delegation-toolkit/0.12.0/experimental/erc-7715-request-permissions/)).
  Мотивация ERC-7715 называет наш сценарий прямо: текущий флоу подтверждений
  «invalidates use cases such as subscriptions». При этом типов вида
  `erc20-recurring-allowance` в спецификации нет — только
  `erc20-token-allowance` с ограничением по expiry. **Периодичность
  не стандартизована и здесь.**
- **ERC-777 операторы** — булево разрешение вместо числового: оператор
  не ограничен суммой вовсе, плюс реентранси через хуки (разбор эксплуатации
  Uniswap V1 с imBTC:
  [OpenZeppelin](https://www.openzeppelin.com/news/exploiting-uniswap-from-reentrancy-to-actual-profit)),
  зависимость от синглтона ERC-1820; реализация помечена deprecated в OZ 4.9
  и удалена в 5.0 ([EIP-777](https://eips.ethereum.org/EIPS/eip-777)).
- **ERC-1363 `approveAndCall`** — разрешение и регистрация подписки одной
  транзакцией; экономия шага при оформлении, на списание не влияет
  ([EIP-1363](https://eips.ethereum.org/EIPS/eip-1363)).

### 4.8. Сравнение

| Подход | Что дает | Чем платит | Требует от токена | Есть срок/период? |
|---|---|---|---|---|
| `approve` + `transferFrom` | Универсально, просто, pull работает | Транзакция и газ плательщика; гонка при повторном approve; потолок без срока | Ничего | Нет |
| Безлимитный `approve` | Одно подтверждение навсегда; дешевле по газу | Риск = весь баланс; расход невидим; поведение при max разнится | Ничего (семантика max зависит от реализации) | Нет |
| EIP-2612 `permit` | Разрешение по подписи, газ платит отправитель; deadline у подписи | Только для токенов с permit; DAI-вариант несовместим; на выходе обычный allowance; последовательные nonce | `permit`, `nonces`, `DOMAIN_SEPARATOR` | Только у подписи |
| Permit2 / AllowanceTransfer | Сумма + `expiration` + `lockdown` + батчи | Безлимитный approve самому Permit2; новый доверенный контракт; сложность | Ничего | Да, «действует до» |
| Permit2 / SignatureTransfer | Разрешения не остается вовсе | Подпись на каждый платеж | Ничего | Только на время транзакции |
| EIP-3009 | Нет длящегося разрешения; газ платит получатель; отзыв по nonce | Подпись на каждый период — потеря автономности | Поддержка 3009 (есть в USDC) | Окно `validAfter`..`validBefore` |
| EIP-7702 | Подключи и правила для обычных EOA, без смены адреса | Делегируется весь аккаунт; коллизии стоража; поломка допущений | Ничего | Да, задается кодом делегата |

Сквозной вывод раздела: **ни один стандартизованный механизм разрешений
не выражает периодичность.** Ближе всех Permit2 («сумма + срок») и session keys
(правила аккаунта), но первый не знает про период, а второй не стандартизован.

---

## 5. Кто дергает списание

### 5.1. Keeper-сети

**Chainlink Automation.** Контракт реализует `checkUpkeep` (симулируется офчейн
бесплатно) и `performUpkeep` (исполняется ончейн), результат первого передается
во второй через `performData`
([Interfaces](https://docs.chain.link/chainlink-automation/reference/automation-interfaces),
[Compatible contracts](https://docs.chain.link/chainlink-automation/guides/compatible-contracts)).
Триггеры: time-based (CRON), custom logic, log
([Getting started](https://docs.chain.link/chainlink-automation/overview/getting-started)).
Для фиксированного периода годится time-based upkeep, где Chainlink
разворачивает служебный `CronUpkeep` и совместимости целевого контракта
не требуется; сама обертка стоит «roughly 110K gas per call»
([Job Scheduler](https://docs.chain.link/chainlink-automation/guides/job-scheduler)).
Минимальная гранулярность расписания — минута.

Узлы образуют p2p-сеть на OCR3, приходят к консенсусу и подписывают отчет,
который проверяет Registry
([Architecture](https://docs.chain.link/chainlink-automation/concepts/automation-architecture)).
Формула оплаты:

```
FeeLINK = [tx.gasPriceNative WEI × gasUsed × (1 + premium%)
           + (gasOverhead × tx.gasPriceNative WEI)] / [LINK/NativeRate in WEI]
```
([Economics](https://docs.chain.link/chainlink-automation/overview/automation-economics))

`gasOverhead` — фиксированные 80 000 газа. Премия зависит от сети: Ethereum 20%,
Arbitrum / Optimism / Base 50%, Polygon 70%
([Supported networks](https://docs.chain.link/chainlink-automation/overview/supported-networks)).
Если баланс upkeep падает ниже минимума, сеть просто не исполняет upkeep
(Economics). Явной гарантии исполнения нет; документация предупреждает
о «мерцающих» условиях: «your upkeep is at risk of not being performed» —
и требует идемпотентности и перепроверки условия внутри `performUpkeep`
([Best practices](https://docs.chain.link/chainlink-automation/concepts/best-practice)).
Ограничить вызывающего можно через персональный Forwarder
([Forwarder](https://docs.chain.link/chainlink-automation/guides/forwarder)).

> **Расхождение.** `seq-03-trigger.md` приводит премию одним числом («в примере
> 70%») и говорит, что газ платит владелец upkeep. `trigger.md` дает таблицу
> премий по сетям и уточняет: формально газ платит узел Automation,
> экономически — владелец upkeep из своего баланса. Версии не противоречат
> по сути, но арифметика в них ведется от разных чисел (70% против 20% на L1).

**Gelato Web3 Functions.** Триггеры time / event / every block; логика на
TypeScript или Solidity; рекуррентные платежи названы штатным сценарием —
«Recurring payments (subscriptions, payroll)»
([Automated Transactions](https://docs.gelato.cloud/web3-functions/introduction/automated-transactions),
[Web3 Functions](https://docs.gelato.cloud/web3-services/web3-functions)).
Функции исполняются как stateless-скрипты, состояние держать негде — все
существенное живет в контракте. Оплата — предоплаченный кросс-чейн **1Balance**,
основной токен USDC: перед исполнением Gelato «will query their Gas Tank to see
if they possess enough equivalent USDC», после — списывает стоимость транзакции
«plus a nominal fee» ([1Balance](https://docs.gelato.cloud/web3-services/1balance)).
Отдельная модель **SyncFee** для Relay платит исполнителю прямо внутри
транзакции, в нативном токене или ERC-20
([SyncFee](https://docs.gelato.cloud/Relay/Subscription-and-payments/SyncFee-payment-tokens)) —
концептуально это позволяет контракту подписки оплатить исполнителя
из списанных средств. Ограничение вызывающего — dedicated msg.sender
([док](https://docs.gelato.cloud/web3-functions/security-considerations/dedicated-msg-sender),
[AutomateReady.sol](https://github.com/gelatodigital/automate/blob/master/contracts/integrations/AutomateReady.sol)),
прямой аналог Forwarder'а.

Точный процент комиссии Gelato и степень децентрализации его исполнителей —
**не подтверждено**.

**OpenZeppelin Defender** (только в `trigger.md`) — управляемый хостинг, не
децентрализованная сеть: Actions по расписанию/вебхуку/алерту и Relayers,
хранящие ключи в AWS KMS, откуда «all sign operations are executed within the
KMS». Ценны инженерные детали, которые обычно и оказываются больным местом
самодельного исполнителя: атомарная выдача nonce, резервирование баланса
на газ, отслеживание незамайненных транзакций и переотправка «with a 10%
increase», вплоть до 150% исходной цены
([Actions](https://docs.openzeppelin.com/defender/module/actions),
[Relayers](https://docs.openzeppelin.com/defender/module/relayers)).

**Keep3r Network** (только в `trigger.md`) — открытый рынок исполнителей: job
регистрируется в сети, кредиты на оплату киперов появляются через Credit Mining
(стейкинг kLP) или Token Payments (`directTokenPayment()`, `worked()`, выплата
считается от фактически потраченного газа)
([jobs](https://docs.keep3r.network/core/jobs),
[payment mechanisms](https://docs.keep3r.network/tokenomics/job-payment-mechanisms)).

### 5.2. Собственный сервис

Сервер с cron, приватным ключом и RPC. Так работают продуктовые провайдеры:
у Loop компания создает transfer request по частоте тарифа
([Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)),
у Request «the API handling the scheduling and triggering of these payments»
([Request Docs](https://docs.request.network/request-network-api/recurring-payments)),
у Spritz списывает сам сервис.

**Дает:** полный контроль над отбором и порядком, отсутствие премии посредника,
мгновенную реакцию на инцидент, свою политику ретраев и батчинга.

**Платит:** горячий ключ; доступность (упавший на сутки крон — сутки
непрошедших списаний, тогда как у keeper-сети избыточность узлов заявлена как
свойство); подсистему nonce и переотправки; централизацию — оператор становится
единственной точкой отказа и доверия, ровно то, что Chainlink продает как
избавление от «risks associated with a centralized automation stack»
([Chainlink](https://docs.chain.link/chainlink-automation)); баланс на газ,
при исчерпании которого подписки молча перестают списываться.

Способ убрать газ с пользователя — paymaster: «Paymasters (under ERC-4337) can
abstract gas entirely, letting users pay fees in the stablecoin itself», но
с честной оговоркой — «the cost is still borne somewhere in the system»
([spark.money](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).

### 5.3. Сам получатель

Канонический пример спецификации — ERC-1337 (из рабочей группы ERC-948, статус
Stagnant, август 2018): плательщик один раз подписывает офчейн мета-транзакцию,
«the owner would sign this hash and then provide it to the party for execution
at a later date», получатель хранит подпись и периодически предъявляет ее
([EIP-1337](https://eips.ethereum.org/EIPS/eip-1337)). У Sablier это `withdraw`,
вызываемый получателем, а в Flow — публично вызываемый при `to` = получатель.

**Плюсы:** стимул совпадает с интересом (получателю деньги нужны — он вызовет),
нет нового доверенного лица, естественная политика повтора без внешнего SLA.

**Минусы:** газ платит получатель, и платит **до** того, как убедится, что
списание пройдет: при отозванном allowance транзакция ревертится, а газ сгорает.
ERC-1337 решает это на своем уровне — «a failed execution will still pay the
issuer of the transaction for their gas costs», что само по себе создает риск
злоупотребления. Точность периода зависит от дисциплины получателя: «раз
в минуту» превращается в «когда бэкенд дошел до этой подписки». При большом
числе подписчиков у получателя появляется стимул батчить и откладывать, что
размывает понятие периода.

### 5.4. Стимулирование сторонних вызывающих

Функция списания открыта для всех, вызывающему платят. Награду может вычитать
либо плательщик (сверх суммы подписки, allowance должен ее покрывать), либо
получатель (из своей выручки, которая тогда плавает вместе с ценой газа) —
это продуктовое, а не техническое решение.

Живые примеры:

- **Superfluid Sentinels** — награда берется из буфера, внесенного при открытии
  потока; роли разведены по времени (Patrician в 30-минутный период, Plebs,
  Pirates), роль PIC разыгрывается аукционом TOGA со стейком и слэшингом
  ([Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga),
  [Sentinels](https://medium.com/superfluid-blog/introducing-sentinels-the-keepers-of-superfluid-protocol-4eadca384cbf)).
- **MakerDAO Liquidations 2.0** — награда из двух частей: `tip` («a flat fee to
  suck from vow to incentivize keepers») и `chip` (процент от `tab`, в
  конфигурации 2%). Смысл фиксированной части назван прямо: «to cover gas costs
  ... or to allow MKR holders to effectively pay Keepers to clear small Vaults
  that would otherwise not be attractive for liquidation»
  ([Maker Docs](https://docs.makerdao.com/smart-contract-modules/dog-and-clipper-detailed-documentation)).
  Академическая проверка подтверждает: «it is more cost-effective to increase
  the constant fee, as opposed to the proportional fee»
  ([StableSims, arXiv:2201.03519](https://arxiv.org/abs/2201.03519)).

Чем платит схема:

- *Гонка за вызов.* «The primary issue with bounties is that nodes end up
  engaging in direct competition for the winner-takes-all reward, driving
  priority gas auction (PGA) bidding wars»; «Under some market conditions, being
  a Keeper can result in a net loss over many game iterations»
  ([B.Protocol](https://medium.com/b-protocol/the-keepers-dilemma-game-theoretic-analysis-of-liquidation-incentives-with-preliminary-b588e82e4d67)).
  Это классический MEV-сценарий
  ([ethereum.org: MEV](https://ethereum.org/developers/docs/mev/),
  [Flash Boys 2.0](https://arxiv.org/abs/1904.05234)). Победитель забирает
  награду, проигравшие транзакции ревертятся, но их газ оплачен и включен в блок.
- *Молчаливая остановка.* Если награда меньше газа, никто не вызовет —
  и система останавливается сама, без сигнала.
- *Grief-вектор.* Если награда платится и за неуспешную попытку (как
  в ERC-1337), появляется стимул вызывать заведомо провальные списания.
- *Утечка приватности.* Открытый `charge()` делает расписание всех подписок
  публично наблюдаемым.

### 5.5. Экономика газа

**Стоимость самого списания.** Здесь два файла дают разные оценки одного и того
же, разными методами:

| Источник оценки | Значение | Метод |
|---|---|---|
| `seq-03-trigger.md` | 45 000–65 000 газа на ERC-20 перевод | Обзорные источники: [KuCoin](https://www.kucoin.com/learn/web3/understanding-ethereum-gas-fees), [TokenHook, arXiv:2107.02997](https://arxiv.org/pdf/2107.02997) |
| `trigger.md` | 49 000–66 000 газа на одиночный `transferFrom` | Замер [solidity-benchmarks](https://github.com/alephao/solidity-benchmarks/blob/main/benchmarks/0.8.26/ERC20.md) (OZ 28 152 / Solmate 26 573 при ненулевом балансе получателя; 45 274 / 43 695 при нулевом) плюс `TX_BASE` 21 000 |

Диапазоны почти совпадают, но вторая оценка объясняет разброс: он определяется
тем, был ли баланс получателя ненулевым — перезапись слота стоит 5 000 против
20 000 за запись в нулевой слот
([execution-specs gas.py](https://github.com/ethereum/execution-specs/blob/master/src/ethereum/forks/cancun/vm/gas.py),
[EIP-2929](https://eips.ethereum.org/EIPS/eip-2929),
[EIP-2200](https://eips.ethereum.org/EIPS/eip-2200),
[EIP-3529](https://eips.ethereum.org/EIPS/eip-3529)). Практический вывод: первое
списание в адрес нового получателя заметно дороже последующих, и «средняя»
цифра газа обманчива.

С надстройкой контракта подписки (чтение записи, обновление счетчика, внешний
CALL в токен, событие) `trigger.md` дает **оценку 70 000…110 000 газа**
на одно списание — арифметика по газовой таблице, не измерение. Через Chainlink
на Ethereum к этому добавляется `gasUsed × 1.2 + 80 000`, то есть при 90 000
газа эффективно оплачивается около 188 000 — вдвое больше самой работы.

**Как это соотносится с размером платежа.** Метод:
`доля_газа = газ_списания × цена_газа_в_валюте_платежа / сумма_платежа`.
Иллюстрация по снимку [l2fees.info](https://l2fees.info/) (страница без
временной метки; в `trigger.md` дата снимка указана дважды и по-разному —
2024-08-25 в тексте и 2026-08-25 в сводке неподтвержденного): Ethereum L1 $1.10
за 21 000 газа, Arbitrum и Optimism по $0.09. Отсюда списание на 70 000 газа
≈ $3.7, на 110 000 ≈ $5.8, через Chainlink ≈ $9.8. Все три числа — оценка,
производная от снимка.

Следствия при этом порядке цен: подписка за $5/мес на L1 съедается газом
целиком; за $10/мес отдает газу от трети до половины, а через keeper-сеть —
практически всю сумму; осмысленной на L1 подписка становится примерно от $100
за период. Чем чаще период, тем хуже: минутный период на L1 — это ~43 200
списаний в месяц, и расходы на газ становятся не инженерной проблемой,
а арифметическим запретом.

**Волатильность важнее средней цены.** «A recurring payment that costs $0.50 in
gas during low congestion might cost $15 during a fee spike. For a $9.99/month
subscription, unpredictable gas can exceed the payment itself»
([spark.money](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).
В карточном мире комиссия — предсказуемый процент; здесь фиксированная сумма
в единицах, курс которых скачет независимо от размера платежа.

**Роль L2.** L2 удешевляет не исполнение, а публикацию данных: «gas used by
a transaction on OP Mainnet is exactly the same as the gas used by the same
transaction on Ethereum», а комиссия складывается как
`totalFee = operatorFee + gasUsed × (baseFee + priorityFee) + l1Fee`, причем
после Ecotone L1-часть определяется ценой блобов
([Optimism Docs](https://docs.optimism.io/stack/transactions/fees)). Это ломает
линейную экстраполяцию «стоимость ∝ газ»: на L2 компактный calldata важнее числа
операций, а батчинг выгоден дважды. Разница L1 и L2 по снимку — порядка 10–12
раз, что сдвигает порог осмысленности примерно на порядок вниз. При этом премия
keeper-сети на L2 выше (50% против 20% на Ethereum), хотя 50% от дешевого газа
все равно дешевле.

`seq-03-trigger.md` добавляет, что L2 — фактический отраслевой ответ: Loop
объявляла запуск на Base
([Loop on Base](https://www.loopcrypto.xyz/blog/loop-crypto-is-live-on-base)),
Spritz работает с USDC на Polygon
([Spritz Help](https://help.spritz.finance/en/articles/7065236-how-does-smartpay-work)).

### 5.6. Сравнение

| Вариант | Кто отправляет транзакцию | Кто платит газ | Наценка | Гарантии доставки | Слабое место |
|---|---|---|---|---|---|
| Chainlink Automation | Узлы сети через Registry и Forwarder | Владелец upkeep из баланса LINK/native | Премия 20–70% по сетям + 80 000 газа overhead | Явной гарантии нет; предупреждение о «мерцающих» условиях | Баланс ниже минимума останавливает исполнение |
| Gelato Web3 Functions | Исполнители Gelato через dedicated msg.sender | Владелец задачи из 1Balance (USDC) либо SyncFee внутри транзакции | «Nominal fee» — точный процент **не подтверждено** | **Не подтверждено** | Состав исполнителей и консенсус не раскрыты |
| OZ Defender (Actions + Relayer) | Релеер OpenZeppelin, ключ в AWS KMS | Владелец релеера | Тарифы **не подтверждено** | Нет; есть переотправка +10% до 150% | Один управляемый провайдер, один отправитель |
| Keep3r Network | Произвольный зарегистрированный keeper | Keeper авансом, компенсация из кредитов job'а | Зависит от job'а | Нет: вызов происходит, только если выгодно | Зависимость от KP3R и governance/slasher |
| Свой сервис | Ваш сервер | Вы | Нет | Нет: ваш uptime, ваш баланс, ваша политика | Горячий ключ, nonce, дежурство, централизация |
| Получатель | Получатель | Получатель, включая газ неуспешных попыток | Нет | Нет; но стимул совпадает с интересом | Платеж «когда вспомнил», не по расписанию |
| Открытый вызов с наградой | Кто угодно | Вызывающий, компенсируется наградой | Награда (tip + chip) | Нет и в худшем виде: при невыгодности система молча встает | PGA-войны, сожженный газ проигравших |

**Сквозное наблюдение:** ни один вариант не дает гарантии доставки
в криптографическом смысле. Все они дают либо экономический стимул, либо
операционное обязательство провайдера. Единственное, что контракт гарантирует
сам, — что списание **не произойдет** раньше срока и не произойдет дважды.
Поэтому идемпотентность и перепроверка условия внутри функции списания — не
«хорошая практика», а единственная часть схемы, которая держится на контракте.

> **Расхождение по газу у pull-провайдеров.** Кто платит за списание:
> `seq-01-providers.md` — «в доступной документации Loop вопрос газа
> не раскрыт, **не подтверждено**»; `providers.md` цитирует документацию Loop —
> «пользователи платят газ только за управление своей авторизацией...
> Пользователи никогда не платят газ за автоматические транзакции», но тоже
> помечает **не подтвержденным**, кто именно платит: Loop или мерчант.
> По Request: `seq-01` пишет, что слова gas, relayer, executor в документации
> по рекуррентным платежам отсутствуют (**не подтверждено**); `providers.md`
> приводит с сайта протокола «Плоская комиссия 0.9%... На EVM-сетях газ
> включен» ([request.network](https://request.network/)). Вторая версия
> опирается на страницу тарифов, а не на страницу рекуррентных платежей —
> противоречия нет, но первая недооценивает доступное.

---

## 6. Сбойные сценарии

### 6.1. Что вообще ломается

Полный список причин из отраслевого обзора: «Insufficient balance, revoked
approvals, wallet migration, and contract upgrades can all cause failures»
([spark.money](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).
Loop дает свой список причин отсутствия события `TransferProcessed`: не хватает
баланса, не хватает allowance, транзакция застряла в мемпуле, «Loop's relay
network is down»
([Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)).
Отсюда важное следствие: **отсутствие платежа не означает отказ плательщика**,
и Loop прямо оставляет компании решать, «how "aggressive" they want to be about
payment confirmation» (там же).

Для сравнения, в карточном мире слой обработки сбоев отработан: «when a card
charge fails, the merchant retries using established dunning sequences: retry on
day 3, again on day 7, send a notification, downgrade the account»
([spark.money](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).
На цепочке этого слоя нет.

### 6.2. Матрица

| Сбой | Как проявляется | Как обрабатывают существующие решения |
|---|---|---|
| **Отзыв или уменьшение разрешения** | `transferFrom` откатывается; контракт не может ни помешать, ни узнать заранее — allowance живет в токене. Ончейн-события «платеж не удался» нет вовсе: сигналом служит отсутствие успеха | **Loop:** штатное действие пользователя; отдельная причина в списке, реакция — письмо «Missed Payment» через 5 минут после срока с указанием причины и ссылкой на портал, плюс предупреждения заранее — в воскресенье перед списанием и повторно за 48 и 24 часа ([renewal](https://docs.loopcrypto.xyz/docs/renewal-payments-copy), [Stripe FAQ](https://loop-crypto.gitbook.io/old-loop-crypto/integrations/stripe-+-loop/faqs-about-stripe-integration)). **Request:** расписание на паузу. **Unlock:** автопродление перестает удаваться, причина читается view-функцией `isRenewable`, которая «reverts with an explanation about why a given membership cannot be renewed» ([Unlock](https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/)). **ERC-1337:** отзыв заявлен как штатный способ выйти из подписки, но что делать расписанию — не описано. **Sablier / Superfluid:** сценария нет (деньги уже внесены; аналог — отзыв прав оператора в ACL) |
| **Нехватка баланса** | Тот же откат, тот же внешний результат. Различима только диагностикой: allowance и баланс читаются по отдельности | **Loop** объединяет с предыдущей причиной; мониторит обе величины в течение окна повторов и проводит платеж, как только средств хватает. **Suberra** проверяет баланс до попытки: «smart payment retries first check if the user has sufficient token balance on-chain before attempting a charge» ([Suberra](https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/)). **Loop** дает то же — «query the payment method's status before charging it». **Spritz:** платеж не проходит, приходит письмо, «if the payment fails, you'll have to manually set it up again». **Superfluid:** единственная ончейн-развязка — буфер (4 часа потока на основных сетях, 1 час на тестовых), состояния solvent → critical («the permissions on the stream now allow anyone to close it») → insolvent, где протокол ведет учет дефицита; закрывают потоки Sentinels, забирая остаток залога, залог отправителя теряется безвозвратно. **Sablier Flow:** не сбой, а uncovered debt |
| **Пропущенные периоды** | Никто не вызвал списание вовремя. Развилка: догонять, не догонять или копить долг | **Loop:** окно 7 дней по умолчанию, настраивается мерчантом — «after 7 days of attempting, Loop will cancel the subscription in Loop and in Stripe and set the due invoice to uncollectable». **Suberra:** grace period 7 дней, внутри него доступ сохраняется и попытки повторяются часто. **Request:** пауза, после unpause подписка «может догнать пропущенные платежи». **Unlock:** долг не копится — ключ истекает, `renewMembershipFor` вызывается только на истекшем ключе кем угодно и продлевает от момента вызова. **Sablier Flow:** долг копится на цепочке, пауза не стирает начисленное. **Superfluid:** понятия пропуска нет по построению. **Spritz:** пропуск завершает серию, восстановление ручное |
| **Отмена** | Прекращение будущих списаний; вопрос — кто вправе и что с начатым периодом | **Sablier Lockup:** только создатель, немедленно, непротекшее возвращается, начисленное получатель должен забрать сам. **Sablier Flow:** отмены нет — `pause` или `void`, который обнуляет непокрытый долг. **Superfluid:** любая из сторон через `deleteFlow`, плюс кто угодно в критическом состоянии. **Loop:** и мерчант через дашборд, и плательщик; «all future scheduled invoices will be cancelled but any currently due invoices will not be» — уже выставленный счет остается к оплате. **Request:** API-действие cancel останавливает будущие платежи. **Unlock:** отмена = перестать продлевать, доступ живет до `expiration`. **ERC-1337:** статусы ACTIVE / PAUSED / CANCELLED / EXPIRED через `modifyStatus()` |
| **Возврат, спор** | Перевод необратим: «on-chain payments are final by design» | Возврат — только новая транзакция в обратную сторону: «this must come in the form of a separate transaction... The initial transfer of cryptocurrency is non-reversible» ([Chargebacks911](https://chargebacks911.com/crypto-chargebacks/)), а спор «shifts from a network reversal process to a merchant-side refund, review, or support workflow» ([Chargeback.io](https://www.chargeback.io/blog/what-to-know-about-crypto-chargebacks)). Контрактный возврат есть только там, где деньги задержаны: **Unlock** — `cancelAndRefund` со штрафом 10% по умолчанию и `expireAndRefundFor` для менеджера лока, с оговоркой, что полный вывод средств с лока ломает обе функции ([PublicLock](https://docs.unlock-protocol.com/core-protocol/smart-contracts-api/PublicLock)); **Sablier** — возврат только «непротекшего». Ближайшая попытка спроектировать chargeback — исследовательское предложение ERC-20R/ERC-721R с окном заморозки в три дня ([arXiv:2208.00543](https://arxiv.org/pdf/2208.00543), [CoinDesk](https://www.coindesk.com/tech/2022/09/28/stanford-proposal-for-reversible-ethereum-transactions-divides-crypto-community)); в подписочных протоколах не используется |
| **Реорг и финализация** | Уже засчитанный платеж исчезает: транзакция из отброшенной ветки «may either be re-queued... or otherwise have its ordering or block number changed» ([Trail of Bits](https://blog.trailofbits.com/2023/08/23/the-engineers-guide-to-blockchain-finality/)). Дважды одна транзакция не исполнится — это исключает nonce | Отраслевого подхода **нет**: ни один подписочный протокол этого не описывает. Общая практика — спрашивать у ноды `finalized`, а не считать подтверждения (в мае 2023 финализация вставала на девять эпох); твердая финализация в Ethereum PoS — две эпохи, около 12,8 минуты ([spark.money](https://www.spark.money/research/payment-finality-comparison-blockchains)). Атака I-A (revert-grant) в разборе x402: сервер выдает ресурс до финализации, реорг убирает платеж ([arXiv](https://arxiv.org/html/2605.11781v1)) |
| **Двойное списание, идемпотентность** | Один период оплачен дважды либо один платеж засчитан многократно | На уровне цепочки защита есть: израсходованный nonce в EIP-3009, `getSubscriptionHash()` и ончейн-статус в ERC-1337, инкрементный nonce в Permit2, невозможность продлить неистекший ключ в Unlock. На уровне приложения защиты нет: живой тест x402 показал, что один платеж породил **248 выдач ресурса**, потому что серверы не проверяли идемпотентность, и что ни один из проверенных SDK не обеспечивает одноразовость по умолчанию ([arXiv](https://arxiv.org/html/2605.11781v1)). Класс ошибок учета периодов подтвержден аудитом: `nextPaymentTimestamp()` возвращает 0 для несуществующей подписки ([ConsenSys Diligence, Daisy](https://github.com/ConsenSys/daisy-audit-report-2019-08)) |
| **Зависшая транзакция, очередь по nonce** | Пропущенный период случается не из-за плательщика, а из-за очереди отправителя: один застрявший вызов блокирует последующие | Отраслевого подхода **нет**; общий прием — replace-by-fee: та же nonce с большей комиссией ([Etherscan](https://info.etherscan.io/how-to-cancel-ethereum-pending-transactions/), [MetaMask](https://support.metamask.io/manage-crypto/transactions/how-to-speed-up-or-cancel-a-pending-transaction/)). Заменять нужно самую раннюю зависшую. Отдельная ловушка: заменяющая транзакция — другая транзакция, и подсчет попыток по хешу насчитает лишнее. Инфраструктурный аналог у Chainlink — падение баланса upkeep ниже минимума |
| **Заморозка или пауза токена** | Внешний отказ, не связанный ни с балансом, ни с allowance | Отраслевого подхода **нет**. В FiatToken (USDC) модуль `Blacklistable`: заблокированный адрес «unable to transfer tokens, mint, or burn tokens» и не может получать токены, но в версии 2.2 ему вернули возможность вызывать `approve`, хотя это «meaningless» ([tokendesign](https://github.com/zhenghui-w/stablecoin-evm/blob/master/doc/tokendesign.md)). То есть allowance у заблокированного плательщика выглядит здоровым, а списание падает. Практика применения существует: заморозка 100 тысяч долларов USDC по запросу правоохранителей ([CoinDesk](https://www.coindesk.com/markets/2020/07/08/circle-confirms-freezing-100k-in-usdc-at-law-enforcements-request)). Роль `pauser` может остановить все переводы токена целиком |

### 6.3. Где отраслевого подхода нет

Отдельно, потому что это результат исследования, а не пробел изложения:

1. **Ретраи и dunning.** «There is no universal standard for retry logic in
   on-chain billing»; «Platforms like Loop and Spritz are building retry and
   webhook infrastructure, but it is proprietary rather than standardized»
   ([spark.money](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).
2. **Догон нескольких пропущенных периодов одной транзакцией.** Поведение
   не описано ни в одной из просмотренных документаций — **не подтверждено**.
   Косвенное объяснение из `failures.md`: такое поведение трудно отличить
   от двойного списания и неприятно плательщику.
3. **Реорги и финализация** на уровне подписочных протоколов — не описаны
   нигде; все найденные источники общие.
4. **Зависшие транзакции и очередь по nonce** — то же.
5. **Блокировка адреса эмитентом стейблкоина** — не описана ни у одного
   из разобранных протоколов.
6. **Возвраты** у Loop, Request, Spritz, Suberra — раздела о возвратах в их
   документации нет.
7. **Периодичность в стандартах разрешений** — не выражена ни в одном
   (раздел 4.8).

> **Расхождения между файлами по сбоям.** Три существенных.
> (1) *Обработка неудачи у Loop.* `seq-04-failures.md` описывает реакцию как
> событийную модель наружу — вебхуки, решение за компанией, никакой автоматики;
> `failures.md` приводит конкретное окно в 7 дней с автоматической отменой
> подписки по его истечении, ссылаясь на `docs.loopcrypto.xyz/docs/renewal-payments-copy`.
> При этом `providers.md` независимо помечает утверждение об автоматической
> отмене после N неудачных попыток как **не подтвержденное**: «утверждение
> встречается в пересказах, первоисточник не найден». Итого две версии
> из трех файлов говорят о разном статусе одного факта.
> (2) *Догон у Request.* `seq-01-providers.md` и `seq-04-failures.md` описывают
> только паузу и снятие с паузы; `providers.md` и `failures.md` добавляют, что
> после unpause подписка «может догнать пропущенные платежи». Детали догона
> в обоих случаях **не подтверждены**.
> (3) *Отмена у Sablier Lockup.* Расхождение внутри самого источника, найденное
> только в `failures.md`: справочник контракта и страница про отменяемость
> говорят «только отправитель», а FAQ отвечает «Yes, both as a sender and
> a recipient» ([FAQ](https://docs.sablier.com/support/faq)). Какой ответ
> к какому продукту относится — не установлено.
>
> Отдельно о покрытии: `failures.md` разбирает Unlock Protocol, Suberra, x402,
> реорги, идемпотентность, nonce и заморозку токена, которых нет в
> `seq-04-failures.md`; `seq-04-failures.md`, в свою очередь, единственный
> приводит источники по карточному chargeback. Пересечение файлов — примерно
> половина объема.

---

## 7. Главный вывод

**Отраслевого стандарта обработки сбоев в on-chain биллинге не существует.**
Формулировка обзора буквальна: «There is no universal standard for retry logic
in on-chain billing», а то, что делают провайдеры, — «proprietary rather than
standardized»
([spark.money](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)).

Все найденные решения проприетарны и вынесены за пределы цепочки. На цепочке
живет только сам перевод и минимальная защита от повторного исполнения. Окно
в 7 дней у Loop, пауза расписания у Request, ручное пересоздание у Spritz,
grace period у Suberra — это логика сервисов, а не контрактов; ни одна из них
не выражена в стандарте и ни одна не читается другим участником.

Отсюда следует главное: **on-chain подписка вопрос сбоев не решает, а выносит
наружу.** Цепочка дает необратимость платежа и невозможность списать дважды
за период. Все остальное — уведомить, повторить, дать отсрочку, закрыть доступ,
вернуть деньги, разобрать спор — остается офчейн, у того же оператора, что
и в карточном мире, только без отработанной отраслевой практики. Попытка
стандартизировать эту часть (ERC-948/EIP-1337) осталась в статусе Stagnant,
а стандарты разрешений периодичность не выражают вовсе.

Второе следствие, менее очевидное: **и вопрос исполнения тоже вынесен наружу.**
Контракт не запускает себя сам; любой из вариантов раздела 5 — это либо
внешний провайдер с депозитом, либо свой сервер, либо экономический стимул
постороннему боту. Ни один не дает гарантии в криптографическом смысле.
Поэтому обещание «работает без офчейн-сервиса» в pull-модели невыполнимо
в принципе: без офчейна работает только предоплата с разблокировкой по времени
(2.1) и непрерывный поток (2.2), и обе платят за это либо замороженным
капиталом, либо оберткой токена и экономикой ликвидаторов.

---

## 8. Стенд как доказательство

Стенд воспроизводит pull-модель (2.3) на локальном EVM с периодом в одну минуту.
Ниже — что именно из перечисленного он показывает и какими действиями.
Обязательные к воспроизведению сценарии перечислены в SPEC.md, раздел 13.

| Тезис исследования | Что делается на стенде | Где в SPEC.md |
|---|---|---|
| Разрешение отзываемо в одностороннем порядке и мгновенно (3.2) | `approve` в ноль, следующий вызов списания идет путем отказа, подписка становится просроченной | Раздел 13, сценарий 1 |
| Разрешение — потолок, а не расписание; оно исчерпаемо (3.1, 4.2) | Стартового разрешения хватает на пять периодов; шестое списание не проходит само, без всякого отзыва | Раздел 13, сценарий 1 (К11) |
| Нехватка баланса и нехватка разрешения — разные причины с одинаковым внешним результатом (6.2) | После десяти списаний денег нет; отказ фиксируется с причиной «не хватает баланса», отдельной от причины «нет разрешения» | Раздел 13, сценарий 2 (К4) |
| Контракт гарантирует только одно: списание не пройдет раньше срока (5.6) | Списание раньше срока — revert | Раздел 13, сценарий 3 |
| Роль вызывающего отделена от роли получателя; газ платит вызывающий (5.3) | Списание посторонним адресом проходит успешно — это поведение, а не сбой; ровно модель публичного вызова у Sablier Flow | Раздел 13, сценарий 4 |
| Пропущенные периоды — главный проектный выбор модели (6.2) | Подписчик пропускает три периода, затем нажимает списание три раза подряд; витрина показывает погашение долга с уменьшающимся счетчиком | Раздел 13, сценарий 9 (К7) |
| Идемпотентность на цепочке есть, но она узкая (6.2) | Проверка периода не дает списать дважды подряд; при этом отмена и повторное оформление в том же периоде дают второе списание — законно с точки зрения контракта | Раздел 13, сценарий 7 (К9) |
| Отмена действует только вперед, деньги за начатый период не возвращаются (6.2) | Отмена сразу после оформления: факт минуты виден до истечения оплаченного периода, затем экран меняется | Раздел 13, сценарий 10 |
| Неудачное списание — нормальное состояние системы, а не авария | Неудачное списание не откатывает транзакцию, а оставляет след в цепочке | Раздел 14, допущение 6 |
| Отсутствие платежа наблюдаемо снаружи | Витрина гаснет: подписка активна — виден факт минуты, не активна — не виден | Раздел 13, сценарии 8 и 10 |

Чего стенд честно показать не может и не пытается: реорганизацию цепочки
и финализацию, зависшую транзакцию и очередь по nonce, блокировку адреса
эмитентом стейблкоина, конкуренцию исполнителей за награду. Первое требует
управления консенсусом, второе — живого мемпула, третье — токена с ролью
blacklister, четвертое — реальной цены газа; на локальном узле с бесплатным
газом эта механика вырождается.

Отдельно: минутный период — осознанное искажение ради наблюдаемости.
Раздел 5.5 показывает, что в реальной экономике L1 минутный период невозможен
ни при каких суммах, и переносить со стенда вывод «минута работает» нельзя.

---

## 9. Чем платит наш стенд

Спорные решения из раздела 14 спецификации. По каждому — почему так решено
на стенде и почему в живом продукте так делать нельзя.

**1. Долг догоняется, пользователь платит за неиспользованные периоды
(допущение 1).**
На стенде так решено, потому что сгорающий долг прячет пропуск: отметка
оплаченного времени прыгала бы к текущему моменту, и по состоянию нельзя было бы
увидеть, сколько периодов пропало. В живом продукте так делать нельзя: человек
платит за время, в котором сервисом не пользовался. Исследование подтверждает,
что это ровно та развилка, где реальные решения расходятся диаметрально:
Request после снятия паузы догоняет, Unlock продлевает от момента вызова
и долг не копит, Sablier Flow копит долг на цепочке. При этом поведение
«списать сразу за несколько пропущенных периодов одной транзакцией» не описано
явно ни в одной просмотренной документации — **не подтверждено**; косвенное
объяснение из `failures.md`: такое списание трудно отличить от двойного и для
плательщика выглядит как несанкционированный платеж, хотя формально разрешение
было.

**2. Предел просрочки принудительно прекращает подписку (допущение 2).**
На стенде так решено, потому что демонстрация должна показывать терминальный
исход просрочки в пределах пяти минут, а не тянуть неоплаченную подписку
бесконечно. В живом продукте так делать нельзя: подписка гасится без
предупреждения и без попытки связаться с плательщиком, причем даже тогда, когда
денег и разрешения хватало — то есть по причине, не зависящей от него
(раздел 6.1: отсутствие платежа не означает отказ плательщика). Отраслевая
практика ровно обратная по составу: у Loop окну в 7 дней предшествуют письма
в воскресенье перед списанием и напоминания за 48 и 24 часа, а само окно
настраивается мерчантом; у Suberra внутри grace period доступ сохраняется.
Автоматическая отмена в отрасли существует, но она — конец длинной цепочки
уведомлений, а не первая реакция.

**3. Отмена гасит долг (допущение 3).**
На стенде так решено, потому что списания по отмененной подписке запрещены,
и это делает состояние «отменена» терминальным и простым для чтения. В живом
продукте так делать нельзя: реальные провайдеры долг при отмене не списывают,
а оставляют к взысканию — формулировка Loop прямая: «all future scheduled
invoices will be cancelled but any currently due invoices will not be».
Прецедент прощения долга в исследовании все же есть, и он полезен как рамка:
`void` у Sablier Flow «forfeits the uncovered debt». Но там это отдельное
терминальное действие с явно названным последствием, а не побочный эффект
обычной отмены.

**4. Все сравнения времени опираются на `block.timestamp` (допущение 9).**
На стенде так решено, потому что на времени блока построена вся механика
периодов и обойти его нечем; локальный узел выдает время ровно, с шагом
в одну секунду. В живом продукте так делать нельзя **на таком периоде**:
валидатор может сдвинуть время блока на несколько секунд, и на периоде длиной
60 секунд это заметная доля — списание пройдет чуть раньше или чуть позже
срока; для периода длиной в месяц отклонение несущественно.

Отдельно отмечу: **утверждение о величине сдвига времени блока в реальной сети
в материалах `research/` источником не подкреплено — не подтверждено.** Оно
взято из самого допущения 9 спецификации. Косвенно с ним согласуется
наблюдение из раздела 5: между наблюдением состояния, консенсусом и включением
транзакции есть задержка, из-за которой Chainlink предупреждает о риске
непроведения upkeep при быстро меняющемся условии — но это про задержку
исполнения, а не про сдвиг `block.timestamp`.

**5. Граница применимости пути 6: перевод не может провалиться
(допущение 10).**
На стенде так решено, потому что для токена стенда это верно: проверки сверяют
ровно те же две величины, что и сам перевод, а между проверкой и переводом
внутри одной транзакции состояние измениться не может. Мультитокен находится
в нецелях, и заделка потребовала бы нового значения причины отказа и новой
строки в таблице списания.

В живом продукте так делать нельзя, и исследование дает этому самое плотное
подтверждение из всех пяти пунктов. Токен с комиссией на перевод, черным
списком, паузой или возвращающий ложь откатит вызов при пройденных проверках —
и неудача не оставит следа в цепочке. Все эти классы токенов существуют
и перечислены поименно: комиссия на перевод (`STA`, `PAXG`), отсутствие
возвращаемого значения (`USDT`, `BNB`, `OMG`), пауза и черный список (`BNB`,
`ZIL`, `USDC`, `USDT`) ([weird-erc20](https://github.com/d-xo/weird-erc20)).
Более того, USDC версии 2.2 позволяет заблокированному адресу вызывать
`approve`, хотя двигать токены он не может — то есть **проверка allowance
пройдет, а перевод упадет** ровно в том сценарии, который допущение 10 выносит
за границу применимости
([tokendesign](https://github.com/zhenghui-w/stablecoin-evm/blob/master/doc/tokendesign.md)).
Это не гипотетика: заморозка адресов USDC применялась на практике
([CoinDesk](https://www.coindesk.com/markets/2020/07/08/circle-confirms-freezing-100k-in-usdc-at-law-enforcements-request)).
Отраслевого подхода к обработке этого сценария при этом нет ни у одного
из разобранных протоколов (6.3, пункт 5).

---

## 10. Не подтверждено

Собрано из всех восьми файлов. Отсутствие источника — это результат, а не
пробел, поэтому список не сокращался.

**Провайдеры и их экономика**

1. Loop Crypto: кто фактически оплачивает газ за автосписание — сам Loop или
   мерчант. Явного источника нет.
2. Loop Crypto: автоматическая отмена подписки после N неудачных попыток —
   `providers.md` не нашел первоисточника; `failures.md` приводит окно 7 дней
   по документации. Статус факта расходится между файлами (см. 6.3).
3. Loop Crypto в целом: официальные страницы `loopcrypto.xyz`
   и `docs.loopcrypto.xyz` не открывались напрямую — цитаты собраны
   из поисковой выдачи по этим URL. Страницы старой документации на GitBook
   открывались нормально и цитируются напрямую.
4. Spritz: механизм gasless-исполнения (мета-транзакции, релеер, конкретный
   провайдер автоматизации) публично не описан.
5. Spritz: поведение при явном отзыве approve пользователем.
6. Request Network: поведение при явном отзыве approve, в отличие
   от нехватки баланса.
7. Request Network: имя контракта рекуррентных платежей.
8. Request Network: точный алгоритм догона после unpause — сколько периодов
   и одной ли транзакцией.
9. Suberra: точное расписание повторов внутри 7-дневного grace period
   («часто» — единственная формулировка).
10. Sablier Lockup: что происходит, если получатель никогда не вызывает
    `withdraw`.
11. Sablier: противоречие между справочником контракта и FAQ по вопросу, кто
    может отменить поток. К какому продукту относится ответ FAQ — не
    установлено.
12. Superfluid: тезис о том, что открытый поток далее не требует газа, взят
    из блога протокола, а не из основной документации.
13. Superfluid: что показывают получателю в интерфейсе в момент ликвидации
    потока.
14. Superfluid: механизм возврата уже переданных средств — не найден.
15. Возвраты у Loop, Request, Spritz, Suberra: раздела о возвратах
    в просмотренной документации нет. Догадка, что Loop делает возврат вне
    цепочки через Stripe, прямо не подтверждена.

**Механика разрешений**

16. Точное поведение mainnet-контракта USDT при `allowance == MAX_UINT`:
    подтверждено только вторичными источниками, исходник открыть не удалось.
17. Наличие или отсутствие `permit` (EIP-2612) в mainnet-контракте USDT.
18. Полный официальный список сетей, где Permit2 развернут по каноническому
    адресу.
19. Дословные формулировки changelog OpenZeppelin про deprecation ERC-777
    в 4.9 и удаление в 5.0: факт подтвержден вторичными источниками,
    цитата не сверялась.
20. Дата и детали инцидента на 24 млн долларов с `increaseAllowance`: сам факт
    упоминания в issue OpenZeppelin подтвержден, первоисточник инцидента
    не проверялся.
21. Насколько EIP-7702 фактически используется провайдерами подписок.

**Исполнители и газ**

22. Точный процент сервисной комиссии Gelato поверх газа: в документации только
    качественные формулировки («nominal fee», «percentage of total gas cost»).
23. Степень децентрализации исполнителей Gelato: число, состав и механизм
    консенсуса не раскрыты.
24. SLA или формальная гарантия исполнения — не обнаружена ни у Chainlink
    Automation, ни у Gelato, ни у Defender.
25. Цифры экономии из вендорского блога Gelato ($7.2/день против $288/день,
    «97.5% cheaper»): маркетинговый материал, сравнивающий с Chainlink
    *Functions*, а не *Automation*; независимо не проверено.
26. Тарифы OpenZeppelin Defender — не проверялись.
27. Текущее состояние и активность Keep3r Network — не проверялись, описана
    только механика по документации.
28. Актуальные цены газа и все производные долларовые суммы: снимок
    `l2fees.info` без временной метки. Дата снимка в `trigger.md` указана
    противоречиво — 2024-08-25 в тексте раздела и 2026-08-25 в сводке.
29. Оценка 70 000…110 000 газа на одно списание — арифметика по газовой
    таблице, не измерение.
30. Оценка 49 000…66 000 газа на одиночный `transferFrom` — сумма бенчмарка
    на минимальных реализациях (по признанию автора, «не на 100% точен»)
    и `TX_BASE`.
31. Абсолютная стоимость подписки на L2 — требует свежего замера.

**Сбои**

32. Сценарий «несколько пропусков подряд списываются одной транзакцией» — явно
    не описан ни в одной просмотренной документации. Риск того, что догон
    выглядит для пользователя как несанкционированный платеж, обсуждается
    в материалах без внешнего источника.
33. Поведение любого из разобранных протоколов при блокировке адреса
    плательщика или получателя эмитентом стейблкоина.
34. Обработка реоргов, зависших транзакций и замены по nonce на уровне самих
    подписочных протоколов: все найденные источники общие, не привязанные
    к подпискам.
35. Идемпотентность и защита от двойного списания у Loop, Request, Spritz,
    Suberra — в документации не описаны.

**Стенд**

36. Величина сдвига `block.timestamp` валидатором в реальной сети (допущение 9
    спецификации): в материалах `research/` источника нет.

---

## 11. Источники

**Стандарты и спецификации**

- [EIP-20: Token Standard](https://eips.ethereum.org/EIPS/eip-20)
- [EIP-777: Token Standard](https://eips.ethereum.org/EIPS/eip-777)
- [EIP-1337: Subscriptions on the blockchain](https://eips.ethereum.org/EIPS/eip-1337)
- [EIP-1363: Payable Token](https://eips.ethereum.org/EIPS/eip-1363)
- [EIP-2200](https://eips.ethereum.org/EIPS/eip-2200), [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929), [EIP-3529](https://eips.ethereum.org/EIPS/eip-3529)
- [EIP-2612: Permit Extension for EIP-20 Signed Approvals](https://eips.ethereum.org/EIPS/eip-2612)
- [EIP-3009: Transfer With Authorization](https://eips.ethereum.org/EIPS/eip-3009), [разбор](https://hackmd.io/@Extropy/EIP3009)
- [EIP-4337: Account Abstraction](https://eips.ethereum.org/EIPS/eip-4337)
- [EIP-7702: Set Code for EOAs](https://eips.ethereum.org/EIPS/eip-7702)
- [ERC-7710](https://github.com/ethereum/ERCs/blob/master/ERCS/erc-7710.md), [ERC-7715](https://github.com/ethereum/ERCs/blob/master/ERCS/erc-7715.md)
- [ERC-948 (issue)](https://github.com/ethereum/EIPs/issues/948), [Unlimited allowance (issue 717)](https://github.com/ethereum/EIPs/issues/717)
- [SWC-114: Transaction Order Dependence](http://swcregistry.io/docs/SWC-114/)

**Ethereum: механика и газ**

- [ethereum.org: Smart contracts](https://ethereum.org/developers/docs/smart-contracts/), [Gas](https://ethereum.org/en/developers/docs/gas/), [MEV](https://ethereum.org/developers/docs/mev/)
- [execution-specs: gas.py (Cancun)](https://github.com/ethereum/execution-specs/blob/master/src/ethereum/forks/cancun/vm/gas.py)
- [Flash Boys 2.0 (arXiv:1904.05234)](https://arxiv.org/abs/1904.05234)
- [Trail of Bits: The Engineer's Guide to Blockchain Finality](https://blog.trailofbits.com/2023/08/23/the-engineers-guide-to-blockchain-finality/)
- [Optimism Docs: Transaction fees](https://docs.optimism.io/stack/transactions/fees)
- [l2fees.info](https://l2fees.info/)
- [solidity-benchmarks](https://github.com/alephao/solidity-benchmarks), [ERC20 0.8.26](https://github.com/alephao/solidity-benchmarks/blob/main/benchmarks/0.8.26/ERC20.md)
- [KuCoin: Understanding Ethereum Gas Fees](https://www.kucoin.com/learn/web3/understanding-ethereum-gas-fees), [TokenHook (arXiv:2107.02997)](https://arxiv.org/pdf/2107.02997)
- [Etherscan: cancel pending transactions](https://info.etherscan.io/how-to-cancel-ethereum-pending-transactions/), [MetaMask: speed up or cancel](https://support.metamask.io/manage-crypto/transactions/how-to-speed-up-or-cancel-a-pending-transaction/)

**Отраслевые обзоры**

- [Spark: Recurring Stablecoin Payment Infrastructure](https://www.spark.money/research/recurring-stablecoin-payment-infrastructure)
- [Spark: Payment finality comparison](https://www.spark.money/research/payment-finality-comparison-blockchains)
- [VeradiVerdict: Loop — Web3 Payment Rail](https://www.veradiverdict.com/p/web3-payment-rail)
- [x402: анализ атак (arXiv)](https://arxiv.org/html/2605.11781v1)

**Sablier**

- [Streaming](https://docs.sablier.com/concepts/streaming), [GitHub: 02-streaming.md](https://github.com/sablier-labs/docs/blob/main/docs/concepts/02-streaming.md)
- [Types of Streams](https://docs.sablier.com/concepts/protocol/stream-types), [Cancelability](https://docs.sablier.com/concepts/cancelability), [FAQ](https://docs.sablier.com/support/faq)
- [Lockup: withdraw](https://docs.sablier.com/guides/lockup/examples/stream-management/withdraw), [cancel](https://docs.sablier.com/guides/lockup/examples/stream-management/cancel), [contract reference](https://docs.sablier.com/reference/lockup/contracts/contract.SablierLockup)
- [Flow Overview](https://docs.sablier.com/concepts/flow/overview), [Flow: stream management](https://docs.sablier.com/guides/flow/examples/stream-management), [github.com/sablier-labs/flow](https://github.com/sablier-labs/flow/)
- [Blog: Overview of Token Streaming Models](https://blog.sablier.com/overview-token-streaming-models)

**Superfluid**

- [Money Streaming (concepts)](https://docs.superfluid.org/docs/concepts/overview/money-streaming), [Super Tokens](https://docs.superfluid.org/docs/concepts/overview/super-tokens), [Glossary](https://docs.superfluid.org/docs/concepts/glossary)
- [Money Streaming (protocol)](https://docs.superfluid.org/docs/protocol/money-streaming/overview), [create/update/delete flow](https://docs.superfluid.org/docs/protocol/money-streaming/guides/create-update-delete-flow)
- [Liquidations & TOGA](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga), [Running a sentinel](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/running-a-sentinnel), [superfluid-sentinel](https://github.com/superfluid-org/superfluid-sentinel)
- [Stream scheduler / Auto-Wrap](https://docs.superfluid.org/docs/protocol/advanced-topics/automations/stream-scheduler), [Automations](https://superfluid.org/post/streamline-your-web3-apps-with-superfluid-automations)
- [CFA ACL](https://github.com/superfluid-finance/docs/blob/main/developers/constant-flow-agreement-cfa/cfa-access-control-list-acl/README.md), [Wiki: CFA ACL](https://github.com/superfluid-finance/protocol-monorepo/wiki/About-CFA-ACL-Feature)
- [Help: How do stream buffers work](https://help.superfluid.finance/en/articles/5744874-how-do-stream-buffers-work-in-superfluid)
- [Blog: Superfluid Streams](https://medium.com/superfluid-blog/superfluid-streams-5cc5141dd8a7), [Introducing Sentinels](https://medium.com/superfluid-blog/introducing-sentinels-the-keepers-of-superfluid-protocol-4eadca384cbf)

**Loop Crypto**

- [docs.loopcrypto.xyz](https://docs.loopcrypto.xyz), [welcome](https://docs.loopcrypto.xyz/docs/welcome), [renewal payments](https://docs.loopcrypto.xyz/docs/renewal-payments-copy), [Stripe Connect](https://docs.loopcrypto.xyz/integrations/stripe-+-loop/subscriptions-with-stripe-connect)
- [GitBook: Subscriptions](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions), [Checkout widget](https://loop-crypto.gitbook.io/old-loop-crypto/technical-docs/archeticture/collecting-authorization/checkout-widget), [Stripe FAQ](https://loop-crypto.gitbook.io/old-loop-crypto/integrations/stripe-+-loop/faqs-about-stripe-integration)
- [Blog: Updating your spend allowance](https://www.loopcrypto.xyz/blog/updating-your-spend-allowance-on-loops-customer-portal), [зеркало](https://loopcrypto.medium.com/updating-your-spend-allowance-on-loop-cryptos-customer-portal-43dd522ae6d1)
- [SaaS](https://www.loopcrypto.xyz/saas), [loopcrypto.xyz](https://www.loopcrypto.xyz/), [Live on Base](https://www.loopcrypto.xyz/blog/loop-crypto-is-live-on-base), [Introducing Loop Crypto](https://loopcrypto.medium.com/introducing-loop-crypto-e2579d81006f)

**Spritz, Request, Unlock, Suberra**

- [Spritz: How does SMARTPay work](https://help.spritz.finance/en/articles/7065236-how-does-smartpay-work), [one-time vs enduring allowance](https://help.spritz.finance/en/articles/7236067-when-you-sign-off-on-a-transaction-with-spritz-are-you-giving-it-a-one-time-allowance-or-an-enduring-one), [insufficient funds](https://help.spritz.finance/en/articles/7065124-what-will-happen-to-my-smartpay-transaction-if-i-don-t-have-enough-funds-in-my-wallet-to-cover-the-payment), [Introducing SMARTPay](https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments)
- [Request: Recurring payments](https://docs.request.network/request-network-api/recurring-payments), [payment reference](https://docs.request.network/advanced/request-network-sdk/sdk-guides/request-client/payment-reference), [how payment networks work](https://docs.request.network/advanced/protocol-overview/how-payment-networks-work), [request.network](https://request.network/)
- [Unlock: renewals](https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/), [PublicLock API](https://docs.unlock-protocol.com/core-protocol/smart-contracts-api/PublicLock), [recurring memberships](https://docs.unlock-protocol.com/move-to-guides/recurring-memberships), [how to cancel a membership](https://unlock-protocol.com/guides/how-to-cancel-a-users-membership/)
- [Suberra: subscriptions](https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/)

**Разрешения: реализации и разборы**

- [OpenZeppelin ERC20.sol](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol), [changelog 5.x](https://docs.openzeppelin.com/contracts/5.x/changelog), [ERC20 3.x](https://docs.openzeppelin.com/contracts/3.x/api/token/erc20), [ERC777 4.x](https://docs.openzeppelin.com/contracts/4.x/erc777)
- [OZ issue 4583](https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4583), [PR 4585](https://github.com/OpenZeppelin/openzeppelin-contracts/pull/4585)
- [OpenZeppelin: EOA Delegation](https://docs.openzeppelin.com/contracts/5.x/eoa-delegation), [Exploiting Uniswap: from reentrancy to actual profit](https://www.openzeppelin.com/news/exploiting-uniswap-from-reentrancy-to-actual-profit)
- [Uniswap/permit2](https://github.com/Uniswap/permit2), [README](https://github.com/Uniswap/permit2/blob/main/README.md), [AllowanceTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/AllowanceTransfer.sol), [IAllowanceTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/interfaces/IAllowanceTransfer.sol), [ISignatureTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/interfaces/ISignatureTransfer.sol), [Allowance.sol](https://github.com/Uniswap/permit2/blob/main/src/libraries/Allowance.sol), [issue 163](https://github.com/Uniswap/permit2/issues/163)
- [Uniswap Docs: AllowanceTransfer](https://developers.uniswap.org/contracts/permit2/reference/allowance-transfer), [SignatureTransfer](https://docs.uniswap.org/contracts/permit2/reference/signature-transfer), [Permit2 overview](https://developers.uniswap.org/contracts/permit2/overview), [allowance-transfer concepts](https://developers.uniswap.org/docs/protocols/permit2/concepts/allowance-transfer), [Permit2 на Etherscan](https://etherscan.io/address/0x000000000022d473030f116ddee9f6b43ac78ba3)
- [Circle: stablecoin-evm EIP2612.sol](https://github.com/circlefin/stablecoin-evm/blob/master/contracts/v2/EIP2612.sol), [Four ways to authorize USDC](https://www.circle.com/blog/four-ways-to-authorize-usdc-smart-contract-interactions-with-circle-sdk), [FiatToken design](https://github.com/zhenghui-w/stablecoin-evm/blob/master/doc/tokendesign.md)
- [MakerDAO dai.sol](https://github.com/makerdao/dss/blob/master/src/dai.sol)
- [weird-erc20](https://github.com/d-xo/weird-erc20), [revoke.cash: how to revoke approvals](https://revoke.cash/learn/approvals/how-to-revoke-token-approvals)
- [Zokyo: ERC20 approve race condition](https://zokyo-auditing-tutorials.gitbook.io/zokyo-tutorials/tutorials/tutorial-3-approvals-and-safe-approvals/vulnerability-examples/erc20-approve-race-condition-vulnerability), [Utila: Understanding Token Approvals](https://utila.io/blog/understanding-token-approvals-on-evm-tron)
- [Eco: EIP-3009](https://eco.com/support/en/articles/14796369-eip-3009-authorization-transfer-for-stablecoins), [Eco: EIP-7702](https://eco.com/support/en/articles/14796249-eip-7702-explained-account-abstraction-for-eoas)
- [MetaMask Delegation Toolkit: ERC-7715](https://docs.metamask.io/delegation-toolkit/0.12.0/experimental/erc-7715-request-permissions/)
- [Jon-Becker/ethereum-recurring-payments](https://github.com/Jon-Becker/ethereum-recurring-payments), [austintgriffith/token-subscription](https://github.com/austintgriffith/token-subscription)
- [Decoding Tether (USDT) code](https://medium.com/coinmonks/decoding-the-tether-usdt-an-in-depth-look-at-the-usdt-code-0f50c994bf81)

**Исполнители**

- Chainlink Automation: [обзор](https://docs.chain.link/chainlink-automation), [getting started](https://docs.chain.link/chainlink-automation/overview/getting-started), [economics](https://docs.chain.link/chainlink-automation/overview/automation-economics), [supported networks](https://docs.chain.link/chainlink-automation/overview/supported-networks), [architecture](https://docs.chain.link/chainlink-automation/concepts/automation-architecture), [best practice](https://docs.chain.link/chainlink-automation/concepts/best-practice), [compatible contracts](https://docs.chain.link/chainlink-automation/guides/compatible-contracts), [forwarder](https://docs.chain.link/chainlink-automation/guides/forwarder), [job scheduler](https://docs.chain.link/chainlink-automation/guides/job-scheduler), [manage upkeeps](https://docs.chain.link/chainlink-automation/guides/manage-upkeeps), [interfaces](https://docs.chain.link/chainlink-automation/reference/automation-interfaces)
- Gelato: [Web3 Functions](https://docs.gelato.cloud/web3-services/web3-functions), [Automated Transactions](https://docs.gelato.cloud/web3-functions/introduction/automated-transactions), [1Balance](https://docs.gelato.cloud/web3-services/1balance), [dedicated msg.sender](https://docs.gelato.cloud/web3-functions/security-considerations/dedicated-msg-sender), [SyncFee](https://docs.gelato.cloud/Relay/Subscription-and-payments/SyncFee-payment-tokens), [writing TS functions](https://docs.gelato.cloud/web3-services/web3-functions/quick-start/writing-typescript-functions), [automate](https://github.com/gelatodigital/automate), [AutomateReady.sol](https://github.com/gelatodigital/automate/blob/master/contracts/integrations/AutomateReady.sol), [вендорское сравнение](https://gelato.cloud/blog/gelato-functions-vs-chainlink-functions)
- OpenZeppelin Defender: [Actions](https://docs.openzeppelin.com/defender/module/actions), [Relayers](https://docs.openzeppelin.com/defender/module/relayers)
- Keep3r: [jobs](https://docs.keep3r.network/core/jobs), [payment mechanisms](https://docs.keep3r.network/tokenomics/job-payment-mechanisms), [token payments](https://docs.keep3r.network/tokenomics/job-payment-mechanisms/token-payments), [credit mining](https://docs.keep3r.network/tokenomics/job-payment-mechanisms/credit-mining), [docs](https://docs.keep3r.network/)
- Pyth: [Using Gelato](https://docs.pyth.network/price-feeds/core/schedule-price-updates/using-gelato)
- MakerDAO: [Liquidation 2.0 Module](https://docs.makerdao.com/smart-contract-modules/dog-and-clipper-detailed-documentation), [StableSims (arXiv:2201.03519)](https://arxiv.org/abs/2201.03519)
- [B.Protocol: The Keeper's Dilemma](https://medium.com/b-protocol/the-keepers-dilemma-game-theoretic-analysis-of-liquidation-incentives-with-preliminary-b588e82e4d67)

**Возвраты и споры**

- [Chargebacks911: Crypto Chargebacks](https://chargebacks911.com/crypto-chargebacks/), [Chargeback.io](https://www.chargeback.io/blog/what-to-know-about-crypto-chargebacks)
- [ERC-20R/721R (arXiv:2208.00543)](https://arxiv.org/pdf/2208.00543), [CoinDesk о предложении](https://www.coindesk.com/tech/2022/09/28/stanford-proposal-for-reversible-ethereum-transactions-divides-crypto-community)
- [CoinDesk: Circle freezes 100k USDC](https://www.coindesk.com/markets/2020/07/08/circle-confirms-freezing-100k-in-usdc-at-law-enforcements-request)

**Аудиты**

- [ConsenSys Diligence: Daisy audit report (2019-08)](https://github.com/ConsenSys/daisy-audit-report-2019-08)
