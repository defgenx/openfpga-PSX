#!/usr/bin/env bash
#
# install.sh - install the PlayStation core onto an Analogue Pocket microSD card.
#
#   ./install.sh                 find the SD card, then install
#   ./install.sh --sd /Volumes/POCKET
#   ./install.sh --bios ~/scph1001.bin   the BIOS to copy (else it is looked for, see INSTALL.md)
#   ./install.sh --dry-run       show what would be copied, change nothing
#   ./install.sh --reset-settings  also erase the core's saved settings (asks first)
#
# On Windows use install.bat (double-click) / install.ps1, or run this under Git Bash.
#
# Files already on the card are never replaced silently: identical ones are skipped,
# and for each one that differs you are asked (default: keep the card's file).
# Without a terminal (or with --dry-run) nothing on the card is ever replaced.
#
set -euo pipefail

REPO="defgenx/openfpga-PSX"
CORE="defgenx.PSX"
RBF="psx.rbf_r"
BIOS_REL="Assets/psx/$CORE/psxbios.bin"
BIOS_SIZE=524288
HERE="$(cd "$(dirname "$0")" && pwd)"

SD=""
BIOS=""
DRY_RUN=0
RESET_SETTINGS=0
while [ $# -gt 0 ]; do
	case "$1" in
		--sd) SD="${2:-}"; shift 2 ;;
		--sd=*) SD="${1#--sd=}"; shift ;;
		--bios) BIOS="${2:-}"; shift 2 ;;
		--bios=*) BIOS="${1#--bios=}"; shift ;;
		--dry-run|-n) DRY_RUN=1; shift ;;
		--reset-settings) RESET_SETTINGS=1; shift ;;
		-h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
	esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
fsize() { wc -c < "$1" | tr -d ' '; }

# ask PROMPT DEFAULT -> answer on stdout; without a terminal the default is used
INTERACTIVE=0; [ -t 0 ] && INTERACTIVE=1
ask() {
	local a=""
	if [ $INTERACTIVE -eq 1 ]; then read -r -p "$1 " a || a=""; fi
	printf '%s' "${a:-$2}"
}

# ---------------------------------------------------------------------------
# 1. Files to install: a built core in pocket/psx/dist (or dist/ beside the script), else the release
# ---------------------------------------------------------------------------

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

SRC=""
for d in "$HERE/pocket/psx/dist" "$HERE/dist" "$HERE"; do
	[ -f "$d/Cores/$CORE/$RBF" ] && { SRC="$d"; break; }
done
if [ -n "$SRC" ]; then
	say "Using the core from $SRC"
else
	command -v curl >/dev/null || die "curl is needed to download the release"
	command -v unzip >/dev/null || die "unzip is needed to unpack the release"
	TMP="$(mktemp -d)"
	# highest version among all releases, pre-releases included (/releases/latest skips those)
	url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" \
		| grep -o "https://[^\"]*/releases/download/v[0-9][^/\"]*/$CORE.zip" \
		| sed 's#.*/download/v\([^/]*\)/.*#\1 &#' \
		| sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | cut -d' ' -f2)" || true
	[ -n "$url" ] || die "no built core here (run pocket/psx/build.sh) and no release of $REPO to download"
	say "Downloading $url"
	curl -fL --progress-bar -o "$TMP/core.zip" "$url" || die "download failed"
	unzip -q "$TMP/core.zip" -d "$TMP/core"
	SRC="$TMP/core"
fi
[ -f "$SRC/Cores/$CORE/$RBF" ] || die "no core bitstream found in $SRC"

# ---------------------------------------------------------------------------
# 2. Find the SD card
# ---------------------------------------------------------------------------

is_pocket_card() {
	# An Analogue Pocket card has at least one of these at its root
	[ -d "$1/Cores" ] || [ -d "$1/Platforms" ] || [ -d "$1/Assets" ] || [ -d "$1/System" ]
}

