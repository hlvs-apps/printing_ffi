#!/bin/sh
# Stands in for Gutenprint's USB backend (gutenprint53+usb) in the bridge test:
# one DS-RX1 with 6x4 paper; print jobs land in /tmp/bridge-test.
OUT=/tmp/bridge-test
if [ -n "$BACKEND_STATS_ONLY" ]; then
	echo "stats $BACKEND $SERIAL" >>"$OUT/backend.log"
	printf '{\n\t"backend": "dnpds40",\n\t"decks": {\n\t\t"Roll": {\n\t\t\t"mediatype": "6x4 (PC)",\n\t\t\t"medialevel": "OK"\n\t\t}\n\t}\n}\n'
	exit 0
fi
if [ $# -eq 0 ]; then
	echo "discover" >>"$OUT/backend.log"
	echo 'direct gutenprint53+usb://dnp-dsrx1/RX1TEST "DNP DS-RX1" "DNP DS-RX1" "MFG:Dai Nippon Printing;MDL:DS-RX1;" ""'
	exit 0
fi
# CUPS job mode: job-id user title copies options [file]
echo "job $1 user=$2 title=$3 options=$5" >>"$OUT/backend.log"
if [ -n "${6:-}" ]; then cat "$6"; else cat; fi >"$OUT/job-$1.bin"
exit 0
