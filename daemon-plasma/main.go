package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	logPrefix = "[wallpaper-switcher-plasma] "
)

type Daemon struct {
	conn           *dbus.Conn
	kdeglobalsPath string
	currentMode    string
	currentScheme  string
	lastModTime    time.Time
	scriptPath     string
	mu             sync.Mutex
}

func main() {
	log.SetFlags(log.Ltime)
	log.SetPrefix(logPrefix)
	log.Println("Starting wallpaper-switcher daemon for KDE Plasma...")

	// Verify we are in a KDE Plasma session
	xdgDesktop := strings.ToUpper(os.Getenv("XDG_CURRENT_DESKTOP"))
	kdeSession := strings.ToLower(os.Getenv("KDE_FULL_SESSION"))
	if !strings.Contains(xdgDesktop, "KDE") && kdeSession != "true" {
		log.Printf("Session is not KDE Plasma (XDG_CURRENT_DESKTOP=%s). Exiting.", os.Getenv("XDG_CURRENT_DESKTOP"))
		os.Exit(0)
	}

	home, _ := os.UserHomeDir()
	kdeglobalsPath := filepath.Join(home, ".config/kdeglobals")

	d := &Daemon{
		scriptPath:     findScriptPath(),
		kdeglobalsPath: kdeglobalsPath,
	}

	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		log.Fatalf("Failed to connect to session bus: %v", err)
	}
	defer conn.Close()
	d.conn = conn

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 1. Initial State Check & Sync
	d.syncInitialState()

	// 2. Start monitoring D-Bus and file events
	d.watchEvents(ctx)
}

func findScriptPath() string {
	// 1. Environment variable override
	if env := os.Getenv("THEME_WALLPAPER_SCRIPT"); env != "" && fileExists(env) {
		return env
	}

	home, _ := os.UserHomeDir()
	// 2. Installed hook locations
	candidates := []string{
		filepath.Join(home, ".config/noctalia-kwe/hooks/theme-wallpaper.sh"),
		filepath.Join(home, ".config/noctalia/hooks/theme-wallpaper.sh"),
		filepath.Join(home, "Projects/kde-noctalia-theme-wallpaper/source/files/theme-wallpaper.sh"),
	}

	for _, c := range candidates {
		if fileExists(c) {
			return c
		}
	}

	return ""
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func isDefaultKdeGlobals(path string) bool {
	if path == "" {
		return true
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return false
	}
	return filepath.Clean(path) == filepath.Clean(filepath.Join(home, ".config/kdeglobals"))
}

func parseKdeGlobals(path string) (colorScheme string, bgNormal string) {
	if path == "" {
		home, _ := os.UserHomeDir()
		path = filepath.Join(home, ".config/kdeglobals")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return "", ""
	}

	var currentSection string
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			currentSection = strings.ToLower(line)
			continue
		}
		idx := strings.Index(line, "=")
		if idx == -1 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		val = strings.Trim(val, `"'`)

		if currentSection == "[general]" && strings.EqualFold(key, "ColorScheme") {
			colorScheme = val
		} else if currentSection == "[colors:window]" && strings.EqualFold(key, "BackgroundNormal") {
			bgNormal = val
		}
	}
	return colorScheme, bgNormal
}

func parseRGB(val string) (int, int, int, bool) {
	val = strings.TrimSpace(val)
	val = strings.Trim(val, `"'`)

	if strings.HasPrefix(val, "#") {
		hexStr := strings.TrimPrefix(val, "#")
		if len(hexStr) == 6 {
			r, err1 := strconv.ParseInt(hexStr[0:2], 16, 64)
			g, err2 := strconv.ParseInt(hexStr[2:4], 16, 64)
			b, err3 := strconv.ParseInt(hexStr[4:6], 16, 64)
			if err1 == nil && err2 == nil && err3 == nil {
				return int(r), int(g), int(b), true
			}
		} else if len(hexStr) == 3 {
			r, err1 := strconv.ParseInt(string(hexStr[0])+string(hexStr[0]), 16, 64)
			g, err2 := strconv.ParseInt(string(hexStr[1])+string(hexStr[1]), 16, 64)
			b, err3 := strconv.ParseInt(string(hexStr[2])+string(hexStr[2]), 16, 64)
			if err1 == nil && err2 == nil && err3 == nil {
				return int(r), int(g), int(b), true
			}
		}
		return 0, 0, 0, false
	}

	parts := strings.Split(val, ",")
	if len(parts) >= 3 {
		r, err1 := strconv.Atoi(strings.TrimSpace(parts[0]))
		g, err2 := strconv.Atoi(strings.TrimSpace(parts[1]))
		b, err3 := strconv.Atoi(strings.TrimSpace(parts[2]))
		if err1 == nil && err2 == nil && err3 == nil {
			return r, g, b, true
		}
	}

	return 0, 0, 0, false
}

