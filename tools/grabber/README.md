# framecut-grab

The companion app for Framecut. Paste a video link (YouTube or anything
yt-dlp supports); it downloads the video, slices it into 1fps JPEG frames
locally, and uploads frames + captions to a Framecut server's ingest API.

## Quickstart

1. **Download** the app for your OS (GitHub Releases, or the landing page in
   `site/`).
2. **Connect it to your server.** Your API key (`fc_…`) lives on your Framecut
   server's **/setup** page. Either:
   - double-click the app — a first-run wizard walks you through server URL +
     API key (with a link straight to `/setup`), or
   - set the env vars once:

     ```sh
     export FRAMECUT_SERVER=https://your-framecut.example
     export FRAMECUT_API_KEY=fc_your_key
     ```

     The CLI uses them as the defaults for `--server` / `--api-key` (explicit
     flags win), and the wizard prefills its fields from them.
3. **Paste a video URL** and hit Grab.
4. When it finishes, click **"Open in Framecut →"** to land in the editor and
   slice your first GIF. (The CLI prints the same link:
   `Done. Edit it now: https://your-framecut.example/video/123`.)

It runs two ways from the **same binary**:

- **Desktop app (default)** — double-click, or run with no arguments. First
  run gets the guided wizard; after that, a native window (Fyne) with a form:
  video URL, server URL, API key, and advanced options, plus a live progress
  log. The server + key are remembered between runs.
- **CLI** — run it with a video URL argument for the original scripted behavior:

  ```sh
  ./framecut-grab "https://www.youtube.com/watch?v=..." \
      --server https://your-framecut.example \
      --api-key fc_your_key
  ```

  Any valid key works via `--api-key` — a per-user `fc_…` key from `/setup`,
  or a server's legacy shared `INGEST_API_KEY`.

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
