//go:build darwin && amd64

package main

import _ "embed"

//go:embed vendor_bin/darwin-amd64/yt-dlp
var ytdlpBin []byte

//go:embed vendor_bin/darwin-amd64/ffmpeg
var ffmpegBin []byte

const exeSuffix = ""
