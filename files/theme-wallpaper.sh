#!/usr/bin/env bash
#
# theme-wallpaper.sh -- apply a wallpaper that matches the active theme mode in KDE Plasma or Noctalia.
#
# Supported environments:
# - Noctalia (KineticWE): Wired to `theme_mode_changed` and `started` hooks. Reads mode
#   from $NOCTALIA_THEME_MODE (falling back to msg theme-mode-get) and applies with msg wallpaper-set.
# - KDE Plasma: Invoked by wallpaper-switcher-plasma daemon or manual script run.
#   Applies wallpaper natively via `plasma-apply-wallpaperimage` and syncs the lockscreen.
#
# Config: ~/.config/noctalia-kwe/theme-wallpaper.conf  (see the .example file)
#
# Set THEME_WALLPAPER_DRY_RUN=1 to log the decision without touching the wallpaper.

# Deliberately no `set -e`: every failure path here should log and exit quietly
# rather than kill the hook, and a missing wallpaper must never blank the desktop.
set -uo pipefail

if [[ -n "${NOCTALIA_BIN:-}" ]]; then
	NOCTALIA="$NOCTALIA_BIN"
elif command -v noctalia-kwe >/dev/null 2>&1; then
	NOCTALIA="noctalia-kwe"
else
	NOCTALIA="noctalia"
fi

if [[ "$(basename -- "$NOCTALIA")" == "noctalia-kwe" ]]; then
	NOCTALIA_DIR_NAME="noctalia-kwe"
else
	NOCTALIA_DIR_NAME="noctalia"
fi

CONFIG_DIR="${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/$NOCTALIA_DIR_NAME}"
CONF="${THEME_WALLPAPER_CONF:-$CONFIG_DIR/theme-wallpaper.conf}"
# Noctalia keeps its custom palettes next to this file, in a "palettes" folder.
PALETTE_DIR="${THEME_WALLPAPER_PALETTE_DIR:-$(dirname -- "$CONF")/palettes}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$NOCTALIA_DIR_NAME"
LOG_TAG="noctalia-theme-wallpaper"
DRY_RUN="${THEME_WALLPAPER_DRY_RUN:-0}"

log() {
	# Always write to the journal, including dry runs. The README tells a
	# user to debug with the journal, so a dry run that logs nowhere makes
	# the tool that exists for debugging useless.
	logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true
	printf '%s\n' "$*"
}

# Skip everything: never blank the desktop because of a config typo.
bail() {
	log "skipped: $*"
	exit 0
}

declare -A CFG=()

