// app.js — логика витрины стенда «Минута».
//
// ============================================================================
// ТРАНСПОРТ: почему без библиотеки
// ============================================================================
//
// Никакой библиотеки нет вообще — ни ethers, ни web3, ни локальной копии
// в vendor/. Причины:
//
//  1. Библиотеки во фронте и CDN — в нецелях (AGENTS.md, раздел 2). Локальная
//     копия ethers формально обошла бы запрет на CDN, но не запрет на
//     библиотеку, и добавила бы к стенду мегабайт кода, который нечего
//     объяснять.
//  2. Работы здесь ровно столько, сколько ее есть: узел говорит по JSON-RPC
//     поверх HTTP, а `fetch` встроен в браузер.
//  3. Подпись транзакций не нужна. Anvil держит свои дефолтные аккаунты
//     разблокированными, поэтому транзакция уходит через `eth_sendTransaction`
//     с полем `from` — подписывает узел. Кошельки-расширения в нецелях,
//     и городить подпись в браузере незачем.
//  4. ABI-кодирование в этом стенде тривиально: аргумент всегда один и всегда
//     адрес, то есть «селектор + адрес, дополненный нулями слева до 32 байт».
//     Селекторы (первые четыре байта keccak от сигнатуры) посчитаны заранее
//     и лежат константами ниже — считать keccak в браузере не нужно.
//  5. Декодирование тоже тривиально: авто-геттер отображения возвращает
//     последовательность 32-байтных слов фиксированной длины, все поля
//     статические. Разбор — нарезка hex-строки по 64 символа.
//
// Интернет для запуска стенда не нужен: витрина ходит только на
// http://127.0.0.1:8545 и читает локальный data/facts.json.
//
// ============================================================================
// КОНТРАКТ С РАЗМЕТКОЙ (web/index.html пишет другой шаг сборки)
// ============================================================================
//
// Этот модуль разметку не создает и не правит, он только читает и заполняет
// уже существующие узлы. Все обращения защищены: отсутствующий узел ничего
// не ломает, витрина просто не покажет соответствующий кусок.
//
// Ожидается следующее.
//
// * `#account-select` — `<select>` с тремя `<option>`, значение каждого равно
//   адресу аккаунта из `ACCOUNTS` конфигурации. Модуль сам подписывается на
//   `change` и сам заполняет список опциями, если он пуст.
//
// * `#app` — корневой узел страницы. Модуль проставляет ему атрибут
//   `data-screen` с одним из пяти значений SCREEN_IDS (см. screens.js):
//       "noSubscription" — экран 1, записи нет
//       "accessOpen"     — экран 2, доступ открыт
//       "canceled"       — экран 3, подписка отменена
//       "debtCatchup"    — экран 4, погашение долга
//       "overdue"        — экран 5, просрочена
//   Оформление экранов — дело CSS, модуль в стили не лезет.
//
// * Текстовые слоты — любые элементы с атрибутом `data-field`. Модуль пишет
//   в них `textContent`. Имена слотов:
//       title        заголовок экрана (из screens.js)
//       text         пояснение экрана (из screens.js)
//       notice       плашка «отменена, доступ до конца периода» (экран 2)
//       hint         подсказка: экран 4 — про один период за нажатие,
//                    экран 5 — поднять разрешение либо пополнить баланс
//       hintLabel    подпись перед подсказкой (только экран 5)
//       attemptText  фраза про число неудачных попыток (экран 5)
//       attempt      число неудачных попыток подряд (экран 5)
//       reason       причина последней неудачи словами (экран 5)
//       reasonLabel  подпись перед причиной (экран 5)
//       debt         N — число неоплаченных периодов (экраны 4 и 5)
//       fact         текст факта минуты (экран 2)
//       factTitle    заголовок факта минуты (экран 2)
//       factIndex    индекс факта, periodsPaid mod 12
//       account      адрес выбранного аккаунта
//       accountRole  роль выбранного аккаунта
//       blockTime    время последнего блока узла, читаемое
//       paidUntil    граница оплаченного периода, читаемая
//       periodsPaid  сколько периодов оплачено
//       status       строка результата последнего действия или ошибки
//
// * Видимость блоков — атрибут `data-screens` со списком экранов через пробел,
//   например `data-screens="debtCatchup overdue"`. Модуль ставит и снимает
//   стандартный атрибут `hidden`. Элементы без `data-screens` модуль не
//   трогает.
//
// * Кнопки — атрибут `data-action` со значением `subscribe`, `charge`
//   или `cancel`. Модуль сам вешает обработчики, сам прячет кнопку там, где
//   действие невозможно, сам подставляет подпись из `actionLabel` текущего
//   экрана и сам блокирует все кнопки на время отправки транзакции.
//   Отдельно `data-screens` на кнопках не нужен.
//
// ============================================================================
// КОНТРАКТ С web/screens.js (его пишет другой шаг сборки)
// ============================================================================
//
// Своих копий текстов здесь нет. Модуль подключает screens.js динамически:
// если файла нет, витрина деградирует мягко — покажет состояние без
// человеческих формулировок и скажет об этом в строке статуса.
//
// Ожидаются экспорты `SCREEN_IDS`, `SCREENS`, `FAILURE_REASONS`,
// `ACTION_LABELS`, `ROLE_LABELS`. Форма задана в screens.js, здесь она
// только читается:
//
//   SCREENS[id] = {
//     id, title, text, actionLabel,
//     // и по экранам:
//     canceledNotice(expiresAt),  // accessOpen — плашка про отмену
//     hint,                       // debtCatchup — про один период за нажатие
//     attemptText(k),             // overdue — число неудачных попыток
//     reasonLabel, hintLabel,     // overdue — подписи
//   };
//
//   FAILURE_REASONS[code] = { code, reason, hint };   // code: 0, 1, 2
//
// Поле-строка отдается как есть, поле-функция вызывается с одним аргументом:
// `text` — с числом периодов долга, `attemptText` — с числом попыток,
// `canceledNotice` — с уже отформатированным временем истечения.
//
// Ключи экранов здесь не дублируются: SCREEN_IDS читается из того же модуля,
// а локальная таблица SCREEN ниже сверяется с ним при загрузке.

