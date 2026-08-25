# Механика разрешений ERC-20 применительно к рекуррентным списаниям

Исследовательская записка. Задача — понять, какими способами плательщик может
заранее выдать получателю право списывать с него токены, и чем каждый способ
платит за удобство. Прикладной контекст — учебный стенд pull-модели
с фиксированной суммой и периодом в одну минуту.

Все содержательные тезисы снабжены ссылкой на источник. Там, где надежного
источника найти не удалось, стоит явная пометка **не подтверждено**.

---

## 1. Классический approve / transferFrom

### 1.1. Интерфейс

Три функции из спецификации ERC-20
(https://eips.ethereum.org/EIPS/eip-20):

```solidity
function approve(address _spender, uint256 _value) public returns (bool success)
function transferFrom(address _from, address _to, uint256 _value) public returns (bool success)
function allowance(address _owner, address _spender) public view returns (uint256 remaining)
```

Модель такая: владелец токенов вызывает `approve`, записывая в контракт токена
число — «сколько этот spender имеет право у меня забрать». Число хранится
в паре (owner, spender) и читается через `allowance`. Дальше spender вызывает
`transferFrom` от своего имени, и контракт токена уменьшает остаток разрешения
на переведенную сумму.

Ключевой момент для рекуррентных платежей: `approve` опирается на `msg.sender`
— то есть подписать разрешение может только сам владелец, отдельной
транзакцией, за свой газ. Это прямо названо мотивацией ERC-2612
(https://eips.ethereum.org/EIPS/eip-2612): «EIP-20's `approve` function relies
on `msg.sender`», из-за чего пользователь вынужден делать две транзакции.

### 1.2. Что именно означает allowance

Разрешение — это **лимит с накоплением расхода**, а не расписание. В нем нет
ни периода, ни срока годности, ни суммы одного платежа. Токен знает только
остаток. Всю логику «раз в минуту не больше X» обязан держать у себя контракт
подписки — токен здесь ничего не проверяет.

Референсная реализация OpenZeppelin списывает остаток в `_spendAllowance`,
вызываемой из `transferFrom`
(https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol).
Документирующий комментарий: «Updates `owner`'s allowance for `spender` based on
spent `value`. Does not update the allowance value in case of infinite
allowance» — про бесконечное разрешение см. раздел 2.

### 1.3. Гонка при повторном approve (front-running)

Проблема известна с 2016 года и упомянута прямо в тексте ERC-20:

> «To prevent attack vectors like the one [described here] and discussed
> [here], clients SHOULD make sure to create user interfaces in such a way that
> they set the allowance first to `0` before setting it to another value for the
> same spender.»
> — https://eips.ethereum.org/EIPS/eip-20

Ссылки, на которые указывает сам EIP:
- разбор атаки: https://docs.google.com/document/d/1YLPtQxZu1UAvO9cZ1O2RPXBbT0mooh4DYKjA_jp-RLM/
- обсуждение: https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729

Суть: у spender уже есть разрешение N. Владелец решает поменять его на M
и шлет `approve(spender, M)`. Spender видит транзакцию в мемпуле, успевает
вперед нее вызвать `transferFrom` на N, после чего проходит `approve`
и он получает еще M. Итого списано N + M вместо задуманных M.

Важные оговорки:
- EIP явно перекладывает смягчение на **интерфейс клиента**, а не на контракт:
  «the contract itself shouldn't enforce it, to allow backwards compatibility
  with contracts deployed before» (там же).
- Схема «сначала 0, потом M» — это две транзакции, и между ними тоже есть окно;
  spender может фронтранить транзакцию обнуления.

Некоторые токены все же зашили защиту на уровне контракта. Каталог
нестандартных поведений weird-erc20 (https://github.com/d-xo/weird-erc20)
формулирует так: «Some tokens (e.g. `USDT`, `KNC`) do not allow approving an
amount `M > 0` when an existing amount `N > 0` is already approved». Там же
отмечено, что это ломало интеграции — например, в Uniswap v2-periphery.

### 1.4. increaseAllowance / decreaseAllowance

Этих функций **нет в спецификации ERC-20** — это расширение, которое
популяризировал OpenZeppelin. Идея: менять разрешение дельтой атомарно, чтобы
не возникало окна между «старое N» и «новое M».

В OpenZeppelin Contracts v5.0.0 их **удалили**. Формулировка changelog:
«Removed the non-standard `increaseAllowance` and `decreaseAllowance`
functions» (https://docs.openzeppelin.com/contracts/5.x/changelog).

Обоснование — в обсуждении
https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4583:
- функции «not part of the EIP-20 specs», то есть их место — в отдельном
  расширении, а не в базовом токене;
- они «may allow for further phishing possibilities»: в тексте issue приводится
  инцидент, где пользователь потерял 24 млн долларов, подписав вредоносный
  payload `increaseAllowance` (кошельки хуже показывают такой вызов, чем
  привычный `approve`);
- защитная ценность ограничена: `decreaseAllowance` сам по себе фронтранится,
  а исходные «security concerns ... are not critical nor high in the wild».

Практический вывод: атомарное изменение дельты закрывает узкую версию гонки, но
вводит новую поверхность для фишинга и не является стандартом. Рассчитывать на
наличие этих функций у произвольного токена нельзя.

### 1.5. Что дает и чем платит

**Дает:**
- работает с любым ERC-20 без исключений — это базовый уровень совместимости;
- прост: одно число в сторадже токена, никакой криптографии в контракте;
- позволяет получателю списывать в удобный ему момент (pull), без участия
  плательщика в момент платежа — ровно то, что нужно подписке;
- отзыв тривиален: `approve(spender, 0)`.

**Платит:**
- отдельная on-chain транзакция и газ плательщика на каждое изменение лимита;
- гонка при повторном approve (см. 1.3) и неудобная схема «обнули, потом
  выставь»;
- в разрешении нет ни срока, ни периода, ни лимита на один платеж — токен
  не поможет ограничить злоупотребление spender'а;
- разрешение действует до явного отзыва, включая случай, когда контракт-spender
  позже окажется скомпрометирован или обновлен через прокси;
- поведение токенов различается сильнее, чем кажется: отсутствие возвращаемого
  значения (`USDT`, `BNB`, `OMG`), комиссия на перевод (`STA`, `PAXG`),
  pausable и blocklist (`BNB`, `ZIL`, `USDC`, `USDT`) —
  https://github.com/d-xo/weird-erc20. Для рекуррентных списаний это значит, что
  «списание прошло» и «получатель получил ровно сумму» — разные утверждения.

---

## 2. Бесконечное разрешение (unlimited approve)

### 2.1. Зачем

Практика: выставить `approve(spender, type(uint256).max)` один раз, чтобы
больше никогда не платить за повторные `approve` и не показывать пользователю
подтверждение перед каждой операцией. Для подписки соблазн очевидный —
плательщик подписывается один раз, дальше контракт списывает сколько угодно раз.

Второй мотив — экономия газа на самих списаниях. В обсуждении
https://github.com/ethereum/EIPs/issues/717 (Unlimited ERC20 token allowance)
проблема ставится так: при стандартной реализации значение вычитается из
`allowed` на каждом `transferFrom`, что при заведомо безлимитном разрешении
бессмысленно и тратит лишний газ на запись в сторадж.

### 2.2. Уменьшается ли allowance при max — зависит от токена

Единого правила в ERC-20 нет; это поведение конкретной реализации.

- **OpenZeppelin ERC20**: не уменьшается. `_spendAllowance` документирована как
  «Does not update the allowance value in case of infinite allowance» и
  сравнивает текущее разрешение с максимумом uint256
  (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol).
  То есть после `approve(max)` значение `allowance` навсегда остается max,
  и «расход» по нему не виден ни в интерфейсе, ни в логах Approval.
- **Токены, реализованные наивно**: уменьшают, как и любое другое число, —
  и тогда max просто очень большое значение, которое на практике не исчерпать.
- **USDT (Tether)**: по вторичным источникам, `transferFrom` не уменьшает
  разрешение, если оно равно MAX_UINT
  (https://github.com/ethereum/EIPs/issues/717,
  https://medium.com/coinmonks/decoding-the-tether-usdt-an-in-depth-look-at-the-usdt-code-0f50c994bf81).
  Исходник контракта в рамках этой сессии открыть не удалось (raw-ссылка
  на репозиторий Tether отдала 404) — **не подтверждено первичным источником**.

Отдельный класс граблей из каталога weird-erc20
(https://github.com/d-xo/weird-erc20): есть токены, которые **ревертят
на `approve` нулевого значения** (`BNB`), и токены с защитой от гонки, которые
не дают выставить M > 0 поверх N > 0 (`USDT`, `KNC`). То есть даже отзыв
безлимитного разрешения не везде выглядит одинаково.

### 2.3. Что дает и чем платит

**Дает:**
- одно подтверждение от пользователя на все время жизни подписки;
- дешевле по газу на списание там, где токен пропускает вычитание при max;
- нет повторного попадания в гонку из 1.3, потому что повторных approve нет.

**Платит:**
- максимальный размер ущерба при компрометации spender'а — не «сумма подписки»,
  а **весь баланс плательщика** по этому токену, сейчас и в будущем;
- разрешение переживает обновление контракта-получателя: апгрейдируемый прокси
  может поменять логику под уже выданным безлимитом;
- пользователь теряет обзор: при реализации в стиле OpenZeppelin `allowance`
  всегда показывает max, и по нему невозможно понять, сколько уже списано;
- отзыв требует отдельной транзакции и активного действия, о котором люди
  забывают; забытые безлимитные разрешения — типовой вектор потерь;
- поведение на самом деле не единообразно между токенами (см. 2.2), поэтому
  «безлимит» — не переносимая абстракция.

---

## 3. EIP-2612: permit — подпись вместо транзакции

Источник: https://eips.ethereum.org/EIPS/eip-2612

### 3.1. Что это

Расширение ERC-20, добавляющее токену функцию, которая выставляет allowance
по **подписи владельца**, а не по `msg.sender`:

```solidity
function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external
```

Дополнительно токен обязан предоставлять `nonces(address owner)` и
`DOMAIN_SEPARATOR()` (там же).

### 3.2. Типизированные данные

Сообщение подписывается по EIP-712. Структура:

```
keccak256(abi.encode(
  keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
  owner, spender, value, nonce, deadline
))
```

Домен (`DOMAIN_SEPARATOR`) включает name, version, chainId и адрес контракта и
существует, чтобы «prevent replay attacks from other domains» (там же).

### 3.3. Nonce и deadline

- `nonces` — счетчик на владельца, «for replay protection»: каждая подпись
  одноразовая, и подписи расходуются строго по порядку (в отличие от Permit2,
  см. 4.3).
- `deadline` — момент, до которого подпись действительна: должно выполняться,
  что «the current blocktime is less than or equal to deadline». В EIP это
  названо средством против цензуры: подписант может «limit the time a Permit is
  valid for by setting deadline to a value in the near future».

### 3.4. Кто платит газ

Подписывает владелец — бесплатно и офчейн. Транзакцию `permit(...)` на цепочку
отправляет кто угодно: сам spender, релеер, контракт-агрегатор. Мотивация EIP
формулирует это как возможность операций с токеном «without requiring ETH for
gas» со стороны владельца. То есть газ платит **отправитель транзакции**, а не
подписант.

Типовой паттерн интеграции — упаковать `permit` и полезное действие в одну
транзакцию: вместо «approve + действие» получается одна операция.

### 3.5. Поддержка токенами

Permit есть **не у всех токенов** — это расширение, требующее изменения самого
контракта токена. Соответственно, для существующего развернутого токена без
`permit` добавить его нельзя (если только он не апгрейдируемый).

- **USDC**: поддерживает. Реализация — `contracts/v2/EIP2612.sol` в репозитории
  Circle (https://github.com/circlefin/stablecoin-evm/blob/master/contracts/v2/EIP2612.sol),
  с `PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9`
  и проверкой `deadline == type(uint256).max || deadline >= now`. Обратите
  внимание: у USDC есть перегрузка `permit` с `bytes memory signature`
  (для ERC-1271 / контрактных кошельков), которой нет в самом EIP-2612.
- **DAI**: поддерживает permit, но **несовместимый с EIP-2612**. Исходник
  https://github.com/makerdao/dss/blob/master/src/dai.sol:

  ```solidity
  function permit(address holder, address spender, uint256 nonce, uint256 expiry,
                  bool allowed, uint8 v, bytes32 r, bytes32 s) external
  ```

  Вместо `value` — булев `allowed`, вместо `deadline` — `expiry`, и nonce
  передается явно с проверкой `require(nonce == nonces[holder]++, "Dai/invalid-nonce")`.
  То есть интегратору нужна отдельная кодовая ветка под DAI.
- **USDT (mainnet)**: наличие/отсутствие `permit` в рамках этой сессии
  первичным источником не проверено — **не подтверждено**.

### 3.6. Что дает и чем платит

**Дает:**
- убирает отдельную транзакцию и газ на стороне плательщика; разрешение можно
  выдать «в одном флаконе» с первым платежом;
- deadline ограничивает срок жизни **подписи** — не разрешения, но это уже
  снижает риск лежащей где-то старой подписи;
- домен EIP-712 привязывает подпись к конкретному токену и сети.

**Платит:**
- требует поддержки **в самом токене**; для произвольного ERC-20 неприменим;
- фрагментация: DAI-подобные варианты требуют отдельного кода (см. 3.5);
- результат permit — **обычный allowance** со всеми проблемами из раздела 1:
  без периода, без лимита на платеж, до отзыва. Permit улучшает способ выдачи,
  а не природу разрешения;
- nonce строго последовательный — параллельно живущие неиспользованные подписи
  инвалидируют друг друга;
- риски из Security Considerations самого EIP: фронтраннинг отправки permit,
  «silent failure of `ecrecover`» (нужна проверка `owner != address(0)`),
  цензура подписи релеером, обычная гонка approve и риск replay при
  форке цепи, если `DOMAIN_SEPARATOR` зафиксирован иммутабельно
  (https://eips.ethereum.org/EIPS/eip-2612);
- UX-риск подписи: пользователь подписывает «просто сообщение», которое на деле
  отдает токены — классическая фишинговая приманка.

---

## 4. Permit2 (Uniswap)

Источники: https://developers.uniswap.org/contracts/permit2/overview,
исходники https://github.com/Uniswap/permit2

### 4.1. Идея и архитектура

Permit2 — отдельный **промежуточный контракт**, который работает поверх любого
существующего ERC-20, не требуя от токена ничего, кроме обычного `approve`.
Схема: пользователь один раз делает `approve` токена **в пользу Permit2**
(документация отмечает, что это значение можно выставить максимальным для
максимума удобства), а дальше все реальные разрешения приложениям выдаются уже
внутри Permit2 — подписями, с суммами и сроками.

Контракт объединяет два независимых механизма (по документации):

- **SignatureTransfer** — одноразовый перевод по подписи: «an allowance on the
  token is bypassed and permissions to the spender only last for the duration of
  the transaction». Никакого persist-разрешения не остается вовсе.
- **AllowanceTransfer** — разрешение с суммой и **сроком действия**: «Any
  transfers that then happen through the `AllowanceTransfer` contract will only
  succeed if the proper permissions have been set».

Адрес: Permit2 развернут детерминированно (CREATE2) по одному и тому же адресу
`0x000000000022D473030F116dDEE9F6B43aC78BA3` в нескольких сетях
(https://etherscan.io/address/0x000000000022d473030f116ddee9f6b43ac78ba3).
Полный официальный список сетей в рамках этой сессии по первичному источнику
не сверялся — **не подтверждено**.

### 4.2. AllowanceTransfer: структуры и семантика срока

Из https://github.com/Uniswap/permit2/blob/main/src/interfaces/IAllowanceTransfer.sol:

```solidity
struct PackedAllowance {
    uint160 amount;
    uint48 expiration;
    uint48 nonce;
}

struct PermitDetails {
    address token;
    uint160 amount;
    uint48 expiration;
    uint48 nonce;
}

struct PermitSingle {
    PermitDetails details;
    address spender;
    uint256 sigDeadline;
}
```

```solidity
function approve(address token, address spender, uint160 amount, uint48 expiration) external;
function permit(address owner, PermitSingle memory permitSingle, bytes calldata signature) external;
function transferFrom(address from, address to, uint160 amount, address token) external;
function lockdown(TokenSpenderPair[] calldata approvals) external;
function invalidateNonces(address token, address spender, uint48 newNonce) external;
```

Существенные детали, подтвержденные исходником:

- Два разных срока. `expiration` — до какого момента живет **разрешение**;
  `sigDeadline` — до какого момента действительна **подпись**. Это разные вещи,
  и в EIP-2612 второго уровня нет вовсе.
- Проверка при переводе в `AllowanceTransfer._transfer`:
  `if (block.timestamp > allowed.expiration) revert AllowanceExpired(allowed.expiration);`
  (https://github.com/Uniswap/permit2/blob/main/src/AllowanceTransfer.sol).
- Безлимит внутри Permit2 существует и тоже не вычитается:
  `if (maxAmount != type(uint160).max) { if (amount > maxAmount) { revert InsufficientAllowance(maxAmount); } else { unchecked { allowed.amount = uint160(maxAmount) - amount; } } }`
  (там же). В интерфейсе это прямо задокументировано: «Setting amount to
  `type(uint160).max` sets an unlimited approval».
- `expiration == 0` — особый случай: библиотека
  https://github.com/Uniswap/permit2/blob/main/src/libraries/Allowance.sol
  выставляет `uint48(block.timestamp)`, то есть «If the inputted expiration is
  0, the allowance only lasts the duration of the block».
- `lockdown` — массовый отзыв: для каждой пары (token, spender) выставляет
  `allowance[owner][token][spender].amount = 0`
  (https://github.com/Uniswap/permit2/blob/main/src/AllowanceTransfer.sol).
- `invalidateNonces` — инвалидация неиспользованных подписей по конкретной паре.

### 4.3. SignatureTransfer: структуры

Из https://github.com/Uniswap/permit2/blob/main/src/interfaces/ISignatureTransfer.sol:

```solidity
struct TokenPermissions { address token; uint256 amount; }
struct PermitTransferFrom { TokenPermissions permitted; uint256 nonce; uint256 deadline; }
struct SignatureTransferDetails { address to; uint256 requestedAmount; }

function permitTransferFrom(
    PermitTransferFrom memory permit,
    SignatureTransferDetails calldata transferDetails,
    address owner,
    bytes calldata signature
) external;

function permitWitnessTransferFrom(
    PermitTransferFrom memory permit,
    SignatureTransferDetails calldata transferDetails,
    address owner,
    bytes32 witness,
    string calldata witnessTypeString,
    bytes calldata signature
) external;
```

Nonce здесь **неупорядоченный** (bitmap): по документации в интерфейсе — «a
unique value for every token owner's signature to prevent signature replays»,
с «unordered nonces so that permit messages do not need to be spent in a certain
order». Это прямо снимает ограничение последовательных nonce из EIP-2612 и
позволяет держать много независимых неиспользованных подписей одновременно.

`permitWitnessTransferFrom` дает привязать к подписи произвольные
дополнительные данные (`witness`) — то есть подпись можно сделать валидной
только в рамках конкретной сделки/условий.

### 4.4. Какие пробелы EIP-2612 он закрывает

1. **Работает с любым ERC-20**, включая токены без `permit` — нужен только
   обычный `approve` в пользу Permit2 один раз.
2. **Срок жизни у самого разрешения** (`expiration`), а не только у подписи.
   В EIP-2612 выданный allowance бессрочен.
3. **Неупорядоченные nonce** — параллельные подписи не мешают друг другу.
4. **Массовый отзыв** одной транзакцией (`lockdown`), плюс `invalidateNonces`.
5. **Батчи** (PermitBatch, batched transferFrom) и witness-привязка.

### 4.5. Что дает и чем платит

**Дает:** все перечисленное в 4.4 — по сути, это ровно тот примитив «сумма +
срок + отзыв», которого не хватает базовому allowance.

**Платит:**
- **новый доверенный контракт в цепочке доверия**: пользователь дает Permit2
  (часто безлимитный) `approve` на токен, и теперь безопасность его баланса
  зависит от корректности Permit2, а не только от токена;
- рекомендуемый безлимитный `approve` в пользу Permit2 воспроизводит риск
  из раздела 2, только смещенный на другой контракт;
- сложнее интеграция: два разных механизма, две структуры сроков (`expiration`
  против `sigDeadline`), EIP-712 типы, отдельный SDK;
- разрешение все равно **не периодическое**: `expiration` — это «действует до»,
  а не «X в минуту». Ограничение частоты и суммы за период Permit2 не выражает;
- разрядность: `amount` — `uint160`, `expiration`/`nonce` — `uint48`; при
  интеграции надо следить за приведением типов;
- у Permit2 есть свой список известных нюансов в трекере, например
  https://github.com/Uniswap/permit2/issues/163 («Can set expired allowances»).

---

## 5. Делегирование: смарт-аккаунты

Это уже другой уровень: вместо «токен разрешает контракту брать» — «аккаунт
пользователя сам умеет исполнять правила».

### 5.1. ERC-4337 (аккаунт-абстракция)

Источник: https://eips.ethereum.org/EIPS/eip-4337

Компоненты:
- **UserOperation** — псевдотранзакция, описывающая действие от имени
  пользователя; логику проверки подписи задает сам аккаунт, а не протокол.
  Поля включают `sender`, `nonce`, `initCode`, `callData`,
  `verificationGasLimit`, `preVerificationGas`, `maxFeePerGas`,
  `maxPriorityFeePerGas`, `paymaster`, `signature`.
- **EntryPoint** — синглтон-контракт, исполняющий пачки UserOperation через
  `handleOps()`.
- **Bundler** — «a node (block builder) that can handle UserOperations, create a
  valid `entryPoint.handleOps()` transaction».
- **Paymaster** — «a helper contract that agrees to pay for the transaction,
  instead of the sender itself»; вызывается `validatePaymasterUserOp()`, и
  EntryPoint проверяет, что у paymaster достаточно депонированного ETH.
  Опционально есть `postOp()`.
- **Aggregator** — опциональная агрегация подписей.

Важная оговорка по источнику: **в тексте самого ERC-4337 нет упоминаний
session keys и рекуррентных/подписочных платежей**. Session keys — это паттерн
поверх 4337 (аккаунт реализует валидацию, при которой отдельный «сессионный»
ключ имеет урезанные права), а не часть стандарта. Не приписывайте его EIP.

Стандартизация этого паттерна ведется отдельными черновиками:

- **ERC-7715** (Draft) — запрос разрешений у кошелька по JSON-RPC. В текущей
  редакции метод называется `wallet_requestExecutionPermissions`
  (https://github.com/ethereum/ERCs/blob/master/ERCS/erc-7715.md); в более
  ранних редакциях и во вторичной документации фигурирует
  `wallet_grantPermissions`
  (https://docs.metamask.io/delegation-toolkit/0.12.0/experimental/erc-7715-request-permissions/)
  — при чтении статей это стоит держать в голове. Разрешение описывается
  типом, флагом `isAdjustmentAllowed` и данными; есть `ExpiryRule`, которое
  «Constrains a permission so that it is only valid until a specified
  timestamp». Мотивация прямо называет наш сценарий: текущий флоу подтверждений
  «invalidates use cases such as subscriptions, passive investments, limit
  orders, and more», а стандарт позволяет исполнять транзакции «for users
  without an active wallet connection».
  Отдельно: в спецификации **не** определены типы вида
  `erc20-recurring-allowance` — только `erc20-token-allowance` и
  `native-token-allowance` с ограничением по expiry. То есть «периодичность»
  и здесь не стандартизована.
- **ERC-7710** (Draft) — контрактная сторона: DelegationManager и
  `redeemDelegations(bytes[] _permissionContexts, bytes32[] _modes, bytes[] _executionCallData)`
  (https://github.com/ethereum/ERCs/blob/master/ERCS/erc-7710.md). Делегат
  предъявляет «the proof of authority (ie delegation) which they are executing
  on behalf of», менеджер валидирует и вызывает аккаунт делегатора. Спецификация
  признает, что «delegations can be revoked, expire, or become invalid due to
  state changes», и рекомендует всегда симулировать redemption перед отправкой.
  Требует совместимости с ERC-1271 и ERC-7579.

**Дает:** произвольные правила — лимит за период, whitelist получателя, срок
действия, отзыв; плюс paymaster может оплатить газ за пользователя (актуально
для подписки: списание не должно требовать ETH у плательщика).

**Платит:** пользователь обязан иметь **смарт-аккаунт**, а не EOA; нужна
инфраструктура (bundler, EntryPoint, paymaster) — то есть внешние сервисы;
session keys не стандартизованы, а ERC-7715/7710 в статусе Draft; резко растет
сложность и объем кода, а вместе с ним и поверхность аудита.

### 5.2. EIP-7702

Источник: https://eips.ethereum.org/EIPS/eip-7702

Новый тип транзакции, позволяющий EOA задать себе код: «Add a new EIP-2718
transaction type that allows Externally Owned Accounts (EOAs) to set the code in
their account». Заявленные цели — батчинг, спонсирование транзакций и
«privilege de-escalation» (урезанные подключи — то есть ровно основа для
session keys, теперь и для обычных EOA).

Механика: авторизационный кортеж `[chain_id, address, nonce, y_parity, r, s]`;
коду аккаунта присваивается «делегационный индикатор» вида
`0xef0100 || address`, и все исполнение идет по этому адресу. `chain_id == 0`
делает авторизацию кросс-чейн, конкретный chain_id ограничивает область.

Security Considerations, релевантные подписке:
- инициализация: логика setup «be signed by the EOA's key using `ecrecover`»,
  иначе возможен фронтраннинг инициализации;
- коллизии стоража при миграции между делегатами;
- ломаются проверки вида `require(tx.origin == msg.sender)` — «breaks atomic
  sandwich protections which rely on `tx.origin`»;
- узлам рекомендовано ограничивать число pending-транзакций от делегированных
  EOA, поскольку «it becomes impossible to know if the balance of the account
  has been swept in a static manner».

**Дает:** правила исполнения и подключи без смены адреса и без миграции
на смарт-аккаунт — самый низкотрений путь к «умному разрешению» для
существующих пользователей.

**Платит:** делегирование — это отдание кода аккаунта стороннему контракту:
одна вредоносная подпись авторизации отдает весь аккаунт целиком, а не только
один токен. Плюс кросс-чейн авторизация с `chain_id = 0`, коллизии стоража при
смене делегата и поломка допущений существующих контрактов.

### 5.3. Хуки: ERC-777 и ERC-1363

**ERC-777** (https://eips.ethereum.org/EIPS/eip-777, статус Final) вводит
операторов: `authorizeOperator()` / `revokeOperator()` дают адресу право
`operatorSend()` и `operatorBurn()` от имени держателя. По сути это **булево
разрешение вместо числового** — оператор либо может двигать токены держателя,
либо нет; суммы в разрешении нет вовсе. Плюс хуки `tokensToSend` (до изменения
балансов) и `tokensReceived` (после), обнаруживаемые через реестр ERC-1820.

Для подписки это выглядит удобно (получатель — оператор, списывает когда надо),
но цена высокая:
- оператор ничем не ограничен по сумме — это хуже безлимитного approve, потому
  что даже числа нет;
- хуки — это реентранси by design. Разбор реальной эксплуатации на Uniswap V1 с
  ERC-777-токеном imBTC:
  https://www.openzeppelin.com/news/exploiting-uniswap-from-reentrancy-to-actual-profit
  — атакующий получает управление в `tokensToSend`, когда «the exchange's ETH
  reserves were already decreased [and] the exchange's token reserves were not
  yet increased»;
- зависимость от внешнего синглтона ERC-1820;
- экосистемно стандарт отступил: OpenZeppelin пометила свою реализацию ERC-777
  как deprecated в 4.9 и удалила в 5.0
  (https://docs.openzeppelin.com/contracts/5.x/changelog,
  https://docs.openzeppelin.com/contracts/4.x/erc777). Точные формулировки
  changelog по ERC-777 дословно в рамках этой сессии не сверялись —
  **частично не подтверждено**.

**ERC-1363** (https://eips.ethereum.org/EIPS/eip-1363, статус Final) — гораздо
скромнее и безопаснее: добавляет к ERC-20 колбэк после перевода/одобрения.

```solidity
function transferAndCall(address to, uint256 value) external returns (bool);
function transferAndCall(address to, uint256 value, bytes memory data) external returns (bool);
function transferFromAndCall(address from, address to, uint256 value) external returns (bool);
function approveAndCall(address spender, uint256 value) external returns (bool);
```

Получатель реализует `onTransferReceived(address operator, address from, uint256 value, bytes memory data)`
(`ERC1363Receiver`) или `onApprovalReceived(address owner, uint256 value, bytes memory data)`
(`ERC1363Spender`). Мотивация: «There is no way to execute code after a ERC-20
transfer or approval», из-за чего нужны две транзакции; среди заявленных
сценариев прямо названы подписки.

Релевантность рекуррентным платежам: `approveAndCall` позволяет **выдать
разрешение и сразу зарегистрировать подписку одной транзакцией** — то есть это
экономия шага при **оформлении**, а не механизм периодического списания. Само
списание все равно идет через обычный `transferFrom` и обычный allowance.
Требует поддержки в токене.

---

## 6. Сводная таблица

| Подход | Что дает | Чем платит | Требует от токена | Есть срок/период? |
|---|---|---|---|---|
| `approve` + `transferFrom` | Универсально, просто, pull работает | Отдельная транзакция и газ плательщика; гонка при повторном approve; лимит без срока | Ничего (базовый ERC-20) | Нет |
| `increaseAllowance` / `decreaseAllowance` | Атомарное изменение дельты | Не стандарт; удалены из OZ v5; фишинг; `decrease` фронтранится | Нестандартное расширение | Нет |
| Безлимитный approve (`type(uint256).max`) | Одно подтверждение навсегда; дешевле по газу | Риск = весь баланс; невидимый расход; поведение при max различается между токенами | Ничего, но семантика max зависит от реализации | Нет |
| EIP-2612 `permit` | Разрешение по подписи, газ платит отправитель; deadline у подписи | Только для токенов с permit; DAI-вариант несовместим; на выходе — обычный бессрочный allowance; последовательные nonce | Поддержка `permit`, `nonces`, `DOMAIN_SEPARATOR` | Только у подписи |
| Permit2 / SignatureTransfer | Разрешения не остается вовсе — только на время транзакции | Нужен `approve` в пользу Permit2; подпись на каждый платеж; новый доверенный контракт | Ничего (любой ERC-20) | Живет только внутри транзакции |
| Permit2 / AllowanceTransfer | Сумма + `expiration` + неупорядоченные nonce + `lockdown` | Тот же доверенный контракт и обычно безлимитный approve ему; сложность интеграции | Ничего (любой ERC-20) | Да, `expiration` (до момента) |
| ERC-4337 + session keys (ERC-7715/7710) | Произвольные правила, включая лимит за период; paymaster платит газ | Нужен смарт-аккаунт и инфраструктура; стандарты в Draft; высокая сложность | Ничего | Да, задается политикой аккаунта |
| EIP-7702 | Те же возможности для обычных EOA, без смены адреса | Делегируется весь аккаунт; риск подписи авторизации; коллизии стоража | Ничего | Да, задается кодом делегата |
| ERC-777 операторы | Оператор списывает без числового лимита | Нет лимита суммы вообще; реентранси через хуки; ERC-1820; вышел из моды | Токен должен быть ERC-777 | Нет |
| ERC-1363 `approveAndCall` | Разрешение + регистрация подписки одной транзакцией | Только оформление; списание все равно через обычный allowance | Поддержка ERC-1363 | Нет |

---

## 7. Что применимо к учебной pull-модели (фиксированная сумма, период в минуту)

Условия стенда: локальный EVM, свой ERC-20, фиксированная сумма, период
одна минута, pull-модель. Отсюда вытекает следующее.

**Берем: классический `approve` + `transferFrom`.**
Это единственный вариант, который ничего не требует ни от инфраструктуры,
ни от кошелька, ни от внешних сервисов, и при этом полностью реализует
pull-модель. Плательщик один раз выдает разрешение, контракт подписки
периодически дергает `transferFrom`. Все ограничения (период, сумма, счетчик
списаний, состояние подписки) живут в контракте подписки — потому что токен,
как показано в 1.2, ничего такого не знает и знать не может ни в одном из
рассмотренных подходов, кроме session keys.

**Практические выводы, которые стоит перенести в стенд:**

1. **Разрешение — это остаток, а не расписание.** Контракт подписки обязан сам
   проверять, что с прошлого списания прошел период, и сам списывать ровно
   фиксированную сумму. Из allowance это не следует.
2. **Недостаточный allowance — штатный сценарий отказа**, а не исключение.
   Он естественным образом «заканчивается» после N списаний, и это надо
   обработать явно (как и недостаточный баланс).
3. **Не выдавать `type(uint256).max` по умолчанию.** На учебном стенде полезнее
   ограниченное разрешение: оно наглядно демонстрирует, как подписка «упирается»
   в лимит, и одновременно моделирует правильную практику. Безлимит стоит
   упомянуть как антипаттерн (раздел 2.3).
4. **Отзыв через `approve(spender, 0)`** — обязательный сценарий для
   демонстрации «отмены подписки со стороны плательщика», отдельно от отмены
   через контракт.
5. **Гонку при повторном approve на стенде воспроизводить не нужно** (локальная
   сеть, один пользователь), но при пополнении разрешения стоит осознанно
   выбрать поведение и записать выбор.
6. **Свой токен пишем предсказуемым** — прямая ERC-20 реализация с возвратом
   bool и revert при нехватке разрешения. Экзотика из weird-erc20 (комиссия
   на перевод, отсутствие возвращаемого значения, защита от гонки в контракте)
   на стенд не нужна и только замаскирует основную механику.

**Не берем и почему:**

- **EIP-2612 permit** — красиво, но добавляет EIP-712 и подписи, при этом
  результат все равно обычный allowance. Для стенда с одной минутой периода
  это чистое усложнение. Может быть интересно как отдельная позиция в списке
  нецелей.
- **Permit2** — самый близкий к задаче примитив по смыслу («сумма + срок»), но
  тянет внешний контракт по фиксированному адресу и вторую модель доверия.
  На локальном стенде это лишняя зависимость. Его главный урок для нас
  концептуальный: правильное разрешение имеет **срок**, а не только сумму.
- **ERC-4337 / EIP-7702 / session keys** — вне объема: требуют смарт-аккаунтов,
  bundler/paymaster или нового типа транзакции. Кроме того, ERC-7715/7710 в
  статусе Draft, а session keys вообще не часть ERC-4337.
- **ERC-777** — активно вреден: оператор без лимита суммы плюс реентранси
  через хуки.
- **ERC-1363 `approveAndCall`** — экономит одну транзакцию при оформлении.
  Соблазнительно, но это оптимизация UX, а не часть изучаемой механики;
  на списание она не влияет.

---

## 8. Что осталось неподтвержденным

- Точное поведение mainnet-контракта USDT при `allowance == MAX_UINT`
  (не вычитается ли остаток): подтверждено только вторичными источниками,
  исходник открыть не удалось.
- Наличие или отсутствие `permit` (EIP-2612) в mainnet-контракте USDT.
- Полный официальный список сетей, где Permit2 развернут по каноническому
  адресу.
- Дословные формулировки changelog OpenZeppelin про deprecation ERC-777
  в 4.9 и удаление в 5.0 (факт подтвержден вторичными источниками и страницей
  документации 4.x, дословная цитата changelog не сверялась).
- Дата и точные детали инцидента на 24 млн долларов с `increaseAllowance`,
  упомянутого в issue OpenZeppelin #4583 (сам факт упоминания в issue
  подтвержден, первоисточник инцидента не проверялся).
