#!/bin/zsh
# Полное удаление привилегированной части + снятие всех наших pf-артефактов.
set -euo pipefail
launchctl bootout system/com.awgapprouter.daemon 2>/dev/null || true
launchctl bootout system/com.approuter.daemon 2>/dev/null || true   # следы до ренойма
rm -f /Library/LaunchDaemons/com.awgapprouter.daemon.plist
rm -f /Library/LaunchDaemons/com.approuter.daemon.plist
rm -rf /usr/local/lib/awgapprouter
rm -rf /usr/local/lib/approuter
# tun может остаться до смерти процесса — убираем маршруты штатно
pkill -x awgapprouter-box 2>/dev/null || true
pkill -x approuter-box 2>/dev/null || true
# если наш аварийный блок всё ещё активен — вернуть родной ruleset
if pfctl -sr 2>/dev/null | grep -q "block drop out quick inet"; then
  pfctl -f /etc/pf.conf
  echo "pf: снят аварийный блок, загружен родной /etc/pf.conf"
fi
rm -f /etc/awgapprouter/pf-active.rules /etc/awgapprouter/enabled
# в profile.conf — приватный ключ: не оставлять нигде
rm -rf /etc/awgapprouter
rm -rf /etc/approuter 2>/dev/null || true                      # до ренойма
rm -f /var/log/awgapprouter-daemon.log /var/log/awgapprouter-box.log
rm -f /var/log/approuter-daemon.log /var/log/approuter-box.log 2>/dev/null || true
echo "AWG App Router: демон удалён, /etc/awgapprouter (включая ключ) удалён"
