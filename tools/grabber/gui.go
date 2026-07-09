package main

// Native desktop front-end (Fyne) for framecut-grab. Launched when the binary
// is double-clicked or run with the `gui` verb. It drives the exact same
// runPipeline() as the CLI, streaming progress into an on-screen log, and
// remembers the server URL + API key between runs.

import (
	_ "embed"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"
)

//go:embed Icon.png
var iconPNG []byte

// guiConfig is the small set of settings we persist so users don't retype
// their server and key on every run.
type guiConfig struct {
	Server      string  `json:"server"`
	APIKey      string  `json:"api_key"`
	FPS         float64 `json:"fps"`
	JPEGQuality int     `json:"jpeg_quality"`
	MaxHeight   int     `json:"max_height"`
	Cookies     string  `json:"cookies"`
}

func runGUI() {
	// Dark UI to match the Framecut brand, regardless of the OS setting.
	_ = os.Setenv("FYNE_THEME", "dark")

	a := app.NewWithID("online.bobbby.framecut.grabber")
	a.SetIcon(fyne.NewStaticResource("icon.png", iconPNG))

	w := a.NewWindow("Framecut Grabber")
	w.Resize(fyne.NewSize(680, 760))
	w.CenterOnScreen()

	cfg := loadGUIConfig()

	urlEntry := widget.NewEntry()
	urlEntry.SetPlaceHolder("https://www.youtube.com/watch?v=…")

	serverEntry := widget.NewEntry()
	serverEntry.SetPlaceHolder("https://your-framecut.example")
	serverEntry.SetText(cfg.Server)

	keyEntry := widget.NewPasswordEntry()
	keyEntry.SetPlaceHolder("INGEST_API_KEY")
	keyEntry.SetText(cfg.APIKey)

	fpsEntry := widget.NewEntry()
	fpsEntry.SetText(trimFloat(cfg.FPS))
	qualityEntry := widget.NewEntry()
	qualityEntry.SetText(strconv.Itoa(cfg.JPEGQuality))
	heightEntry := widget.NewEntry()
	heightEntry.SetText(strconv.Itoa(cfg.MaxHeight))

	cookieSelect := widget.NewSelect(
		[]string{"none", "chrome", "firefox", "safari", "edge", "brave"}, nil)
	if cfg.Cookies == "" {
		cookieSelect.SetSelected("none")
	} else {
		cookieSelect.SetSelected(cfg.Cookies)
	}

	localOnly := widget.NewCheck("Local only — skip upload, keep the files", nil)

	mainForm := widget.NewForm(
		widget.NewFormItem("Video URL", urlEntry),
		widget.NewFormItem("Server URL", serverEntry),
		widget.NewFormItem("API key", keyEntry),
	)

	advanced := widget.NewForm(
		widget.NewFormItem("Frames / sec", fpsEntry),
		widget.NewFormItem("JPEG quality", qualityEntry),
		widget.NewFormItem("Max height", heightEntry),
		widget.NewFormItem("Cookies from", cookieSelect),
	)
	adv := widget.NewAccordion(widget.NewAccordionItem("Advanced options", advanced))

	logView := widget.NewMultiLineEntry()
	logView.Wrapping = fyne.TextWrapWord
	logView.Disable()
	logScroll := container.NewVScroll(logView)
	logScroll.SetMinSize(fyne.NewSize(0, 220))

	resultLink := widget.NewHyperlink("", nil)
	resultLink.Hide()

	// logBuf is only ever touched on the UI goroutine (inside fyne.Do or the
	// tap handler), so no locking is needed.
	var logBuf strings.Builder
	appendLine := func(s string) {
		fyne.Do(func() {
			logBuf.WriteString(s)
			logBuf.WriteByte('\n')
			logView.SetText(logBuf.String())
			logView.CursorRow = strings.Count(logBuf.String(), "\n")
			logScroll.ScrollToBottom()
		})
	}

	var running atomic.Bool
	grabBtn := widget.NewButton("Grab it", nil)
	grabBtn.Importance = widget.HighImportance

	grabBtn.OnTapped = func() {
		if !running.CompareAndSwap(false, true) {
			return
		}

		cookies := cookieSelect.Selected
		if cookies == "none" {
			cookies = ""
		}
		opts, err := guiBuildOptions(urlEntry.Text, serverEntry.Text, keyEntry.Text,
			fpsEntry.Text, qualityEntry.Text, heightEntry.Text, cookies, localOnly.Checked)
		if err != nil {
			running.Store(false)
			dialog.ShowError(err, w)
			return
		}

		saveGUIConfig(guiConfig{
			Server:      opts.server,
			APIKey:      opts.apiKey,
			FPS:         opts.fps,
			JPEGQuality: opts.jpegQuality,
			MaxHeight:   opts.maxHeight,
			Cookies:     cookies,
		})

		// This handler runs on the UI goroutine, so update widgets directly
		// (fyne.Do is only for background goroutines).
		logBuf.Reset()
		logView.SetText("")
		resultLink.Hide()
		grabBtn.Disable()
		grabBtn.SetText("Working…")

		// Route the shared pipeline's output into the on-screen log.
		logLine = appendLine
		procOut = &lineWriter{}

		go func() {
			resultURL, err := runPipeline(opts)

			switch {
			case err != nil:
				appendLine("")
				appendLine("error: " + err.Error())
			case resultURL != "":
				appendLine("")
				appendLine("done!")
				fyne.Do(func() {
					resultLink.SetText("Open " + resultURL)
					_ = resultLink.SetURLFromString(resultURL)
					resultLink.Show()
				})
			default:
				appendLine("")
				appendLine("done — files kept locally.")
			}

			running.Store(false)
			fyne.Do(func() {
				grabBtn.Enable()
				grabBtn.SetText("Grab it")
			})
		}()
	}

	header := container.NewVBox(
		widget.NewLabelWithStyle("Framecut Grabber", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		widget.NewLabel("Paste a video link and hit Grab — frames land on your Framecut server."),
		widget.NewLabelWithStyle("Only grab content you own or have the rights to use.",
			fyne.TextAlignLeading, fyne.TextStyle{Italic: true}),
	)

	top := container.NewVBox(
		header,
		widget.NewSeparator(),
		mainForm,
		adv,
		localOnly,
		container.NewPadded(grabBtn),
		resultLink,
		widget.NewLabelWithStyle("Progress", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
	)

	w.SetContent(container.NewPadded(container.NewBorder(top, nil, nil, nil, logScroll)))
	w.ShowAndRun()
}

func guiBuildOptions(urlS, serverS, keyS, fpsS, qualityS, heightS, cookies string, localOnly bool) (options, error) {
	o := options{
		url:       strings.TrimSpace(urlS),
		server:    strings.TrimRight(strings.TrimSpace(serverS), "/"),
		apiKey:    strings.TrimSpace(keyS),
		cookies:   strings.TrimSpace(cookies),
		batchSize: 10,
		localOnly: localOnly,
	}
	if o.url == "" {
		return o, errors.New("enter a video URL")
	}
	o.fps = parseFloatOr(fpsS, 1)
	if o.fps <= 0 {
		o.fps = 1
	}
	o.jpegQuality = parseIntOr(qualityS, 85)
	o.maxHeight = parseIntOr(heightS, 480)

	if !localOnly && (o.server == "" || o.apiKey == "") {
		return o, errors.New("Server URL and API key are required (or tick “Local only”)")
	}
	return o, nil
}

// --- config persistence ------------------------------------------------------

func guiConfigPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "framecut", "grabber.json"), nil
}

func loadGUIConfig() guiConfig {
	cfg := guiConfig{FPS: 1, JPEGQuality: 85, MaxHeight: 480}
	path, err := guiConfigPath()
	if err != nil {
		return cfg
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg
	}
	_ = json.Unmarshal(data, &cfg)
	if cfg.FPS <= 0 {
		cfg.FPS = 1
	}
	if cfg.JPEGQuality <= 0 {
		cfg.JPEGQuality = 85
	}
	if cfg.MaxHeight <= 0 {
		cfg.MaxHeight = 480
	}
	return cfg
}

func saveGUIConfig(cfg guiConfig) {
	path, err := guiConfigPath()
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0o600)
}

// --- small parse helpers -----------------------------------------------------

func parseFloatOr(s string, def float64) float64 {
	if v, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err == nil {
		return v
	}
	return def
}

func parseIntOr(s string, def int) int {
	if v, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
		return v
	}
	return def
}

func trimFloat(f float64) string {
	return strconv.FormatFloat(f, 'g', -1, 64)
}
