#!/bin/bash
# Установка AI Recorder на свой Mac (E5.2): скачивает библиотеку sherpa-onnx и модели,
# собирает приложение из исходников и копирует его в /Applications (без прав — в ~/Applications).
# Приложение собирается на этом Mac, поэтому Gatekeeper его не блокирует.
# Повторный запуск ничего не перекачивает и не пересобирает без необходимости.
# Совместим с bash 3.2 (версия macOS по умолчанию).
#
# Для проверок: AIRECORDER_SUPPORT_DIR (модели и source-path), AIRECORDER_APPS_DIR (папка установки).
set -euo pipefail

cd "$(dirname "$0")"
SRC_DIR="$(pwd -P)"
SUPPORT_DIR="${AIRECORDER_SUPPORT_DIR:-$HOME/Library/Application Support/AI Recorder}"
LOG_DIR="$HOME/Library/Logs/AI Recorder"
LOG="$LOG_DIR/install.log"
APP_NAME="AIRecorder.app"
BUILT_APP="$SRC_DIR/build/$APP_NAME"
STAMP="$SRC_DIR/build/.install-stamp"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TOTAL=5
STEP=0
STEP_NAME=""
LINE_OPEN=0
START=$(date +%s)

mkdir -p "$LOG_DIR"
: > "$LOG"
echo "AI Recorder install.sh, $(date), $SRC_DIR" >> "$LOG"

# --- печать шагов: «[i/5] название .......... статус» ---

dots() {   # точки до 44-го символа
    local len
    len=$(printf '%s' "$1" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
    local n=$((44 - len))
    [ "$n" -lt 3 ] && n=3
    printf '%*s' "$n" '' | tr ' ' '.'
}

step_begin() {
    STEP=$1
    STEP_NAME=$2
    printf '[%s/%s] %s %s ' "$STEP" "$TOTAL" "$STEP_NAME" "$(dots "$STEP_NAME")"
    LINE_OPEN=1
    echo "== [$STEP/$TOTAL] $STEP_NAME" >> "$LOG"
}

# Строка внутри шага (например, «скачиваю …»): закрывает строку шага, если она открыта.
step_note() {
    if [ "$LINE_OPEN" = 1 ]; then printf '\n'; LINE_OPEN=0; fi
    echo "      $1"
}

step_end() {
    if [ "$LINE_OPEN" = 1 ]; then
        echo "$1"
    else
        printf '[%s/%s] %s %s %s\n' "$STEP" "$TOTAL" "$STEP_NAME" "$(dots "$STEP_NAME")" "$1"
    fi
    LINE_OPEN=0
    echo "== [$STEP/$TOTAL] $1" >> "$LOG"
}

# Остановка с номером шага и ненулевым кодом.
fail() {
    if [ "$STEP" -gt 0 ]; then
        step_end "ошибка"
        echo ""
        echo "Ошибка на шаге $STEP из $TOTAL ($STEP_NAME): $1" >&2
    else
        echo "Ошибка: $1" >&2
    fi
    echo "Ошибка: $1" >> "$LOG"
    echo "Подробности: $LOG" >&2
    trap - EXIT
    exit "${2:-1}"
}

# Непредвиденная ошибка (set -e) тоже называет шаг.
on_exit() {
    local code=$?
    [ "$code" = 0 ] && return
    if [ "$LINE_OPEN" = 1 ]; then printf '\n'; fi
    echo "Установка прервана на шаге $STEP из $TOTAL ($STEP_NAME), код $code. Подробности: $LOG" >&2
}
trap on_exit EXIT

version_ge() {   # $1 >= $2, версии вида 13.3 или 14.6.1
    local IFS=.
    local a=($1) b=($2) i x y
    for i in 0 1 2; do
        x=${a[$i]:-0}; y=${b[$i]:-0}
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 0
}

# Запускает скрипт загрузки: stdout читается построчно (строки «скачиваю» видны), stderr
# (полоска загрузки curl и ошибки) идёт прямо в терминал. Статус шага — в FETCH_STATUS:
# «готово», если что-то скачано, иначе «есть».
fetch_step() {   # скрипт
    local marker code
    marker="$(mktemp)"
    set +e
    "$1" | while IFS= read -r line; do
        echo "$line" >> "$LOG"
        case "$line" in
            скачиваю*) echo 1 > "$marker"; step_note "$line" ;;
        esac
    done
    code=${PIPESTATUS[0]}
    set -e
    # step_note работал в подоболочке: строка шага уже закрыта, если что-то скачивалось
    if [ -s "$marker" ]; then LINE_OPEN=0; FETCH_STATUS="готово"; else FETCH_STATUS="есть"; fi
    rm -f "$marker"
    if [ "$code" != 0 ]; then
        fail "скрипт $(basename "$1") завершился с кодом $code"
    fi
}