import * as cfg from "./config.js";

// ============================================================================
// Ключи экранов
// ============================================================================
//
// Значения обязаны совпадать с SCREEN_IDS из screens.js. Локальная копия
// нужна затем, что screens.js подключается динамически (мягкая деградация),
// а решать, какой экран показывать, надо и без него. Совпадение проверяется
// на загрузке в checkScreenIds(): расхождение видно сразу, а не через экран,
// который молча остался пустым.

const SCREEN = {
  NO_SUBSCRIPTION: "noSubscription",
  ACCESS_OPEN: "accessOpen",
  CANCELED: "canceled",
  DEBT_CATCHUP: "debtCatchup",
  OVERDUE: "overdue",
};

// ============================================================================
// Селекторы функций
// ============================================================================
//
// Первые четыре байта keccak-256 от сигнатуры. Посчитаны заранее, чтобы не
// тащить в браузер реализацию keccak. Проверить можно так:
//     cast sig "charge(address)"

const SEL_SUBSCRIBE = "0x8f449a05"; // subscribe()
const SEL_CHARGE = "0xfc6bd76a"; // charge(address)
const SEL_CANCEL = "0xea8a1af0"; // cancel()
const SEL_SUBSCRIPTIONS = "0xf046395a"; // subscriptions(address) — авто-геттер
const SEL_DEBT_PERIODS = "0x5294106b"; // debtPeriods(address)
const SEL_HAS_ACCESS = "0x95a078e8"; // hasAccess(address)

/// Селектор стандартной ошибки Error(string) — нужен, чтобы прочитать текст
/// revert из ответа узла.
const SEL_ERROR_STRING = "0x08c379a0";

// ============================================================================
// Состояние модуля
// ============================================================================

