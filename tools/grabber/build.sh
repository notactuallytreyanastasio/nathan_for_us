#!/usr/bin/env bash
#
# Build framecut-grab binaries with yt-dlp + ffmpeg vendored inside.
#
#   ./build.sh                 build for the host platform only
#   ./build.sh all             build every supported platform
#   ./build.sh linux-amd64     build one specific platform
#
# Outputs land in ../../priv/static/downloads/ as framecut-grab-<platform>.
# Vendored tool downloads are cached in vendor_bin/<platform>/.
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

build_one() {
  local platform=$1
  read -r goos goarch ytdlp_asset ffmpeg_asset suffix <<<"$(spec "$platform")"
  suffix=${suffix//\'/}

  echo "== $platform"
  mkdir -p "vendor_bin/$platform" "$OUT_DIR"
  fetch "$YTDLP_BASE/$ytdlp_asset" "vendor_bin/$platform/yt-dlp$suffix"
  fetch "$FFMPEG_BASE/$ffmpeg_asset" "vendor_bin/$platform/ffmpeg$suffix"

  GOOS=$goos GOARCH=$goarch CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w" \
    -o "$OUT_DIR/framecut-grab-$platform$suffix" .

  du -sh "$OUT_DIR/framecut-grab-$platform$suffix"
}

case "${1:-host}" in
  host) build_one "$(host_platform)" ;;
  all)
    for p in darwin-arm64 darwin-amd64 linux-amd64 windows-amd64; do
      build_one "$p"
    done
    ;;
  *) build_one "$1" ;;
esac
