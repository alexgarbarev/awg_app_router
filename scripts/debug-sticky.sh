#!/bin/zsh
# debug-sticky v2 — изоляция на «правильном» сокете.
#
# Урок v1: новые сокеты при включённой защите открываются через tun
# (LOCAL 10.8.1.4), pf их не видит в упёртую, а сервер на :80 сам рвёт
# мусор — сигнал был испорчен.
#
# Здесь: сокет, ПРИНУДИТЕЛЬНО привязанный к физическому интерфейсу
# (именно так выглядит залипшее direct-соединение), к терпеливому серверу
# 1.1.1.1:53 (TCP слушает, молчит, сам не сбрасывает).
#
# Запуск: sudo scripts/debug-sticky.sh        (защита ВКЛЮЧЕНА, как в баге)
set -uo pipefail
TARGET=${1:-1.1.1.1:53}
HOST=${TARGET%%:*}; PORT=${TARGET##*:}

ALTQ="No ALTQ support in kernel
ALTQ related functions disabled"

echo "== 0. окружение =="
/sbin/route -n get default | grep -E 'interface|gateway'
DEFIF=$(echo "$(/sbin/route -n get default)" | awk '/interface:/ {print $2; exit}')
ENIP=$(ipconfig getifaddr "$DEFIF")
echo "default via $DEFIF ip=$ENIP"
[[ -z "$ENIP" ]] && { echo "нет IP на $DEFIF — выйди из туннеля роутом? стоп"; exit 1; }

cat >/tmp/sticky-client.py <<'PY'
import os, socket, sys, time
host, port, bindip = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket()
s.bind((bindip, 0))            # ПРИВЯЗКА к физ. интерфейсу — sticky-сценарий
s.settimeout(4)
try:
    s.connect((host, port))
except OSError as e:
    print("CONNECT-FAIL %s (не страшно, тогда хост другой)" % e); sys.exit(2)
lport = s.getsockname()[1]
open("/tmp/sticky-local.txt", "w").write("%s %d" % (bindip, lport))
print("LOCAL %s:%d -> %s:%d (bound %s)" % (bindip, lport, host, port, bindip), flush=True)
open("/tmp/sticky-wake", "w").close()
t0 = time.time()
while time.time() - t0 < 90:
    if os.path.getmtime("/tmp/sticky-wake") > t0:
        try:
            s.sendall(b"\xde\xad")
        except OSError as e:
            print("%.0fs SEND %s => DEAD" % (time.time()-t0, e), flush=True)
            sys.exit(0)
        try:
            d = s.recv(80)
            print("%.0fs ALIVE recv=%d" % (time.time()-t0, len(d)), flush=True)
        except socket.timeout:
            print("%.0fs ALIVE (silence)" % (time.time()-t0), flush=True)
        except OSError as e:
            print("%.0fs %s => DEAD" % (time.time()-t0, e), flush=True)
            sys.exit(0)
        open("/tmp/sticky-wake", "w").close()
    time.sleep(0.2)
print("END — жив 90 с, pf НЕ рвёт")
PY

pf_send() { python3 - >/dev/null 2>&1 <<'PY'
import os, time
os.utime("/tmp/sticky-wake", None)
PY
sleep 1.2; }

pf_load() { # $1 правило → pf (base + правило перед anchor)
python3 - "$1" >/tmp/pf-dbg.rules <<'PY2'
import sys
rule = sys.argv[1]
base = open("/etc/pf.conf").read().split("\n")
out, ins = [], False
for l in base:
    if not ins and l.startswith("anchor "):
        out.append(rule); ins = True
    out.append(l)
print("\n".join(out if ins else out + [rule]))
PY2
/sbin/pfctl -nf /tmp/pf-dbg.rules 2>/dev/null && /sbin/pfctl -f /tmp/pf-dbg.rules 2>/dev/null
}

echo; echo "== A. sticky-сокет (bound $ENIP) к $TARGET =="
python3 /tmp/sticky-client.py "$HOST" "$PORT" "$ENIP" & CLIENT=$!
sleep 2
read LADDR LPORT </tmp/sticky-local.txt
pf_send
echo "pf states по потоку:"
/sbin/pfctl -ss 2>/dev/null | grep -E "\b$LPORT\b|$HOST" || echo "  (нет — pf не отслеживает?)"

RULE="block return-rst out quick proto tcp from $ENIP port $LPORT to $HOST port $PORT"
echo; echo "== B. pfctl -k только (правила нет) =="
/sbin/pfctl -k $HOST 2>/dev/null; /sbin/pfctl -K $HOST 2>/dev/null
pf_send

echo; echo "== C. правило ЗАГРУЖЕНО, state не трогали =="
pf_load "$RULE" && echo "  loaded: $RULE" || echo "  LOAD FAILED"
pf_send

echo; echo "== D. state flush ПОСЛЕ правила =="
/sbin/pfctl -k $HOST 2>/dev/null; /sbin/pfctl -K $HOST 2>/dev/null
pf_send
pf_send

echo; echo "== E. restore =="
/sbin/pfctl -f /etc/pf.conf 2>/dev/null && echo "  pf restored"
kill $CLIENT 2>/dev/null

echo '
——— расшифровка (сасматривай строки ALIVE/DEAD по фазам) ———
A ALIVE, C DEAD            => правило работает сразу, kill не нужен
   => приложение: причина была в другом (порядок irrelevant)
C ALIVE + D DEAD          => порядок-баг: СНАЧАЛА правила, ПОТОМ pfctl -k
D ALIVE                    => pf слеп к этому трафику: нужен другой механизм
   (tun bounce / перезапуск приложения)
B DEAD                    => pf killStates сам по себе рвёт (маловероятно, но
   тогда flush + ладно, механизм проще)'
