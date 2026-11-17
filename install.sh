#!/usr/bin/env bash
#
# install.sh -- install the Noctalia theme -> wallpaper switcher.
#
#   ./install.sh            install (or update) and print next steps
#   ./install.sh --uninstall remove the hooks, script, and config
#
# Idempotent: safe to re-run after editing anything.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$HERE/files"

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
HOOKS_DIR="$CONFIG_DIR/hooks"
SCRIPT="$HOOKS_DIR/theme-wallpaper.sh"
CONF="$CONFIG_DIR/theme-wallpaper.conf"
HOOKS_TOML="$CONFIG_DIR/hooks-theme-wallpaper.toml"
GUI="$CONFIG_DIR/theme-wallpaper-gui.py"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APPS_DIR/theme-wallpaper-gui.desktop"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
ICON_FILE="$ICONS_DIR/theme-wallpaper-gui.svg"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# The GUI is optional. It needs GTK 4 and libadwaita, which a KDE-only machine
# may not have, so never make the hook depend on it.
have_gui_deps() {
	python3 -c "
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
from gi.repository import Gtk, Adw
# AdwSwitchRow, AdwToolbarView and AdwTabBar arrived in libadwaita 1.4.
if (Adw.get_major_version(), Adw.get_minor_version()) < (1, 4):
    raise SystemExit('libadwaita 1.4 or newer is required')
# GtkFileDialog arrived in GTK 4.10.
if (Gtk.get_major_version(), Gtk.get_minor_version()) < (4, 10):
    raise SystemExit('GTK 4.10 or newer is required')
" >/dev/null 2>&1
}

uninstall() {
	rm -f "$HOOKS_TOML" "$DESKTOP_FILE" "$ICON_FILE" "$GUI" "$SCRIPT"
	rm -f "$HOOKS_DIR/palette-generator.py"
	if [[ -f "$CONF" ]] && grep -q "installed by the theme-wallpaper switcher" "$CONF"; then
		rm -f "$CONF"
		printf 'removed config: %s\n' "$CONF"
	else
		printf 'kept your config: %s\n' "$CONF"
	fi
	rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/$NOCTALIA_DIR_NAME"/theme-wallpaper-dark.idx
	rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/$NOCTALIA_DIR_NAME"/theme-wallpaper-light.idx
	rmdir "$HOOKS_DIR" 2>/dev/null || true
	update-desktop-database "$APPS_DIR" 2>/dev/null || true
	gtk-update-icon-cache "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true
	printf 'uninstalled. reload with: %s msg config-reload\n' "$NOCTALIA"
}

[[ "${1:-}" == "--uninstall" ]] && {
	uninstall
	exit 0
}

command -v "$NOCTALIA" >/dev/null 2>&1 || die "$NOCTALIA not found on PATH"

# Validate before installing, so a broken script never reaches the hooks file.
bash -n "$FILES/theme-wallpaper.sh" || die "the hook script has a syntax error"
python3 -m py_compile "$FILES/palette-generator.py" ||
	die "the palette generator has a syntax error"

mkdir -p "$HOOKS_DIR" || die "cannot create $HOOKS_DIR"
install -m 0755 "$FILES/theme-wallpaper.sh" "$SCRIPT" || die "cannot install script"
install -m 0755 "$FILES/palette-generator.py" "$HOOKS_DIR/palette-generator.py" ||
	die "cannot install the palette generator"

# Write the absolute script path into the hooks file rather than shipping a
# template with $HOME, so the hook cannot depend on Noctalia running it through
# a shell that expands variables.
# A bash substitution, not sed. A path may contain & or |, which sed treats
# as special, and the redirect would truncate the target before sed could fail.
render_template() { # render_template <template> <placeholder> <value> <destination>
	local tmpl="$1" key="$2" value="$3" dest="$4" body tmp
	body="$(cat "$tmpl")" || die "cannot read $tmpl"
	body="${body//"$key"/"$value"}"
	tmp="$dest.tmp.$$"
	printf '%s\n' "$body" >"$tmp" || {
		rm -f "$tmp"
		die "cannot write $dest"
	}
	chmod 0644 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$dest" || {
		rm -f "$tmp"
		die "cannot install $dest"
	}
}
render_template "$FILES/hooks-theme-wallpaper.toml" "__SCRIPT__" "$SCRIPT" "$HOOKS_TOML"