/// Выбранный аккаунт: и просмотр, и отправитель транзакций (раздел 10).
let selectedAccount = cfg.ACCOUNTS.find((a) => a.id === cfg.DEFAULT_ACCOUNT_ID) || cfg.ACCOUNTS[0];

/// Тексты экранов; null, если screens.js недоступен.
let screensModule = null;

/// Список фактов минуты; null, если data/facts.json недоступен.
let facts = null;

/// Идет отправка транзакции — кнопки заблокированы.
let busy = false;

/// Таймер опроса состояния.
let refreshTimer = null;

/// Последнее прочитанное состояние — чтобы обработчики кнопок знали,
/// что показано на экране.
let lastView = null;

// ============================================================================
// JSON-RPC поверх fetch
// ============================================================================

let rpcId = 0;

/// Один вызов JSON-RPC к локальному узлу. Ошибку узла превращает в исключение
/// с человеческим текстом.
async function rpc(method, params = []) {
  const response = await fetch(cfg.RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });

  if (!response.ok) {
    throw new Error(`узел ответил HTTP ${response.status}`);
  }

  const body = await response.json();

  if (body.error) {
    const err = new Error(rpcErrorText(body.error));
    err.rpcError = body.error;
    throw err;
  }

  return body.result;
}

/// Текст ошибки узла. Если в ошибке лежат данные revert — достает строку
/// причины, ту самую, что написана в require контракта.
function rpcErrorText(error) {
  const raw = error && error.data;
  const data = typeof raw === "string" ? raw : raw && raw.data;
  const revert = decodeRevertReason(data);
  if (revert) return revert;
  return (error && error.message) || "неизвестная ошибка узла";
}

/// Разбор данных ошибки Error(string): селектор, смещение, длина, байты строки.
function decodeRevertReason(data) {
  if (typeof data !== "string" || !data.startsWith(SEL_ERROR_STRING)) return null;

  const words = hexWords(data.slice(SEL_ERROR_STRING.length));
  if (words.length < 2) return null;

  const length = Number(BigInt("0x" + words[1]));
  const bytesHex = words.slice(2).join("").slice(0, length * 2);

  let text = "";
  for (let i = 0; i < bytesHex.length; i += 2) {
    text += String.fromCharCode(parseInt(bytesHex.slice(i, i + 2), 16));
  }
  return text || null;
}

// ============================================================================
// Кодирование и декодирование ABI
// ============================================================================

/// Адрес как аргумент вызова: 20 байт, дополненные нулями слева до 32 байт.
function encodeAddress(address) {
  return address.toLowerCase().replace(/^0x/, "").padStart(64, "0");
}

/// Данные вызова функции с одним аргументом-адресом.
function callData(selector, address) {
  return selector + encodeAddress(address);
}

/// Нарезка hex-ответа на 32-байтные слова (по 64 hex-символа).
function hexWords(hex) {
  const clean = (hex || "").replace(/^0x/, "");
  const words = [];
  for (let i = 0; i + 64 <= clean.length; i += 64) {
    words.push(clean.slice(i, i + 64));
  }
  return words;
}

/// Слово как целое без знака.
function wordToBigInt(word) {
  return BigInt("0x" + word);
}

/// Чтение через eth_call от имени выбранного аккаунта.
async function ethCall(to, data, from) {
  return rpc("eth_call", [{ to, data, ...(from ? { from } : {}) }, "latest"]);
}

// ============================================================================
// Чтение состояния контракта
// ============================================================================

/// Запись подписки через авто-геттер публичного отображения
/// `subscriptions(address)`. Отдельных view-функций на поля нет (раздел 4),
/// поэтому декодируется кортеж из семи статических слов в порядке объявления
/// полей структуры.
async function readRecord(subscriber) {
  const raw = await ethCall(cfg.SUBSCRIPTION_ADDRESS, callData(SEL_SUBSCRIPTIONS, subscriber));
  const w = hexWords(raw);

  if (w.length < 7) {
    throw new Error("авто-геттер subscriptions вернул неожиданный ответ");
  }

  return {
    exists: wordToBigInt(w[0]) !== 0n,
    canceled: wordToBigInt(w[1]) !== 0n,
    startedAt: wordToBigInt(w[2]),
    paidUntil: wordToBigInt(w[3]),
    periodsPaid: wordToBigInt(w[4]),
    failedAttempts: wordToBigInt(w[5]),
    lastFailureReason: Number(wordToBigInt(w[6])),
  };
}

