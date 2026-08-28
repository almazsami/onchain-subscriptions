#!/usr/bin/env bash
#
# run.sh — стенд «Минута» одной командой.
#
# Делает то же, что README расписывает на три терминала: поднимает anvil,
# разворачивает контракты, поднимает статику и открывает витрину. Держится
# в терминале; Ctrl+C гасит оба фоновых процесса.
#
# Скрипт ничего не качает из сети сам, кроме зависимостей контрактов
# (подмодули или forge install) — установщики инструментов и правка профиля
# оболочки остаются решением человека.
#
# Логи узла, сборки и сервера — в .logs/ (каталог игнорируется гитом).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

RPC_PORT=8545
WEB_PORT=8000
RPC_URL="http://127.0.0.1:${RPC_PORT}"
WEB_URL="http://127.0.0.1:${WEB_PORT}/web/index.html"

# Версии совпадают с foundry.lock: если репозиторий скачан архивом, подмодулей
# нет и ставить зависимости приходится по имени и тегу.
DEP_FORGE_STD="foundry-rs/forge-std@v1.16.2"
DEP_OPENZEPPELIN="OpenZeppelin/openzeppelin-contracts@v5.7.0"

LOG_DIR="$ROOT/.logs"
ANVIL_LOG="$LOG_DIR/anvil.log"
WEB_LOG="$LOG_DIR/web.log"
BUILD_LOG="$LOG_DIR/build.log"
DEPLOY_LOG="$LOG_DIR/deploy.log"

ANVIL_PID=""
WEB_PID=""

if [ -t 1 ]; then B=$'\033[1m'; N=$'\033[0m'; else B=""; N=""; fi

step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s !!%s %s\n' "$B" "$N" "$*" >&2; }
die()  { printf '\n%s !!%s %s\n' "$B" "$N" "$*" >&2; exit 1; }

mkdir -p "$LOG_DIR"

# --- 1. Инструменты ---------------------------------------------------------

step "Проверяю инструменты"

foundry_missing=""
for tool in anvil forge cast; do
    command -v "$tool" >/dev/null 2>&1 || foundry_missing="$foundry_missing $tool"
done

if [ -n "$foundry_missing" ]; then
    {
        printf '\n%s !!%s Foundry не найден (нет:%s)\n\n' "$B" "$N" "$foundry_missing"
        printf '    Поставьте сами — скрипт запуска стенда не качает установщики\n'
        printf '    из сети и не правит профиль оболочки:\n\n'
        printf '      1) curl -L https://foundry.paradigm.xyz | bash\n'
        printf '      2) перезапустите терминал (или откройте новую вкладку),\n'
        printf '         чтобы подхватился ~/.foundry/bin в PATH\n'
        printf '      3) foundryup\n'
        printf '      4) forge --version — должна напечататься версия\n\n'
        printf '    Потом запустите ./run.sh заново.\n'
    } >&2
    exit 1
fi

# Витрина — статика без сборщиков, поэтому годится любой сервер, отдающий
# файлы из корня репозитория. python3 первый выбор, остальные — если его нет.
WEB_SERVER=()
WEB_SERVER_NAME=""
if command -v python3 >/dev/null 2>&1; then
    WEB_SERVER=(python3 -m http.server "$WEB_PORT" --bind 127.0.0.1)
    WEB_SERVER_NAME="python3 -m http.server"
elif command -v php >/dev/null 2>&1; then
    WEB_SERVER=(php -S "127.0.0.1:$WEB_PORT" -t "$ROOT")
    WEB_SERVER_NAME="php -S"
elif command -v ruby >/dev/null 2>&1; then
    WEB_SERVER=(ruby -run -e httpd "$ROOT" -p "$WEB_PORT" -b 127.0.0.1)
    WEB_SERVER_NAME="ruby -run -e httpd"
elif command -v busybox >/dev/null 2>&1; then
    WEB_SERVER=(busybox httpd -f -p "127.0.0.1:$WEB_PORT" -h "$ROOT")
    WEB_SERVER_NAME="busybox httpd"
fi

