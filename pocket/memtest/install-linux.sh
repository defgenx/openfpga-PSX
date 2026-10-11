#!/usr/bin/env bash
# Copy the PSX memory test core onto the Pocket's SD card. Double-click it ("Run" or "Run in terminal"), or:
#   ./install-linux.sh [SD card mount point]
# It takes memtest-135.zip / memtest-101.zip (or defgenx.PSXMemTest.zip) from its own folder: docs/pocket/MEMTEST.md, Install.
set -euo pipefail

self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
here=$(dirname "$self")

# started without a terminal (double-click): reopen in one, so the questions can be answered
if [ ! -t 0 ] && [ -z "${MT_IN_TERM:-}" ]; then
	export MT_IN_TERM=1
	for t in x-terminal-emulator gnome-terminal konsole xfce4-terminal mate-terminal xterm; do
		command -v "$t" >/dev/null || continue
		case "$t" in
			gnome-terminal|mate-terminal) exec "$t" -- bash "$self" "$@" ;;
			xfce4-terminal) exec "$t" -x bash "$self" "$@" ;;
			*) exec "$t" -e bash "$self" "$@" ;;
		esac
	done
fi
# keep a double-clicked window open to show the result
finish() { local rc=$?; [ -n "${MT_IN_TERM:-}" ] && read -r -p "Press Enter to close. " _ || true; exit $rc; }
trap finish EXIT
die() { echo "ERROR: $*" >&2; exit 1; }

# ---- which variant
zips=()
for z in memtest-135.zip memtest-101.zip defgenx.PSXMemTest.zip; do
	[ -f "$here/$z" ] && zips+=("$here/$z")
done
[ ${#zips[@]} -gt 0 ] || die "no memtest zip next to this script; run pocket/memtest/build.sh package 135 (and 101) first"
if [ ${#zips[@]} -eq 1 ]; then
	zip=${zips[0]}
else
	echo "Which variant?"
	for ((i = 0; i < ${#zips[@]}; i++)); do
		note=""; case "${zips[$i]}" in *-135.zip) note="  (run this one first: the PSX core's clock)" ;; esac
		echo "  $((i + 1))) $(basename "${zips[$i]}")$note"
	done
	read -r -p "Number [1]: " n; n=${n:-1}
	[[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#zips[@]} ] || die "no such choice: $n"
	zip=${zips[$((n - 1))]}
fi

# ---- which SD card
target=${1:-}
if [ -z "$target" ]; then
	cands=()
	me=${USER:-$(id -un)}
	for d in /media/"$me"/* /run/media/"$me"/* /media/* /mnt/*; do
		[ -d "$d" ] && mountpoint -q "$d" 2>/dev/null && cands+=("$d")
	done
	echo
	echo "Where is the Pocket's SD card mounted?"
	for ((i = 0; i < ${#cands[@]}; i++)); do
		mark=""; [ -d "${cands[$i]}/Cores" ] && mark="  <- has a Cores folder (looks like a Pocket card)"
		echo "  $((i + 1))) ${cands[$i]}$mark"
	done
	[ ${#cands[@]} -gt 0 ] || echo "  (no mounted card found: insert it, or type its path)"
	read -r -p "Number, or a path: " n
	if [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#cands[@]} ]; then target=${cands[$((n - 1))]}; else target=$n; fi
fi
[ -n "$target" ] && [ -d "$target" ] || die "not a folder: '$target'"
[ -w "$target" ] || die "cannot write to $target (mounted read-only, or try: sudo $self $target)"

echo
echo "Copy $(basename "$zip") onto $target"
echo "(it writes only Cores/defgenx.PSXMemTest, Platforms/psxmemtest.json and Assets/psxmemtest; nothing else is touched)"
read -r -p "Go? [y/N] " a
case "$a" in y|Y|yes|YES) ;; *) die "cancelled, nothing copied" ;; esac

if command -v unzip >/dev/null; then
	unzip -o -q "$zip" -d "$target"
elif command -v python3 >/dev/null; then
	python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$target"
elif command -v bsdtar >/dev/null; then
	bsdtar -xf "$zip" -C "$target"
else
	die "need unzip, python3 or bsdtar to extract the zip"
fi
sync
[ -f "$target/Cores/defgenx.PSXMemTest/memtest.rbf_r" ] || die "copy failed: memtest.rbf_r missing on the card"

cat <<EOF

Done. Eject the card safely, put it in the Pocket and start "PSX Memory Test".
Photograph the screen after row 0 says DONE, and again after 30 minutes. What to look at:
  - every error count 0 (green)
  - row 7: eye width 10 or more, flags 0 or 2
  - rows 8-9: 0 late lines
EOF
