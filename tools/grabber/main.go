// framecut-grab: grab a video (YouTube or any yt-dlp-supported URL), slice it
// into 1fps JPEG frames, and upload frames + captions to a Framecut server.
//
// Fully self-contained: the official self-contained yt-dlp build and a static
// ffmpeg are embedded in this binary and extracted to a per-user cache
// directory on first run. No Python, no package manager, no PATH setup.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"image/jpeg"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type options struct {
	url         string
	server      string
	apiKey      string
	fps         float64
	jpegQuality int
	maxHeight   int
	batchSize   int
	cookies     string
	keepFiles   bool
	localOnly   bool
	title       string
}

type caption struct {
	StartTimeMs  int    `json:"start_time_ms"`
	EndTimeMs    int    `json:"end_time_ms"`
	Text         string `json:"text"`
	CaptionIndex int    `json:"caption_index"`
}

type frame struct {
	FrameNumber      int     `json:"frame_number"`
	TimestampMs      int     `json:"timestamp_ms"`
	FileSize         int     `json:"file_size"`
	Width            int     `json:"width"`
	Height           int     `json:"height"`
	ImageData        string  `json:"image_data"`
	CompressionRatio float64 `json:"compression_ratio"`
}

// Progress plumbing shared by the CLI and GUI. logLine receives our own
// human-readable status lines; procOut receives the raw stdout/stderr of the
// child yt-dlp / ffmpeg processes. The CLI writes both straight to the
// terminal; the GUI swaps in writers that append to the on-screen log.
var (
	logLine           = func(s string) { fmt.Println(s) }
	procOut io.Writer = os.Stdout
)

// lineWriter forwards child-process output to logLine one whole line at a time,
// so GUI log updates land as discrete lines rather than partial byte chunks.
type lineWriter struct{ buf []byte }

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimRight(string(w.buf[:i]), "\r")
		if line != "" {
			logLine(line)
		}
		w.buf = append(w.buf[:0], w.buf[i+1:]...)
	}
	return len(p), nil
}

