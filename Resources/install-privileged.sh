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

mkdir -p /usr/local/lib/awgapprouter /etc/awgapprouter

# бинари (ad-hoc подпись пересоздаём на месте — cp сохраняет, но на всякий)
install -m 0755 -o root -g wheel "$RES/awgapprouterd" /usr/local/lib/awgapprouter/awgapprouterd
install -m 0755 -o root -g wheel "$RES/awgapprouter-box" /usr/local/lib/awgapprouter/awgapprouter-box
codesign --force --sign - /usr/local/lib/awgapprouter/awgapprouterd
codesign --force --sign - /usr/local/lib/awgapprouter/awgapprouter-box

install -m 0644 -o root -g wheel "$RES/com.awgapprouter.daemon.plist" \
    /Library/LaunchDaemons/com.awgapprouter.daemon.plist

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

launchctl bootout system/com.awgapprouter.daemon 2>/dev/null || true
# bootout асинхронный: bootstrap сразу может вернуть "already loaded" —retry
BOOT_OK=no
for _ in 1 2 3 4 5 6; do
    if launchctl bootstrap system /Library/LaunchDaemons/com.awgapprouter.daemon.plist 2>/dev/null; then
        BOOT_OK=yes; break
    fi
    sleep 0.5
done
if [ "$BOOT_OK" != yes ]; then
    # возможно уже был загружен и жив — перезапускаем, иначе это настоящая ошибка
    launchctl print system/com.awgapprouter.daemon >/dev/null 2>&1 || exit 1
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
