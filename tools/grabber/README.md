# framecut-grab

The companion app for Framecut. Paste a video link (YouTube or anything
yt-dlp supports); it downloads the video, slices it into 1fps JPEG frames
locally, and uploads frames + captions to a Framecut server's ingest API.

It runs two ways from the **same binary**:

- **Desktop app (default)** — double-click, or run with no arguments. A native
  window (Fyne) with a form: video URL, server URL, API key, and advanced
  options, plus a live progress log. The server + key are remembered between
  runs.
- **CLI** — run it with a video URL argument for the original scripted behavior:

  ```sh
  ./framecut-grab "https://www.youtube.com/watch?v=..." \
      --server https://your-framecut.example \
      --api-key YOUR_INGEST_API_KEY
  ```

  Useful flags: `--cookies-from-browser chrome` (age-restricted videos),
  `--local-only` (skip upload, keep mp4+subs for the /add web flow),
  `--fps`, `--max-height`, `--jpeg-quality`, `--batch-size`, `--title`.

The official self-contained yt-dlp build and a static ffmpeg are **embedded in
the binary** (`go:embed`) and extracted to the user's cache directory
(`~/Library/Caches/framecut/tools/<hash>` on macOS, `~/.cache/...` on Linux)
on first run. Users install nothing — no Python, no pip, no brew.

## Building

Requires Go 1.22+ and a C toolchain (the GUI uses CGO). Because of CGO, builds
are **native per-OS** — you can't cross-compile every target from one host like
the old CLI-only tool.

```sh
./build.sh                    # fetch host tools + build a runnable host binary
./build.sh fetch linux-amd64  # only download vendored yt-dlp + ffmpeg for a target
```

`build.sh` writes the host binary to `priv/static/downloads/` and caches
vendored tools in `vendor_bin/<platform>/` (both gitignored). The Python
fallback (`priv/static/downloads/framecut_grab.py`) stays in the repo for
anyone who prefers it.

To produce distributable, double-clickable bundles (`.app`, `.exe`) use the
`fyne` CLI:

```sh
go install fyne.io/tools/cmd/fyne@latest
fyne package --target darwin --release --icon Icon.png   # → "Framecut Grabber.app"
```

## Releases

`.github/workflows/grabber-release.yml` builds all three platforms on native
runners (macOS universal `.app`, Windows `.exe`, Linux binary) and attaches them
to a GitHub Release. Cut one with:

```sh
git tag grabber-v1.0.0 && git push origin grabber-v1.0.0
```

The download + setup landing page lives in `site/` (deployed to
downloader.bobbby.online) and links to `releases/latest/download/...`.

## Licensing note

The distributed binary embeds yt-dlp (Unlicense) and FFmpeg (GPL builds from
ffmpeg-static). If you distribute these binaries publicly, FFmpeg's GPL terms
apply — keep a source offer available.