if [ ${#WEB_SERVER[@]} -eq 0 ]; then
    {
        printf '\n%s !!%s Нечем поднять статику: нет python3\n\n' "$B" "$N"
        printf '    Витрине нужен любой статический сервер из корня репозитория.\n'
        printf '    Подойдет любой из них — поставьте тот, что ближе:\n\n'
        printf '      python3 -m http.server 8000\n'
        printf '      php -S 127.0.0.1:8000\n'
        printf '      ruby -run -e httpd . -p 8000 -b 127.0.0.1\n\n'
        printf '    Скрипт использует первый найденный.\n'
    } >&2
    exit 1
fi

info "anvil, forge, cast — на месте"
info "статику отдаем через $WEB_SERVER_NAME"

# --- 2. Зависимости контрактов ----------------------------------------------

step "Проверяю зависимости контрактов"

dir_empty() { [ -z "$(ls -A "$1" 2>/dev/null || true)" ]; }

empty_deps=""
for dep_dir in lib/forge-std lib/openzeppelin-contracts; do
    dir_empty "$dep_dir" && empty_deps="$empty_deps $dep_dir"
done

if [ -n "$empty_deps" ]; then
    info "пусто:$empty_deps"
    if git rev-parse --git-dir >/dev/null 2>&1; then
        info "проект в git-репозитории — подтягиваю подмодули, нужна сеть"
        info "git submodule update --init --recursive"
        git submodule update --init --recursive \
            || warn "git submodule update завершился ошибкой"
    else
        # Архив с GitHub не содержит ни .git, ни содержимого подмодулей:
        # ставим те же версии напрямую, без submodule.
        install_deps=()
        case "$empty_deps" in *lib/forge-std*)           install_deps+=("$DEP_FORGE_STD") ;; esac
        case "$empty_deps" in *lib/openzeppelin-contracts*) install_deps+=("$DEP_OPENZEPPELIN") ;; esac
        info ".git нет — репозиторий скачан архивом, подмодулей в нем не бывает"
        info "ставлю зависимости через forge install, нужна сеть"
        info "forge install --no-git ${install_deps[*]}"
        forge install --no-git "${install_deps[@]}" \
            || warn "forge install завершился ошибкой"
    fi

    still_empty=""
    for dep_dir in lib/forge-std lib/openzeppelin-contracts; do
        dir_empty "$dep_dir" && still_empty="$still_empty $dep_dir"
    done
    [ -z "$still_empty" ] || die "Зависимости так и не подтянулись:$still_empty
    Проверьте сеть и доступ к github.com, либо склонируйте репозиторий
    заново вместе с подмодулями:

      git clone --recurse-submodules git@github.com:almazsami/onchain-subscriptions.git

    Скачивание архивом (Download ZIP) подмодули не приносит."
fi

info "lib/forge-std и lib/openzeppelin-contracts на месте"

# --- 3. Сборка --------------------------------------------------------------

step "Собираю контракты"
if ! forge build >"$BUILD_LOG" 2>&1; then
    warn "Сборка не прошла. Последние строки .logs/build.log:"
    tail -20 "$BUILD_LOG" >&2
    die "forge build завершился с ошибкой — стенд поднимать нечем.
    Полный вывод: .logs/build.log"
fi
info "forge build прошел, вывод в .logs/build.log"

# --- 4. Уборка за собой -----------------------------------------------------

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
    local code="${1:-$?}"
    trap - INT TERM EXIT
    printf '\n'
    step "Останавливаю стенд"
    stop_pid "$WEB_PID" "статический сервер"
    stop_pid "$ANVIL_PID" "узел anvil"
    info "логи остались в .logs/"
    exit "$code"
}

# Ctrl+C — это штатное завершение стенда, а не ошибка.
trap 'cleanup 0' INT TERM
trap cleanup EXIT

# --- 5. Порты от предыдущего запуска ----------------------------------------

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

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

# --- 6. Узел ----------------------------------------------------------------

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

# --- 7. Развертывание -------------------------------------------------------

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

# --- 8. Статика -------------------------------------------------------------

step "Поднимаю статический сервер"
: > "$WEB_LOG"
"${WEB_SERVER[@]}" >"$WEB_LOG" 2>&1 &
WEB_PID=$!
info "PID $WEB_PID, лог .logs/web.log"

ready=""
for _ in $(seq 1 40); do
    if port_open "$WEB_PORT"; then ready=1; break; fi
    kill -0 "$WEB_PID" 2>/dev/null || die "Статический сервер упал, смотрите .logs/web.log"
    sleep 0.3
done
[ -n "$ready" ] || die "Статический сервер не поднялся, смотрите .logs/web.log"
info "витрина отдается на $WEB_URL"

# --- 9. Браузер -------------------------------------------------------------

step "Открываю витрину"
if command -v open >/dev/null 2>&1; then
    open "$WEB_URL" >/dev/null 2>&1 || warn "браузер не открылся, откройте вручную"
elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$WEB_URL" >/dev/null 2>&1 || warn "браузер не открылся, откройте вручную"
else
    info "браузер открыть нечем — откройте вручную"
fi
info "$WEB_URL"

# --- 10. Ждем ---------------------------------------------------------------

printf '\n'
step "Стенд поднят. Сценарий демонстрации — в README, раздел «Пятиминутный сценарий»."
info "Ctrl+C — остановить стенд и убрать за собой."
printf '\n'

while :; do
    kill -0 "$ANVIL_PID" 2>/dev/null || { warn "узел anvil остановился сам"; break; }
    kill -0 "$WEB_PID"   2>/dev/null || { warn "статический сервер остановился сам"; break; }
    sleep 1
done
