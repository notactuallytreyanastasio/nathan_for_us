#!/usr/bin/env bash
#
# Build the framecut-grab desktop app (Fyne GUI + CLI fallback) with yt-dlp +
# ffmpeg vendored inside. The GUI needs CGO, so builds are NATIVE per-OS — the
# release CI runs the packaging on separate macOS / Windows / Linux runners.
# Locally, `./build.sh` just builds a runnable binary for your own machine.
#
#   ./build.sh                 fetch host tools + build a host binary
#   ./build.sh fetch <plat>    only download vendored yt-dlp + ffmpeg for <plat>
#
# <plat> is one of: darwin-arm64 darwin-amd64 linux-amd64 windows-amd64.
# Vendored tool downloads are cached in vendor_bin/<plat>/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")"

YTDLP_BASE="https://github.com/yt-dlp/yt-dlp/releases/latest/download"
FFMPEG_BASE="https://github.com/eugeneware/ffmpeg-static/releases/latest/download"
OUT_DIR="${FRAMECUT_GRAB_OUT:-../../priv/static/downloads}"

# platform -> "GOOS GOARCH ytdlp-asset ffmpeg-asset suffix"
spec() {
  case "$1" in
    darwin-arm64)  echo "darwin arm64 yt-dlp_macos ffmpeg-darwin-arm64 ''" ;;
    darwin-amd64)  echo "darwin amd64 yt-dlp_macos ffmpeg-darwin-x64 ''" ;;
    linux-amd64)   echo "linux amd64 yt-dlp_linux ffmpeg-linux-x64 ''" ;;
    windows-amd64) echo "windows amd64 yt-dlp.exe ffmpeg-win32-x64 .exe" ;;
    *) echo "unknown platform: $1" >&2; exit 1 ;;
  esac
}

host_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64) arch=amd64 ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
  echo "$os-$arch"
}

fetch() { # url dest
  if [ ! -s "$2" ]; then
    echo "  fetching $(basename "$2") ..."
    curl -sL --fail -o "$2" "$1"
    chmod +x "$2"
  fi
}

# Download the vendored yt-dlp + ffmpeg for a platform into vendor_bin/<plat>/
# so the platform's //go:embed directives can bake them into the binary.
fetch_tools() {
  local platform=$1 goos goarch ytdlp_asset ffmpeg_asset suffix
  read -r goos goarch ytdlp_asset ffmpeg_asset suffix <<<"$(spec "$platform")"
  suffix=${suffix//\'/}
  echo "== fetch $platform"
  mkdir -p "vendor_bin/$platform"
  fetch "$YTDLP_BASE/$ytdlp_asset" "vendor_bin/$platform/yt-dlp$suffix"
  fetch "$FFMPEG_BASE/$ffmpeg_asset" "vendor_bin/$platform/ffmpeg$suffix"
}

case "${1:-host}" in
  fetch)
    fetch_tools "${2:?usage: build.sh fetch <platform>}"
    ;;
  host)
    plat="$(host_platform)"
    read -r goos goarch _ _ suffix <<<"$(spec "$plat")"
    suffix=${suffix//\'/}
    fetch_tools "$plat"
    mkdir -p "$OUT_DIR"
    echo "== build $plat (CGO, native)"
    CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" \
      -o "$OUT_DIR/framecut-grab-$plat$suffix" .
    du -sh "$OUT_DIR/framecut-grab-$plat$suffix"
    ;;
  *)
    echo "usage: build.sh [host|fetch <platform>]" >&2
    exit 1
    ;;
esac
