# KDE Plasma & Noctalia: Theme-Reactive Wallpaper Switcher

A theme-aware wallpaper switcher with automatic desktop environment detection for **KDE Plasma** and **Noctalia** (KineticWE).

Makes your desktop wallpaper and lock screen follow the active theme mode: a light wallpaper in light mode, and a dark wallpaper in dark mode. Reacts to manual theme toggles, KDE color-scheme switches (including `AutomaticLookAndFeel` day/night and `kde-material-you-colors`), and Noctalia's sunrise/sunset flips.

* **Automatic Desktop Detection**: Detects whether you are running **KDE Plasma** or **Noctalia / KineticWE** and applies wallpapers using the native interface (`plasma-apply-wallpaperimage` on Plasma, `noctalia-kwe msg wallpaper-set` on Noctalia).
* **Isolated Environment Configs**: Supports per-environment configs (`KDE_` prefixed options for Plasma alongside base options for Noctalia), coexisting without conflicts.
* **Low-Resource Reactive Daemon for KDE**: Provides a ~4 MB Go daemon (`wallpaper-switcher-plasma`) that listens on D-Bus without consuming CPU cycles.

## How it works

The tool reacts to theme switches across both supported desktop environments:

```
   KDE Plasma Session                          Noctalia / KineticWE Session
   ──────────────────                          ────────────────────────────
KDE color scheme change                     Noctalia [theme].mode change
(System Settings, daylight, material-you)   (manual toggle, sunrise/sunset)
         │                                               │
         ▼                                               ▼
D-Bus signal / kdeglobals change            `theme_mode_changed` hook
         │                                               │
         ▼                                               │
Go Daemon: wallpaper-switcher-plasma                     │
(ultra-lightweight, ~4MB, zero CPU)                      │
         │                                               │
         └───────────────────────┬───────────────────────┘
                                 │
                                 ▼
                         theme-wallpaper.sh
             (Auto-detects XDG_CURRENT_DESKTOP session)
                                 │
                 STRATEGY = fixed | random | cycle
                                 │
                 ┌───────────────┴───────────────┐
                 │                               │
                 ▼                               ▼
            KDE Plasma:                  Noctalia / KineticWE:
   plasma-apply-wallpaperimage <path>    noctalia msg wallpaper-set <path>
   + kscreenlockerrc lockscreen sync     + palette generation / sync
```

* **Noctalia / KineticWE**: Fully hook-driven. Noctalia exports `$NOCTALIA_THEME_MODE` and invokes `theme-wallpaper.sh`. No background process is needed.
* **KDE Plasma**: Plasma doesn't have an external hook system for wallpaper scripts, so an ultra-lightweight Go daemon (`wallpaper-switcher-plasma`, ~4 MB RAM, 0% CPU) monitors session D-Bus and `kdeglobals`, triggering `theme-wallpaper.sh` on changes.

## Install

```sh
./install.sh
```

Then either open **Noctalia Theme Wallpaper** from the app menu, or edit the file
by hand:

```sh
vim ~/.config/noctalia-kwe/theme-wallpaper.conf
```

Test without changing anything:

```sh
THEME_WALLPAPER_DRY_RUN=1 ~/.config/noctalia-kwe/hooks/theme-wallpaper.sh
noctalia-kwe msg theme-mode-toggle
```

Run the hook only if you changed Noctalia settings. The wallpaper hook file is
read on every switch, so ordinary config edits need no reload.

To remove:

```sh
./install.sh --uninstall
```

## Configuration

`~/.config/noctalia-kwe/theme-wallpaper.conf` (or `~/.config/noctalia/theme-wallpaper.conf` on vanilla Noctalia)

| Key | Meaning |
| --- | --- |
| `STRATEGY` | `fixed`, `random`, or `cycle` |
| `DARK_WALLPAPER` / `LIGHT_WALLPAPER` | exact image per mode, for `fixed` |
| `DARK_DIR` / `LIGHT_DIR` | folder to scan per mode, for `random` / `cycle` |
| `CONNECTORS` | optional space-separated outputs; empty = all outputs in sync |

All three strategies are supported:

- **`fixed`** — one specific image per mode.
- **`random`** — a fresh random image from that mode's folder on every switch.
- **`cycle`** — walks the folder in order and wraps, so no image repeats
  until every one has been used.