/// N — число неоплаченных периодов. Берется только из контракта, витрина его
/// не считает: формула раздела 7 живет в одном месте (раздел 10).
async function readDebtPeriods(subscriber) {
  const raw = await ethCall(cfg.SUBSCRIPTION_ADDRESS, callData(SEL_DEBT_PERIODS, subscriber));
  return wordToBigInt(hexWords(raw)[0] || "0".repeat(64));
}

/// Доступ к фиду по правилу контракта: текущее_время < paidUntil.
async function readHasAccess(subscriber) {
  const raw = await ethCall(cfg.SUBSCRIPTION_ADDRESS, callData(SEL_HAS_ACCESS, subscriber));
  return wordToBigInt(hexWords(raw)[0] || "0".repeat(64)) !== 0n;
}

/// Время последнего блока узла. Вся механика периодов построена на
/// `block.timestamp`, поэтому часы браузера здесь не используются вообще:
/// они могут расходиться с узлом, и экран показывал бы не то состояние,
/// из которого исходит контракт.
async function readBlockTimestamp() {
  const block = await rpc("eth_getBlockByNumber", ["latest", false]);
  if (!block) throw new Error("узел не вернул последний блок");
  return BigInt(block.timestamp);
}

// ============================================================================
// Правило экрана (раздел 10)
// ============================================================================

/// Пять экранов, порядок строгий, первое совпавшее условие выигрывает.
/// Порядок здесь важнее всего остального в файле: он же записан в разделе 10
/// спецификации, и менять его нельзя.
function pickScreen(record, hasAccess) {
  // 1. Записи нет.
  if (!record.exists) return SCREEN.NO_SUBSCRIPTION;

  // 2. текущее_время < paidUntil — доступ открыт. Флаг отмены в правило
  //    доступа не входит: отмена не отбирает уже оплаченный период.
  if (hasAccess) return SCREEN.ACCESS_OPEN;

  // 3. Подписка отменена. Долг не показывается — он сгорел вместе с отменой.
  if (record.canceled) return SCREEN.CANCELED;

  // 4. Неудачных попыток не было — это погашение долга, а не сбой.
  if (record.failedAttempts === 0n) return SCREEN.DEBT_CATCHUP;

  // 5. Иначе просрочена: есть причина неудачи и номер попытки.
  return SCREEN.OVERDUE;
}

// ============================================================================
// Факт минуты (раздел 10, К10)
// ============================================================================

/// Загрузка списка фактов. Файл пишет другой шаг сборки; если его нет,
/// деградируем мягко: ни исключения, ни стектрейса в консоли, витрина
/// работает без факта.
async function loadFacts() {
  for (const url of cfg.FACTS_URLS) {
    try {
      const response = await fetch(url);
      if (!response.ok) continue;
      const data = await response.json();
      const list = Array.isArray(data) ? data : Array.isArray(data && data.facts) ? data.facts : null;
      if (list && list.length) return list;
    } catch (_) {
      // Файла нет или он не читается — пробуем следующий путь.
    }
  }
  return null;
}

/// Индекс факта — остаток от деления periodsPaid на 12 (К10).
function factIndex(periodsPaid) {
  return Number(periodsPaid % BigInt(cfg.FACTS_COUNT));
}

/// Текст факта по индексу. Элемент списка может быть строкой или объектом
/// с полем text — принимаем оба варианта, форму файла задает другой шаг.
function factText(index) {
  if (!facts) return "";
  const item = facts[index];
  if (item == null) return "";
  if (typeof item === "string") return item;
  return item.text || item.fact || "";
}

/// Заголовок факта. У элемента-строки заголовка нет — это не ошибка,
/// слот просто останется пустым.
function factTitle(index) {
  if (!facts) return "";
  const item = facts[index];
  if (item == null || typeof item === "string") return "";
  return item.title || "";
}