# --- проверки перед стартом ---

echo "Установка AI Recorder"
echo ""
if [ "$(uname -m)" != "arm64" ]; then
    fail "Нужен Mac на Apple Silicon (M1 или новее). На Mac с Intel приложение не работает."
fi
MACOS="$(sw_vers -productVersion)"
# Приложение работает на 13.3+, но собрать его можно только Swift 6, а ему нужна macOS 14.5+
if ! version_ge "$MACOS" "14.5"; then
    fail "Нужна macOS 14.5 или новее, у вас $MACOS. Обновите macOS и запустите install.sh снова."
fi
FREE_KB=$(df -k "$HOME" | awk 'NR==2 {print $4}')
if [ "${FREE_KB:-0}" -lt 2000000 ]; then
    echo "Внимание: свободно меньше 2 ГБ, установка может не поместиться."
fi

# --- [1/5] инструменты разработчика ---

step_begin 1 "Инструменты разработчика"
if ! xcode-select -p >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
    step_end "ошибка"
    xcode-select --install >/dev/null 2>&1 || true
    echo ""
    echo "Подтвердите установку инструментов в открывшемся окне, после неё запустите install.sh снова."
    trap - EXIT
    exit 1
fi
SWIFT_VERSION="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
echo "swift $SWIFT_VERSION, $(xcode-select -p)" >> "$LOG"
# Код собирается только Swift 6+ (Xcode 16 или Command Line Tools 16, им нужна macOS 14.5+):
# Swift 5.10 падает на проверках многопоточности в RecorderController
if [ -z "$SWIFT_VERSION" ] || ! version_ge "$SWIFT_VERSION" "6.0"; then
    fail "нужен Swift 6 или новее, у вас ${SWIFT_VERSION:-неизвестно}. Обновите macOS до 14.5 или новее, затем инструменты: Системные настройки → Основные → Обновление ПО."
fi
if ! xcrun --find actool >/dev/null 2>&1; then
    step_note "Внимание: нет actool (он есть только в полном Xcode). Значок в уведомлениях"
    step_note "может не показываться, всё остальное работает. Установка продолжается."
fi
step_end "есть"

# --- [2/5] библиотека sherpa-onnx ---

step_begin 2 "Библиотека sherpa-onnx (около 9 МБ)"
fetch_step "$SRC_DIR/scripts/fetch-sherpa-onnx.sh"
step_end "$FETCH_STATUS"

# --- [3/5] модели ---

step_begin 3 "Модели (около 610 МБ)"
export AIRECORDER_MODELS_DIR="$SUPPORT_DIR/Models"
fetch_step "$SRC_DIR/scripts/fetch-models.sh"
step_end "$FETCH_STATUS"

# --- [4/5] сборка ---

# Отпечаток всего, от чего зависит сборка: если он не изменился и приложение собрано, сборку пропускаем.
fingerprint() {
    {
        { find Sources Resources scripts -type f ! -name .DS_Store; ls Package.swift Package.resolved 2>/dev/null || true; } \
            | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done
        cat Vendor/sherpa-onnx/lib/.version 2>/dev/null || true
        swift --version 2>&1
    } | shasum -a 256 | cut -d' ' -f1
}

