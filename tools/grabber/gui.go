package main

// Native desktop front-end (Fyne) for framecut-grab. Launched when the binary
// is double-clicked or run with the `gui` verb. It drives the exact same
// runPipeline() as the CLI, streaming progress into an on-screen log, and
// remembers the server URL + API key between runs. First runs (no saved
// config file yet) get a short guided wizard instead of the full form.

import (
	_ "embed"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/layout"
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
	OutputDir   string  `json:"output_dir"`
}

func runGUI() {
	// Dark UI to match the Framecut brand, regardless of the OS setting.
	_ = os.Setenv("FYNE_THEME", "dark")

	a := app.NewWithID("online.bobbby.framecut.grabber")
	a.SetIcon(fyne.NewStaticResource("icon.png", iconPNG))

	w := a.NewWindow("Framecut Grabber")
	w.Resize(fyne.NewSize(680, 760))
	w.CenterOnScreen()

	ui := newGrabUI(a, w)

	// Returning users (a config file on disk) land on the classic one-screen
	// form. No file yet means a first run, which gets the guided wizard —
	// seeded from FRAMECUT_SERVER / FRAMECUT_API_KEY so env-configured users
	// only have to confirm.
	cfg, haveConfig := loadGUIConfigFile()
	if haveConfig {
		w.SetContent(ui.mainScreen(cfg))
	} else {
		cfg.Server = strings.TrimSpace(os.Getenv("FRAMECUT_SERVER"))
		cfg.APIKey = strings.TrimSpace(os.Getenv("FRAMECUT_API_KEY"))
		w.SetContent(ui.wizardWelcome(cfg))
	}
	w.ShowAndRun()
}

// grabUI owns the state shared by every screen — the streaming log, its
// repaint pump, and the single-run guard — so the wizard steps and the main
// form can be swapped into the window without re-wiring the pipeline hooks.
type grabUI struct {
	app fyne.App
	win fyne.Window

	logView   *widget.Entry
	logScroll *container.Scroll

	// yt-dlp and ffmpeg emit hundreds of progress lines a second. Repainting
	// the widget on every line floods the UI thread and freezes the window,
	// so lines are buffered under a lock and pumpLog repaints at a fixed rate.
	logMu    sync.Mutex
	logLines []string
	logDirty bool

	running atomic.Bool
}

const maxLogLines = 500

func newGrabUI(a fyne.App, w fyne.Window) *grabUI {
	logView := widget.NewMultiLineEntry()
	logView.Wrapping = fyne.TextWrapWord
	logView.Disable()
	logScroll := container.NewVScroll(logView)
	logScroll.SetMinSize(fyne.NewSize(0, 220))

	ui := &grabUI{app: a, win: w, logView: logView, logScroll: logScroll}
	go ui.pumpLog()
	return ui
}

func (ui *grabUI) appendLine(s string) {
	ui.logMu.Lock()
	// Collapse consecutive download-progress lines into one updating line
	// instead of thousands of rows.
	if n := len(ui.logLines); n > 0 && isProgressLine(s) && isProgressLine(ui.logLines[n-1]) {
		ui.logLines[n-1] = s
	} else {
		ui.logLines = append(ui.logLines, s)
		if len(ui.logLines) > maxLogLines {
			ui.logLines = ui.logLines[len(ui.logLines)-maxLogLines:]
		}
	}
	ui.logDirty = true
	ui.logMu.Unlock()
}

func (ui *grabUI) resetLog() {
	ui.logMu.Lock()
	ui.logLines = ui.logLines[:0]
	ui.logDirty = true
	ui.logMu.Unlock()
}

// pumpLog coalesces buffered lines into a single widget update ~12×/sec, and
// only when something actually changed.
func (ui *grabUI) pumpLog() {
	ticker := time.NewTicker(80 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		ui.logMu.Lock()
		if !ui.logDirty {
			ui.logMu.Unlock()
			continue
		}
		text := strings.Join(ui.logLines, "\n")
		ui.logDirty = false
		ui.logMu.Unlock()

		fyne.Do(func() {
			ui.logView.SetText(text)
			ui.logScroll.ScrollToBottom()
		})
	}
}

