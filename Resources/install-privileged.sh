#!/bin/zsh
# Установка привилегированной части. Запускается через osascript "with administrator
# privileges" из приложения; скрипт лежит внутри AWGAppRouter.app/Contents/Resources —
# определяем расположение бандла по своему пути.
set -euo pipefail
# GUI при установке копирует скрипт в /tmp (в карантином/Translocation бандле
# exec запрещён) и передаёт настоящий ресурсный каталог через AWG_RES
RES="${AWG_RES:-$(cd "$(dirname "$0")" && pwd)}"
APP="$(dirname "$(dirname "$RES")")"
echo "установка из: $APP"

# --- ренойм AppRouter → AWG App Router (28.11): выносим старый неймспейс ---
# старый демон снимается до старта нового (два mach-сервиса не воюют);
# старый box — единственный осиротевший туннель — доубивается заодно
launchctl bootout system/com.approuter.daemon 2>/dev/null || true
pkill -TERM -x approuter-box 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.approuter.daemon.plist

# --- карантин ---
# zip из Firefox/Chrome: карантин на всех файлах бандла; install/cp переносит
# его на plist и бинари — launchd отказывается бустрапить карантинный plist
# (стабильный "Bootstrap failed: 5: Input/output error"), а AMFI убивает
# карантинный бинарь. Снимаем: сначала с бандла (если он не на read-only
# translocation-монте — тогда не получится и снимаем с копий ниже).
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

mkdir -p /usr/local/lib/awgapprouter /etc/awgapprouter

# Снимаем текущий демон ДО перезаписи бинарей: писать в исполняемый файл
# живого процесса — гонка (ETXTBSY/полускопированный бинарь).
launchctl bootout system/com.awgapprouter.daemon 2>/dev/null || true
# bootout асинхронный и с дочерним box может занимать секунды: bootstrap в это
# время стабильно отдаёт "Input/output error". Ждём фактического исчезновения
# сервиса (до 10 с).
for _ in $(seq 1 20); do
    launchctl print system/com.awgapprouter.daemon >/dev/null 2>&1 || break
    sleep 0.5
done

install -m 0644 -o root -g wheel "$RES/com.awgapprouter.daemon.plist" \
    /Library/LaunchDaemons/com.awgapprouter.daemon.plist
install -m 0755 -o root -g wheel "$RES/awgapprouterd" /usr/local/lib/awgapprouter/awgapprouterd
install -m 0755 -o root -g wheel "$RES/awgapprouter-box" /usr/local/lib/awgapprouter/awgapprouter-box
# бинари: подпись из бандла переезжает нетронутой (install сохраняет байты).
# НЕ переподписываем безусловно: codesign другой версии macOS переписывает
# подпись иначе → лишние различия установленного от бандла. Только если битая.
codesign --verify /usr/local/lib/awgapprouter/awgapprouterd 2>/dev/null \
    || codesign --force --sign - /usr/local/lib/awgapprouter/awgapprouterd
codesign --verify /usr/local/lib/awgapprouter/awgapprouter-box 2>/dev/null \
    || codesign --force --sign - /usr/local/lib/awgapprouter/awgapprouter-box
# целевые пути — без карантина, даже если источник не удалось очистить
xattr -d com.apple.quarantine /Library/LaunchDaemons/com.awgapprouter.daemon.plist \
    /usr/local/lib/awgapprouter/awgapprouterd /usr/local/lib/awgapprouter/awgapprouter-box \
    2>/dev/null || true

# посев состояние: apps/servers из GUI-стора (если есть). Серверы сеются
# ВЫКЛЮЧЕННЫМИ — это тюрьма: приложения без сети, остальное direct. Включает
# сервер пользователь сам (или «Запустить»).
# do shell script работает от root — ищем домашнюю каталогу консольного пользователя
CONSOLE="$(stat -f%Su /dev/console 2>/dev/null || echo root)"
case "$CONSOLE" in root|"") CONSOLE="${SUDO_USER:-}" ;; esac
GUI="/Users/$CONSOLE/Library/Application Support/AWGAppRouter"
if [ ! -f "$GUI/state.json" ]; then
    # GUI ещё не мигрировал каталог после ренойма — читаем старый напрямую
    GUI_OLD="/Users/$CONSOLE/Library/Application Support/AppRouter"
    [ -f "$GUI_OLD/state.json" ] && GUI="$GUI_OLD"