step_begin 4 "Сборка приложения"
PRINT="$(fingerprint)"
if [ -d "$BUILT_APP" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$PRINT" ]; then
    step_end "есть"
else
    rm -f "$STAMP"
    step_note "первая сборка занимает несколько минут"
    set +e
    # Полный вывод в журнал, на экране только текущая строка прогресса swift
    "$SRC_DIR/scripts/build-app.sh" 2>&1 | while IFS= read -r line; do
        echo "$line" >> "$LOG"
        if [ -t 1 ]; then
            printf '\r\033[K      %s' "${line:0:70}"
        fi
    done
    code=${PIPESTATUS[0]}
    set -e
    [ -t 1 ] && printf '\r\033[K'
    if [ "$code" != 0 ]; then
        step_end "ошибка"
        echo ""
        echo "Последние 20 строк журнала:"
        tail -n 20 "$LOG"
        echo ""
        echo "Ошибка на шаге 4 из $TOTAL (сборка), код $code. Полный журнал: $LOG" >&2
        trap - EXIT
        exit 1
    fi
    echo "$PRINT" > "$STAMP"
    step_end "готово"
fi

# --- [5/5] установка ---

cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

# Куда ставить: туда, где уже стоит прежняя версия, иначе /Applications, без прав ~/Applications
if [ -n "${AIRECORDER_APPS_DIR:-}" ]; then
    APPS_DIR="$AIRECORDER_APPS_DIR"
elif [ -d "$HOME/Applications/$APP_NAME" ] && [ ! -d "/Applications/$APP_NAME" ]; then
    APPS_DIR="$HOME/Applications"
elif [ -w /Applications ]; then
    APPS_DIR="/Applications"
else
    APPS_DIR="$HOME/Applications"
fi
DEST="$APPS_DIR/$APP_NAME"

# Запущенные копии AI Recorder: pid и путь к .app
running_copies() {
    ps -axo pid=,comm= | sed -n 's|^ *\([0-9][0-9]*\) \(.*\.app\)/Contents/MacOS/AIRecorder$|\1 \2|p'
}

step_begin 5 "Установка в $APPS_DIR"
OTHER=""
OURS=""
while read -r pid path; do
    [ -z "$pid" ] && continue
    if [ "$path" = "$DEST" ]; then OURS="$pid"; else OTHER="$path"; fi
done <<EOF
$(running_copies)
EOF

UPDATED=0
if [ -d "$DEST" ] && [ "$(cdhash "$DEST")" = "$(cdhash "$BUILT_APP")" ]; then
    INSTALL_STATUS="есть"
else
    if [ -n "$OURS" ]; then
        step_note "закрываю прежнюю версию"
        osascript -e "tell application \"$DEST\" to quit" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            kill -0 "$OURS" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$OURS" 2>/dev/null; then
            fail "AI Recorder не закрылся (возможно, идёт запись). Остановите запись, выйдите из приложения и запустите install.sh снова."
        fi
    fi
    mkdir -p "$APPS_DIR" || fail "не удалось создать папку $APPS_DIR"
    rm -rf "$DEST.new"
    ditto "$BUILT_APP" "$DEST.new" || fail "не удалось скопировать приложение в $APPS_DIR"
    rm -rf "$DEST"
    mv "$DEST.new" "$DEST"
    codesign --verify --strict "$DEST" >> "$LOG" 2>&1 || fail "подпись скопированного приложения не проходит проверку"
    # Центр уведомлений и Spotlight должны видеть установленную копию, а не папку сборки
    "$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
    UPDATED=1
    INSTALL_STATUS="готово"
fi

mkdir -p "$SUPPORT_DIR"
echo "$SRC_DIR" > "$SUPPORT_DIR/source-path"   # для «Скопировать команду» в окне обновлений

if [ -n "$OTHER" ]; then
    step_note "Запущена другая копия AI Recorder: $OTHER"
    step_note "Выйдите из неё и откройте $DEST."
else
    open "$DEST" || fail "не удалось открыть $DEST"
fi
step_end "$INSTALL_STATUS"

if [ "$UPDATED" = 1 ] && [ -z "$OTHER" ]; then
    # Новая сборка: macOS привязывает разрешения к подписи, их нужно выдать (заново)
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
fi

ELAPSED=$(( $(date +%s) - START ))
echo "Готово за $((ELAPSED / 60)) мин $((ELAPSED % 60)) с" >> "$LOG"

echo ""
echo "Установка завершена: $DEST"
echo ""
echo "Дальше:"
echo "  1. Разрешения. Системные настройки → Конфиденциальность и безопасность →"
echo "     «Запись экрана и системного звука»: включите AI Recorder (установщик открыл"
echo "     этот раздел). Микрофон macOS спросит при первой записи."
echo "     После выдачи разрешения на запись экрана перезапустите приложение."
echo "  2. Запись. Значок волны в строке меню → «Начать запись» (⌘R)."
echo "  3. Результат. Записи и расшифровки лежат в ~/Documents/AI Recorder."
echo ""
echo "Время установки: $((ELAPSED / 60)) мин $((ELAPSED % 60)) с. Журнал: $LOG"

# Уведомление придёт от имени Терминала (или Script Editor), а не с значком приложения: это нормально
osascript -e 'display notification "Приложение в строке меню, записи в ~/Documents/AI Recorder" with title "AI Recorder установлен"' >/dev/null 2>&1 || true

trap - EXIT
exit 0
