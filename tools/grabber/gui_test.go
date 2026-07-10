package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMakeWorkdirUsesOutputDir(t *testing.T) {
	target := filepath.Join(t.TempDir(), "kept")

	wd, cleanup, err := makeWorkdir(options{localOnly: true, outputDir: target})
	defer cleanup()
	if err != nil {
		t.Fatalf("makeWorkdir: %v", err)
	}
	if wd != target {
		t.Errorf("workdir = %q, want %q", wd, target)
	}
	if fi, err := os.Stat(wd); err != nil || !fi.IsDir() {
		t.Errorf("output dir not created: %v", err)
	}
}

func TestMakeWorkdirEphemeralIsCleaned(t *testing.T) {
	wd, cleanup, err := makeWorkdir(options{}) // upload mode: temp + cleanup
	if err != nil {
		t.Fatalf("makeWorkdir: %v", err)
	}
	if _, err := os.Stat(wd); err != nil {
		t.Fatalf("temp workdir missing: %v", err)
	}
	cleanup()
	if _, err := os.Stat(wd); !os.IsNotExist(err) {
		t.Errorf("temp workdir not removed after cleanup")
	}
}

func TestDefaultOutputDir(t *testing.T) {
	got := defaultOutputDir()
	if got != "framecut_grab" && !strings.HasSuffix(got, filepath.Join("Downloads", "Framecut")) {
		t.Errorf("unexpected default output dir: %q", got)
	}
}

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

func TestIsProgressLine(t *testing.T) {
	progress := []string{
		"[download]  42.6% of  160.46MiB at  Unknown B/s ETA Unknown",
		"[download] 100% of  160.46MiB in 00:00:23 at 6.95MiB/s",
		"  [download]  48.5% of 160MiB at 9.65MiB/s ETA 00:08",
	}
	for _, s := range progress {
		if !isProgressLine(s) {
			t.Errorf("expected progress line: %q", s)
		}
	}

	notProgress := []string{
		"[download] Destination: /tmp/video.mp4",
		"downloading video + subtitles...",
		"slicing frames...",
		"sliced 214 frames at 1 fps",
		"",
	}
	for _, s := range notProgress {
		if isProgressLine(s) {
			t.Errorf("did not expect progress line: %q", s)
		}
	}
}

func TestGuiConfigRoundTrip(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)            // macOS: ~/Library/Application Support
	t.Setenv("XDG_CONFIG_HOME", dir) // linux: honored by os.UserConfigDir

	want := guiConfig{Server: "https://s.example", APIKey: "sekret", FPS: 2, JPEGQuality: 90, MaxHeight: 720, Cookies: "firefox", OutputDir: "/tmp/framecut-out"}
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