// ============================================================================
// Тексты экранов
// ============================================================================

/// Таблица причин неудачи (FAILURE_REASONS); null, если модуль недоступен.
let reasonsTable = null;

/// Подписи кнопок (ACTION_LABELS); null, если модуль недоступен.
let actionLabels = null;

/// Названия ролей аккаунтов (ROLE_LABELS); null, если модуль недоступен.
let roleLabels = null;

/// Подключение screens.js. Динамический импорт, а не статический, ровно ради
/// мягкой деградации: статический импорт отсутствующего файла обрушил бы
/// весь модуль целиком.
async function loadScreens() {
  try {
    const mod = await import("./screens.js");
    screensModule = mod.SCREENS || null;
    reasonsTable = mod.FAILURE_REASONS || null;
    actionLabels = mod.ACTION_LABELS || null;
    roleLabels = mod.ROLE_LABELS || null;
    checkScreenIds(mod.SCREEN_IDS);
  } catch (_) {
    screensModule = null;
    reasonsTable = null;
    actionLabels = null;
    roleLabels = null;
  }
}

/// Сверка локальных ключей экранов с SCREEN_IDS из screens.js. Словарь
/// у трех файлов витрины один, и расхождение должно быть слышно сразу,
/// а не оборачиваться пустым экраном без объяснений.
function checkScreenIds(ids) {
  if (!ids) return;

  const known = new Set(Object.values(ids));
  const missing = Object.values(SCREEN).filter((id) => !known.has(id));

  if (missing.length) {
    setStatus(`Словарь разошелся: в screens.js нет экранов ${missing.join(", ")}.`);
  }
}

/// Поле экрана. Строка отдается как есть, функция-шаблон вызывается с одним
/// аргументом — форму задает screens.js, здесь она только читается.
/// Нет screens.js — пустая строка, и разметка оставляет свое значение.
function screenField(screenId, field, arg) {
  if (!screensModule) return "";

  const entry = screensModule[screenId];
  if (!entry) return "";

  const value = entry[field];

  if (typeof value === "function") {
    try {
      return String(value(arg));
    } catch (_) {
      return "";
    }
  }

  return typeof value === "string" ? value : "";
}

/// Причина неудачи словами (`reason`) и подсказка по ней (`hint`).
/// Ключ — число из lastFailureReason: 1 — не хватает разрешения,
/// 2 — не хватает баланса (раздел 6). Своего перечисления здесь нет.
function reasonField(code, field) {
  if (!reasonsTable) return "";

  const entry = reasonsTable[code] || reasonsTable[String(code)];
  if (!entry) return "";

  return typeof entry[field] === "string" ? entry[field] : "";
}

// ============================================================================
// Работа с DOM
// ============================================================================

function $(selector) {
  return document.querySelector(selector);
}

function $$(selector) {
  return Array.from(document.querySelectorAll(selector));
}

/// Запись в текстовый слот. Отсутствующий слот — не ошибка.
function setField(name, value) {
  for (const node of $$(`[data-field="${name}"]`)) {
    node.textContent = value == null ? "" : String(value);
  }
}

/// Видимость блоков по текущему экрану.
function applyScreenVisibility(screenId) {
  for (const node of $$("[data-screens]")) {
    const list = node.getAttribute("data-screens").trim().split(/\s+/);
    node.hidden = !list.includes(screenId);
  }
}

