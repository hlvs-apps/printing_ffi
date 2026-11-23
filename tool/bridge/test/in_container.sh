#!/usr/bin/env bash
# Runs inside a Debian/Ubuntu container (see run_bridge_test.sh): build and
# install the bridge package, then check it end to end with only the USB
# backend stubbed: queue creation + page size, LAN token auth, and a JPEG
# through the real filter chain (imagetoraster -> rastertogutenprint).
set -euo pipefail
PORT=${BRIDGE_TEST_PORT:-1631}
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends cups-daemon cups-client cups-filters \
  printer-driver-gutenprint avahi-daemon libcups2-dev gcc libc6-dev dpkg-dev qrencode \
  iproute2 ca-certificates >/dev/null

rm -rf /work && cp -a /src /work && cd /work
bash tool/bridge/build_bridge_deb.sh /work/out
dpkg -i /work/out/fotobox-print-bridge_*.deb

echo '== installed'
id fotobox-print
test -s /etc/fotobox-print-bridge/token
grep -q 'Require user @SYSTEM' /etc/cups/cupsd.conf
test -e /etc/cups/cupsd.conf.fotobox-orig
test -e /etc/avahi/services/fotobox-print-bridge.service
TOKEN=$(head -n1 /etc/fotobox-print-bridge/token)

# Only the USB backend is fake.
dpkg-divert --quiet --rename --add /usr/lib/cups/backend/gutenprint53+usb
install -m 0755 tool/bridge/test/stub-backend.sh /usr/lib/cups/backend/gutenprint53+usb
mkdir -p /tmp/bridge-test && chmod 1777 /tmp/bridge-test
# Discovery runs as root, print jobs as lp: both append to one log.
install -m 0666 /dev/null /tmp/bridge-test/backend.log
# Host networking: keep clear of the host's own cupsd on 631.
sed -i "s/^Port 631$/Port $PORT/" /etc/cups/cupsd.conf
mkdir -p /run/cups
/usr/sbin/cupsd
for _ in $(seq 1 30); do [ -S /run/cups/cups.sock ] && break; sleep 0.5; done

mkdir -p /var/lib/fotobox-print-bridge
# Its own process group, as under systemd: on SIGTERM it signals its group.
setsid /usr/lib/fotobox-print-bridge/fotobox-cupsd >/tmp/bridge-test/daemon.log 2>&1 &
DAEMON=$!
for _ in $(seq 1 60); do grep -q 'ready (' /tmp/bridge-test/daemon.log && break; sleep 0.5; done
cat /tmp/bridge-test/daemon.log
QUEUE=$(lpstat -d | sed -n 's/^system default destination: //p')
echo "== default queue: $QUEUE"
[ "$QUEUE" = dnp-dsrx1_52583154455354 ]
PAGE=$(lpoptions -p "$QUEUE" -l | sed -n 's/^PageSize[^:]*:.*\*\([^ ]*\).*/\1/p')
echo "== default page size: $PAGE"
[ "$PAGE" = w288h432 ]
lpstat -l -p "$QUEUE" | head -5

# The app's client, from this host's LAN address (so cupsd sees a network
# client, not localhost).
# @LOCAL is the subnets of broadcast interfaces: skip point-to-point links
# (VPNs), which CUPS rightly does not count as local.
LAN_IP=
while read -r _ iface _ cidr _; do
  ip -o link show dev "$iface" | grep -q POINTOPOINT && continue
  ip -o link show dev "$iface" | grep -q LOWER_UP || continue
  LAN_IP=${cidr%/*}; break
done < <(ip -4 -o addr show scope global)
[ -n "$LAN_IP" ] || { echo 'no broadcast LAN interface to test from' >&2; exit 1; }
echo "== LAN address $LAN_IP"
# shellcheck disable=SC2046
cc -O1 -Wno-deprecated-declarations -D_GNU_SOURCE -DPRINTING_FFI_IOS=1 -Isrc $(cups-config --cflags) \
  tool/bridge/test/client_test.c src/printing_ffi.c $(cups-config --libs) -lpthread -o /tmp/client_test

echo '== no token'
if timeout 60 /tmp/client_test "$LAN_IP:$PORT" "" "" > /tmp/bridge-test/notoken.out 2>&1; then
  cat /tmp/bridge-test/notoken.out; echo 'FAIL: printed without a token'; exit 1; fi
cat /tmp/bridge-test/notoken.out
grep -q 'needs its print bridge token' /tmp/bridge-test/notoken.out
echo '== wrong token'
if timeout 60 /tmp/client_test "$LAN_IP:$PORT" fotobox-print wrong-token > /tmp/bridge-test/wrong.out 2>&1; then
  cat /tmp/bridge-test/wrong.out; echo 'FAIL: wrong token accepted'; exit 1; fi
cat /tmp/bridge-test/wrong.out
grep -q 'needs its print bridge token' /tmp/bridge-test/wrong.out
echo '== token + JPEG'
timeout 120 /tmp/client_test "$LAN_IP:$PORT" fotobox-print "$TOKEN" /src/tool/bridge/test/sheet.jpg
for _ in $(seq 1 60); do ls /tmp/bridge-test/job-*.bin >/dev/null 2>&1 && break; sleep 0.5; done
sleep 1
cat /tmp/bridge-test/backend.log
JOB=$(ls /tmp/bridge-test/job-*.bin | head -1)
SIZE=$(stat -c %s "$JOB")
echo "== printer data: $SIZE bytes"
[ "$SIZE" -gt 100000 ]
grep -q 'user=fotobox-print' /tmp/bridge-test/backend.log
grep -q 'PageSize=w288h432\|media=w288h432' /tmp/bridge-test/backend.log
# The page size is set once: a restart neither recreates nor re-asks.
kill $DAEMON; wait $DAEMON 2>/dev/null || true
STATS=$(grep -c '^stats' /tmp/bridge-test/backend.log)
setsid /usr/lib/fotobox-print-bridge/fotobox-cupsd >>/tmp/bridge-test/daemon.log 2>&1 &
sleep 7
kill $! || true
[ "$(grep -c '^stats' /tmp/bridge-test/backend.log)" = "$STATS" ]
[ "$(grep -c 'ready (' /tmp/bridge-test/daemon.log)" = 1 ]
echo 'PASS: bridge package, page size from paper, token auth, JPEG through the filter chain'