For `random` and `cycle`, create the folders and put images in them:

```sh
mkdir -p ~/Pictures/Wallpapers/{dark,light}
```

Only image files directly inside each folder are used; subfolders are ignored.

## Multi-environment support (KDE Plasma & Noctalia)

The application automatically detects the active desktop environment (`XDG_CURRENT_DESKTOP` / `KDE_FULL_SESSION`):
- **Banner indicator**: Displays the detected session at the top (e.g., `KDE Plasma session detected (Plasma 6)` or `Noctalia session detected`).
- **Per-environment wallpapers and folders**: In KDE Plasma, settings prefixed with `KDE_` (such as `KDE_STRATEGY`, `KDE_LIGHT_WALLPAPER`, `KDE_DARK_WALLPAPER`, `KDE_LIGHT_DIR`, and `KDE_DARK_DIR`) are used and saved, falling back to base keys if unset. In Noctalia / KineticWE, the base keys are used. Both desktop setups coexist cleanly without overriding or breaking each other.
- **KDE Plasma behavior**: In Plasma sessions, wallpapers are applied natively with `plasma-apply-wallpaperimage`, the lock screen is synced via `~/.config/kscreenlockerrc`, and palette generation is bypassed (relying on `kde-material-you-colors`).

## KDE Plasma Daemon (`wallpaper-switcher-plasma`)

In Noctalia, the shell fires hooks automatically when the theme changes. In KDE Plasma, there is no built-in wallpaper hook. To bridge this gap, a dedicated, ultra-low-resource daemon is provided in `daemon-plasma/`.

- **Purely reactive architecture**: Written in Go, it connects to Linux session D-Bus (`org.kde.KGlobalSettings.notifyChange` / `org.freedesktop.portal.Settings.SettingChanged`) and checks `~/.config/kdeglobals` every 2 seconds, consuming **near 0.0% CPU** and only ~**4 MB RAM**.
- **KDE Plasma theme ownership**: The daemon **never** changes or applies KDE color schemes itself. Instead, it respects KDE's native day/night switching (`AutomaticLookAndFeel=true`), user System Settings changes, or `kde-material-you-colors`, resolving whether the active theme is `light` or `dark` from `kdeglobals` and invoking `theme-wallpaper.sh` so your wallpaper and lockscreen match.
- **Session-isolated**: The daemon checks `XDG_CURRENT_DESKTOP` on launch. If you log into KineticWE or another shell, it exits immediately and never touches non-KDE sessions.

### Building and Managing the Daemon

#### Automatic setup:
`./install.sh` automatically compiles the binary and enables the user systemd service if `go` is installed on your system.

#### Manual compilation:
```bash
cd daemon-plasma
go build -ldflags="-s -w" -o wallpaper-switcher-plasma .
cp wallpaper-switcher-plasma ~/.local/bin/
```

#### Service controls:
```bash
systemctl --user status wallpaper-switcher-plasma.service
systemctl --user restart wallpaper-switcher-plasma.service
journalctl --user -u wallpaper-switcher-plasma.service -f
```

For a comprehensive beginner guide and detailed breakdown of the logic, see [Wiki Chapter 27: The KDE Plasma Daemon](docs/wiki/27-the-kde-plasma-daemon.md).

## KDE lock screen

On KDE Plasma, the lock screen is `kscreenlocker_greet`. It reads its background
from the `[Greeter][Wallpaper][org.kde.image][General]` group in
`~/.config/kscreenlockerrc`. When running in KDE Plasma, the GUI displays the **KDE lock screen** tab:
- `LOCKSCREEN_SYNC`: Enable or disable lock screen background updates.
- `LOCKSCREEN_SOURCE`: `desktop` (matches the active wallpaper) or `custom` (distinct light/dark wallpapers configured via `LOCKSCREEN_LIGHT_WALLPAPER` / `LOCKSCREEN_DARK_WALLPAPER`).

## Noctalia lock screen

In KineticWE V2, session locking is handled natively by Noctalia Lockscreen.
When `[lockscreen].wallpaper` is left empty in Noctalia's settings, the lock
screen automatically uses the active desktop wallpaper per output, which this
hook switches on every mode change.

