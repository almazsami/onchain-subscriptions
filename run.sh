#!/usr/bin/env bash
#
# run.sh — стенд «Минута» одной командой.
#
# Делает то же, что README расписывает на три терминала: поднимает anvil,
# разворачивает контракты, поднимает статику и открывает витрину. Держится
# в терминале; Ctrl+C гасит оба фоновых процесса.
#
# Логи узла и сервера — в .logs/ (каталог игнорируется гитом).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

RPC_PORT=8545
WEB_PORT=8000
RPC_URL="http://127.0.0.1:${RPC_PORT}"
WEB_URL="http://127.0.0.1:${WEB_PORT}/web/index.html"

LOG_DIR="$ROOT/.logs"
ANVIL_LOG="$LOG_DIR/anvil.log"
WEB_LOG="$LOG_DIR/web.log"
DEPLOY_LOG="$LOG_DIR/deploy.log"

ANVIL_PID=""
WEB_PID=""

if [ -t 1 ]; then B=$'\033[1m'; N=$'\033[0m'; else B=""; N=""; fi

step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s !!%s %s\n' "$B" "$N" "$*" >&2; }
die()  { printf '\n%s !!%s %s\n' "$B" "$N" "$*" >&2; exit 1; }

# --- 7. Уборка за собой -----------------------------------------------------

stop_pid() {
    local pid="$1" name="$2" i
    [ -n "$pid" ] || return 0
    # По Ctrl+C сигнал приходит всей группе процессов, и фоновые обычно
    # успевают умереть сами — тогда просто говорим об этом, а не молчим.
    if ! kill -0 "$pid" 2>/dev/null; then info "$name уже остановлен"; return 0; fi
    kill "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || { info "$name остановлен"; return 0; }
        sleep 0.3
    done
    kill -9 "$pid" 2>/dev/null || true
    info "$name остановлен принудительно"
}

cleanup() {
    trap - INT TERM EXIT
    printf '\n'
    step "Останавливаю стенд"
    stop_pid "$WEB_PID" "статический сервер"
    stop_pid "$ANVIL_PID" "узел anvil"
    info "логи остались в .logs/"
    exit 0
}

trap cleanup INT TERM EXIT

# --- 1. Инструменты ---------------------------------------------------------

step "Проверяю инструменты"

missing=""
for tool in anvil forge cast python3; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done

if [ -n "$missing" ]; then
    printf '\n%s !!%s Не хватает:%s\n' "$B" "$N" "$missing" >&2
    case "$missing" in
        *anvil*|*forge*|*cast*)
            printf '    anvil, forge и cast ставятся вместе с Foundry.\n' >&2 ;;
    esac
    case "$missing" in
        *python3*) printf '    python3 нужен для статического сервера витрины.\n' >&2 ;;
    esac
    trap - INT TERM EXIT
    exit 1
fi
info "anvil, forge, cast, python3 — на месте"

if [ ! -f lib/forge-std/src/Script.sol ]; then
    die "Подмодули не инициализированы. Выполните:
    git submodule update --init --recursive"
fi

mkdir -p "$LOG_DIR"

# --- 2. Порты от предыдущего запуска ----------------------------------------

free_port() {
    local port="$1" name="$2" pids pid
    command -v lsof >/dev/null 2>&1 || return 0
    pids="$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null || true)"
    [ -n "$pids" ] || return 0
    step "Порт $port занят ($name) — гашу процессы предыдущего запуска"
    for pid in $pids; do
        info "PID $pid"
        kill "$pid" 2>/dev/null || true
    done
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pids="$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null || true)"
        [ -n "$pids" ] || return 0
        sleep 0.3
    done
    for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 0.3
    pids="$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null || true)"
    [ -z "$pids" ] || die "Порт $port освободить не удалось, занят: $pids"
}

free_port "$RPC_PORT" "узел"
free_port "$WEB_PORT" "статика"

# --- 3. Узел ----------------------------------------------------------------