func main() {
	// No arguments (a Finder/Explorer double-click) or the explicit "gui"
	// verb opens the desktop app; a URL argument runs the classic CLI.
	if len(os.Args) <= 1 || os.Args[1] == "gui" {
		runGUI()
		return
	}

	opts := parseFlags()

	logLine("framecut-grab — slice any video into GIF-ready frames")
	logLine("note: only grab content you own or have the rights to use.")
	logLine("")

	resultURL, err := runPipeline(opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	if resultURL != "" {
		logLine("\ndone! watch it at " + resultURL)
	} else {
		logLine("\ndone!")
	}
}

// runPipeline runs the full grab — unpack tools, fetch metadata, download,
// slice frames, parse captions, and (unless --local-only) upload. Progress is
// emitted through logLine so the CLI and GUI share one implementation. Returns
// the resulting watch URL when an upload happened, or "" for --local-only.
func runPipeline(opts options) (string, error) {
	ytdlp, ffmpeg, err := ensureTools()
	if err != nil {
		return "", fmt.Errorf("setting up bundled tools: %w", err)
	}

	workdir, cleanup, err := makeWorkdir(opts)
	if err != nil {
		return "", fmt.Errorf("creating work directory: %w", err)
	}
	defer cleanup()

	meta, err := fetchMetadata(ytdlp, opts)
	if err != nil {
		return "", fmt.Errorf("reading video metadata: %w", err)
	}
	title := opts.title
	if title == "" {
		title = meta.title
	}
	logLine(fmt.Sprintf("video: %s (%s, %ds)", title, meta.id, meta.durationS))

	videoPath, subsPath, err := download(ytdlp, ffmpeg, opts, workdir)
	if err != nil {
		return "", fmt.Errorf("downloading video: %w", err)
	}

	framesDir := filepath.Join(workdir, "frames")
	frames, err := sliceFrames(ffmpeg, opts, videoPath, framesDir)
	if err != nil {
		return "", fmt.Errorf("extracting frames: %w", err)
	}
	logLine(fmt.Sprintf("sliced %d frames at %.2g fps", len(frames), opts.fps))

	captions := parseSubtitles(subsPath)
	if len(captions) > 0 {
		logLine(fmt.Sprintf("parsed %d captions", len(captions)))
	} else {
		logLine("no captions found (video will not be text-searchable)")
	}

	if opts.localOnly {
		logLine("")
		logLine("--local-only: files kept in " + workdir)
		logLine("upload the video (and captions) through the site's /add page.")
		return "", nil
	}

	return upload(opts, meta, title, frames, captions)
}

func parseFlags() options {
	var o options
	flag.StringVar(&o.server, "server", "", "Framecut server base URL, e.g. https://example.com")
	flag.StringVar(&o.apiKey, "api-key", "", "API key sent as the X-API-Key header")
	flag.Float64Var(&o.fps, "fps", 1.0, "frames per second to extract")
	flag.IntVar(&o.jpegQuality, "jpeg-quality", 85, "JPEG quality 0-100")
	flag.IntVar(&o.maxHeight, "max-height", 480, "max frame height in pixels; smaller videos are kept as-is")
	flag.IntVar(&o.batchSize, "batch-size", 10, "frames per upload request")
	flag.StringVar(&o.cookies, "cookies-from-browser", "", "passed through to yt-dlp, e.g. chrome, firefox, safari")
	flag.BoolVar(&o.keepFiles, "keep-files", false, "keep the downloaded files and extracted frames")
	flag.BoolVar(&o.localOnly, "local-only", false, "skip the upload; keep the mp4 + subtitles for the /add web upload flow")
	flag.StringVar(&o.title, "title", "", "override the video title")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: %s <video-url> [flags]\n\nflags:\n", filepath.Base(os.Args[0]))
		flag.PrintDefaults()
	}

	// Go's flag package stops at the first positional argument, but the
	// natural way to call this tool is `framecut-grab <url> --server ...`.
	// Reorder so flags come first, then parse.
	flags, positionals := reorderArgs(os.Args[1:])
	_ = flag.CommandLine.Parse(append(flags, positionals...))

	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	o.url = flag.Arg(0)

	if !o.localOnly {
		if o.server == "" || o.apiKey == "" {
			fmt.Fprintln(os.Stderr, "error: --server and --api-key are required (or use --local-only)")
			os.Exit(2)
		}
		o.server = strings.TrimRight(o.server, "/")
	}
	if o.fps <= 0 {
		fmt.Fprintln(os.Stderr, "error: --fps must be positive")
		os.Exit(2)
	}
	return o
}

// ensureTools extracts the embedded yt-dlp and ffmpeg into a per-user cache
// directory keyed by their content hash, so upgraded binaries never collide
// with previously extracted ones.
func ensureTools() (ytdlp, ffmpeg string, err error) {
	cacheRoot, err := os.UserCacheDir()
	if err != nil {
		return "", "", err
	}

	sum := sha256.New()
	sum.Write(ytdlpBin)
	sum.Write(ffmpegBin)
	dir := filepath.Join(cacheRoot, "framecut", "tools", hex.EncodeToString(sum.Sum(nil))[:12])

	ytdlp = filepath.Join(dir, "yt-dlp"+exeSuffix)
	ffmpeg = filepath.Join(dir, "ffmpeg"+exeSuffix)

	if fileExists(ytdlp) && fileExists(ffmpeg) {
		return ytdlp, ffmpeg, nil
	}

	logLine("first run: unpacking bundled yt-dlp + ffmpeg to " + dir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", "", err
	}
	if err := writeExecutable(ytdlp, ytdlpBin); err != nil {
		return "", "", err
	}
	if err := writeExecutable(ffmpeg, ffmpegBin); err != nil {
		return "", "", err
	}
	return ytdlp, ffmpeg, nil
}