if [ -z "$SD" ]; then
	candidates=()
	bases=(/Volumes /media/"${USER:-}" /run/media/"${USER:-}" /media /mnt)
	# Git Bash / MSYS / Cygwin on Windows: drive letters are /d, /e ... (skip the system drive)
	case "$(uname -s)" in
		MINGW*|MSYS*|CYGWIN*)
			bases=()
			for d in /[d-z] /cygdrive/[d-z]; do [ -d "$d" ] && candidates+=("$d"); done ;;
	esac
	for base in ${bases[@]+"${bases[@]}"}; do
		[ -d "$base" ] || continue
		for v in "$base"/*; do
			[ -d "$v" ] && [ -w "$v" ] || continue
			case "$v" in "/Volumes/Macintosh HD"*|/Volumes/Recovery|/Volumes/Preboot) continue ;; esac
			candidates+=("$v")
		done
	done

	pocket=()
	for v in ${candidates[@]+"${candidates[@]}"}; do is_pocket_card "$v" && pocket+=("$v"); done

	if [ ${#pocket[@]} -eq 1 ]; then
		SD="${pocket[0]}"
		say "Found Pocket SD card: $SD"
		case "$(ask "Install there? [Y/n]" y)" in [nN]*) die "aborted" ;; esac
	else
		list=("${pocket[@]+"${pocket[@]}"}")
		[ ${#list[@]} -eq 0 ] && list=("${candidates[@]+"${candidates[@]}"}")
		[ ${#list[@]} -eq 0 ] && die "no writable volume found - insert the SD card, or pass --sd PATH"
		[ ${#pocket[@]} -eq 0 ] && say "No card with Pocket folders found; mounted volumes:"
		[ ${#pocket[@]} -gt 1 ] && say "Several Pocket cards found:"
		i=1
		for v in "${list[@]}"; do say "  $i) $v"; i=$((i + 1)); done
		[ $INTERACTIVE -eq 1 ] || die "several volumes found - pass --sd PATH"
		n="$(ask "Number of the SD card to install to:" "")"
		[[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#list[@]} ] || die "invalid choice"
		SD="${list[$((n - 1))]}"
	fi
fi

[ -d "$SD" ] || die "$SD is not a directory"
[ -w "$SD" ] || die "$SD is not writable"
is_pocket_card "$SD" || say "Note: $SD has no Cores/Platforms/Assets folders yet; they will be created."

# ---------------------------------------------------------------------------
# 2b. The BIOS: the user's own dump (it cannot ship with the core), 512 KB, as Assets/psx/defgenx.PSX/psxbios.bin
# ---------------------------------------------------------------------------

is_bios() { [ -f "$1" ] && [ "$(fsize "$1")" = "$BIOS_SIZE" ]; }

if [ -n "$BIOS" ]; then
	is_bios "$BIOS" || die "$BIOS is not a PlayStation BIOS (a file of exactly $BIOS_SIZE bytes)"
elif is_bios "$SD/$BIOS_REL"; then
	say "BIOS already on the card ($BIOS_REL)."
else
	# psxbios.bin first, then scph*.bin, in the usual places
	for dir in "$HERE" "$HERE/bios" "$SD/Assets/psx/common" "$SD" "$HOME/Downloads" "$HOME"; do
		for f in "$dir"/psxbios.bin "$dir"/[sS][cC][pP][hH]*.[bB][iI][nN]; do
			is_bios "$f" && { BIOS="$f"; break 2; }
		done
	done
	if [ -n "$BIOS" ]; then
		say "Found a BIOS: $BIOS"
	else
		say "No PlayStation BIOS found (a 512 KB file such as scph1001.bin; see INSTALL.md)."
		BIOS="$(ask "Path to your BIOS file, or Enter to skip:" "")"
		BIOS="${BIOS%\'}"; BIOS="${BIOS#\'}"; BIOS="${BIOS%\"}"; BIOS="${BIOS#\"}"   # drag-and-drop quotes
		BIOS="${BIOS/#\~/$HOME}"
		[ -z "$BIOS" ] || is_bios "$BIOS" || die "$BIOS is not a PlayStation BIOS (a file of exactly $BIOS_SIZE bytes)"
	fi
fi

# ---------------------------------------------------------------------------
# 2c. Optionally erase the settings the Pocket saved for this core
# ---------------------------------------------------------------------------

if [ $RESET_SETTINGS -eq 1 ]; then
	settings="$SD/Settings/$CORE"
	if [ ! -d "$settings" ]; then
		say "No saved settings for $CORE on the card (nothing to reset)."
	elif [ $DRY_RUN -eq 1 ]; then
		say "would erase $settings"
	elif [ $INTERACTIVE -eq 0 ]; then
		say "Not erasing $settings without a terminal to confirm."
	else
		case "$(ask "Erase the saved settings in $settings? The core starts with defaults. [y/N]" n)" in
			[yY]*) rm -rf "$settings" && say "Erased saved settings: the core will start with its defaults." ;;
			*) say "Saved settings kept." ;;
		esac
	fi
fi

# ---------------------------------------------------------------------------
# 3. Copy, never replacing anything
# ---------------------------------------------------------------------------

# macOS: -X skips extended attributes, so no ._ AppleDouble files land on the FAT card
CP=(cp)
[ "$(uname)" = "Darwin" ] && CP=(cp -X)

copied=0
replaced=0
same=0
kept=()
policy=""   # "all" = replace every differing file, "none" = keep every one

# install_file SRC REL: copy SRC to $SD/REL, asking before replacing a different file
install_file() {
	local src="$1" rel="$2" dst="$SD/$2" verb="copied  " a
	if [ -e "$dst" ]; then
		if cmp -s "$src" "$dst"; then same=$((same + 1)); return; fi
		if [ $DRY_RUN -eq 1 ] || [ $INTERACTIVE -eq 0 ] || [ "$policy" = "none" ]; then kept+=("$rel"); return; fi
		if [ "$policy" != "all" ]; then
			a="$(ask "$rel already exists and differs. Replace it? [y]es/[N]o/[a]ll/[s]kip all" n)"
			case "$a" in
				[aA]*) policy="all" ;;
				[sS]*) policy="none"; kept+=("$rel"); return ;;
				[yY]*) ;;
				*) kept+=("$rel"); return ;;
			esac
		fi
		verb="replaced"
	fi
	if [ $DRY_RUN -eq 1 ]; then
		say "would copy  $rel"
	else
		mkdir -p "$(dirname "$dst")"
		"${CP[@]}" "$src" "$dst"
		say "$verb    $rel"
	fi
	if [ "$verb" = "replaced" ]; then replaced=$((replaced + 1)); else copied=$((copied + 1)); fi
}

# only the card's folders: a source folder that is the repo or a release also holds other files
for top in Assets Cores Platforms; do
	[ -d "$SRC/$top" ] || continue
	# file list on fd 3 so the questions can read the terminal on stdin
	while IFS= read -r -d '' f <&3; do
		rel="${f#"$SRC"/}"
		case "$(basename "$rel")" in .DS_Store|._*|.keep) continue ;; esac
		install_file "$f" "$rel"
	done 3< <(find "$SRC/$top" -type f -print0 | sort -z)
done

[ -n "$BIOS" ] && install_file "$BIOS" "$BIOS_REL"

# the install guide goes along (a release zip already carries it as PSX-INSTALL.md)
if [ ! -f "$SRC/PSX-INSTALL.md" ] && [ -f "$HERE/INSTALL.md" ]; then
	install_file "$HERE/INSTALL.md" "PSX-INSTALL.md"
elif [ -f "$SRC/PSX-INSTALL.md" ]; then
	install_file "$SRC/PSX-INSTALL.md" "PSX-INSTALL.md"
fi

say ""
if [ $DRY_RUN -eq 1 ]; then say "Dry run: $copied file(s) would be copied to $SD"
else say "Copied $copied new file(s), replaced $replaced, $same already up to date on $SD"; fi
if [ ${#kept[@]} -gt 0 ]; then
	say "Kept the card's version (differs from this release): ${#kept[@]}"
	for s in "${kept[@]}"; do say "  - $s"; done
	[ $INTERACTIVE -eq 0 ] && [ $DRY_RUN -eq 0 ] && say "Run the script in a terminal to be asked about replacing them."
fi
is_bios "$SD/$BIOS_REL" || [ $DRY_RUN -eq 1 -a -n "$BIOS" ] || say "No BIOS on the card: the core will not start until $BIOS_REL exists (see INSTALL.md)."
[ $DRY_RUN -eq 1 ] && exit 0

# ---------------------------------------------------------------------------
# 4. Eject
# ---------------------------------------------------------------------------

sync
case "$(ask "Eject the SD card now? [Y/n]" "$([ $INTERACTIVE -eq 1 ] && echo y || echo n)")" in
	[nN]*) say "Remember to eject the card before removing it." ;;
	*)
		if [ "$(uname)" = "Darwin" ]; then
			diskutil eject "$SD" && say "Ejected. Put the card in the Pocket and start openFPGA -> PlayStation."
		elif command -v udisksctl >/dev/null; then
			dev="$(df --output=source "$SD" | tail -1)"
			udisksctl unmount -b "$dev" && udisksctl power-off -b "$dev" && say "Ejected."
		else
			umount "$SD" && say "Unmounted."
		fi ;;
esac
