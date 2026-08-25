# Сбойные сценарии рекуррентных платежей на цепочке

Исследовательская записка. Задача — собрать, какие бывают сбои у ончейн-подписок
и как их обрабатывают существующие протоколы, чтобы понимать, чего ждать от
простой pull-модели через `approve` + `transferFrom` с периодом в одну минуту.

## Как читать документ

- Каждый содержательный тезис снабжен ссылкой на источник прямо в тексте.
- Там, где надежного источника не нашлось, стоит явная пометка
  **не подтверждено**. Это не «скорее всего так» — это «в документации не найдено».
- Данные синтетические, реальных адресов, ключей и сумм из живых сервисов здесь нет.
- Оговорка по Loop Crypto: страницы `docs.loopcrypto.xyz/*` не открылись напрямую
  (соединение обрывалось), поэтому их содержимое приведено по цитатам из поисковой
  выдачи по этим же URL. Страницы старой документации на GitBook
  (`loop-crypto.gitbook.io`) открылись нормально и цитируются напрямую.

## Ноль: две разные модели, у них разные сбои

Прежде чем разбирать сбои, стоит разделить решения на два класса — иначе сравнение
не работает.

**Pull-модель по периодам** (Loop Crypto, Spritz, Unlock Protocol, Suberra,
Request Network, ERC-1337). Плательщик выдает разрешение (`approve` или подпись
EIP-2612/EIP-3009), дальше кто-то — сервис, продавец, релеер — в нужный момент
дергает списание. Платеж дискретный: он либо прошел, либо не прошел. Ровно эта
модель у нашего стенда.

**Стриминг** (Superfluid, Sablier). Нет «периодов» и нет «списаний» — есть
непрерывно меняющийся баланс. Сбой здесь не «платеж не прошел», а «поток стал
неплатежеспособным». Термины `buffer`, `liquidation`, `sentinel`, `uncovered debt`
живут только тут.

Из-за этого одни и те же слова («отмена», «пропуск», «возврат») означают в двух
классах разное, и таблица в конце разносит их по колонкам.

---

## 1. Отозванное или уменьшенное разрешение

### Что происходит технически