func writeExecutable(path string, data []byte) error {
	// Write to a temp name then rename, so a concurrent or interrupted run
	// never sees a half-written executable.
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o755); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func makeWorkdir(opts options) (string, func(), error) {
	if opts.keepFiles || opts.localOnly {
		dir, err := filepath.Abs("framecut_grab")
		if err == nil {
			err = os.MkdirAll(dir, 0o755)
		}
		return dir, func() {}, err
	}

	dir, err := os.MkdirTemp("", "framecut-grab-")
	return dir, func() { os.RemoveAll(dir) }, err
}

type metadata struct {
	id        string
	title     string
	durationS int
}

func fetchMetadata(ytdlp string, opts options) (metadata, error) {
	args := []string{"--skip-download", "--no-playlist", "--print", "%(id)s\n%(title)s\n%(duration)s"}
	args = append(args, cookieArgs(opts)...)
	args = append(args, opts.url)

	out, err := runCapture(ytdlp, args...)
	if err != nil {
		return metadata{}, err
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 3 {
		return metadata{}, fmt.Errorf("unexpected yt-dlp metadata output: %q", out)
	}
	duration, _ := strconv.ParseFloat(strings.TrimSpace(lines[2]), 64)
	return metadata{
		id:        strings.TrimSpace(lines[0]),
		title:     strings.TrimSpace(lines[1]),
		durationS: int(duration),
	}, nil
}

func download(ytdlp, ffmpeg string, opts options, workdir string) (videoPath, subsPath string, err error) {
	logLine("downloading video + subtitles...")

	args := []string{
		"--no-playlist",
		"--ffmpeg-location", ffmpeg,
		"-f", "bv*[ext=mp4][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/b",
		"--write-auto-subs", "--write-subs", "--sub-langs", "en.*,en",
		"-o", filepath.Join(workdir, "video.%(ext)s"),
	}
	args = append(args, cookieArgs(opts)...)
	args = append(args, opts.url)

	if err := runStreaming(ytdlp, args...); err != nil {
		return "", "", err
	}

	matches, _ := filepath.Glob(filepath.Join(workdir, "video.*"))
	for _, m := range matches {
		switch strings.ToLower(filepath.Ext(m)) {
		case ".mp4", ".mkv", ".webm", ".mov":
			videoPath = m
		case ".vtt", ".srt":
			// Prefer the first subtitle file alphabetically (video.en.vtt
			// sorts before video.en-orig.vtt), but any is fine.
			if subsPath == "" {
				subsPath = m
			}
		}
	}
	sort.Strings(matches)
	if videoPath == "" {
		return "", "", fmt.Errorf("yt-dlp finished but no video file found in %s", workdir)
	}
	return videoPath, subsPath, nil
}

func sliceFrames(ffmpeg string, opts options, videoPath, framesDir string) ([]frame, error) {
	if err := os.MkdirAll(framesDir, 0o755); err != nil {
		return nil, err
	}

	logLine("slicing frames...")
	vf := fmt.Sprintf("fps=%g,scale=-2:'min(%d,ih)'", opts.fps, opts.maxHeight)
	err := runStreaming(ffmpeg,
		"-hide_banner", "-loglevel", "error",
		"-i", videoPath,
		"-vf", vf,
		"-q:v", strconv.Itoa(qualityToQscale(opts.jpegQuality)),
		filepath.Join(framesDir, "frame_%08d.jpg"),
	)
	if err != nil {
		return nil, err
	}

	paths, err := filepath.Glob(filepath.Join(framesDir, "frame_*.jpg"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		return nil, fmt.Errorf("ffmpeg produced no frames")
	}

	frames := make([]frame, 0, len(paths))
	for i, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		w, h := jpegDims(data)
		frames = append(frames, frame{
			FrameNumber:      i + 1,
			TimestampMs:      int(float64(i) * 1000.0 / opts.fps),
			FileSize:         len(data),
			Width:            w,
			Height:           h,
			ImageData:        base64.StdEncoding.EncodeToString(data),
			CompressionRatio: 1.0,
		})
	}
	return frames, nil
}

// qualityToQscale maps a familiar 0-100 JPEG quality to ffmpeg's -q:v scale,
// where 2 is best and 7 is worst (same mapping as the original Python tool).
func qualityToQscale(q int) int {
	switch {
	case q >= 90:
		return 2
	case q >= 80:
		return 3
	case q >= 70:
		return 4
	case q >= 60:
		return 5
	case q >= 50:
		return 6
	default:
		return 7
	}
}

func jpegDims(data []byte) (int, int) {
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return 0, 0
	}
	return cfg.Width, cfg.Height
}

