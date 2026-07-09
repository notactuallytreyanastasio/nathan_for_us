FRAMECUT GRABBER
================

Three ways to run the grabber:

1. THE DESKTOP APP (recommended — zero dependencies)
   Download it from the /setup page:

     macOS    Framecut-Grabber-macos.zip        unzip, right-click > Open once
     Windows  Framecut-Grabber-windows-amd64.exe
     Linux    framecut-grabber-linux-amd64      chmod +x, needs a desktop w/ OpenGL

   yt-dlp and ffmpeg are built in; nothing to install. On first open it
   walks you through connecting to your server (your personal API key
   lives on the /setup page, or set FRAMECUT_SERVER / FRAMECUT_API_KEY
   in your environment and it configures itself). Paste a link, hit
   Grab, then "Open in Framecut" to jump straight into the editor.

2. THE SAME BINARY, FROM THE TERMINAL

     chmod +x framecut-grabber*
     ./framecut-grabber* "https://www.youtube.com/watch?v=..." \
         --server https://your-framecut-server \
         --api-key fc_your_key

   (On macOS the CLI lives inside the app bundle:
    "Framecut Grabber.app/Contents/MacOS/". Flags beat the env vars.)

   On first run it unpacks its bundled tools to your user cache directory
   (~/Library/Caches/framecut on macOS, ~/.cache/framecut on Linux).

3. THE PYTHON SCRIPT (if you already have the tools)
   Requires Python 3.9+, yt-dlp (pip install yt-dlp) and ffmpeg on PATH.

     python3 framecut_grab.py "https://www.youtube.com/watch?v=..." \
         --server https://your-framecut-server \
         --api-key fc_your_key

CLI and Python accept the same flags:

  --fps N                   frames per second to extract (default 1.0)
  --jpeg-quality N          0-100 (default 85)
  --max-height N            cap frame height in pixels (default 480)
  --batch-size N            frames per upload request (default 10)
  --cookies-from-browser B  chrome/firefox/safari — for age-restricted videos
  --local-only              skip upload; keep mp4 + subtitles for the /add
                            web upload flow
  --keep-files              keep the working files after upload
  --title T                 override the video title

TROUBLESHOOTING

  401 invalid api key      copy your key again from the /setup page (it
                           changes if you hit Regenerate)
  403 / age-gate errors    add --cookies-from-browser chrome (or firefox,
                           safari) so yt-dlp can use your logged-in session
  macOS "cannot be opened" right-click > Open once, or:
                           xattr -d com.apple.quarantine "Framecut Grabber.app"

Only grab content you own or have the rights to use.