load_conf() {
	[[ -r "$CONF" ]] || return 1
	local line key val
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line#"${line%%[![:space:]]*}"}" # trim leading space
		[[ -z "$line" || "$line" == \#* ]] && continue
		[[ "$line" != *=* ]] && continue
		key="${line%%=*}"
		val="${line#*=}"
		key="${key%"${key##*[![:space:]]}"}" # trim trailing space
		val="${val#"${val%%[![:space:]]*}"}"
		val="${val%"${val##*[![:space:]]}"}"
		# strip one layer of matching quotes
		if [[ ${#val} -ge 2 && "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
			val="${val:1:${#val}-2}"
		elif [[ ${#val} -ge 2 && "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
			val="${val:1:${#val}-2}"
		fi
		[[ -n "$key" ]] && CFG["$key"]="$val"
	done <"$CONF"
	return 0
}

# Environment / session detection: KDE Plasma vs Noctalia
detect_session() {
	local xdg="${XDG_CURRENT_DESKTOP:-}"
	local kde_full="${KDE_FULL_SESSION:-}"
	if [[ "${xdg^^}" == *"KDE"* || "${kde_full,,}" == "true" ]]; then
		printf 'kde'
	else
		printf 'noctalia'
	fi
}

SESSION="$(detect_session)"

# cfg <key> <default>
# If running in KDE, check KDE_<key> first before falling back to <key>.
cfg() {
	local key="$1" default="$2" pfx=""
	[[ "$SESSION" == "kde" ]] && pfx="KDE_"
	local v="${CFG[${pfx}${key}]-}"
	if [[ -n "$v" ]]; then
		printf '%s' "$v"
		return 0
	fi
	v="${CFG[$key]-}"
	if [[ -n "$v" ]]; then
		printf '%s' "$v"
	else
		printf '%s' "$default"
	fi
}

# A leading ~/ in a configured path should behave the way the Noctalia settings UI
# implies it does, so expand it here instead of failing with "no such file".
expand() {
	local p="$1"
	if [[ "$p" == "~/"* ]]; then
		printf '%s/%s' "$HOME" "${p#\~/}"
	elif [[ "$p" == "~" ]]; then
		printf '%s' "$HOME"
	else
		printf '%s' "$p"
	fi
}

load_conf || bail "config not readable: $CONF"

# ------------------------------------------------------------ KDE helpers
LOCKSCREEN_RC="${THEME_WALLPAPER_LOCKSCREEN_RC:-$HOME/.config/kscreenlockerrc}"
LOCKSCREEN_GROUP='[Greeter][Wallpaper][org.kde.image][General]'

url_encode() {
	local s="$1" out="" i c
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
		' ' | '%' | '#' | '?' | '"' | '<' | '>' | '\\' | '^' | '`' | '{' | '}' | '|' | $'\n')
			printf -v c '%%%02X' "'$c"
			;;
		esac
		out+="$c"
	done
	printf '%s' "$out"
}

set_lockscreen_image() {
	local image="$1"
	local file="$LOCKSCREEN_RC"
	local url="file://$(url_encode "$image")"
	local -a lines new
	local i saw_group=0 saw_image=0 saw_prev=0 in_group=0
	local tmp perms dir base target

	base="$(basename -- "$file")"
	case "$base" in
	*.rc | *.conf | kscreenlockerrc) ;;
	*) log "lockscreen: $base does not look like a settings file (skipped)"; return 0 ;;
	esac

	target="$(readlink -f -- "$file" 2>/dev/null || printf '%s' "$file")"
	[[ -f "$target" ]] || {
		log "lockscreen: no $file (skipped)"
		return 0
	}

	mapfile -t lines <"$target" || {
		log "lockscreen: cannot read $file (skipped)"
		return 0
	}

	for ((i = 0; i < ${#lines[@]}; i++)); do
		local stripped="${lines[i]%$'\r'}"
		stripped="${stripped// /}"
		if [[ "$stripped" == \[* ]]; then
			if [[ "$stripped" == "$LOCKSCREEN_GROUP" ]]; then
				in_group=1
				saw_group=1
				new+=("${stripped}")
				continue
			fi
			in_group=0
			new+=("${lines[i]}")
			continue
		fi

		if ((in_group)); then
			case "${lines[i]%$'\r'}" in
			Image=*)
				new+=("Image=$url")
				saw_image=1
				continue
				;;
			PreviewImage=*)
				new+=("PreviewImage=$url")
				saw_prev=1
				continue
				;;
			esac
		fi
		new+=("${lines[i]}")
	done

	if ((saw_group == 0)); then
		while [[ ${#new[@]} -gt 0 && -z "${new[-1]//[[:space:]]/}" ]]; do
			new=("${new[@]:0:${#new[@]}-1}")
		done
		new+=("" "$LOCKSCREEN_GROUP")
	elif ((saw_image == 0 || saw_prev == 0)); then
		local -a merged=()
		local inside=0
		for line in ${new[@]+"${new[@]}"}; do
			merged+=("$line")
			if ((inside == 0)); then
				[[ "${line// /}" == "$LOCKSCREEN_GROUP" ]] && inside=1
			elif [[ "$line" == \[* ]]; then
				inside=2
			fi
		done
		if [[ $inside == 1 ]]; then
			((saw_image == 0)) && merged+=("Image=$url")
			((saw_prev == 0)) && merged+=("PreviewImage=$url")
		fi
		new=(${merged[@]+"${merged[@]}"})
	fi

	dir="$(dirname -- "$target")"
	tmp="$dir/.${base}.twp.$$"
	if ! printf '%s\n' "${new[@]}" >"$tmp"; then
		rm -f "$tmp"
		log "lockscreen: cannot write $file (skipped)"
		return 0
	fi

	if [[ "$(printf '%s\n' "${new[@]}")" == "$(printf '%s\n' "${lines[@]}")" ]]; then
		log "lockscreen: already set -> $(basename "$image")"
		rm -f "$tmp"
		return 0
	fi

	perms="$(stat -Lc '%a' -- "$target" 2>/dev/null || echo 600)"
	if ! mv -f -- "$tmp" "$target"; then
		rm -f "$tmp"
		log "lockscreen: cannot replace $file (skipped)"
		return 0
	fi
	chmod "$perms" -- "$target" 2>/dev/null || true
	log "lockscreen: set -> $(basename "$image")"
	return 0
}

sync_lockscreen() {
	local mode="$1" desktop_image="$2" lock_image lock_source lv

	[[ "$(cfg LOCKSCREEN_SYNC true)" != "false" ]] || return 0

	lock_image="$desktop_image"
	lock_source="$(cfg LOCKSCREEN_SOURCE desktop)"
	lock_source="${lock_source,,}"
	case "$lock_source" in
	desktop) ;;
	custom)
		if [[ "$mode" == "dark" ]]; then
			lv="$(cfg LOCKSCREEN_DARK_WALLPAPER "")"
		else
			lv="$(cfg LOCKSCREEN_LIGHT_WALLPAPER "")"
		fi
		if [[ -z "$lv" ]]; then
			log "lockscreen: custom source with no image for $mode, mirroring desktop"
		else
			lv="$(expand "$lv")"
			if [[ -f "$lv" && -r "$lv" ]]; then
				lock_image="$lv"
			else
				log "lockscreen: $lv unusable, mirroring desktop"
			fi
		fi
		;;
	*)
		log "error: unknown LOCKSCREEN_SOURCE '${lock_source}' (use desktop or custom)"
		return 0
		;;
	esac

	if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
		log "DRY RUN lockscreen ($lock_source): would point at $(basename "$lock_image")"
		return 0
	fi

	set_lockscreen_image "$lock_image"
}

get_kde_current_wallpaper() {
	local appletsrc="${THEME_WALLPAPER_APPLETSRC:-$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc}"
	[[ -r "$appletsrc" ]] || return 1
	local line in_group=0 val=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%$'\r'}"
		if [[ "$line" == \[* ]]; then
			if [[ "$line" == *"[Wallpaper][org.kde.image][General]"* ]]; then
				in_group=1
			else
				in_group=0
			fi
		elif ((in_group)) && [[ "$line" == Image=* ]]; then
			val="${line#Image=}"
			if [[ "$val" == "file://"* ]]; then
				val="${val#file://}"
				val="$(python3 -c "import urllib.parse, sys; print(urllib.parse.unquote(sys.argv[1]))" "$val" 2>/dev/null || printf '%s' "$val")"
			fi
			printf '%s' "$val"
			return 0
		fi
	done <"$appletsrc"
	return 1
}

# ---------------------------------------------------------------- resolve mode
mode="${NOCTALIA_THEME_MODE:-}"
if [[ -z "$mode" ]]; then
	if [[ "$SESSION" == "kde" ]]; then
		kde_scheme=""
		if command -v kreadconfig6 >/dev/null 2>&1; then
			kde_scheme="$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null || true)"
		elif command -v kreadconfig5 >/dev/null 2>&1; then
			kde_scheme="$(kreadconfig5 --file kdeglobals --group General --key ColorScheme 2>/dev/null || true)"
		fi
		if [[ -z "$kde_scheme" && -r "$HOME/.config/kdeglobals" ]]; then
			kde_scheme="$(grep -E '^ColorScheme=' "$HOME/.config/kdeglobals" 2>/dev/null | cut -d= -f2- || true)"
		fi
		if [[ "${kde_scheme,,}" == *"dark"* ]]; then
			mode="dark"
		else
			mode="light"
		fi
	else
		mode="$("$NOCTALIA" msg theme-mode-get 2>/dev/null | tr -d '[:space:]')"
	fi
fi
case "$mode" in
dark | light) ;;
*) bail "could not resolve theme mode (got '${mode:-empty}')" ;;
esac

if [[ "$mode" == "dark" ]]; then
	dir_key="DARK_DIR"
	file_key="DARK_WALLPAPER"
else
	dir_key="LIGHT_DIR"
	file_key="LIGHT_WALLPAPER"
fi

strategy="$(cfg STRATEGY fixed)"
strategy="${strategy,,}"

# ------------------------------------------------------------------- palette
# The palette is a pure function of the wallpaper, so one file is enough: going
# back to a wallpaper regenerates the same palette it had before. A file per
# wallpaper would only accumulate, and the random strategy would create a new
# one on every switch.
#
# The file holds a dark and a light variant, so a theme mode change needs no
# regeneration at all. Noctalia picks the variant that matches the mode.
sync_palette() {
	local wallpaper="$1" generator variant seed name out generator_script output scheme saved

	generator="$(cfg PALETTE_GENERATOR noctalia)"
	case "$generator" in
	noctalia)
		# Noctalia owns the palette. Hand the source back to it so the
		# wallpaper and its own scheme apply again.
		scheme="$(cfg PALETTE_SCHEME m3-rainbow)"
		if "$NOCTALIA" msg color-scheme-set wallpaper "$scheme" >/dev/null 2>&1; then
			log "palette: Noctalia owns it (scheme $scheme)"
		else
			log "palette: could not hand the palette back to Noctalia"
		fi
		return 0
		;;
	ours | random) ;;
	*) log "palette: unknown PALETTE_GENERATOR '${generator}' (skipped)"; return 0 ;;
	esac

	generator_script="${BASH_SOURCE[0]%/*}/palette-generator.py"
	if [[ ! -f "$generator_script" ]]; then
		log "palette: generator not found at $generator_script (skipped)"
		return 0
	fi

	# A wallpaper can have palettes saved for it. By default a new one is
	# drawn every time. The other setting keeps the saved one instead.
	if [[ "$(cfg PALETTE_SAVED always)" == "prefer" ]]; then
		saved="$(python3 "$generator_script" --find-saved --wallpaper "$wallpaper" \
			--palette-dir "$PALETTE_DIR" 2>/dev/null || true)"
		if [[ -n "$saved" ]] && "$NOCTALIA" msg color-scheme-set custom "$saved" >/dev/null 2>&1; then
			log "palette: using the saved palette $saved"
			return 0
		fi
	fi

	variant="$(cfg PALETTE_VARIANT duotone)"
	seed="$(cfg PALETTE_SEED 0)"
	name="ours"
	[[ "$generator" == "random" ]] && name="ours-random"
	out="$PALETTE_DIR/$name.json"

	local -a args=(--wallpaper "$wallpaper" --output "$out" --variant "$variant" --seed "$seed")
	[[ "$generator" == "random" ]] && args+=(--random)

	if ! output="$(python3 "$generator_script" "${args[@]}" 2>&1)"; then
		log "palette: generation failed, keeping the current palette: $output"
		return 0
	fi

	if ! "$NOCTALIA" msg color-scheme-set custom "$name" >/dev/null 2>&1; then
		log "palette: could not apply $name (skipped)"
		return 0
	fi
	log "palette: applied $name from $(basename "$wallpaper")"
}

# ------------------------------------------------------- wallpaper changed event
# Noctalia fires wallpaper_changed whenever the wallpaper is changed, by the
# wallpaper panel, a plugin, or by this script. When something else changed it,
# the desktop wallpaper is already correct and must not be changed back. Only
# the palette needs reconciling, against the wallpaper that is on screen.
if [[ -n "${NOCTALIA_WALLPAPER_PATH:-}" ]]; then
	current="$("$NOCTALIA" msg wallpaper-get 2>/dev/null | head -1 | tr -d '[:space:]')"
	[[ -n "$current" ]] || bail "wallpaper_changed: could not read the current wallpaper"
	log "wallpaper changed elsewhere: keeping $(basename "$current")"
	if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
		log "DRY RUN palette: would sync palette for $(basename "$current")"
		exit 0
	fi
	sync_palette "$current"
	exit 0
fi

# ---------------------------------------------------------------- pick wallpaper
chosen=""
index_state=""
images=()
outputs=()
keep=()
img=""

case "$strategy" in
fixed)
	chosen="$(cfg "$file_key" "")"
	[[ -n "$chosen" ]] || bail "fixed: $file_key is not set"
	chosen="$(expand "$chosen")"
	;;

random | cycle)
	dir="$(cfg "$dir_key" "")"
	[[ -n "$dir" ]] || bail "$strategy: $dir_key is not set"
	dir="$(expand "$dir")"
	[[ -d "$dir" ]] || bail "$strategy: not a directory: $dir"

	# Deterministic order so `cycle` is stable across invocations.
	# -print0 and sort -z, because a file name may contain a newline and
	# a line-based pipeline would split one file into two fake entries.
	# -type f -o -type l keeps symlinked wallpapers, which a dotfiles setup
	# relies on. Broken symlinks are filtered out by the test below.
	mapfile -d '' -t images < <(
		find "$dir" -maxdepth 1 \( -type f -o -type l \) \
			\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
			-o -iname '*.webp' -o -iname '*.jxl' -o -iname '*.avif' \) -print0 2>/dev/null |
			LC_ALL=C sort -z
	)
	# Drop anything that does not resolve to a readable file.
	keep=()
	for img in ${images[@]+"${images[@]}"}; do
		[[ -f "$img" && -r "$img" ]] && keep+=("$img")
	done
	images=(${keep[@]+"${keep[@]}"})
	[[ ${#images[@]} -gt 0 ]] || bail "$strategy: no images in $dir"

	if [[ "$strategy" == "random" ]]; then
		chosen="${images[RANDOM % ${#images[@]}]}"
	else
		# cycle: advance through the folder, wrapping, so no repeat until the end
		index_state="$STATE_DIR/theme-wallpaper-$mode.idx"
		mkdir -p "$STATE_DIR" 2>/dev/null || true
		last="-1"
		if [[ -r "$index_state" ]]; then
			read -r last <"$index_state" || last="-1"
		fi
		[[ "$last" =~ ^-?[0-9]+$ ]] || last="-1"
		idx=$(((last + 1) % ${#images[@]}))
		if ! printf '%s\n' "$idx" >"$index_state" 2>/dev/null; then
			log "cycle: cannot write $index_state, so the order will not advance"
		fi
		chosen="${images[$idx]}"
	fi
	;;

*)
	bail "unknown STRATEGY '${strategy}' (use fixed, random, or cycle)"
	;;
esac

[[ -n "$chosen" && -f "$chosen" ]] || bail "chosen wallpaper is not a readable file: ${chosen:-empty}"
[[ -r "$chosen" ]] || bail "chosen wallpaper is not readable: $chosen"

# ---------------------------------------------------------------- apply
if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
	log "DRY RUN $mode ($strategy): would set $(basename "$chosen")"
elif [[ "$SESSION" == "kde" ]]; then
	current="$(get_kde_current_wallpaper || true)"
	if [[ -n "$current" && "$current" == "$chosen" ]]; then
		log "$mode: KDE desktop wallpaper already applied ($(basename "$chosen"))"
	else
		if command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
			if plasma-apply-wallpaperimage "$chosen" >/dev/null 2>&1; then
				log "$mode: set KDE wallpaper -> $chosen"
			else
				bail "plasma-apply-wallpaperimage failed for $chosen"
			fi
		else
			log "warning: plasma-apply-wallpaperimage not found on PATH"
		fi
	fi
else
	current="$("$NOCTALIA" msg wallpaper-get 2>/dev/null | head -1 | tr -d '[:space:]')"
	if [[ -n "$current" && "$current" == "$chosen" ]]; then
		log "$mode: desktop wallpaper already applied ($(basename "$chosen"))"
	else
		connectors="$(cfg CONNECTORS "")"
		if [[ -n "$connectors" ]]; then
			ok=1
			read -r -a outputs <<<"$connectors"
			for c in ${outputs[@]+"${outputs[@]}"}; do
				if "$NOCTALIA" msg wallpaper-set "$c" "$chosen" >/dev/null 2>&1; then
					log "$mode: set on $c -> $chosen"
				else
					log "$mode: FAILED on $c (is '$c' connected?)"
					ok=0
				fi
			done
			[[ "$ok" == "1" ]] || bail "one or more outputs failed"
		else
			if "$NOCTALIA" msg wallpaper-set "$chosen" >/dev/null 2>&1; then
				log "$mode: set -> $chosen"
			else
				bail "wallpaper-set failed for $chosen"
			fi
		fi
	fi
fi

# ------------------------------------------------------------ lock screen
# In KDE Plasma, synchronize the lock screen image if configured.
if [[ "$SESSION" == "kde" ]]; then
	sync_lockscreen "$mode" "$chosen"
fi

exit 0