// --- subtitles ---------------------------------------------------------------

var (
	srtTiming = regexp.MustCompile(`(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})`)
	vttShort  = regexp.MustCompile(`(?:^|\s)(\d{1,2}):(\d{2})\.(\d{3})\s*-->\s*(\d{1,2}):(\d{2})\.(\d{3})`)
	tagRe     = regexp.MustCompile(`<[^>]+>`)
)

// parseSubtitles reads an .srt or .vtt file into caption entries.
// Returns nil on any problem — captions are best-effort.
func parseSubtitles(path string) []caption {
	if path == "" {
		return nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}

	text := strings.ReplaceAll(string(raw), "\r\n", "\n")
	text = strings.TrimPrefix(text, "\uFEFF")

	var captions []caption
	index := 0
	seen := map[string]bool{}

	for _, block := range regexp.MustCompile(`\n\s*\n`).Split(text, -1) {
		lines := strings.Split(strings.TrimSpace(block), "\n")

		timingLine := -1
		var start, end int
		for i, line := range lines {
			if m := srtTiming.FindStringSubmatch(line); m != nil {
				start = tsMs(m[1], m[2], m[3], m[4])
				end = tsMs(m[5], m[6], m[7], m[8])
				timingLine = i
				break
			}
			if m := vttShort.FindStringSubmatch(line); m != nil {
				start = tsMs("0", m[1], m[2], m[3])
				end = tsMs("0", m[4], m[5], m[6])
				timingLine = i
				break
			}
		}
		if timingLine < 0 || end <= start {
			continue
		}

		var parts []string
		for _, line := range lines[timingLine+1:] {
			line = strings.TrimSpace(tagRe.ReplaceAllString(line, ""))
			if line != "" {
				parts = append(parts, line)
			}
		}
		body := strings.Join(parts, " ")
		if body == "" {
			continue
		}

		// Auto-generated YouTube subs repeat each line across overlapping
		// cues; drop exact duplicates of the previous cue's text.
		key := fmt.Sprintf("%d|%s", start, body)
		if seen[key] {
			continue
		}
		seen[key] = true

		captions = append(captions, caption{
			StartTimeMs:  start,
			EndTimeMs:    end,
			Text:         body,
			CaptionIndex: index,
		})
		index++
	}
	return captions
}

func tsMs(h, m, s, ms string) int {
	hi, _ := strconv.Atoi(h)
	mi, _ := strconv.Atoi(m)
	si, _ := strconv.Atoi(s)
	msi, _ := strconv.Atoi(ms)
	return ((hi*60+mi)*60+si)*1000 + msi
}

// --- upload ------------------------------------------------------------------

