//go:build darwin && arm64

package main

import _ "embed"

//go:embed vendor_bin/darwin-arm64/yt-dlp
var ytdlpBin []byte

//go:embed vendor_bin/darwin-arm64/ffmpeg
var ffmpegBin []byte

const exeSuffix = ""
