//go:build linux && amd64

package main

import _ "embed"

//go:embed vendor_bin/linux-amd64/yt-dlp
var ytdlpBin []byte

//go:embed vendor_bin/linux-amd64/ffmpeg
var ffmpegBin []byte

const exeSuffix = ""