/// Доступность действий. Кнопка списания есть только на экранах погашения
/// долга и просрочки: на экране открытого доступа ее нет по разделу 10.
///
/// Подпись видимой кнопки берется из `actionLabel` текущего экрана: на экране
/// просрочки screens.js дает «Повторить списание», на экране долга —
/// «Списать за период». Своих подписей здесь нет.
function applyActions(view) {
  const screenId = view.screen;

  const available = {
    subscribe: screenId === SCREEN.NO_SUBSCRIPTION || screenId === SCREEN.CANCELED,
    charge: screenId === SCREEN.DEBT_CATCHUP || screenId === SCREEN.OVERDUE,
    cancel: view.record.exists && !view.record.canceled,
  };

  const screenAction = screenField(screenId, "actionLabel");

  const labels = {
    subscribe: screenAction,
    charge: screenAction,
    cancel: actionLabels ? actionLabels.cancel : "",
  };

  for (const node of $$("[data-action]")) {
    const action = node.getAttribute("data-action");
    if (!(action in available)) continue;

    node.hidden = !available[action];
    node.disabled = busy || !available[action];

    // Подпись меняем только у видимой кнопки и только если текст есть:
    // без screens.js в разметке остается ее собственная подпись.
    if (available[action] && labels[action]) node.textContent = labels[action];
  }
}

/// Блокировка кнопок на время отправки транзакции.
function setBusy(value) {
  busy = value;

  if (value) {
    for (const node of $$("[data-action]")) node.disabled = true;
    return;
  }

  if (lastView) {
    applyActions(lastView);
  } else {
    for (const node of $$("[data-action]")) node.disabled = false;
  }
}

function setStatus(text) {
  setField("status", text);
}

/// Название роли аккаунта. Берется из ROLE_LABELS в screens.js — там тексты
/// живут в одном месте; в config.js остается роль как запасной вариант,
/// если screens.js недоступен.
function accountRoleLabel(account) {
  if (roleLabels && typeof roleLabels[account.id] === "string") return roleLabels[account.id];
  return account.role || account.id;
}

/// Время секундами эпохи в читаемый вид. Само значение — время блока узла.
function formatTime(seconds) {
  if (!seconds) return "—";
  const d = new Date(Number(seconds) * 1000);
  return d.toLocaleTimeString("ru-RU", { hour12: false });
}

// ============================================================================
// Сборка и отрисовка экрана
// ============================================================================

/// Чтение всего, что нужно экрану, одним заходом.
async function readView(subscriber) {
  const [record, debt, hasAccess, now] = await Promise.all([
    readRecord(subscriber),
    readDebtPeriods(subscriber),
    readHasAccess(subscriber),
    readBlockTimestamp(),
  ]);

  return { record, debt, hasAccess, now, screen: pickScreen(record, hasAccess) };
}

function render(view) {
  lastView = view;

  const { record, debt, now, screen } = view;

  const root = $("#app");
  if (root) root.setAttribute("data-screen", screen);

  applyScreenVisibility(screen);

  setField("account", selectedAccount.address);
  setField("accountRole", accountRoleLabel(selectedAccount));
  setField("blockTime", formatTime(now));
  setField("periodsPaid", record.exists ? record.periodsPaid.toString() : "—");
  setField("paidUntil", record.exists ? formatTime(record.paidUntil) : "—");

  // `text` на экранах долга и просрочки — функция от числа периодов долга,
  // на остальных — обычная строка. Лишний аргумент строке не мешает.
  setField("title", screenField(screen, "title"));
  setField("text", screenField(screen, "text", Number(debt)));

  // Экран 2: доступ открыт — показываем факт минуты. Плашка про сохранение
  // доступа появляется дополнительно, если подписка отменена; факт при этом
  // все равно показывается, за период заплачено.
  if (screen === SCREEN.ACCESS_OPEN) {
    const index = factIndex(record.periodsPaid);
    setField("factIndex", String(index));
    setField("fact", facts ? factText(index) : "");
    setField("factTitle", facts ? factTitle(index) : "");

    const notice = record.canceled
      ? screenField(SCREEN.ACCESS_OPEN, "canceledNotice", formatTime(record.paidUntil))
      : "";
    setField("notice", notice);
    for (const node of $$('[data-field="notice"]')) {
      node.hidden = !record.canceled;
    }
  } else {
    setField("fact", "");
    setField("factTitle", "");
    setField("factIndex", "");
    setField("notice", "");
    for (const node of $$('[data-field="notice"]')) {
      node.hidden = true;
    }
  }

  // Экраны 4 и 5: N берется из debtPeriods контракта, а не считается здесь.
  // Экран 3 долг не показывает — он сгорел вместе с отменой.
  if (screen === SCREEN.DEBT_CATCHUP || screen === SCREEN.OVERDUE) {
    setField("debt", debt.toString());
  } else {
    setField("debt", "");
  }

  // Экран 5: причина последней неудачи и число попыток подряд. На экране 4
  // причины нет по определению — там не было ни одной неудачной попытки,
  // и подсказка там своя, про один период за нажатие.
  if (screen === SCREEN.OVERDUE) {
    const attempts = Number(record.failedAttempts);
    setField("attempt", record.failedAttempts.toString());
    setField("attemptText", screenField(SCREEN.OVERDUE, "attemptText", attempts));
    setField("reasonLabel", screenField(SCREEN.OVERDUE, "reasonLabel"));
    setField("reason", reasonField(record.lastFailureReason, "reason"));
    setField("hintLabel", screenField(SCREEN.OVERDUE, "hintLabel"));
    setField("hint", reasonField(record.lastFailureReason, "hint"));
  } else if (screen === SCREEN.DEBT_CATCHUP) {
    setField("attempt", "");
    setField("attemptText", "");
    setField("reasonLabel", "");
    setField("reason", "");
    setField("hintLabel", "");
    setField("hint", screenField(SCREEN.DEBT_CATCHUP, "hint"));
  } else {
    setField("attempt", "");
    setField("attemptText", "");
    setField("reasonLabel", "");
    setField("reason", "");
    setField("hintLabel", "");
    setField("hint", "");
  }

  applyActions(view);
}