## Palette

The tool can draw the colour palette from the wallpaper as well, so the whole
desktop shares one set of colours.

```toml
PALETTE_GENERATOR = noctalia   # noctalia | ours | random
PALETTE_SCHEME = m3-rainbow    # used when the generator is noctalia
PALETTE_VARIANT = duotone      # duotone | tonal
PALETTE_SEED = 0               # for the random generator
```

| Generator | What it does |
| --- | --- |
| `noctalia` | Noctalia draws the palette, with the scheme named in `PALETTE_SCHEME`. The tool does not touch the palette. |
| `ours` | The tool draws a palette from the wallpaper and applies it as a Noctalia custom palette. |
| `random` | The same, but the accent colours move around the hue of the wallpaper, so each wallpaper still feels like itself. |

`PALETTE_VARIANT` decides how the two modes relate to the picture. `duotone`
keeps the picture's real hues, with light washed out and dark deep. `tonal` uses
one seed hue for all three accents, the way Noctalia's own schemes do.

`PALETTE_SAVED` decides what happens when a wallpaper already has a palette
saved for it. `always` draws a new one every time, which is the default.
`prefer` uses the palette you kept for that wallpaper instead.

The palette is a pure function of the wallpaper, so one file is enough. The file
holds a dark and a light variant, so a theme mode change needs no regeneration
at all. The generator guarantees the contrast of every colour pair it supplies
and refuses to write a palette that fails its own check, so a broken palette
never reaches the desktop.

Setting `PALETTE_GENERATOR = noctalia` hands the palette back to Noctalia
completely. That is also the ownership switch. While the generator is `ours` or
`random` the tool owns the palette source, and a change made in Noctalia's own
settings lasts only until the next wallpaper change.

## Design notes

**Why a hook and not a Luau plugin.** Noctalia plugins run as Luau services, and
a service's only lifecycle callbacks are `onConfigChanged()` and
`onOutputsChanged()` — there is no theme-change callback. A plugin would have to
poll `noctalia.isDarkMode()` on a timer. The hook system is event-driven, so this
approach reacts instantly with nothing running in the background.

**Why not the built-in `directory_light` / `directory_dark`.** Noctalia already
has theme-aware wallpaper folders, and it is the right tool when `shell_mode` is
pinned to `dark` or `light`. It does not work in `auto` mode — the docs state
Auto falls back to the plain `directory` — and it changes what folder the picker
*browses* rather than pinning a wallpaper per mode. This hook covers `auto` and
pins exact images.

**Startup.** `theme_mode_changed` only fires on an actual change, so it would
never run on a session that starts already in dark mode. The `started` hook
covers that; the script asks Noctalia for the current mode when
`$NOCTALIA_THEME_MODE` is empty.

**Safety.** Every failure path logs and exits without changing anything: a
missing config, a typo'd path, an empty folder, an unknown strategy, an
unreadable mode, or a failed `wallpaper-set`. A bad config can never blank the
desktop. Failures go to the journal:

```sh
journalctl -t noctalia-theme-wallpaper -f
```

**No loops.** Applying a wallpaper fires `wallpaper_changed`, not
`theme_mode_changed`, so the hook cannot retrigger itself. The script also skips
the IPC call when the target image is already applied, avoiding a redundant
reload and its transition flash.

**The hook listens for three events.** `theme_mode_changed` picks and applies
the image. `started` covers a session that boots already in a given mode.
`wallpaper_changed` covers a wallpaper change made by anything else, and it only
reconciles the palette so the script never changes the wallpaper back.

**Palette synergy.** Your `[theme].source = "wallpaper"` means Noctalia
regenerates the palette from the current wallpaper on every change. So the
wallpaper you pick per mode also drives your colors automatically.

## Graphical settings

An optional GTK 4 / libadwaita window edits the same config file. Start it from
the app menu as **Noctalia Theme Wallpaper**.

It gives you a thumbnail grid for picking the light and dark wallpaper, folder
pickers, the strategy selector, the palette generator controls, and **Apply now**
and **Dry run** buttons. Dry run shows exactly what the hook would do and changes
nothing.

The window follows Noctalia's current theme mode, so it is dark when Noctalia is
dark. The mode is also shown at the bottom, so it is clear which wallpaper
**Apply now** will set.

