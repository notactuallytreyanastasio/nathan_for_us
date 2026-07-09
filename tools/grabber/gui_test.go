package main

import "testing"

func TestGuiBuildOptions(t *testing.T) {
	t.Run("valid upload trims and defaults", func(t *testing.T) {
		o, err := guiBuildOptions("https://youtu.be/x", "https://s.example/", "key", "", "", "", "", false)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if o.server != "https://s.example" {
			t.Errorf("server trailing slash not trimmed: %q", o.server)
		}
		if o.fps != 1 || o.jpegQuality != 85 || o.maxHeight != 480 {
			t.Errorf("defaults wrong: fps=%v q=%d h=%d", o.fps, o.jpegQuality, o.maxHeight)
		}
		if o.batchSize != 10 {
			t.Errorf("batchSize = %d, want 10", o.batchSize)
		}
	})

	t.Run("missing url errors", func(t *testing.T) {
		if _, err := guiBuildOptions("  ", "s", "k", "", "", "", "", false); err == nil {
			t.Error("expected error for empty url")
		}
	})

	t.Run("upload requires server and key", func(t *testing.T) {
		if _, err := guiBuildOptions("u", "", "", "", "", "", "", false); err == nil {
			t.Error("expected error when server/key missing")
		}
	})

	t.Run("local-only needs only a url", func(t *testing.T) {
		o, err := guiBuildOptions("u", "", "", "", "", "", "", true)
		if err != nil {
			t.Fatalf("local-only should not require server/key: %v", err)
		}
		if !o.localOnly {
			t.Error("localOnly not set")
		}
	})

	t.Run("advanced values parse, bad values fall back", func(t *testing.T) {
		o, err := guiBuildOptions("u", "s", "k", "2", "90", "720", "chrome", false)
		if err != nil {
			t.Fatal(err)
		}
		if o.fps != 2 || o.jpegQuality != 90 || o.maxHeight != 720 || o.cookies != "chrome" {
			t.Errorf("advanced parse wrong: %+v", o)
		}
		bad, _ := guiBuildOptions("u", "s", "k", "notanumber", "x", "y", "", false)
		if bad.fps != 1 || bad.jpegQuality != 85 || bad.maxHeight != 480 {
			t.Errorf("bad values should fall back to defaults: %+v", bad)
		}
	})

	t.Run("non-positive fps coerced to 1", func(t *testing.T) {
		o, _ := guiBuildOptions("u", "s", "k", "0", "", "", "", false)
		if o.fps != 1 {
			t.Errorf("fps = %v, want 1", o.fps)
		}
	})
}

func TestGuiConfigRoundTrip(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)             // macOS: ~/Library/Application Support
	t.Setenv("XDG_CONFIG_HOME", dir)  // linux: honored by os.UserConfigDir

	want := guiConfig{Server: "https://s.example", APIKey: "sekret", FPS: 2, JPEGQuality: 90, MaxHeight: 720, Cookies: "firefox"}
	saveGUIConfig(want)

	got := loadGUIConfig()
	if got != want {
		t.Errorf("round-trip mismatch:\n got %+v\nwant %+v", got, want)
	}
}



func TestLoadGUIConfigDefaultsWhenMissing(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Setenv("XDG_CONFIG_HOME", dir)

	cfg := loadGUIConfig()
	if cfg.FPS != 1 || cfg.JPEGQuality != 85 || cfg.MaxHeight != 480 {
		t.Errorf("missing-config defaults wrong: %+v", cfg)
	}
}