// ============================================================================
// Отправка транзакций
// ============================================================================

/// Отправка вызова от имени выбранного аккаунта.
///
/// Подпись не нужна: anvil держит свои дефолтные аккаунты разблокированными,
/// поэтому достаточно `eth_sendTransaction` с полем `from`.
///
/// Перед отправкой делается `eth_call` теми же параметрами. Это не защита,
/// а способ показать причину: контракт откатывает вызов строкой из `require`,
/// и без предварительной проверки эта строка потерялась бы в неудачной
/// квитанции. Вызовы, которые контракт считает успешной работой — прекращение
/// по предельной просрочке и зафиксированная неудачная попытка, — через
/// предварительную проверку проходят и уходят в цепочку как положено.
async function sendCall(data, label) {
  const from = selectedAccount.address;

  setBusy(true);
  setStatus(`${label}: проверяем вызов…`);

  try {
    await ethCall(cfg.SUBSCRIPTION_ADDRESS, data, from);
  } catch (error) {
    setBusy(false);
    setStatus(`${label}: вызов не проходит — ${error.message}`);
    return null;
  }

  try {
    setStatus(`${label}: отправляем транзакцию…`);
    const hash = await rpc("eth_sendTransaction", [{ from, to: cfg.SUBSCRIPTION_ADDRESS, data }]);

    setStatus(`${label}: ждем блок…`);
    const receipt = await waitForReceipt(hash);

    if (!receipt) {
      setStatus(`${label}: квитанция не пришла за отведенное время, транзакция ${hash}`);
    } else if (receipt.status === "0x0") {
      setStatus(`${label}: транзакция откачена, ${hash}`);
    } else {
      setStatus(`${label}: готово, блок ${Number(BigInt(receipt.blockNumber))}`);
    }

    return receipt;
  } catch (error) {
    setStatus(`${label}: ошибка — ${error.message}`);
    return null;
  } finally {
    setBusy(false);
    await refresh();
  }
}

