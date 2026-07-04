#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# device-test-dnp.sh — on-device verification of the DNP dye-sub integration.
#
# Runs the STANDALONE cupsd (under /data/local/tmp/cupstest, shell uid) — NOT
# the in-app cupsd — so the DNP queue/PPD/filter resolution can be exercised
# without building the APK. Steps:
#   1. push the gutenprint backend (gutenprint53+usb), rastertogutenprint filter,
#      commandtodyesub, cups-genppd, and the share/gutenprint XML driver data.
#   2. extend the serverbin farm with the gutenprint backend + filters.
#   3. run cups-genppd ON THE DEVICE (STP_DATA_PATH set) to make the DS620 PPD —
#      proves PPD generation works with no printer attached.
#   4. boot cupsd, create a queue with that PPD + device-uri gutenprint53+usb:...
#   5. lpstat -p + dump error_log; a real print WILL fail at the USB fd stage
#      (no printer) — success here = the QUEUE + PPD + filter/backend resolve.
#
# Requires: a working `adb` with exactly one device (pin with ADB_SERIAL=...).
# The base CUPS runtime must already be staged on-device from the CUPS spike, OR
# this script pushes the minimum it needs. Idempotent.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUT_CUPS="$SCRIPT_DIR/../out/arm64"
OUT_GP="$SCRIPT_DIR/../out/arm64-gutenprint"

ADB="adb"
[ -n "${ADB_SERIAL:-}" ] && ADB="adb -s $ADB_SERIAL"

DEV=/data/local/tmp/cupstest
DRIVER="dnp-ds620"
PPD_NAME="stp-${DRIVER}.5.3.ppd"
QUEUE="dnp_ds620_test"

echo "==> device: $($ADB get-state 2>/dev/null || echo OFFLINE)"

# --- 1. push binaries (as plain files; chmod +x) --------------------------
echo "==> pushing gutenprint binaries + data"
$ADB shell "mkdir -p $DEV/lib/cups/backend $DEV/lib/cups/filter $DEV/bin $DEV/etc/cups/ppd $DEV/gutenprint"
$ADB push "$OUT_GP/cups/backend/gutenprint53+usb"        "$DEV/lib/cups/backend/gutenprint53+usb"
# The generated PPD references rastertogutenprint.5.3 (WITH the version suffix).
$ADB push "$OUT_GP/cups/filter/rastertogutenprint.5.3"   "$DEV/lib/cups/filter/rastertogutenprint.5.3"
$ADB push "$OUT_GP/cups/filter/commandtodyesub"          "$DEV/lib/cups/filter/commandtodyesub"
$ADB push "$OUT_GP/bin/cups-genppd.5.3"                  "$DEV/bin/cups-genppd"
$ADB shell "chmod 0755 $DEV/lib/cups/backend/gutenprint53+usb $DEV/lib/cups/filter/rastertogutenprint.5.3 $DEV/lib/cups/filter/commandtodyesub $DEV/bin/cups-genppd"
# gutenprint driver data (share/gutenprint/5.3/xml/...) -> STP_DATA_PATH root
$ADB push "$OUT_GP/share/gutenprint" "$DEV/gutenprint/share/gutenprint" >/dev/null
STP="$DEV/gutenprint/share/gutenprint/5.3/xml"
$ADB shell "ls $STP/xml-stamp" >/dev/null && echo "    STP_DATA_PATH=$STP OK"

# --- 2. generate the DS620 PPD on-device ----------------------------------
echo "==> running cups-genppd on-device (no printer needed)"
$ADB shell "cd $DEV/etc/cups/ppd && STP_DATA_PATH=$STP $DEV/bin/cups-genppd -p $DEV/etc/cups/ppd -Z $DRIVER; echo GENPPD_EXIT=\$?"
$ADB shell "ls -l $DEV/etc/cups/ppd/$PPD_NAME" && echo "    PPD generated OK" || { echo "!! PPD generation FAILED"; exit 1; }

# --- 3. boot cupsd (assumes base CUPS runtime already staged) -------------
# The base cupsd + backends/filters/daemons + share/cups must already be on the
# device from the CUPS boot spike. This script only adds the gutenprint pieces.
echo "==> (re)starting cupsd"
$ADB shell "pkill -f 'cupsd -f' 2>/dev/null; sleep 1; true"
$ADB shell "cd $DEV && ./sbin/cupsd -f -c $DEV/etc/cups/cupsd.conf -s $DEV/etc/cups/cups-files.conf >/dev/null 2>&1 &"
sleep 3

# --- 4. create the DNP queue against the generated PPD ---------------------
PORT="$($ADB shell "grep -oE 'Listen 127.0.0.1:[0-9]+' $DEV/etc/cups/cupsd.conf | grep -oE '[0-9]+$'" | tr -d '\r')"
echo "==> creating queue $QUEUE on port $PORT"
$ADB shell "CUPS_SERVER=127.0.0.1:$PORT $DEV/bin/lpadmin -p $QUEUE -v 'gutenprint53+usb://dnpds40/TEST' -P $DEV/etc/cups/ppd/$PPD_NAME -E; echo LPADMIN_EXIT=\$?"

# --- 5. verify + dump error_log ------------------------------------------
echo "==> lpstat -p"
$ADB shell "CUPS_SERVER=127.0.0.1:$PORT $DEV/bin/lpstat -p $QUEUE -l 2>&1 | head -20"
echo ""
echo "==> submit a tiny job (WILL fail at USB fd — that's expected)"
$ADB shell "echo hi > $DEV/testjob.txt; CUPS_SERVER=127.0.0.1:$PORT $DEV/bin/lp -d $QUEUE $DEV/testjob.txt; sleep 3"
echo ""
echo "==> error_log (filter/backend resolution + USB failure point)"
$ADB shell "grep -iE 'gutenprint|rastertogutenprint|PRINTING_FFI|Executing|Started filter|Started backend|No matching|wrap_sys|usb' $DEV/var/log/error_log 2>/dev/null | tail -40"
echo ""
echo "==> DONE. Expected: filter+backend EXEC'd, failing only at the USB fd stage."
