# framecut-grab

Zero-dependency companion binary for Framecut: grabs a video from YouTube (or
any yt-dlp-supported site), slices it into 1fps JPEG frames locally, and
uploads frames + captions to a Framecut server's ingest API.

The official self-contained yt-dlp build and a static ffmpeg are **embedded in
the binary** (`go:embed`) and extracted to the user's cache directory
(`~/Library/Caches/framecut/tools/<hash>` on macOS, `~/.cache/...` on Linux)
on first run. Users install nothing — no Python, no pip, no brew.

## Usage

```sh
./framecut-grab "https://www.youtube.com/watch?v=..." \
    --server https://your-framecut.example \
    --api-key YOUR_INGEST_API_KEY
```

Useful flags: `--cookies-from-browser chrome` (age-restricted videos),
`--local-only` (skip upload, keep mp4+subs for the /add web flow),
`--fps`, `--max-height`, `--jpeg-quality`, `--batch-size`, `--title`.

## Building

Requires Go 1.22+. `build.sh` downloads the vendored tools per platform
(cached in `vendor_bin/`, gitignored) and produces binaries in
`priv/static/downloads/`:

```sh
./build.sh              # host platform
./build.sh all          # darwin-arm64, darwin-amd64, linux-amd64, windows-amd64
```

Binaries are ~90MB (that's the embedded ffmpeg + yt-dlp) and are **not
committed** — build them in CI/at deploy time, or attach them to releases.
The Python fallback (`priv/static/downloads/framecut_grab.py`) stays in the
repo for anyone who prefers it.

## Licensing note

The distributed binary embeds yt-dlp (Unlicense) and FFmpeg (GPL builds from
ffmpeg-static). If you distribute these binaries publicly, FFmpeg's GPL terms
apply — keep a source offer available.