step "Поднимаю узел anvil (блок раз в секунду)"
: > "$ANVIL_LOG"
anvil --block-time 1 --port "$RPC_PORT" >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
info "PID $ANVIL_PID, лог .logs/anvil.log"

ready=""
for _ in $(seq 1 60); do
    if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then ready=1; break; fi
    kill -0 "$ANVIL_PID" 2>/dev/null || die "anvil упал при старте, смотрите .logs/anvil.log"
    sleep 0.3
done
[ -n "$ready" ] || die "Узел не ответил за 18 секунд, смотрите .logs/anvil.log"
info "узел отвечает на $RPC_URL"

# --- 4. Развертывание -------------------------------------------------------

step "Разворачиваю контракты"
if ! forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast >"$DEPLOY_LOG" 2>&1; then
    warn "Деплой не прошел. Последние строки .logs/deploy.log:"
    tail -20 "$DEPLOY_LOG" >&2
    die "Развертывание не удалось"
fi

token_addr="$(grep -oE 'MockUSDT[[:space:]]+0x[0-9a-fA-F]{40}' "$DEPLOY_LOG" | head -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)"
sub_addr="$(grep -oE 'Subscription[[:space:]]+0x[0-9a-fA-F]{40}' "$DEPLOY_LOG" | head -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)"

if [ -n "$token_addr" ] && [ -n "$sub_addr" ]; then
    info "MockUSDT      $token_addr"
    info "Subscription  $sub_addr"
else
    warn "Адреса из вывода деплоя не вычитались, смотрите .logs/deploy.log"
fi

# Витрина читает адреса из web/config.js и наружу не ходит: если узел уже
# что-то видел, адреса разъедутся и стенд будет выглядеть сломанным.
for pair in "MOCK_USDT_ADDRESS:$token_addr" "SUBSCRIPTION_ADDRESS:$sub_addr"; do
    name="${pair%%:*}"; got="${pair#*:}"
    [ -n "$got" ] || continue
    want="$(grep -oE "${name}[[:space:]]*=[[:space:]]*\"0x[0-9a-fA-F]{40}\"" web/config.js | grep -oE '0x[0-9a-fA-F]{40}' | head -1 || true)"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
        warn "web/config.js: $name = $want, а развернулось $got — перенесите адрес руками"
    fi
done

# --- 5. Статика -------------------------------------------------------------

step "Поднимаю статический сервер"
: > "$WEB_LOG"
python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 >"$WEB_LOG" 2>&1 &
WEB_PID=$!
info "PID $WEB_PID, лог .logs/web.log"

ready=""
for _ in $(seq 1 40); do
    if python3 - "$WEB_PORT" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.3)
s.close()
PY
    then ready=1; break; fi
    kill -0 "$WEB_PID" 2>/dev/null || die "Статический сервер упал, смотрите .logs/web.log"
    sleep 0.3
done
[ -n "$ready" ] || die "Статический сервер не поднялся, смотрите .logs/web.log"
info "витрина отдается на $WEB_URL"

# --- 6. Браузер -------------------------------------------------------------

step "Открываю витрину"
if command -v open >/dev/null 2>&1; then
    open "$WEB_URL" >/dev/null 2>&1 || warn "браузер не открылся, откройте вручную"
elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$WEB_URL" >/dev/null 2>&1 || warn "браузер не открылся, откройте вручную"
else
    info "браузер открыть нечем — откройте вручную"
fi
info "$WEB_URL"

# --- 7. Ждем -----------------------------------------------------------------

printf '\n'
step "Стенд поднят. Сценарий демонстрации — в README, раздел «Пятиминутный сценарий»."
info "Ctrl+C — остановить стенд и убрать за собой."
printf '\n'

while :; do
    kill -0 "$ANVIL_PID" 2>/dev/null || { warn "узел anvil остановился сам"; break; }
    kill -0 "$WEB_PID"   2>/dev/null || { warn "статический сервер остановился сам"; break; }
    sleep 1
done
