FRAMECUT GRABBER
================

Two ways to run the grabber:

1. THE BINARY (recommended — zero dependencies)
   Download framecut-grab-<your-platform> from the /add page.
   yt-dlp and ffmpeg are built into the binary; nothing to install.

     chmod +x framecut-grab-darwin-arm64
     ./framecut-grab-darwin-arm64 "https://www.youtube.com/watch?v=..." \
         --server https://your-framecut-server \
         --api-key YOUR_API_KEY

   On first run it unpacks its bundled tools to your user cache directory
   (~/Library/Caches/framecut on macOS, ~/.cache/framecut on Linux).

2. THE PYTHON SCRIPT (if you already have the tools)
   Requires Python 3.9+, yt-dlp (pip install yt-dlp) and ffmpeg on PATH.

     python3 framecut_grab.py "https://www.youtube.com/watch?v=..." \
         --server https://your-framecut-server \
         --api-key YOUR_API_KEY

Both accept the same flags:

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

  401 invalid api key      ask the site admin for the INGEST_API_KEY
  503 ingest disabled      the server has no INGEST_API_KEY configured
  403 / age-gate errors    add --cookies-from-browser chrome (or firefox,
                           safari) so yt-dlp can use your logged-in session
  macOS "cannot be opened" right-click > Open once, or:
                           xattr -d com.apple.quarantine framecut-grab-*

Only grab content you own or have the rights to use.
