# Блок 2. Механика разрешений ERC-20

Что дает каждый подход к «разрешить кому-то тратить мои токены» и чем за это
платит. Материал собран поиском в сети; спорные места помечены
**не подтверждено**.

Дата сбора: 25 августа 2026.

---

## Сводка

| Подход | Что подписывает пользователь | Срок жизни | Как отзывается | Главная цена |
|---|---|---|---|---|
| `approve` на точную сумму | Транзакцию | До израсходования | `approve(spender, 0)` — транзакция | Транзакция перед каждым периодом |
| Бесконечный `approve` | Транзакцию один раз | Бессрочно | `approve(spender, 0)` — транзакция | Неограниченный риск при компрометации spender |
| `permit` (EIP-2612) | Подпись EIP-712 | До `deadline`, затем allowance живет как обычно | Инкремент nonce или `approve(0)` | Токен обязан поддерживать 2612 |
| Permit2 | Подпись EIP-712 | `expiration` (uint48) | `lockdown`, `invalidateNonces`, `amount = 0` | Разовый бесконечный `approve` на сам Permit2 |
| EIP-3009 | Подпись на один конкретный перевод | Окно `validAfter`..`validBefore` | `cancelAuthorization` по nonce | Нет длящегося разрешения — подпись на каждый период |
| EIP-7702 делегирование | Авторизацию делегации | До отзыва | Делегация на нулевой адрес | Весь аккаунт под управлением стороннего кода |

---

## 1. Базовый `approve` / `transferFrom`

### Что это

Спецификация EIP-20 определяет три функции:

