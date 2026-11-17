package main

import (
	"os"
	"path/filepath"
	"testing"
)

func createTempKdeGlobals(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "kdeglobals")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp kdeglobals: %v", err)
	}
	return path
}

func TestResolveActiveThemeMode_MaterialYouLight(t *testing.T) {
	content := `[General]
ColorScheme=MaterialYouLight
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "light" {
		t.Errorf("expected mode 'light', got %q", mode)
	}
}

func TestResolveActiveThemeMode_MaterialYouDark(t *testing.T) {
	content := `[General]
ColorScheme=MaterialYouDark
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "dark" {
		t.Errorf("expected mode 'dark', got %q", mode)
	}
}

func TestResolveActiveThemeMode_BreezeLight(t *testing.T) {
	content := `[General]
ColorScheme=BreezeLight
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "light" {
		t.Errorf("expected mode 'light', got %q", mode)
	}
}

func TestResolveActiveThemeMode_BreezeDark(t *testing.T) {
	content := `[General]
ColorScheme=BreezeDark
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "dark" {
		t.Errorf("expected mode 'dark', got %q", mode)
	}
}

func TestResolveActiveThemeMode_CustomSchemeLightRGB(t *testing.T) {
	content := `[General]
ColorScheme=CustomNordic
[Colors:Window]
BackgroundNormal=239,240,241
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "light" {
		t.Errorf("expected mode 'light' for BackgroundNormal=239,240,241, got %q", mode)
	}
}

func TestResolveActiveThemeMode_CustomSchemeDarkHex(t *testing.T) {
	content := `[General]
ColorScheme=CustomTokyoNight
[Colors:Window]
BackgroundNormal=#1a1b26
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "dark" {
		t.Errorf("expected mode 'dark' for BackgroundNormal=#1a1b26, got %q", mode)
	}
}

func TestResolveActiveThemeMode_CustomSchemeDarkRGB(t *testing.T) {
	content := `[General]
ColorScheme=CustomCatppuccin
[Colors:Window]
BackgroundNormal=30,30,46
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "dark" {
		t.Errorf("expected mode 'dark' for BackgroundNormal=30,30,46, got %q", mode)
	}
}

func TestResolveActiveThemeMode_CustomSchemeLightHex(t *testing.T) {
	content := `[General]
ColorScheme=CustomSolarized
[Colors:Window]
BackgroundNormal=#f5faff
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "light" {
		t.Errorf("expected mode 'light' for BackgroundNormal=#f5faff, got %q", mode)
	}
}

func TestResolveActiveThemeMode_FallbackDefault(t *testing.T) {
	content := `[General]
`
	path := createTempKdeGlobals(t, content)
	mode := resolveActiveThemeMode(path)
	if mode != "dark" {
		t.Errorf("expected default fallback 'dark', got %q", mode)
	}
}

func TestParseRGB(t *testing.T) {
	cases := []struct {
		input  string
		wantR  int
		wantG  int
		wantB  int
		wantOk bool
	}{
		{"239,240,241", 239, 240, 241, true},
		{" 30 , 30 , 46 ", 30, 30, 46, true},
		{"#1a1b26", 26, 27, 38, true},
		{"#fff", 255, 255, 255, true},
		{`"239,240,241"`, 239, 240, 241, true},
		{"invalid", 0, 0, 0, false},
		{"#zzzzzz", 0, 0, 0, false},
	}

	for _, tc := range cases {
		r, g, b, ok := parseRGB(tc.input)
		if ok != tc.wantOk {
			t.Errorf("parseRGB(%q) ok = %v; want %v", tc.input, ok, tc.wantOk)
			continue
		}
		if ok && (r != tc.wantR || g != tc.wantG || b != tc.wantB) {
			t.Errorf("parseRGB(%q) = (%d, %d, %d); want (%d, %d, %d)",
				tc.input, r, g, b, tc.wantR, tc.wantG, tc.wantB)
		}
	}
}