Отзыв разрешения — это обычная транзакция, которая ставит allowance в ноль:
«Revoking a token approval sends a new transaction that changes that allowance to
zero, so the contract can no longer move that token for future actions»
(https://revoke.cash/learn/approvals/how-to-revoke-token-approvals). Там же
отмечено, что allowance можно не обнулять, а уменьшить до другого значения.

Важное следствие, которое там же сформулировано прямо: «Revoking an approval stops
future spending only. It does not recover tokens that already left your wallet»
(https://revoke.cash/learn/approvals/how-to-revoke-token-approvals). То есть отзыв
действует только вперед, уже списанное не возвращается.

Отдельная тонкость самого `approve` — состояние гонки при изменении ненулевого
allowance на другое ненулевое: спендер может успеть потратить старое значение до
того, как новое вступит в силу, и суммарно потратить X + Y. Проблема известна с
EIP-20; типовые смягчения — сначала обнулить, потом выставить нужное, либо
пользоваться `increaseAllowance`/`decreaseAllowance`
(https://zokyo-auditing-tutorials.gitbook.io/zokyo-tutorials/tutorials/tutorial-3-approvals-and-safe-approvals/vulnerability-examples/erc20-approve-race-condition-vulnerability,
https://docs.openzeppelin.com/contracts/3.x/api/token/erc20, http://swcregistry.io/docs/SWC-114/).
Для подписки это значит: момент «плательщик меняет лимит» — сам по себе окно, в
котором поведение зависит от порядка транзакций.

### Что видит плательщик

В Loop Crypto отзыв разрешения — штатное и полностью пользовательское действие:
«You can revoke the allowance in your wallet at any time or on the Loop Crypto
Portal through any block explorer or platform such as revoke.cash. When an
allowance is revoked, it would prevent future payments from being processed»
(https://docs.loopcrypto.xyz/docs/welcome). Дальше плательщик получает письмо
«Missed Payment» через 5 минут после наступления срока платежа с указанием
причины — низкий баланс или низкая авторизация — и ссылкой на портал, где лимит
можно поднять (https://docs.loopcrypto.xyz/docs/renewal-payments-copy).

Loop также шлет предупреждения заранее: письмо в воскресенье перед списанием с
указанием, хватает ли средств и allowance, и повторные напоминания за 48 и 24 часа,
если средств не хватает (https://loop-crypto.gitbook.io/old-loop-crypto/integrations/stripe-+-loop/faqs-about-stripe-integration).

### Что видит получатель

Ничего не приходит, и на цепочке не появляется события об оплате. В терминах Loop
Crypto: «The `TransferProcessed` event would not occur if the wallet does not have
enough balance to cover the payment or does not have enough token allowance to
cover the payment» (https://docs.loopcrypto.xyz/docs/welcome). То есть отсутствие
события — и есть весь сигнал; отдельного ончейн-события «платеж не удался» нет.

Продавец может проверить состояние заранее: Loop дает возможность «query the
payment method's status before charging it, allowing you to troubleshoot payment
issues before they occur» (https://docs.loopcrypto.xyz/docs/welcome). Это важная
архитектурная идея: в pull-модели проверка «хватит ли allowance и баланса» —
отдельная операция чтения до попытки списания, а не результат неудачной транзакции.

В интеграции со Stripe поведение описано так: «If a customer lacks sufficient funds
or allowance, the transaction will simply not be processed», а счет остается
открытым, пока плательщик не поднимет лимит или не пополнит кошелек
(https://loop-crypto.gitbook.io/old-loop-crypto/integrations/stripe-+-loop/faqs-about-stripe-integration).

### Как это обрабатывают конкретные протоколы

- **ERC-1337 / ERC-948.** Отзыв allowance изначально заявлен как штатный способ
  «выйти» из подписки: пользователь заранее одобряет контракт подписки и может
  отозвать разрешение в любой момент, поставив подписку на паузу или отменив ее,
  не трогая исходную мета-транзакцию (https://eips.ethereum.org/EIPS/eip-1337,
  https://github.com/ethereum/EIPs/issues/948). При этом сам текст EIP-1337 не
  описывает, что должно происходить с расписанием при отозванном allowance или
  нехватке баланса — только что «a failed execution will still pay the issuer of
  the transaction for their gas costs» (https://eips.ethereum.org/EIPS/eip-1337).
- **Unlock Protocol.** Автопродление через `renewMembershipFor` работает только
  для ERC-20-локов, где владелец выдал достаточный allowance: «this function can
  only be called for ERC20 locks where the owner has approved the renewals through
  an ERC20 approval» (https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/).
  Полезная деталь для диагностики: есть view-функция `isRenewable`, которая
  «reverts with an explanation about why a given membership cannot be renewed if it
  is indeed not renewable» — то есть протокол отдельно продумал читаемую причину
  отказа (там же).
- **Superfluid.** Прямого аналога `approve` для собственных потоков нет: поток
  открывает сам отправитель. Но у ACL-слоя есть похожая сущность — оператор
  получает разрешения create/update/delete и `flow rate allowance`, и владелец
  может выдать или отозвать их в любой момент
  (https://github.com/superfluid-finance/docs/blob/main/developers/constant-flow-agreement-cfa/cfa-access-control-list-acl/README.md).
- **Permit2** (не подписочный протокол, но релевантный дизайн разрешений). Здесь
  allowance — это тройка «сумма + срок + nonce»: `PermitDetails` содержит
  `uint160 amount` и `uint48 expiration` — «a timestamp at which a spender's token
  allowances become invalid», плюс инкрементный nonce для защиты от повтора
  (https://developers.uniswap.org/docs/protocols/permit2/concepts/allowance-transfer,
  https://github.com/Uniswap/permit2/blob/main/src/interfaces/IAllowanceTransfer.sol).
  Отзыв делается пакетно функцией `lockdown` по массиву пар «токен-спендер», а
  `invalidateNonces` обнуляет подписи. Отдельно подчеркнуто, что истекший allowance
  не нужно отзывать транзакцией — он просто перестает действовать. Для подписок это
  ровно та штука, которой не хватает голому `approve`: у разрешения нет срока
  годности, и висящий бесконечный allowance — норма, а не исключение.

### Чего ждать в простой pull-модели

Отзыв allowance неотличим от «плательщик передумал»: транзакция списания
откатится на `transferFrom` (или ее вообще не станут отправлять после проверки
`allowance()`), никакого уведомления контракт получателя не получит, а состояние
подписки придется менять отдельным действием. Единственное, что можно сделать
честно, — читать `allowance()` перед попыткой и отражать это в статусе.

---

## 2. Нехватка баланса в момент списания

### Pull-модель: просто отказ

В дискретной модели нехватка баланса и нехватка allowance неразличимы по эффекту:
списание не проходит. Loop Crypto объединяет их в одну причину отказа — нет ни
события `TransferProcessed`, ни платежа
(https://docs.loopcrypto.xyz/docs/welcome). Дальше все решает уровень сервиса,
а не цепочка: Loop мониторит allowance и баланс в течение периода повторов, и если
за это время средств стало достаточно — платеж проходит
(https://docs.loopcrypto.xyz/docs/renewal-payments-copy).

Spritz в модели SMARTPay работает иначе и жестче: плательщик заранее одобряет сумму
на несколько платежей вперед, «you pre-approve an amount that represents a number
of transactions in advance, and smart contracts will deduct only the correct amount
on the correct date each month», но обязан держать нужную сумму на счете каждый
месяц, и «if the payment fails, you'll have to manually set it up again»
(https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments).
То есть у Spritz одна неудача убивает всю серию — восстановление ручное.

Suberra перед попыткой списания проверяет баланс на цепочке: «Suberra's smart
payment retries first check if the user has sufficient token balance on-chain before
attempting a charge»
(https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/). Опять
тот же прием — читать состояние до отправки транзакции, чтобы не платить газ за
заведомо неудачную попытку.

### Superfluid: ликвидация потока, buffer/deposit, sentinels

Это самый проработанный публично описанный механизм обработки «кончились деньги»,
поэтому разбираю подробно.

**Buffer (deposit).** При открытии потока протокол блокирует у отправителя
залог — «tokens locked temporarily when a stream starts»
(https://docs.superfluid.org/docs/concepts/glossary). Размер — четыре часа потока
на большинстве основных сетей и один час на тестовых
(https://help.superfluid.finance/en/articles/5744874-how-do-stream-buffers-work-in-superfluid).
Смысл залога — экономический стимул закрыть поток самому, до того как баланс
обнулится.

**Critical.** Когда баланс отправителя доходит до нуля, аккаунт становится
критическим. С этого момента «the permissions on the stream now allow anyone to
close it», а получателю продолжают идти деньги — уже из залога
(https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga).

**Insolvent.** Если поток так и не закрыли и залог исчерпан, начинается
неплатежеспособный период: «the stream will continue to the receiver, however since
these tokens don't actually exist in the sender's wallet, we must keep track of this
`deficit` so that the Super Token itself can remain solvent within the Superfluid
Protocol» (там же). Это ключевая деталь: получателю продолжает капать, а протокол
ведет учет дефицита.

**«3P» — кому достается залог.** Критический период делится на подпериоды
(https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga):

- *Patrician period* (по документации — 30 минут): закрыть поток и забрать остаток
  залога может только PIC (Patrician In Charge).
- *Plebs period*: до наступления неплатежеспособности закрыть поток и забрать
  остаток залога может кто угодно.
- *Pirate period*: уже в неплатежеспособности; тому, кто закроет поток, выплачивают
  награду в размере залога, и она берется из слэшинга стейка PIC.

**TOGA** (Transparent OnGoing Auction) — механизм, которым определяется PIC:
претендент вносит стейк в самом токене, и «if the new `stake` is higher than the
existing `stake`, the new Patrician becomes the PIC»; забрать стейк можно только
потоком с заданным `exitRate` и минимальным периодом выхода в одну неделю (там же).

**Sentinels** — узлы, которые все это исполняют: «a node monitoring the Superfluid
network and closing critical or insolvent streams. Anyone can run a sentinel node»
(https://docs.superfluid.org/docs/concepts/glossary,
https://github.com/superfluid-org/superfluid-sentinel).

**Что видит плательщик.** Залог потерян безвозвратно. Документация формулирует это
как прямое предупреждение: «You must always cancel your streams before your Super
Token balance hits zero or your buffer will be lost», и при ликвидации в истории
активности появляется соответствующее уведомление без возможности вернуть залог
(https://help.superfluid.finance/en/articles/5744874-how-do-stream-buffers-work-in-superfluid).

**Что видит получатель.** До момента фактического закрытия потока деньги
продолжают поступать — сначала из залога, потом «в долг» протоколу. После закрытия
поток просто прекращается. Отдельного описания того, что показывают получателю в
интерфейсе в момент ликвидации, в найденной документации нет — **не подтверждено**.

**Смягчение.** У Superfluid есть Auto-Wrap: автоматическое заворачивание обычных
ERC-20 в Super Token «just-in-time», чтобы потоки не встали. Но и там оговорка —
нужно самому следить, чтобы базового токена хватало, иначе ликвидация все равно
случится (https://docs.superfluid.org/docs/protocol/advanced-topics/automations/stream-scheduler,
https://superfluid.org/post/streamline-your-web3-apps-with-superfluid-automations).

### Sablier: долг вместо ликвидации

Sablier Flow решает ту же проблему принципиально иначе — без залога и без
ликвидаторов. Поток задается ставкой в секунду, и суммарный долг растет как
`rps × время`; если на балансе потока не хватает средств, разница становится
**uncovered debt** — тем, что отправитель должен потоку
(https://docs.sablier.com/concepts/flow/overview). То есть поток не «ломается», он
уходит в минус, и отправитель обязан пополниться.

### Чего ждать в простой pull-модели

Ни залога, ни долга, ни ликвидаторов у нас нет. Нехватка баланса = откат
`transferFrom`. Все, что можно позаимствовать, — идея проверки состояния до попытки
(как у Loop и Suberra) и идея явного различения причин отказа в интерфейсе
(«не хватает баланса» против «не хватает разрешения»), даже если на цепочке они
дают один и тот же результат.

---

## 3. Пропущенные периоды: долг, «задним числом», grace period

### Есть ли окно и что в нем происходит

**Loop Crypto** — самый конкретный публично описанный grace period в
pull-подписках: «By default, Loop will attempt to collect payment for 7 days past
the due date, and after 7 days of attempting, Loop will cancel the subscription in
Loop and in Stripe and set the due invoice to uncollectable»; продавец может
переопределить эти 7 дней (https://docs.loopcrypto.xyz/docs/renewal-payments-copy).
Внутри окна Loop продолжает следить за allowance и балансом, и как только их
хватает — платеж проходит (там же). То есть списание «задним числом» возможно, но
только внутри окна и только за текущий незакрытый счет.

**Suberra**: «By default, we configure a 7 days grace period for each monthly
product subscription», внутри окна доступ к продукту сохраняется, а система часто
повторяет попытки; если grace period не настроен — продукт просто приостанавливают
(https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/).

**Request Network**: при неудаче расписание не отменяется, а ставится на паузу —
«if a payment fails (for example due to insufficient funds), the schedule is paused,
and you can unpause it once the issue is resolved», и после снятия паузы подписка
может «догнать» пропущенные платежи
(https://docs.request.network/request-network-api/recurring-payments). Это прямой
пример накопления долга на уровне сервиса. Точный алгоритм догона (сколько
пропущенных периодов списывается и одной ли транзакцией) в документации не
раскрыт — **не подтверждено**.

**Unlock Protocol**: механика пропуска встроена в саму модель. Членство — это NFT
со сроком истечения, а `renewMembershipFor` можно вызвать только на уже истекшем
ключе, и вызвать его может кто угодно, если у владельца хватает allowance:
«anyone can call this function on an expired membership NFT, provided that the
current owner of said NFT has approved a large enough amount of ERC20 to be spent
for the renewal to succeed» (https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/).
То есть «долг» не копится — просто истекает доступ, и продление продлевает срок с
момента продления. Отдельное ограничение: продление сработает только если цена и
длительность лока не менялись с момента покупки, иначе все существующие членства,
которые продлились бы, начнут падать
(https://docs.unlock-protocol.com/move-to-guides/recurring-memberships).

**Spritz**: пропуск фактически завершает серию — после неудачи подписку надо
создавать заново вручную (https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments).

**Sablier Flow** — единственный из разобранных, где пропуск буквально превращается
в ончейн-долг: незакрытая часть становится uncovered debt, отправитель может
пополнить поток позже, и получатель заберет накопленное
(https://docs.sablier.com/concepts/flow/overview). Пауза при этом не стирает уже
накопленные обязательства: «a sender may pause streams and restart them later
without losing accrued obligations» (там же).

**Superfluid**: понятие «пропущенный период» отсутствует по построению — баланс
меняется каждую секунду, пропускать нечего. Аналог пропуска — уход в
неплатежеспособность и накопление дефицита (см. раздел 2).

### Несколько пропусков подряд

Тут документация небогата. Что удалось подтвердить:

- Loop: несколько неудачных попыток внутри окна — это все еще один незакрытый счет;
  по истечении окна подписка отменяется, а счет помечается как безнадежный
  (https://docs.loopcrypto.xyz/docs/renewal-payments-copy).
- Suberra: повторы «часто» внутри grace period, конкретной сетки интервалов в
  документации нет — точное расписание повторов **не подтверждено**
  (https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/).
- Request Network: расписание на паузе, платежи не идут, пока не снимут паузу
  (https://docs.request.network/request-network-api/recurring-payments).

Поведение «списать сразу за три пропущенных периода одной транзакцией» ни в одной
из просмотренных документаций явно не описано — **не подтверждено**. Косвенно это
понятно: такое поведение сложно отличить от двойного списания и оно неприятно для
плательщика.

### Чего ждать в простой pull-модели

Если контракт хранит «время последнего платежа» и разрешает списание при
`now >= last + period`, то после N пропущенных минут возможны ровно два
разумных дизайна, и выбрать надо явно:

1. **Долг копится**: разрешаем N списаний подряд (или одно списание на N×цена).
   Плательщик может неожиданно потерять много денег после того, как пополнит счет.
2. **Долг не копится**: сдвигаем `last` к текущему моменту, списываем один период.
   Получатель теряет деньги за простой.

Обе стратегии встречаются в реальных решениях (Request Network «догоняет», Unlock
просто продлевает от момента продления), так что для учебного стенда это хороший
предмет демонстрации.

---

## 4. Отмена подписки

### Кто может отменить

**Sablier Lockup**: отменяет только отправитель. В справочнике по контракту прямо:
для `cancel` — «msg.sender must be the stream's sender», поток должен быть
`warm and cancelable`
(https://docs.sablier.com/reference/lockup/contracts/contract.SablierLockup).
Концептуальная страница подтверждает: «Only the stream creator can cancel a stream.
Recipients do not have the ability to cancel a stream»
(https://docs.sablier.com/concepts/cancelability).

Расхождение в источниках: в FAQ Sablier на вопрос об отмене отвечено «Yes, both as
a sender and a recipient» (https://docs.sablier.com/support/faq). Скорее всего это
относится к другому продукту (Flow) или к другой формулировке вопроса, но
**однозначно не подтверждено**; в качестве нормативного источника по Lockup стоит
брать справочник по контракту.

**Sablier Flow**: отмены как таковой нет, есть `pause` (ставка в секунду
обнуляется, поток можно возобновить) и `void` (поток останавливается навсегда).
Ключевое отличие void от pause — «it also sets the stream's uncovered debt to zero»
(https://docs.sablier.com/guides/flow/examples/stream-management), то есть
непокрытый долг при void просто прощается
(https://docs.sablier.com/concepts/flow/overview).

**Superfluid**: поток закрывает `deleteFlow`, вызвать может сам отправитель, либо
оператор, которому выдано разрешение на удаление через ACL
(https://github.com/superfluid-finance/docs/blob/main/developers/constant-flow-agreement-cfa/cfa-access-control-list-acl/README.md,
https://docs.superfluid.org/docs/protocol/money-streaming/guides/create-update-delete-flow).
Плюс особый случай: как только аккаунт стал критическим, закрыть поток может кто
угодно (https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga).

**Loop Crypto**: отменить может и продавец через дашборд, и сам плательщик через
портал; продавцу прилетает вебхук `AgreementCancelled`
(https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions).

**Request Network**: отмена через API (PATCH), останавливает все будущие платежи
(https://docs.request.network/request-network-api/recurring-payments).

**ERC-1337**: пользователь меняет статус подписки через `modifyStatus()` —
предусмотрены статусы ACTIVE, PAUSED, CANCELLED, EXPIRED
(https://eips.ethereum.org/EIPS/eip-1337).

### С какого момента действует и что с начатым периодом

Это самое интересное место, и ответы расходятся.

**Loop Crypto**: «When a subscription is canceled, all future scheduled invoices
will be cancelled but any currently due invoices will not be»
(https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions).
То есть уже выставленный счет остается к оплате. В связке со Stripe при отмене
через Loop подписка переводится в «cancel at the end of period», чтобы плательщик
дожил оплаченный период до конца (https://docs.loopcrypto.xyz/docs/renewal-payments-copy);
при этом Stripe отменяет только будущие и черновые счета, а просроченные продавцу
надо гасить вручную (https://loop-crypto.gitbook.io/old-loop-crypto/integrations/stripe-+-loop/faqs-about-stripe-integration).

**Sablier Lockup**: отмена срабатывает немедленно, уже «протекшая» часть остается
за получателем и невозвратна, непротекшая возвращается отправителю
(https://docs.sablier.com/concepts/cancelability). Важная деталь для UI: уже
начисленное не переводится автоматически — «the portion that has already been
streamed is NOT automatically transferred - the recipient will need to withdraw it»
(https://docs.sablier.com/guides/lockup/examples/stream-management/cancel).

**Unlock Protocol**: отмена = просто перестать продлевать; членство доживает до
`expiration`, потому что продление возможно только на истекшем ключе
(https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/).

**Отдельная особенность Sablier**: отменяемость можно необратимо отключить.
`renounce` вызывает отправитель, это «an irreversible operation», после которой
право отмены пропадает навсегда
(https://docs.sablier.com/reference/lockup/contracts/contract.SablierLockup);
«a cancelable stream can be set as uncancelable at any point in time by the stream
creator. However, an uncancelable stream cannot be set as cancelable»
(https://docs.sablier.com/concepts/cancelability).

### Чего ждать в простой pull-модели

Отмена в pull-модели — это по сути `approve(0)` плюс, возможно, отметка статуса в
контракте. Она действует только вперед. Вопрос «что с уже начатым периодом»
контракт не решает сам: если период уже оплачен вперед, деньги ушли, и вернуть их
без отдельной логики нельзя (см. раздел 5). Кто имеет право отменить — тоже
проектное решение: у плательщика это право есть всегда, потому что он владеет
allowance, а вот право получателя отменить подписку нужно закладывать явно.

---

## 5. Возвраты и споры

### Возможны ли возвраты на цепочке

Общая рамка: обычный перевод необратим. Обзор инфраструктуры рекуррентных
стейблкоин-платежей формулирует это прямо — «on-chain payments are final by design»,
и добавляет, что «consumer protection frameworks specifically for recurring crypto
billing remain underdeveloped»
(https://www.spark.money/research/recurring-stablecoin-payment-infrastructure).
Значит, любой «возврат» — это отдельный добровольный перевод обратно или
специальная логика контракта, а не откат.

### Возврат на уровне контракта: где он есть

**Unlock Protocol** — самый явный пример ончейн-возврата в подписочной модели.
Функция `cancelAndRefund` включена по умолчанию на всех локах со штрафом 10%;
`getCancelAndRefundValue` — view-функция, возвращающая расчетную сумму возврата
(фактическая будет чуть меньше из-за времени майнинга); менеджер лока может
менять штраф через `updateRefundPenalty`; есть также `expireAndRefundFor`, которой
менеджер лока принудительно завершает членство с возвратом пропорционально
остатку срока (https://docs.unlock-protocol.com/core-protocol/smart-contracts-api/PublicLock,
https://unlock-protocol.com/guides/how-to-cancel-a-users-membership/). Практическое
предостережение из той же документации: полный вывод средств с лока ломает
`cancelAndRefund` и `expireAndRefundFor` — возвращать не из чего.

**Sablier** — возврат в смысле «неизрасходованное обратно отправителю». В Lockup
это происходит при отмене: до старта возвращается весь депозит, во время потока —
остаток после вычета уже начисленного получателю, после окончания возвращать нечего
и все уходит получателю (https://docs.sablier.com/support/faq,
https://docs.sablier.com/concepts/cancelability). В Flow есть отдельная функция
`refund`, которой отправитель забирает неначисленную часть в пределах refundable
amount (https://docs.sablier.com/guides/flow/examples/stream-management).
Обратите внимание: во всех случаях возвращается только то, что еще не «протекло».
Возврата уже полученного получателем нет.

**Superfluid**: механизма возврата уже перетекших средств в найденной документации
нет — **не подтверждено**. Единственная близкая по смыслу вещь — потеря залога, но
это не возврат, а наоборот.

**Loop Crypto, Request Network, Spritz, Suberra**: в просмотренной документации
раздел о возвратах отсутствует
(https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions,
https://docs.request.network/request-network-api/recurring-payments,
https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/) —
**не подтверждено**. Из того, что Loop работает как процессор поверх Stripe,
логично предположить возврат вне цепочки, но прямого утверждения об этом в
документации не найдено, поэтому это остается догадкой, а не фактом.

### Аналоги chargeback

Отдельного механизма спора в разобранных подписочных протоколах нет. Ближайшая
публичная попытка спроектировать такое — исследовательское предложение Стэнфорда
ERC-20R / ERC-721R: opt-in токен-стандарты, где транзакцию можно оспорить в
короткое окно, «within the short dispute period, a sender can request to reverse a
transaction by convincing a decentralized set of judges to first freeze the disputed
assets, and then later convincing them to reverse the transaction», а окно
заморозки в прототипе — три дня
(https://arxiv.org/pdf/2208.00543,
https://www.coindesk.com/tech/2022/09/28/stanford-proposal-for-reversible-ethereum-transactions-divides-crypto-community).
Это именно предложение, оно вызвало заметное сопротивление в сообществе и в
подписочных протоколах не используется.

### Чего ждать в простой pull-модели

Возврата нет, если его не написать. Написать можно только тот возврат, деньги для
которого лежат в контракте — то есть модель «получатель забирает средства сразу»
и модель «возврат возможен» несовместимы без эскроу. Хорошая иллюстрация — оговорка
Unlock про полный вывод средств, ломающий возврат.

---

## 6. Дополнительно: реорги, идемпотентность, двойное списание, зависшие транзакции, заморозка токена

### Реорганизации цепочки и повторные списания

Реорг может отменить уже включенную транзакцию: «different portions of the network
consider a different chain to be canonical», и транзакция из отброшенной ветки
«may either be re-queued for inclusion in a new block, or otherwise have its
ordering or block number changed»
(https://blog.trailofbits.com/2023/08/23/the-engineers-guide-to-blockchain-finality/).
Классический вектор потерь — засчитать платеж до финализации.

Практический вывод оттуда же: считать по числу подтверждений недостаточно, надо
спрашивать у ноды именно финализированный блок (`eth_getBlockByNumber` с параметром
`finalized`), потому что в мае 2023 финализация в Ethereum вставала на девять эпох
(там же). Твердая финализация в Ethereum PoS — две эпохи, около 12,8 минуты
(https://www.spark.money/research/payment-finality-comparison-blockchains).

Для подписок это значит: событие «платеж прошел» нельзя считать окончательным
сразу. В исследовании атак на x402 это выделено в отдельную атаку I-A
(revert-grant): сервер выдает ресурс до финализации, а последующая реорганизация
убирает платеж, услуга при этом уже оказана
(https://arxiv.org/html/2605.11781v1).

Важно понимать, что именно реорг делает и чего не делает. Он не приводит к тому,
что одна и та же транзакция исполнится дважды — nonce отправителя это исключает.
Он приводит к тому, что платеж, который вы уже засчитали, исчезнет.

### Идемпотентность и двойное списание за один период

Здесь два разных уровня, и их постоянно путают.

**Уровень цепочки.** У подписи-авторизации должна быть защита от повтора. В
EIP-3009 `transferWithAuthorization` принимает `from`, `to`, `value`, `validAfter`,
`validBefore`, `nonce` и подпись; контракт проверяет, что nonce еще не
использовался, и после исполнения nonce считается израсходованным, так что
авторизацию нельзя переиспользовать (https://eips.ethereum.org/EIPS/eip-3009).
Причем nonce тут — случайные 32 байта, а не счетчик, что позволяет заранее
подготовить несколько независимых авторизаций (например, по одной на период)
(https://hackmd.io/@Extropy/EIP3009). В ERC-1337 роль идентификатора играет
`getSubscriptionHash()`, а статус подписки хранится на цепочке, что и не дает
исполнить одну авторизацию дважды (https://eips.ethereum.org/EIPS/eip-1337).
В Permit2 защита от повтора — инкрементный nonce на тройку «владелец, токен,
спендер» (https://developers.uniswap.org/docs/protocols/permit2/concepts/allowance-transfer).

**Уровень приложения.** Даже при идеальной ончейн-защите двойной «зачет» легко
получить выше по стеку. Исследование x402 показало на живом тесте, что один платеж
породил 248 выдач ресурса, потому что серверы не проверяли идемпотентность, — при
одном-единственном ончейн-расчете; и что ни один из проверенных SDK не обеспечивает
одноразовость по умолчанию (https://arxiv.org/html/2605.11781v1).

**Ошибки учета периодов.** Аудит подписочных контрактов Daisy (ConsenSys Diligence)
отмечал именно такого рода проблему: `SubscriptionManager.nextPaymentTimestamp()`
возвращает 0 для несуществующей подписки, что требует отдельной проверки
существования, иначе учет периодов поедет
(https://github.com/ConsenSys/daisy-audit-report-2019-08). Там же — находка средней
серьезности про потерю кредитов при замене подписки новой. Это ровно тот класс
багов, который порождает «списали дважды за один период» или «не списали вовсе».

### Зависшая транзакция и замена по nonce

Транзакция может застрять в мемпуле. Стандартный выход — replace-by-fee: отправить
транзакцию с тем же nonce и более высокой комиссией; заменяющая вытесняет прежнюю,
и «only unique nonce transactions per ETH address can exist»
(https://info.etherscan.io/how-to-cancel-ethereum-pending-transactions/,
https://support.metamask.io/manage-crypto/transactions/how-to-speed-up-or-cancel-a-pending-transaction/).
Отмена делается тем же приемом: перевод на 0 самому себе с тем же nonce и большей
комиссией. Отдельно важно, что заменять нужно самую раннюю зависшую транзакцию —
все с большими nonce будут ждать ее в любом случае (там же).

Что это значит для подписки: у той стороны, которая дергает списание (сервис,
продавец, keeper), транзакции могут стоять в очереди по nonce. Один застрявший
вызов блокирует последующие, и «пропущенный период» может случиться не из-за
плательщика, а из-за очереди отправителя. Отдельно: заменяющая транзакция — это
другая транзакция, и если приложение считает «попытки» по хешу, оно легко
насчитает лишнее.

### Пауза и заморозка токена

Стейблкоин может по решению эмитента заблокировать конкретный адрес или встать
целиком — это внешний по отношению к подписке отказ, который никак не связан ни с
балансом, ни с allowance.

**Блокировка адреса.** В контракте FiatToken (USDC) есть модуль `Blacklistable` с
ролью `blacklister`. Заблокированный адрес «unable to transfer tokens, mint, or
burn tokens», не может вызывать `transfer`/`transferFrom` и не может получать
токены (https://github.com/zhenghui-w/stablecoin-evm/blob/master/doc/tokendesign.md).
Любопытная деталь версии 2.2: заблокированным адресам вернули возможность вызывать
`approve`, но это «meaningless», раз двигать активы они все равно не могут (там же).
Для нас это значит, что allowance у заблокированного плательщика может выглядеть
абсолютно здоровым, а списание все равно упадет.

Практика применения существует: CENTRE блокировал адрес USDC по запросу
правоохранительных органов, заморозив 100 тысяч долларов
(https://www.coindesk.com/markets/2020/07/08/circle-confirms-freezing-100k-in-usdc-at-law-enforcements-request).

**Пауза всего токена.** Роль `pauser` может остановить все переводы, минт и берн;
при этом изменение черного списка, снятие минтеров, смена ролей и апгрейд
продолжают работать — «only the `pauser` role may call pause»
(https://github.com/zhenghui-w/stablecoin-evm/blob/master/doc/tokendesign.md).

Как конкретные подписочные протоколы обрабатывают блокировку адреса плательщика
или получателя — в просмотренной документации не описано, **не подтверждено**.
Симптоматика при этом та же, что у любой другой неудачи: списание не проходит.

---

## 7. Сводная таблица

| Сценарий | Superfluid | Sablier | Loop Crypto | Request Network | Unlock Protocol | Suberra / Spritz | Чего ждать в простой pull-модели через approve |
|---|---|---|---|---|---|---|---|
| Отзыв / уменьшение разрешения | Аналог — отзыв прав оператора и flow rate allowance в ACL ([док](https://github.com/superfluid-finance/docs/blob/main/developers/constant-flow-agreement-cfa/cfa-access-control-list-acl/README.md)) | Не применимо: средства уже внесены в поток при создании | Штатное действие плательщика; будущие платежи перестают проходить, событие `TransferProcessed` не возникает ([док](https://docs.loopcrypto.xyz/docs/welcome)) | Не подтверждено (документация описывает подпись EIP-712/permit, отзыв не описан) | Автопродление просто перестает удаваться; `isRenewable` объясняет причину ([док](https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/)) | Не подтверждено | `transferFrom` откатывается, уведомления никому нет; нужна собственная проверка `allowance()` до попытки |
| Нехватка баланса | Ликвидация: buffer 4 часа, critical → insolvent, sentinels, TOGA, залог теряется ([док](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)) | Flow: uncovered debt, поток уходит в минус, ликвидатора нет ([док](https://docs.sablier.com/concepts/flow/overview)) | Неотличимо от нехватки allowance; письмо «Missed Payment» через 5 минут ([док](https://docs.loopcrypto.xyz/docs/renewal-payments-copy)) | Расписание ставится на паузу ([док](https://docs.request.network/request-network-api/recurring-payments)) | Продление не проходит, членство истекает | Suberra проверяет баланс до попытки ([док](https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/)); Spritz требует ручного пересоздания ([док](https://www.spritz.finance/blog/introducing-smartpay-recurring-crypto-bill-payments)) | Откат транзакции. Ни залога, ни долга, ни ликвидатора |
| Пропущенные периоды, долг, grace period | Понятия периода нет; аналог — дефицит при неплатежеспособности | Flow: долг копится и оплачивается при пополнении; пауза не стирает начисленное ([док](https://docs.sablier.com/guides/flow/examples/stream-management)) | Окно 7 дней по умолчанию, настраивается; внутри окна платеж пройдет, как только хватит средств; по истечении — отмена подписки ([док](https://docs.loopcrypto.xyz/docs/renewal-payments-copy)) | Пауза + «догон» пропущенного после unpause; детали догона не подтверждены ([док](https://docs.request.network/request-network-api/recurring-payments)) | Долг не копится: ключ истекает, продление продлевает от момента вызова ([док](https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/)) | Suberra: grace period 7 дней по умолчанию, частые повторы внутри него ([док](https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/)) | Ничего не происходит само: нужен явный выбор между «копить долг» и «сдвигать окно», иначе после простоя спишется неожиданная сумма |
| Отмена | `deleteFlow` отправителем или оператором с ACL; в критическом состоянии — кем угодно ([док](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga)) | Lockup: только отправитель, немедленно, непротекшее возвращается ([док](https://docs.sablier.com/reference/lockup/contracts/contract.SablierLockup)); Flow: pause или void, void обнуляет непокрытый долг ([док](https://docs.sablier.com/guides/flow/examples/stream-management)) | И плательщик, и продавец; будущие счета отменяются, текущий выставленный — нет ([док](https://loop-crypto.gitbook.io/old-loop-crypto/dashboard-functionality/subscriptions)) | Отмена через API, останавливает будущие платежи ([док](https://docs.request.network/request-network-api/recurring-payments)) | Отмена = перестать продлевать, доступ живет до `expiration` | Не подтверждено | `approve(0)` + отметка статуса. Действует только вперед; уже списанное за начатый период не возвращается |
| Возврат / спор | Не подтверждено | Возвращается только «непротекшее»: Lockup — при отмене, Flow — функцией `refund` ([док](https://docs.sablier.com/concepts/cancelability)) | Не подтверждено | Не подтверждено | `cancelAndRefund` со штрафом 10% по умолчанию, `expireAndRefundFor` для менеджера лока ([док](https://docs.unlock-protocol.com/core-protocol/smart-contracts-api/PublicLock)) | Не подтверждено | Возврата нет, пока средства не задержаны в контракте; полный вывод получателем делает возврат невозможным |
| Реорг / финализация | Не описано в документации протоколов; общая практика — ждать `finalized` ([Trail of Bits](https://blog.trailofbits.com/2023/08/23/the-engineers-guide-to-blockchain-finality/)) | То же | То же | То же | То же | То же | «Платеж прошел» нельзя считать окончательным сразу; на локальном стенде реорга обычно нет, и это отдельная ловушка восприятия |
| Идемпотентность / двойное списание | Не применимо (нет дискретных списаний) | Не применимо | Не подтверждено | Не подтверждено | Продление невозможно на неистекшем ключе — это и есть защита ([док](https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/)) | Не подтверждено | На цепочке спасает проверка `now >= last + period`; на уровне приложения — нет, см. 248 выдач на один платеж в x402 ([статья](https://arxiv.org/html/2605.11781v1)) |
| Зависшая транзакция / замена по nonce | Не описано | Не описано | Не описано | Не описано | Не описано | Не описано | Очередь по nonce у вызывающей стороны блокирует последующие списания; replace-by-fee — стандартный выход ([MetaMask](https://support.metamask.io/manage-crypto/transactions/how-to-speed-up-or-cancel-a-pending-transaction/)) |
| Заморозка / пауза токена | Не описано | Не описано | Не описано | Не описано | Не описано | Не описано | Заблокированный адрес не может двигать токены, при этом `approve` в USDC 2.2 ему доступен — allowance выглядит здоровым, а списание падает ([док](https://github.com/zhenghui-w/stablecoin-evm/blob/master/doc/tokendesign.md)) |

---

## 8. Минимальный набор сбоев для учебного стенда

Отбирал по двум критериям: сбой должен быть воспроизводим локально одной-двумя
командами, и он должен показывать что-то, чего не видно на «счастливом пути».
Список — предложение для обсуждения, а не решение: любой пункт, который расширяет
объем стенда, идет в нецели, а не в код.

**Обязательный минимум — четыре сбоя.**

1. **Разрешение отозвано.** Плательщик делает `approve(0)`, время платежа
   наступает, вызов списания откатывается. Что показать: со стороны получателя не
   появилось ни события, ни транзакции — отказ виден только как отсутствие успеха.
   Что демонстрирует: allowance — не обязательство, а разрешение, и оно
   односторонне отзывается в любой момент
   (https://revoke.cash/learn/approvals/how-to-revoke-token-approvals).

2. **Разрешения хватает, баланса нет.** `allowance` большой, баланс меньше цены
   периода. Что показать: причина отказа другая, а внешний результат тот же.
   Что демонстрирует: в pull-модели нужны две независимые проверки перед попыткой,
   как это делают Loop и Suberra
   (https://docs.loopcrypto.xyz/docs/welcome,
   https://suberra.github.io/suberra-docs/docs/subscriptions/subscriptions/).

3. **Пропущенные периоды.** Никто не вызывал списание N минут подряд, потом вызвали.
   Что показать: сколько денег спишется — за один период или за N, и как ведет себя
   `last`. Что демонстрирует: главный проектный выбор всей модели; реальные решения
   расходятся здесь диаметрально — Request Network догоняет
   (https://docs.request.network/request-network-api/recurring-payments), Unlock
   продлевает от момента вызова
   (https://docs.unlock-protocol.com/core-protocol/public-lock/renewals/).

4. **Двойной вызов в одном периоде.** Списание дергают дважды подряд. Что показать:
   вторая попытка должна откатиться по проверке периода. Что демонстрирует:
   идемпотентность на цепочке — и то, что она не спасает уровень приложения
   (https://arxiv.org/html/2605.11781v1).

**Желательные, если позволит объем — еще два.**

5. **Отмена посреди оплаченного периода.** Что показать: деньги за начатый период
   уже у получателя, вернуть их нечем. Что демонстрирует: невозможность возврата
   без эскроу — ровно та проблема, из-за которой у Unlock полный вывод средств
   ломает `cancelAndRefund`
   (https://docs.unlock-protocol.com/core-protocol/smart-contracts-api/PublicLock).

6. **Разрешение уменьшено ниже цены периода** (не обнулено, а именно уменьшено).
   Что показать: подписка выглядит активной, но платеж не пройдет. Что
   демонстрирует: недостаточно проверять «allowance > 0», надо сравнивать с ценой
   периода — и заодно можно упомянуть, почему у `approve` нет срока годности, в
   отличие от Permit2 с его `expiration`
   (https://developers.uniswap.org/docs/protocols/permit2/concepts/allowance-transfer).

**Что на локальном стенде показать честно не получится** (упомянуть, но не
реализовывать): реорганизацию цепочки и вопрос финализации
(https://blog.trailofbits.com/2023/08/23/the-engineers-guide-to-blockchain-finality/),
зависшую транзакцию и очередь по nonce, блокировку адреса эмитентом стейблкоина
(https://github.com/zhenghui-w/stablecoin-evm/blob/master/doc/tokendesign.md).
Первое требует управления консенсусом, второе — живого мемпула с конкуренцией,
третье — токена с ролью blacklister. Каждое из них тянет за собой заметный объем,
поэтому это кандидаты в нецели.

---

## 9. Что осталось неподтвержденным

Собрано в одном месте, чтобы не перечитывать документ.

- Что именно показывают получателю в интерфейсе Superfluid в момент ликвидации
  потока — в документации не описано.
- Точный алгоритм «догона» пропущенных платежей в Request Network после unpause:
  сколько периодов, одной ли транзакцией.
- Точное расписание повторов Suberra внутри 7-дневного grace period («часто» —
  единственная формулировка в документации).
- Возвраты у Loop Crypto, Request Network, Spritz, Suberra: раздела о возвратах в
  просмотренной документации нет. Что Loop делает возврат вне цепочки через
  Stripe — правдоподобная догадка, но прямо не написано.
- Возврат уже переданных средств в Superfluid — механизма не найдено.
- Расхождение у Sablier: справочник по контракту Lockup и страница про
  отменяемость говорят «только отправитель», FAQ говорит «и отправитель, и
  получатель». Какой из ответов к какому продукту относится — не установлено.
- Поведение любого из разобранных подписочных протоколов при блокировке адреса
  плательщика или получателя эмитентом стейблкоина — не описано нигде.
- Обработка реоргов, зависших транзакций и замены по nonce на уровне самих
  подписочных протоколов — в их документации не описана; все найденные источники
  по этим темам общие, не привязанные к подпискам.
- Сценарий «несколько пропусков подряд списываются одной транзакцией» — явно не
  описан ни в одной из просмотренных документаций.