Saving needs no reload. The hook re-reads the config on every switch, so a saved
change is live at the next mode change.

The GUI needs only `python3-gobject`, GTK 4 and libadwaita, all of which are
already on Fedora by default. `install.sh` checks for them and skips the GUI if
they are missing. The hook never depends on the GUI.

### The palette window

The **Palette** tab shows the palette the current wallpaper produces, with a
swatch for every colour role. **Draw a new one** makes another palette from the
same wallpaper, and **Save this palette** keeps it.

A saved palette is written into `~/.config/noctalia-kwe/palettes/` (or
`~/.config/noctalia/palettes/`), which is the folder Noctalia reads. It
therefore appears in Noctalia's own custom palette list straight away, with a
preview, and needs nothing else to work.

The window lists the saved palettes twice. **Saved for this wallpaper** holds
the ones that belong to the wallpaper on screen, and **All custom palettes**
holds every one, including the ones Noctalia or you made. Each row has a **Use**
button that applies it and a **Delete** button that removes it.

Every palette says how it was made, in the row and under the swatches. The
values come from the file itself, so they are never a guess. Each row also
carries four small colour dots, the primary, the secondary, the tertiary and the
error colour, so a list can be told apart at a glance. This is the same preview
Noctalia shows for a custom palette.

```text
  ours-random                       random, duotone, seed 3, beach.jpg
  ours                              drawn by this tool, duotone, seed 3, dusk.jpg
  wallhaven-6lyv5x-1920x1080-mc     made by Noctalia or by hand
```

The window shows the palette that is **live**, read from the file Noctalia is
using, not a fresh one it drew. It checks every three seconds, so a wallpaper
change made anywhere shows up on its own. **Draw a new one** makes another
palette and shows it, and **Use this palette** makes it the live one.

The Desktop wallpaper tab also says whether the theme mode is pinned. Noctalia
lets you set the mode to `dark` or `light` instead of `auto`, and when it is
pinned the day and night schedule never runs, so the wallpaper quietly stops
following the sun. The window notices that and offers a way back.

The Desktop wallpaper tab has a **Right now** group that shows the picture the
desktop is really using, and the wallpaper on screen is marked in the picker
with a border of its own, so it cannot be mistaken for the image that is
selected.

The name of a saved palette is up to you. A name that starts with the wallpaper
name groups it under that wallpaper.

The **When a wallpaper has a saved palette** setting sits at the top of the
Palette tab. It decides whether a new palette is drawn every time the wallpaper
changes, or whether the one you saved is used.

### Config file handling

The GUI edits `KEY=VALUE` lines in place. It keeps your comments, blank lines and
key order, rewrites only the keys you changed, and appends new keys at the end.
Unknown keys are left alone. A duplicated key is collapsed to one.

The Python reader and the shell reader are deliberately identical, including
quote stripping and the one-layer `~` expansion, so the window and the hook read
the same value from the same file. That guarantee has limits worth naming. A
folder containing only symlinked images, a file name holding a newline, and
non-ASCII spaces are the cases where the two can still disagree, so a value
that looks wrong in one place and right in the other is worth reporting.

## Files

```
install.sh                              install / uninstall
files/hooks-theme-wallpaper.toml        [hooks] wiring (theme_mode_changed, started, wallpaper_changed)
files/theme-wallpaper.sh                the script Noctalia runs
files/palette-generator.py              the wallpaper palette generator
files/theme-wallpaper.conf.example      config template with docs
gui/theme-wallpaper-gui.py              GTK 4 / libadwaita settings window
gui/theme-wallpaper-gui.desktop         app menu launcher
```

The hooks live in their own `hooks-theme-wallpaper.toml` so they merge into the
Noctalia config stack without editing any existing `*.toml`.

## Notes

- Noctalia's `auto` mode follows **sunrise/sunset** from your `[location]`, not
  the GNOME or KDE color scheme. This switcher follows Noctalia's mode. If you
  change appearance in KDE's System Settings, that does not move Noctalia's mode.
- With `[theme].mode = "auto"`, the flip happens once at sunrise and once at
  sunset. If you want different wallpapers at other times of day, that is a
  different feature — say the word and it can be added.