// resolveActiveThemeMode determines whether the active KDE theme is "light" or "dark".
// Rules:
// 1. Read [General] ColorScheme. If it contains "dark" -> "dark". If "light" -> "light".
// 2. Fall back to [Colors:Window] BackgroundNormal (R,G,B or #RRGGBB): if (R+G+B) < 382 -> "dark", else "light".
// 3. Default fallback: "dark".
func resolveActiveThemeMode(kdeglobalsPath string) string {
	colorScheme, bgNormal := parseKdeGlobals(kdeglobalsPath)

	if isDefaultKdeGlobals(kdeglobalsPath) {
		if colorScheme == "" {
			if out, err := exec.Command("kreadconfig6", "--file", "kdeglobals", "--group", "General", "--key", "ColorScheme").Output(); err == nil {
				colorScheme = strings.TrimSpace(string(out))
			}
		}
		if bgNormal == "" {
			if out, err := exec.Command("kreadconfig6", "--file", "kdeglobals", "--group", "Colors:Window", "--key", "BackgroundNormal").Output(); err == nil {
				bgNormal = strings.TrimSpace(string(out))
			}
		}
	}

	if colorScheme != "" {
		lower := strings.ToLower(colorScheme)
		if strings.Contains(lower, "dark") {
			return "dark"
		}
		if strings.Contains(lower, "light") {
			return "light"
		}
	}

	if bgNormal != "" {
		if r, g, b, ok := parseRGB(bgNormal); ok {
			if (r + g + b) < 382 {
				return "dark"
			}
			return "light"
		}
	}

	return "dark"
}

func (d *Daemon) resolveCurrentMode() string {
	return resolveActiveThemeMode(d.kdeglobalsPath)
}

func (d *Daemon) readCurrentColorScheme() string {
	scheme, _ := parseKdeGlobals(d.kdeglobalsPath)
	if scheme != "" {
		return scheme
	}
	if isDefaultKdeGlobals(d.kdeglobalsPath) {
		out, err := exec.Command("kreadconfig6", "--file", "kdeglobals", "--group", "General", "--key", "ColorScheme").Output()
		if err == nil {
			s := strings.TrimSpace(string(out))
			if s != "" {
				return s
			}
		}
	}
	return ""
}

func (d *Daemon) syncInitialState() {
	d.mu.Lock()
	defer d.mu.Unlock()

	if info, err := os.Stat(d.kdeglobalsPath); err == nil {
		d.lastModTime = info.ModTime()
	}

	mode := d.resolveCurrentMode()
	scheme := d.readCurrentColorScheme()

	d.currentMode = mode
	d.currentScheme = scheme

	log.Printf("Detected active KDE ColorScheme: %q (resolved mode: %s)", scheme, mode)
	d.triggerWallpaper(mode)
}

func (d *Daemon) triggerWallpaper(mode string) {
	if d.scriptPath == "" {
		log.Println("Warning: theme-wallpaper.sh script not found; skipping wallpaper apply.")
		return
	}

	log.Printf("Executing %s for mode %s...", filepath.Base(d.scriptPath), mode)
	cmd := exec.Command(d.scriptPath)
	cmd.Env = append(os.Environ(), "NOCTALIA_THEME_MODE="+mode)
	if out, err := cmd.CombinedOutput(); err != nil {
		log.Printf("theme-wallpaper.sh failed: %v (%s)", err, strings.TrimSpace(string(out)))
	} else {
		outStr := strings.TrimSpace(string(out))
		if outStr != "" {
			log.Printf("theme-wallpaper.sh output: %s", outStr)
		}
	}
}

func (d *Daemon) checkAndApplyModeChange(source string) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if info, err := os.Stat(d.kdeglobalsPath); err == nil {
		d.lastModTime = info.ModTime()
	}

	newMode := d.resolveCurrentMode()
	newScheme := d.readCurrentColorScheme()

	if newMode != d.currentMode {
		log.Printf("Theme mode change detected via %s: %s -> %s (ColorScheme=%q)", source, d.currentMode, newMode, newScheme)
		d.currentMode = newMode
		d.currentScheme = newScheme
		d.triggerWallpaper(newMode)
	} else if newScheme != "" && newScheme != d.currentScheme {
		log.Printf("ColorScheme changed via %s: %q -> %q (mode remains %s)", source, d.currentScheme, newScheme, d.currentMode)
		d.currentScheme = newScheme
	}
}

func (d *Daemon) watchEvents(ctx context.Context) {
	// Add match rules for KDE global settings and freedesktop portal settings
	matchKGlobalSettings := "type='signal',interface='org.kde.KGlobalSettings',member='notifyChange'"
	d.conn.BusObject().Call("org.freedesktop.DBus.AddMatch", 0, matchKGlobalSettings)

	matchPortalSettings := "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'"
	d.conn.BusObject().Call("org.freedesktop.DBus.AddMatch", 0, matchPortalSettings)

	signals := make(chan *dbus.Signal, 10)
	d.conn.Signal(signals)

	log.Println("Listening for KDE theme transition events (D-Bus signals & kdeglobals polling)...")

	// 2-second poll interval to catch file changes even if D-Bus signals are delayed/missed
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case sig := <-signals:
			d.handleSignal(sig)
		case <-ticker.C:
			d.pollKdeGlobals()
		}
	}
}

func (d *Daemon) handleSignal(sig *dbus.Signal) {
	if sig == nil {
		return
	}
	if strings.Contains(sig.Name, "notifyChange") || strings.Contains(sig.Name, "SettingChanged") {
		d.checkAndApplyModeChange(fmt.Sprintf("D-Bus %s", sig.Name))
	}
}

func (d *Daemon) pollKdeGlobals() {
	info, err := os.Stat(d.kdeglobalsPath)
	if err != nil {
		return
	}

	d.mu.Lock()
	mtimeChanged := !info.ModTime().Equal(d.lastModTime)
	d.mu.Unlock()

	if mtimeChanged {
		d.checkAndApplyModeChange("kdeglobals mtime poll")
		return
	}

	// Secondary check: verify if mode differs from currentMode
	if d.resolveCurrentMode() != d.currentMode {
		d.checkAndApplyModeChange("kdeglobals content poll")
	}
}