// startGrab routes the shared pipeline's output into the on-screen log and
// runs it on a background goroutine. onDone is delivered on the UI thread;
// callers own the ui.running guard.
func (ui *grabUI) startGrab(opts options, onDone func(*grabResult, error)) {
	ui.resetLog()
	logLine = ui.appendLine
	procOut = &lineWriter{}

	go func() {
		res, err := runPipeline(opts)
		fyne.Do(func() { onDone(res, err) })
	}()
}

// mainScreen is the classic one-screen form for returning users: URL, server,
// key, advanced options, and the streaming log below.
func (ui *grabUI) mainScreen(cfg guiConfig) fyne.CanvasObject {
	urlEntry := widget.NewEntry()
	urlEntry.SetPlaceHolder("https://www.youtube.com/watch?v=…")

	serverEntry := widget.NewEntry()
	serverEntry.SetPlaceHolder("https://your-framecut.example")
	serverEntry.SetText(cfg.Server)

	keyEntry := widget.NewPasswordEntry()
	keyEntry.SetPlaceHolder("fc_… (from your server's /setup page)")
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

	// Where kept files land (used with Local only / --keep-files). Defaults to
	// ~/Downloads/Framecut so a Finder/Explorer launch never writes to a bad CWD.
	outputEntry := widget.NewEntry()
	if cfg.OutputDir != "" {
		outputEntry.SetText(cfg.OutputDir)
	} else {
		outputEntry.SetText(defaultOutputDir())
	}
	browseBtn := widget.NewButton("Browse…", func() {
		dialog.ShowFolderOpen(func(u fyne.ListableURI, err error) {
			if err == nil && u != nil {
				outputEntry.SetText(u.Path())
			}
		}, ui.win)
	})
	outputRow := container.NewBorder(nil, nil, widget.NewLabel("Save to"), browseBtn, outputEntry)

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

	// Success state: jump straight to the freshly uploaded video's editor.
	var editorURL string
	openBtn := widget.NewButton("Open in Framecut →", func() {
		openInBrowser(ui.app, editorURL)
	})
	openBtn.Importance = widget.HighImportance
	openBtn.Hide()

	grabBtn := widget.NewButton("Grab it", nil)
	grabBtn.Importance = widget.HighImportance

	grabBtn.OnTapped = func() {
		if !ui.running.CompareAndSwap(false, true) {
			return
		}

		cookies := cookieSelect.Selected
		if cookies == "none" {
			cookies = ""
		}
		opts, err := guiBuildOptions(urlEntry.Text, serverEntry.Text, keyEntry.Text,
			fpsEntry.Text, qualityEntry.Text, heightEntry.Text, cookies, localOnly.Checked)
		if err != nil {
			ui.running.Store(false)
			dialog.ShowError(err, ui.win)
			return
		}
		opts.outputDir = strings.TrimSpace(outputEntry.Text)

		saveGUIConfig(guiConfig{
			Server:      opts.server,
			APIKey:      opts.apiKey,
			FPS:         opts.fps,
			JPEGQuality: opts.jpegQuality,
			MaxHeight:   opts.maxHeight,
			Cookies:     cookies,
			OutputDir:   opts.outputDir,
		})

		// This handler runs on the UI goroutine, so update widgets directly
		// (fyne.Do is only for background goroutines).
		openBtn.Hide()
		grabBtn.Disable()
		grabBtn.SetText("Working…")

		ui.startGrab(opts, func(res *grabResult, err error) {
			switch {
			case err != nil:
				ui.appendLine("")
				ui.appendLine("error: " + err.Error())
			case res != nil && res.editorURL != "":
				ui.appendLine("")
				ui.appendLine("done! " + res.editorURL)
				editorURL = res.editorURL
				openBtn.Show()
			default:
				ui.appendLine("")
				ui.appendLine("done — files kept locally.")
			}
			ui.running.Store(false)
			grabBtn.Enable()
			grabBtn.SetText("Grab it")
		})
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
		outputRow,
		container.NewPadded(grabBtn),
		openBtn,
		widget.NewLabelWithStyle("Progress", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
	)

	return container.NewPadded(container.NewBorder(top, nil, nil, nil, ui.logScroll))
}

// --- first-run wizard ----------------------------------------------------

// wizardWelcome is step 1: one bold promise and a Continue button.
func (ui *grabUI) wizardWelcome(cfg guiConfig) fyne.CanvasObject {
	headline := widget.NewLabelWithStyle("Let's rip your first video into frames.",
		fyne.TextAlignCenter, fyne.TextStyle{Bold: true})

	cont := widget.NewButton("Continue", func() {
		ui.win.SetContent(ui.wizardConnect(cfg))
	})
	cont.Importance = widget.HighImportance

	return container.NewPadded(container.NewVBox(
		layout.NewSpacer(),
		headline,
		container.NewPadded(container.NewCenter(cont)),
		layout.NewSpacer(),
	))
}

// wizardConnect is step 2: collect the server URL and per-user API key,
// pointing at the server's /setup page where keys are issued. The fields
// arrive prefilled from FRAMECUT_SERVER / FRAMECUT_API_KEY when those are set.
func (ui *grabUI) wizardConnect(cfg guiConfig) fyne.CanvasObject {
	serverEntry := widget.NewEntry()
	serverEntry.SetPlaceHolder("https://your-framecut.example")
	serverEntry.SetText(cfg.Server)

	keyEntry := widget.NewPasswordEntry()
	keyEntry.SetPlaceHolder("fc_…")
	keyEntry.SetText(cfg.APIKey)

	// The /setup link tracks whatever is typed in the server field, so users
	// can jump straight to the page that shows their key. With no server yet
	// the link has no URL and clicking it is a no-op.
	setupLink := widget.NewHyperlink("Open your server's /setup page", nil)
	syncSetupLink := func(s string) {
		base := strings.TrimRight(strings.TrimSpace(s), "/")
		if base == "" {
			setupLink.SetURL(nil)
			return
		}
		if u, err := url.Parse(base + "/setup"); err == nil {
			setupLink.SetURL(u)
		}
	}
	serverEntry.OnChanged = syncSetupLink
	syncSetupLink(serverEntry.Text)

	form := widget.NewForm(
		widget.NewFormItem("Server URL", serverEntry),
		widget.NewFormItem("API key", keyEntry),
	)

	cont := widget.NewButton("Continue", func() {
		cfg.Server = strings.TrimRight(strings.TrimSpace(serverEntry.Text), "/")
		cfg.APIKey = strings.TrimSpace(keyEntry.Text)
		if cfg.Server == "" || cfg.APIKey == "" {
			dialog.ShowError(errors.New("enter both the server URL and an API key"), ui.win)
			return
		}
		// Persist right away so a returning user skips the wizard even if
		// they close the app before their first rip finishes.
		saveGUIConfig(cfg)
		ui.win.SetContent(ui.wizardFirstRip(cfg))
	})
	cont.Importance = widget.HighImportance

	return container.NewPadded(container.NewVBox(
		widget.NewLabelWithStyle("Connect to your Framecut server",
			fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		form,
		widget.NewLabelWithStyle("Your key lives at your Framecut server's /setup page.",
			fyne.TextAlignLeading, fyne.TextStyle{Italic: true}),
		setupLink,
		container.NewPadded(cont),
	))
}

// wizardFirstRip is step 3: paste a link, hit Grab, and watch the same
// streaming log the main screen uses. Success moves on to the done screen;
// failures stay here with the error at the bottom of the log.
func (ui *grabUI) wizardFirstRip(cfg guiConfig) fyne.CanvasObject {
	urlEntry := widget.NewEntry()
	urlEntry.SetPlaceHolder("https://www.youtube.com/watch?v=…")

	grabBtn := widget.NewButton("Grab it", nil)
	grabBtn.Importance = widget.HighImportance

	grabBtn.OnTapped = func() {
		if !ui.running.CompareAndSwap(false, true) {
			return
		}
		opts, err := guiBuildOptions(urlEntry.Text, cfg.Server, cfg.APIKey,
			trimFloat(cfg.FPS), strconv.Itoa(cfg.JPEGQuality), strconv.Itoa(cfg.MaxHeight),
			cfg.Cookies, false)
		if err != nil {
			ui.running.Store(false)
			dialog.ShowError(err, ui.win)
			return
		}

		grabBtn.Disable()
		grabBtn.SetText("Working…")

		ui.startGrab(opts, func(res *grabResult, err error) {
			ui.running.Store(false)
			if err != nil {
				ui.appendLine("")
				ui.appendLine("error: " + err.Error())
				grabBtn.Enable()
				grabBtn.SetText("Grab it")
				return
			}
			ui.win.SetContent(ui.wizardDone(cfg, res))
		})
	}

	top := container.NewVBox(
		widget.NewLabelWithStyle("Grab your first video",
			fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		widget.NewLabel("Paste a video link — frames land on your Framecut server."),
		widget.NewLabelWithStyle("Only grab content you own or have the rights to use.",
			fyne.TextAlignLeading, fyne.TextStyle{Italic: true}),
		widget.NewForm(widget.NewFormItem("Video URL", urlEntry)),
		container.NewPadded(grabBtn),
		widget.NewLabelWithStyle("Progress", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
	)

	return container.NewPadded(container.NewBorder(top, nil, nil, nil, ui.logScroll))
}

// wizardDone is step 4: a prominent jump into the editor for the video that
// just landed (user-initiated — never auto-opened), plus a way back to the
// regular screen for the next rip.
func (ui *grabUI) wizardDone(cfg guiConfig, res *grabResult) fyne.CanvasObject {
	headline := widget.NewLabelWithStyle("Your video is on the server.",
		fyne.TextAlignCenter, fyne.TextStyle{Bold: true})
	sub := widget.NewLabelWithStyle("Pick a frame range in the editor to make your first GIF.",
		fyne.TextAlignCenter, fyne.TextStyle{})

	openBtn := widget.NewButton("Open in Framecut →", func() {
		if res != nil {
			openInBrowser(ui.app, res.editorURL)
		}
	})
	openBtn.Importance = widget.HighImportance
	if res == nil || res.editorURL == "" {
		openBtn.Hide()
	}

	again := widget.NewButton("Rip another", func() {
		ui.win.SetContent(ui.mainScreen(cfg))
	})

	return container.NewPadded(container.NewVBox(
		layout.NewSpacer(),
		headline,
		sub,
		container.NewPadded(container.NewCenter(openBtn)),
		container.NewCenter(again),
		layout.NewSpacer(),
	))
}

// isProgressLine reports whether a log line is a yt-dlp/ffmpeg progress tick
// (e.g. "[download]  42.6% ... ETA 00:09") so the log can collapse the stream
// of them into a single updating row.
func isProgressLine(s string) bool {
	t := strings.TrimSpace(s)
	return strings.HasPrefix(t, "[download]") && (strings.Contains(t, "%") || strings.Contains(t, "ETA"))
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

// openInBrowser opens an absolute URL in the user's default browser through
// the OS integration Fyne provides; a blank or unparsable URL is ignored.
func openInBrowser(a fyne.App, raw string) {
	if raw == "" {
		return
	}
	if u, err := url.Parse(raw); err == nil {
		_ = a.OpenURL(u)
	}
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
	cfg, _ := loadGUIConfigFile()
	return cfg
}

// loadGUIConfigFile loads the saved config and reports whether a config file
// was actually read — the first-run wizard keys off "no file yet", which the
// defaults-only guiConfig value alone can't distinguish.
func loadGUIConfigFile() (guiConfig, bool) {
	cfg := guiConfig{FPS: 1, JPEGQuality: 85, MaxHeight: 480}
	path, err := guiConfigPath()
	if err != nil {
		return cfg, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, false
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
	return cfg, true
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