/// Ожидание квитанции. Anvil делает блок раз в секунду, так что опрос
/// с шагом в полсекунды укладывается в пару итераций.
async function waitForReceipt(hash) {
  const deadline = Date.now() + cfg.RECEIPT_TIMEOUT_MS;

  while (Date.now() < deadline) {
    const receipt = await rpc("eth_getTransactionReceipt", [hash]);
    if (receipt) return receipt;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  return null;
}

// ============================================================================
// Экспортируемые действия — точки подключения для разметки
// ============================================================================

/// Оформление подписки от имени выбранного аккаунта. Оформление и первое
/// списание — один вызов (раздел 8).
export async function subscribe() {
  return sendCall(SEL_SUBSCRIBE, "Оформление подписки");
}

/// Списание одного периода. Адрес подписки — тот, состояние которого показано
/// на экране; вызывающим может быть ЛЮБОЙ из трех аккаунтов, включая
/// постороннего. Это свойство pull-модели, и витрина существует в том числе
/// затем, чтобы его показать (раздел 10).
export async function charge(subscriber) {
  const target = subscriber || cfg.SUBSCRIBER_ADDRESS;
  return sendCall(callData(SEL_CHARGE, target), "Списание периода");
}

/// Отмена подписки. Отменить может только сам подписчик, поэтому вызов уходит
/// от имени выбранного аккаунта, а не по чужому адресу.
export async function cancel() {
  return sendCall(SEL_CANCEL, "Отмена подписки");
}

/// Смена выбранного аккаунта: меняется и просмотр, и отправитель транзакций.
export async function selectAccount(address) {
  const account = cfg.ACCOUNTS.find((a) => a.address.toLowerCase() === String(address).toLowerCase());
  if (!account) return;

  selectedAccount = account;

  const select = $("#account-select");
  if (select && select.value !== account.address) select.value = account.address;

  await refresh();
}

/// Перечитать состояние узла и перерисовать экран.
export async function refresh() {
  try {
    const view = await readView(cfg.SUBSCRIBER_ADDRESS);
    render(view);
    return view;
  } catch (error) {
    setStatus(`Не удалось прочитать состояние: ${error.message}`);
    return null;
  }
}

/// Текущее прочитанное состояние — на случай, если разметке понадобится
/// заглянуть в него из своего кода.
export function currentView() {
  return lastView;
}

/// Выбранный аккаунт.
export function currentAccount() {
  return selectedAccount;
}

// ============================================================================
// Запуск
// ============================================================================

/// Подключение обработчиков и первая отрисовка.
export async function init() {
  // Адрес контракта не заполнен — деплой-скрипт еще не отработал.
  if (/^0x0+$/.test(cfg.SUBSCRIPTION_ADDRESS)) {
    setStatus("Адрес контракта подписки в web/config.js не заполнен: запустите деплой-скрипт.");
  }

  const select = $("#account-select");
  if (select) {
    if (!select.options.length) {
      for (const account of cfg.ACCOUNTS) {
        const option = document.createElement("option");
        option.value = account.address;
        option.dataset.role = account.id;
        option.textContent = `${accountRoleLabel(account)} — ${account.address}`;
        select.appendChild(option);
      }
    }
    select.value = selectedAccount.address;
    select.addEventListener("change", () => selectAccount(select.value));
  }

  for (const node of $$("[data-action]")) {
    const action = node.getAttribute("data-action");
    node.addEventListener("click", () => {
      if (busy) return;
      if (action === "subscribe") subscribe();
      else if (action === "charge") charge(cfg.SUBSCRIBER_ADDRESS);
      else if (action === "cancel") cancel();
    });
  }

  // Тексты и факты — мягкая деградация, если соседние файлы недоступны.
  const [, loadedFacts] = await Promise.all([loadScreens(), loadFacts()]);
  facts = loadedFacts;

  if (!screensModule) {
    setStatus("Файл web/screens.js недоступен: экраны показываются без текстов.");
  }

  await refresh();

  // Опрос узла. Только чтение: витрина никогда не списывает сама,
  // автоматический исполнитель находится в нецелях. Опрос нужен потому,
  // что время идет само и оплаченный период истекает без участия человека.
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(() => {
    if (!busy) refresh();
  }, cfg.REFRESH_MS);
}

/// Останов опроса — на случай, если разметке понадобится погасить витрину.
export function stop() {
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = null;
}

// Автозапуск: разметке достаточно подключить модуль строкой
// <script type="module" src="./app.js"></script>.
if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => init());
  } else {
    init();
  }
}