func upload(opts options, meta metadata, title string, frames []frame, captions []caption) (string, error) {
	endpoint := opts.server + "/api/videos/upload"

	durationMs := meta.durationS * 1000
	if durationMs == 0 {
		// Some extractors (e.g. generic direct URLs) don't know the duration
		// up front; the frame count at a known fps is just as accurate.
		durationMs = int(float64(len(frames)) * 1000.0 / opts.fps)
	}

	videoInfo := map[string]any{
		"title":       title,
		"file_path":   fmt.Sprintf("youtube/%s.mp4", meta.id),
		"duration_ms": durationMs,
		"fps":         opts.fps,
		"frame_count": len(frames),
		"metadata": map[string]any{
			"source":     "framecut-grab",
			"url":        opts.url,
			"youtube_id": meta.id,
		},
	}

	batches := (len(frames) + opts.batchSize - 1) / opts.batchSize
	var videoID any

	for i := 0; i < batches; i++ {
		lo := i * opts.batchSize
		hi := min(lo+opts.batchSize, len(frames))

		payload := map[string]any{
			"video":  videoInfo,
			"frames": frames[lo:hi],
			// The server clears + rebuilds captions when they're present, so
			// they ride along only with the first batch.
			"captions": []caption{},
		}
		if i == 0 {
			payload["captions"] = captions
		}

		resp, err := postWithRetry(endpoint, opts.apiKey, payload)
		if err != nil {
			return "", fmt.Errorf("batch %d/%d: %w", i+1, batches, err)
		}
		if id, ok := resp["video_id"]; ok {
			videoID = id
		}
		logLine(fmt.Sprintf("uploaded batch %d/%d (%d frames)", i+1, batches, hi-lo))
	}

	if videoID != nil {
		return fmt.Sprintf("%s/video/%v", opts.server, videoID), nil
	}
	return "", nil
}

func postWithRetry(endpoint, apiKey string, payload any) (map[string]any, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-API-Key", apiKey)

		client := &http.Client{Timeout: 120 * time.Second}
		resp, err := client.Do(req)
		if err == nil {
			respBody, _ := io.ReadAll(resp.Body)
			resp.Body.Close()

			switch {
			case resp.StatusCode >= 200 && resp.StatusCode < 300:
				var parsed map[string]any
				_ = json.Unmarshal(respBody, &parsed)
				return parsed, nil
			case resp.StatusCode == 401:
				return nil, fmt.Errorf("server rejected the API key (401)")
			case resp.StatusCode == 503:
				return nil, fmt.Errorf("server has ingest disabled (503) — is INGEST_API_KEY set?")
			case resp.StatusCode >= 500:
				lastErr = fmt.Errorf("server error %d: %s", resp.StatusCode, truncate(string(respBody), 300))
			default:
				return nil, fmt.Errorf("server returned %d: %s", resp.StatusCode, truncate(string(respBody), 300))
			}
		} else {
			lastErr = err
		}

		if attempt < 3 {
			wait := time.Duration(attempt*attempt) * 2 * time.Second
			logLine(fmt.Sprintf("  retrying in %s (%v)", wait, lastErr))
			time.Sleep(wait)
		}
	}
	return nil, lastErr
}

// reorderArgs splits args into flags (with their values) and positionals so
// flags may appear before or after the URL. Boolean flags take no value.
func reorderArgs(args []string) (flags, positionals []string) {
	boolFlags := map[string]bool{"keep-files": true, "local-only": true, "h": true, "help": true}

	for i := 0; i < len(args); i++ {
		arg := args[i]
		if !strings.HasPrefix(arg, "-") {
			positionals = append(positionals, arg)
			continue
		}

		flags = append(flags, arg)
		name := strings.TrimLeft(arg, "-")
		if eq := strings.Index(name, "="); eq >= 0 {
			continue // value inline: --flag=value
		}
		if !boolFlags[name] && i+1 < len(args) {
			i++
			flags = append(flags, args[i])
		}
	}
	return flags, positionals
}

// --- helpers -----------------------------------------------------------------

func cookieArgs(opts options) []string {
	if opts.cookies == "" {
		return nil
	}
	return []string{"--cookies-from-browser", opts.cookies}
}

func runCapture(bin string, args ...string) (string, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.Command(bin, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s failed: %v\n%s", filepath.Base(bin), err, truncate(stderr.String(), 800))
	}
	return stdout.String(), nil
}

func runStreaming(bin string, args ...string) error {
	cmd := exec.Command(bin, args...)
	cmd.Stdout = procOut
	cmd.Stderr = procOut
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s failed: %v", filepath.Base(bin), err)
	}
	return nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