fi
# намерение пользователя — в mode-файле (новом; при первом запуске после
# ренойма — в старом /etc/approuter). Исторические значения:
# "off"|"tunnel" (старое) и "running"|"off" (нынешний демон). off = выключено,
# всё остальное = туннель был включён → сохраняем серверы включёнными.
MODE=running
AUTO=no
MODESRC=""
if [ -f /etc/awgapprouter/mode ]; then
    MODESRC=/etc/awgapprouter/mode
elif [ -f /etc/approuter/mode ]; then
    MODESRC=/etc/approuter/mode
fi
if [ -n "$MODESRC" ]; then
    case "$(tr -d '[:space:]' < "$MODESRC")" in
        off) MODE=off ;;
        *)   AUTO=yes ;;
    esac
fi
if [ -f "$GUI/state.json" ]; then
    python3 - "$GUI/state.json" "$AUTO" <<'PY'
import json, os, sys
state_path, auto = sys.argv[1], sys.argv[2]
try:
    s = json.load(open(state_path))
    apps = s.get("apps", [])
    servers = s.get("servers") or []
    # миграция v1: один профиль -> один сервер
    if not servers and (s.get("profileText") or ""):
        servers = [{"id": "srv-1", "name": s.get("profileName") or "server-1",
                   "confText": s["profileText"], "enabled": False, "paid": False}]
        for a in apps:
            if not a.get("serverID"):
                a["serverID"] = "srv-1"
    for a in apps:
        a.setdefault("serverID", "")
    autoconnect = (auto == "yes")
    for sv in servers:
        sv.setdefault("paid", False)
        # enabled: Уважаем выбор пользователя из GUI-стора; ключ отсутствовал
        # (миграция v1) — включаем, если туннель был жив
        if "enabled" not in sv:
            sv["enabled"] = autoconnect
    open("/etc/awgapprouter/apps.json", "w").write(json.dumps(apps))
    open("/etc/awgapprouter/servers.json", "w").write(json.dumps(servers))
    os.chmod("/etc/awgapprouter/servers.json", 0o600)
    # «автоподключение при старте» из Настроек: демон сам прочтёт флаг на boot
    if s.get("autoConnect"):
        open("/etc/awgapprouter/autoconnect", "w").write("1")
    print("seed: apps=%d servers=%d autoconnect=%s" % (len(apps), len(servers), bool(s.get("autoConnect"))))
except Exception as e:
    print("seed skip:", e)
PY
fi
echo -n "$MODE" > /etc/awgapprouter/mode
chmod 0644 /etc/awgapprouter/mode /etc/awgapprouter/apps.json 2>/dev/null || true
chmod 0750 /etc/awgapprouter

# (bootout уже выполнен выше, до перезаписи бинарей; сервис снят)
BOOT_OK=no
BOOT_ERR=""
for _ in 1 2 3 4 5 6; do
    if BOOT_ERR="$(launchctl bootstrap system /Library/LaunchDaemons/com.awgapprouter.daemon.plist 2>&1)"; then
        BOOT_OK=yes; break
    fi
    sleep 0.5
done
if [ "$BOOT_OK" != yes ]; then
    # возможно уже был загружен и жив — перезапускаем, иначе это настоящая ошибка
    if ! launchctl print system/com.awgapprouter.daemon >/dev/null 2>&1; then
        echo "bootstrap не удался: $BOOT_ERR"
        echo "--- launchd print ---"
        launchctl print system/com.awgapprouter.daemon 2>&1 | head -15 || true
        echo "--- daemon log ---"
        tail -8 /var/log/awgapprouter-daemon.log 2>/dev/null || echo "(лог пуст/нет)"
        exit 1
    fi
    launchctl kickstart -k system/com.awgapprouter.daemon 2>/dev/null || true
fi

# старый неймспейс долой: каталоги, бинари, логи (состояние уже мигрировано выше)
rm -rf /usr/local/lib/approuter /etc/approuter 2>/dev/null || true
rm -f /var/log/approuter-daemon.log /var/log/approuter-box.log 2>/dev/null || true

if [ "$AUTO" = yes ]; then
    echo "демон установлен и запущен (режим: ${MODE}, серверы подключены — был туннель)"
else
    echo "демон установлен и запущен (режим: ${MODE}, серверы выключены = защита)"
fi
