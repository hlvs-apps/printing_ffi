#!/usr/bin/env bash
# Fake AppSocket/JetDirect printer for testing the Android bundled-cupsd raw path.
#
# Listens on a TCP port (default 9100) and saves each received print job to a file,
# printing its size + a short preview. Point a CUPS socket:// queue at this Mac:
#   socket://<this-mac-lan-ip>:9100
#
# IMPORTANT: uses Apple-signed /usr/bin/python3, NOT `nc`. The macOS Application
# Firewall silently DROPS inbound LAN connections to an unsigned `nc` listener
# (localhost works, but the device can't reach it), while signed binaries are
# allowed. python3 is signed, so this works over the LAN out of the box.
#
# Usage:  tool/android/fake-printer.sh [port] [outdir]
# Stop:   Ctrl-C
set -uo pipefail
PORT="${1:-9100}"
OUTDIR="${2:-/tmp/fake-printer}"
mkdir -p "$OUTDIR"
echo "Fake printer (python3) listening on 0.0.0.0:$PORT ; jobs -> $OUTDIR"
echo "Mac LAN IP(s): $(ipconfig getifaddr en0 2>/dev/null || true) $(ipconfig getifaddr en1 2>/dev/null || true)"
echo "Add a CUPS queue with device URI: socket://<mac-ip>:$PORT"
echo "Ctrl-C to stop."
exec /usr/bin/python3 - "$PORT" "$OUTDIR" <<'PY'
import socket, sys, os
port = int(sys.argv[1]); outdir = sys.argv[2]
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port)); srv.listen(5)
i = 0
while True:
    conn, addr = srv.accept()
    i += 1
    conn.settimeout(5)
    data = b""
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    conn.close()
    fn = os.path.join(outdir, "job_%03d.prn" % i)
    with open(fn, "wb") as f:
        f.write(data)
    preview = "".join(chr(c) if 32 <= c < 127 or c in (9, 10) else "." for c in data[:200])
    print("[received] job #%d from %s : %d bytes -> %s" % (i, addr[0], len(data), fn), flush=True)
    print(preview, flush=True)
PY
