#!/bin/sh
# Smoke test: gte vs gte_serial (stub micro-code). Usage: run.sh [G_L]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
RTL=$HERE/../../../rtl
WK=${WK:-$HERE/work}
GL=${1:-1}
rm -rf "$WK"; mkdir -p "$WK"; cd "$WK"
# the golden appends to a file with this literal name; send it to /dev/null
ln -s /dev/null 'R:\\debug_gte_sim.txt'
nvc --std=2008 -a $RTL/pGTE.vhd $RTL/gte_mac0.vhd $RTL/gte_mac123.vhd $RTL/gte_UNRDivide.vhd $RTL/gte.vhd \
    $RTL/gte_serial_pkg.vhd $HERE/gte_serial_ucode.vhd $RTL/gte_serial_div.vhd $RTL/gte_serial.vhd $HERE/tb_smoke.vhd
nvc --std=2008 -e -gG_L=$GL tb_smoke 2>/dev/null || nvc --std=2008 -e tb_smoke
nvc --std=2008 -r tb_smoke
