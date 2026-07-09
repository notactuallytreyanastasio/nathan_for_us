//go:build windows && amd64

package main

import _ "embed"

//go:embed vendor_bin/windows-amd64/yt-dlp.exe
var ytdlpBin []byte

//go:embed vendor_bin/windows-amd64/ffmpeg.exe
var ffmpegBin []byte

const exeSuffix = ".exe"