if [[ -f "$CONF" ]]; then
	printf 'kept your existing config: %s\n' "$CONF"
else
	{
		printf '# installed by the theme-wallpaper switcher\n'
		cat "$FILES/theme-wallpaper.conf.example"
	} >"$CONF" || die "cannot write config"
	printf 'created config: %s\n' "$CONF"
fi

bash -n "$SCRIPT" || die "script has a syntax error"

# Warn (do not fail) if another config file already claims the same hook keys.
others="$(grep -rlsE '^[[:space:]]*(theme_mode_changed|started)[[:space:]]*=' \
	"$CONFIG_DIR"/*.toml 2>/dev/null | grep -v "^$HOOKS_TOML$" || true)"
if [[ -n "$others" ]]; then
	printf '\nnote: these files also define a hook key; only one value wins:\n'
	printf '  %s\n' "${others[@]}"
fi

printf '\nvalidating config...\n'
if "$NOCTALIA" config validate; then
	printf 'config OK\n'
else
	printf '\nconfig reported problems -- review them before reloading.\n'
fi

# ------------------------------------------------------------- optional GUI
if have_gui_deps; then
	mkdir -p "$APPS_DIR" "$ICONS_DIR" || die "cannot create GUI directories"
	install -m 0755 "$FILES/../gui/theme-wallpaper-gui.py" "$GUI" || die "cannot install the GUI"
	install -m 0644 "$FILES/../gui/theme-wallpaper-gui.svg" "$ICON_FILE" || die "cannot install the GUI icon"
	render_template "$FILES/../gui/theme-wallpaper-gui.desktop" "__GUI__" "$GUI" "$DESKTOP_FILE"
	update-desktop-database "$APPS_DIR" 2>/dev/null || true
	gtk-update-icon-cache "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true
	gui_state="installed: $GUI
  launcher: Noctalia Theme Wallpaper in your app menu"
else
	gui_state="skipped: GTK 4 and libadwaita Python bindings not found.
  The hook does not need them. Install python3-gobject to enable the GUI."
fi

# ------------------------------------------------------------- optional Plasma daemon
plasma_daemon_state="skipped (go not available)"
if command -v go >/dev/null 2>&1 && [[ -d "$HERE/daemon-plasma" ]]; then
	BIN_DIR="${HOME}/.local/bin"
	SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	mkdir -p "$BIN_DIR" "$SYSTEMD_USER_DIR"
	(
		cd "$HERE/daemon-plasma"
		go build -ldflags="-s -w" -o "$BIN_DIR/wallpaper-switcher-plasma" main.go
	) && {
		install -m 0644 "$HERE/daemon-plasma/wallpaper-switcher-plasma.service" "$SYSTEMD_USER_DIR/"
		systemctl --user daemon-reload 2>/dev/null || true
		systemctl --user enable --now wallpaper-switcher-plasma.service 2>/dev/null || true
		plasma_daemon_state="installed: $BIN_DIR/wallpaper-switcher-plasma (systemd service active)"
	}
fi

printf '\ninstalled:\n  script: %s\n  hooks:  %s\n  config: %s\n' "$SCRIPT" "$HOOKS_TOML" "$CONF"
printf '  gui:    %s\n' "$gui_state"
printf '  plasma: %s\n' "$plasma_daemon_state"
printf '\nnext:\n'
printf '  1. edit %s\n' "$CONF"
printf '  2. %s msg config-reload\n' "$NOCTALIA"
printf '  3. test with:  THEME_WALLPAPER_DRY_RUN=1 %s\n' "$SCRIPT"
printf '  4. try it:    %s msg theme-mode-toggle\n' "$NOCTALIA"