- `approve(address _spender, uint256 _value)` — «Allows `_spender` to withdraw
  from your account multiple times, up to the `_value` amount. If this function
  is called again it overwrites the current allowance with `_value`»
  ([EIP-20](https://eips.ethereum.org/EIPS/eip-20)).
- `allowance(address _owner, address _spender)` — «Returns the amount which
  `_spender` is still allowed to withdraw from `_owner`» (там же).
- `transferFrom(address _from, address _to, uint256 _value)` — «The function
  SHOULD throw unless the `_from` account has deliberately authorized the sender
  of the message» (там же).

Именно на этой паре строится pull-модель подписки: пользователь один раз
разрешает, контракт периодически списывает.

### Что дает

Ровно то, что нужно рекуррентному платежу: **разрешение живет между
транзакциями**. Пользователь не должен быть онлайн в момент списания.
Разрешение при этом не передает токены — они остаются в кошельке
пользователя до фактического `transferFrom`.

### Чем платит

**Race condition при изменении разрешения.** Сама спецификация предупреждает:
«clients SHOULD make sure to create user interfaces in such a way that they set
the allowance first to `0` before setting it to another value for the same
spender», и это «prevents attack vectors», но контракт не обязан требовать
такой порядок ради обратной совместимости
([EIP-20](https://eips.ethereum.org/EIPS/eip-20)).

Классический сценарий: пользователь меняет разрешение со 100 на 50, spender
видит транзакцию в мемпуле, обгоняет ее с `transferFrom` на 100 и после
подтверждения тратит еще 50 — итого 150 вместо задуманных 50
([Zokyo: ERC20 Approve Race Condition](https://zokyo-auditing-tutorials.gitbook.io/zokyo-tutorials/tutorials/tutorial-3-approvals-and-safe-approvals/vulnerability-examples/erc20-approve-race-condition-vulnerability)).

**Две транзакции.** «Current EIP-20 requires two transactions to use tokens in
contracts» — сначала approve, потом действие, и на обе нужен ETH
([EIP-2612](https://eips.ethereum.org/EIPS/eip-2612), раздел Motivation).

**Отзыв стоит газа.** Отозвать разрешение можно только транзакцией
`approve(spender, 0)`, то есть за свой газ и только будучи в состоянии
отправить транзакцию.

### `increaseAllowance` / `decreaseAllowance` — тупиковая ветка

Нестандартные функции, добавлявшиеся ради обхода race condition, были **удалены
из OpenZeppelin Contracts 5.0**. Причины: они нестандартны, дают дополнительные
векторы фишинга (задокументирован случай потери $24 млн после подписи вредоносного
`increaseAllowance`), а у `decreaseAllowance` есть собственные проблемы с
front-running
([OpenZeppelin Issue #4583](https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4583),
[PR #4585](https://github.com/OpenZeppelin/openzeppelin-contracts/pull/4585)).

Для стенда вывод простой: не изобретать вокруг `approve` дополнительных
функций, это уже пробовали.

---

## 2. Бесконечное разрешение

### Что это

`approve(spender, type(uint256).max)`. Ровно та же функция, просто значение
такое, что вычитание при `transferFrom` практически никогда не исчерпает лимит.

Это до сих пор рабочая практика: например, реализация рекуррентных платежей,
где «an unlimited allowance (2^256-1) is approved to the subscription contract
address, which periodically allows the payee to call a timelocked proxy of
ERC-20's `transferFrom()` method»
([Jon-Becker/ethereum-recurring-payments](https://github.com/Jon-Becker/ethereum-recurring-payments)).

### Что дает

Один `approve` — и подписка работает бесконечно. Нет повторных транзакций
на продление, нет «платеж не прошел, потому что разрешение кончилось».
Для UX это самое дешевое решение.

### Чем платит

Весь баланс кошелька по этому токену становится заложником одного контракта.
«Over-permissioned or infinite allowances can pose a risk if the spender
contract is compromised or malicious», и в реальных атаках неполная валидация
входных данных позволяла опустошать кошельки с бесконечными approve
([Utila: Understanding Token Approvals](https://utila.io/blog/understanding-token-approvals-on-evm-tron)).

Практика провайдеров это подтверждает: Loop Crypto вместо бесконечного лимита
предлагает по умолчанию **13-кратную сумму месячной подписки** — первый платеж
плюс год
([Loop Crypto Docs: Checkout widget](https://loop-crypto.gitbook.io/old-loop-crypto/technical-docs/archeticture/collecting-authorization/checkout-widget)).

Это готовый ответ на вопрос «какой размер разрешения разумен для подписки»:
не бесконечность, а N периодов вперед.

---

## 3. `permit` (EIP-2612)

### Что это

Расширение ERC-20: функция, меняющая allowance по подписанному сообщению,
а не по `msg.sender`.

```solidity
function permit(address owner, address spender, uint value,
                uint deadline, uint8 v, bytes32 r, bytes32 s) external;
function nonces(address owner) external view returns (uint);
function DOMAIN_SEPARATOR() external view returns (bytes32);
```
([EIP-2612](https://eips.ethereum.org/EIPS/eip-2612))

Подписываемая EIP-712 структура: `owner`, `spender`, `value`, `nonce`,
`deadline` плюс домен (имя, версия, chainId, адрес контракта). `nonce`
инкрементируется при каждом успешном `permit` и защищает от повтора подписи;
`deadline` — блокчейн-время, после которого транзакция откатывается (там же).

### Что дает

- Убирает вторую транзакцию: approve и действие складываются в одну.
- Пользователю **не нужен ETH**, чтобы выдать разрешение: цель стандарта —
  «ability to interact with Ethereum without holding any ETH» (там же).
- Газ за подачу `permit` платит тот, кто отправляет транзакцию, — то есть
  разрешение можно собрать «бесплатно» для пользователя.

### Чем платит

- **Токен должен поддерживать стандарт.** Это свойство токена, а не кошелька.
  Для произвольного ERC-20 permit недоступен.
- **Race condition никуда не делся**: раздел Security Considerations прямо
  указывает, что «the standard EIP-20 approve race condition remains
  applicable» (там же).
- **Front-running**: третья сторона может исполнить permit раньше
  предполагаемого получателя подписи (там же).
- **Цензура релеера**: тот, кому отдали подпись, может ее просто не отправить
  (там же).
- **Риск при форке цепи**, если `DOMAIN_SEPARATOR` зафиксирован на момент
  деплоя, а не пересчитывается по актуальному `chainId` (там же).

Важно для нашей темы: permit **не решает рекуррентность**. Он делает выдачу
разрешения дешевле и удобнее, но само разрешение остается обычным allowance
со всеми его свойствами.

---

## 4. Permit2

### Что это

Отдельный контракт-посредник Uniswap, объединяющий два механизма:
SignatureTransfer и AllowanceTransfer
([Uniswap/permit2](https://github.com/Uniswap/permit2)).

**AllowanceTransfer** хранит разрешение с явным сроком:

```solidity
struct PermitDetails {
    address token;
    uint160 amount;
    uint48 expiration;
    uint48 nonce;
}
```
([IAllowanceTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/interfaces/IAllowanceTransfer.sol))

- `amount` (uint160) — максимальная сумма; «Setting amount to
  `type(uint160).max` sets an unlimited approval» (там же).
- `expiration` (uint48) — «timestamp at which a spender's token allowances
  become invalid»; передача `0` в `approve` обнуляет срок до `block.timestamp`,
  то есть делает разрешение недействительным немедленно
  ([Uniswap Docs: AllowanceTransfer](https://developers.uniswap.org/contracts/permit2/reference/allowance-transfer)).
- `nonce` (uint48) — «an incrementing value indexed per owner, token, and
  spender» (там же).

**SignatureTransfer** вообще обходит хранимое разрешение: «an allowance on the
token is bypassed and permissions to the spender only last for the duration of
the transaction that the one-time signature is spent»
([Uniswap/permit2 README](https://github.com/Uniswap/permit2/blob/main/README.md)).

### Что дает

- **Работает с любым ERC-20**, даже без поддержки EIP-2612 (там же). Это
  главное отличие от permit: Permit2 переносит логику из токена в контракт.
- **Разрешение со сроком годности** — прямой ответ на проблему «висящих»
  бесконечных approve.
- **Батчинг**: одна подпись на несколько токенов и спендеров (там же).
- **Массовый отзыв**: `lockdown(TokenSpenderPair[] calldata approvals)` —
  «batch revoking approvals»
  ([IAllowanceTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/interfaces/IAllowanceTransfer.sol)).
- **Инвалидация подписей**: `invalidateNonces(address token, address spender,
  uint48 newNonce)` — «Invalidates all nonces less than it», не более 2^16
  за одну транзакцию (там же).
- **Non-monotonic replay protection**: подписи можно исполнять в произвольном
  порядке
  ([README](https://github.com/Uniswap/permit2/blob/main/README.md)).

### Чем платит

Главный компромисс: **чтобы пользоваться Permit2, надо один раз сделать обычный
(как правило, бесконечный) `approve` на сам контракт Permit2**
(там же). То есть риск не исчезает, а концентрируется: вместо N разрешений
разным контрактам — одно разрешение одному сильно используемому контракту,
поверх которого уже действуют ограниченные по сумме и сроку права.

Плюс интеграционные издержки: README указывает необходимость компиляции
`viaIR` при интеграции (там же).

---

## 5. EIP-3009: перевод по авторизации

### Что это

Не разрешение, а **подписанный конкретный перевод**:

```solidity
function transferWithAuthorization(address from, address to, uint256 value,
    uint256 validAfter, uint256 validBefore, bytes32 nonce,
    uint8 v, bytes32 r, bytes32 s);
function receiveWithAuthorization(...);
function cancelAuthorization(address authorizer, bytes32 nonce,
    uint8 v, bytes32 r, bytes32 s); // optional
```
([EIP-3009](https://eips.ethereum.org/EIPS/eip-3009))

`nonce` — случайные 32 байта, а не последовательный счетчик; это сделано,
чтобы можно было создавать авторизации параллельно, без зависимости от порядка:
при последовательных nonce «transactions with too-high values revert immediately
rather than staying pending» (там же).

Стандарт нативно реализован в USDC
([Circle: Four ways to authorize USDC](https://www.circle.com/blog/four-ways-to-authorize-usdc-smart-contract-interactions-with-circle-sdk)).

### Что дает

- **Нет длящегося разрешения вообще.** Каждая подпись — ровно один перевод
  конкретному получателю на конкретную сумму в конкретном временном окне.
- **Газ платит получатель**: «The customer signs a `transferWithAuthorization`
  message; the merchant's relayer submits it on-chain, paying gas. The customer
  never holds ETH and never pays gas»
  ([Eco: EIP-3009 Authorization Transfer for Stablecoins](https://eco.com/support/en/articles/14796369-eip-3009-authorization-transfer-for-stablecoins)).
- **Отзыв без гонки**: `cancelAuthorization` гасит конкретный nonce
  ([EIP-3009](https://eips.ethereum.org/EIPS/eip-3009)).
- **Защита от front-running**: «Use `receiveWithAuthorization` instead of
  `transferWithAuthorization` when calling from other contracts» — проверка
  получателя не дает злоумышленнику вытащить подпись из мемпула и исполнить
  ее вне задуманной обертки (там же).

### Чем платит

Для рекуррентного платежа это **шаг назад по автономности**: подпись на каждый
период надо получить заранее. Либо пользователь подписывает пачку авторизаций
на год вперед (что превращается в аналог расписания и требует их хранения
у получателя), либо каждый период требует участия пользователя.

Именно поэтому EIP-3009 хорош «for checkout or payment flows where you want
gasless user experience without persistent allowances»
([Eco](https://eco.com/support/en/articles/14796369-eip-3009-authorization-transfer-for-stablecoins)),
а не для подписки в чистом виде.

---

## 6. Делегирование аккаунта (EIP-7702)

### Что это

С хардфорка Pectra (7 мая 2025) EOA может делегировать исполнение смарт-контракту:
в состояние аккаунта записывается 23-байтный указатель делегации — префикс
`0xef0100` плюс 20-байтный адрес реализации, и EVM исполняет вызовы к EOA так,
как если бы это были вызовы к этому контракту
([Eco: EIP-7702 Explained](https://eco.com/support/en/articles/14796249-eip-7702-explained-account-abstraction-for-eoas),
[EIP-7702](https://eips.ethereum.org/EIPS/eip-7702)).

Технически это новый тип транзакции `0x04` (SET_CODE_TX_TYPE), в котором
владелец EOA подписывает авторизацию с chainId, nonce и адресом делегата
([OpenZeppelin Docs: EOA Delegation](https://docs.openzeppelin.com/contracts/5.x/eoa-delegation)).

### Что дает

Для подписок важны три вещи из списка возможностей:

- **Batching**: несколько операций (например, approve + transfer) в одной
  транзакции (там же).
- **Session keys**: «privilege de-escalation with limited permissions» — ключ
  с ограниченными правами, что концептуально ближе всего к «разрешению на
  списание N раз по M токенов» (там же).
- **Sponsorship**: газ может оплатить третья сторона через paymaster ERC-4337
  (там же).

EIP-7702 дополняет ERC-4337, а не заменяет его: «7702 upgrades the account,
4337 standardizes how that account interacts with bundlers and paymasters»
([Eco](https://eco.com/support/en/articles/14796249-eip-7702-explained-account-abstraction-for-eoas)).

### Чем платит

**Радикально больший радиус поражения.** OpenZeppelin формулирует прямо: плохо
написанный контракт-делегат позволяет «a malicious actor to take near complete
control over a signer's EOA»
([OpenZeppelin Docs: EOA Delegation](https://docs.openzeppelin.com/contracts/5.x/eoa-delegation)).
Возможны коллизии хранилища — требуется namespaced storage по ERC-7201 (там же).

**Отзыв делегации** — отдельная транзакция SET_CODE_TX_TYPE с авторизацией на
нулевой адрес: это «will clear the account's code and reset its code hash to
the empty hash», но storage при этом автоматически не очищается (там же).

Насколько 7702 фактически используется провайдерами подписок на момент сбора
материала — **не подтверждено**, надежного источника не нашлось.

---

## Как это ложится на стенд

Стенд использует базовый `approve` + `transferFrom`, и это осознанный выбор:
все остальные подходы либо требуют свойств от токена (permit, 3009), либо
добавляют внешний контракт (Permit2), либо меняют модель аккаунта (7702).

Что из блока стоит держать в голове при реализации:

1. **Не делать бесконечное разрешение по умолчанию.** Разумный дефолт —
   N периодов вперед, как у Loop (13 периодов для месячной подписки).
2. **Разрешение исчерпаемо.** Если `approve` был на N периодов, на N+1-м
   списание не пройдет — это не сбой, а штатное завершение. См. блок 4.
3. **Отзыв односторонний и мгновенный.** Контракт не может ему помешать
   и узнает о нем только в момент неудачного `transferFrom`.
4. **Порядок «сначала в ноль, потом в новое значение»** при смене разрешения —
   рекомендация самой спецификации, ее стоит воспроизвести во фронте хотя бы
   как иллюстрацию.

---

## Источники

- [EIP-20: Token Standard](https://eips.ethereum.org/EIPS/eip-20)
- [EIP-2612: Permit Extension for EIP-20 Signed Approvals](https://eips.ethereum.org/EIPS/eip-2612)
- [EIP-3009: Transfer With Authorization](https://eips.ethereum.org/EIPS/eip-3009)
- [EIP-7702: Set Code for EOAs](https://eips.ethereum.org/EIPS/eip-7702)
- [Uniswap/permit2 (README)](https://github.com/Uniswap/permit2/blob/main/README.md)
- [Uniswap/permit2: IAllowanceTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/interfaces/IAllowanceTransfer.sol)
- [Uniswap Docs: Permit2 AllowanceTransfer](https://developers.uniswap.org/contracts/permit2/reference/allowance-transfer)
- [Uniswap Docs: Permit2 SignatureTransfer](https://docs.uniswap.org/contracts/permit2/reference/signature-transfer)
- [OpenZeppelin Docs: EOA Delegation](https://docs.openzeppelin.com/contracts/5.x/eoa-delegation)
- [OpenZeppelin Issue #4583: Discussion to remove increaseAllowance/decreaseAllowance](https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4583)
- [OpenZeppelin PR #4585](https://github.com/OpenZeppelin/openzeppelin-contracts/pull/4585)
- [Zokyo: ERC20 Approve Race Condition Vulnerability](https://zokyo-auditing-tutorials.gitbook.io/zokyo-tutorials/tutorials/tutorial-3-approvals-and-safe-approvals/vulnerability-examples/erc20-approve-race-condition-vulnerability)
- [Utila: Understanding Token Approvals on EVM and Tron](https://utila.io/blog/understanding-token-approvals-on-evm-tron)
- [Eco: EIP-3009 Authorization Transfer for Stablecoins](https://eco.com/support/en/articles/14796369-eip-3009-authorization-transfer-for-stablecoins)
- [Eco: EIP-7702 Explained](https://eco.com/support/en/articles/14796249-eip-7702-explained-account-abstraction-for-eoas)
- [Circle: Four Ways to Authorize USDC Smart Contract Interactions](https://www.circle.com/blog/four-ways-to-authorize-usdc-smart-contract-interactions-with-circle-sdk)
- [Loop Crypto Docs: Checkout widget](https://loop-crypto.gitbook.io/old-loop-crypto/technical-docs/archeticture/collecting-authorization/checkout-widget)
- [Jon-Becker/ethereum-recurring-payments](https://github.com/Jon-Becker/ethereum-recurring-payments)
