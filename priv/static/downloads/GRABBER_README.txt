FRAMECUT GRABBER
================

framecut_grab.py downloads a YouTube video, slices it into JPEG frames,
parses the English subtitles, and uploads everything to a Framecut server
so you can make GIFs from it at /video/<id>.

Legal note: only grab content you own or have the rights to use.


PREREQUISITES
-------------

  1. Python 3.9 or newer (no pip packages needed for the script itself)
  2. yt-dlp        pip install yt-dlp
  3. ffmpeg        brew install ffmpeg          (macOS)
                   sudo apt install ffmpeg      (Debian/Ubuntu)
                   winget install ffmpeg        (Windows)

The script checks for these and tells you what is missing.


BASIC USAGE
-----------

  python3 framecut_grab.py "https://www.youtube.com/watch?v=VIDEO_ID" \
      --server https://your-framecut-server.com \
      --api-key YOUR_API_KEY

When it finishes it prints the URL of the new video's GIF editor, e.g.
https://your-framecut-server.com/video/42


FLAGS
-----

  --fps N                    Frames per second to extract (default 1.0).
  --jpeg-quality N           JPEG quality 0-100 (default 85).
  --max-height N             Downscale frames taller than N px (default 480).
  --batch-size N             Frames per upload request (default 10). Lower
                             this if uploads time out on a slow connection.
  --cookies-from-browser B   Use your browser's YouTube cookies (chrome,
                             firefox, safari, edge, ...). Needed for
                             age-gated or members-only videos.
  --title "My Title"         Override the video title.
  --keep-files               Keep the downloaded video and frames in a
                             ./framecut_<youtube-id>/ directory.
  --local-only               Download and extract but do NOT upload.
  --api-key KEY              Sent as the X-API-Key header.
  --server URL               Base URL of your Framecut server.


EXAMPLES
--------

  Age-gated video, using your Chrome login:

    python3 framecut_grab.py "https://youtu.be/VIDEO_ID" \
        --server https://example.com --api-key KEY \
        --cookies-from-browser chrome

  Higher quality, 2 frames per second:

    python3 framecut_grab.py "https://youtu.be/VIDEO_ID" \
        --server https://example.com --api-key KEY \
        --fps 2 --jpeg-quality 95 --max-height 720

  No API key? Use --local-only, then upload through the website:

    python3 framecut_grab.py "https://youtu.be/VIDEO_ID" --local-only

    This keeps the .mp4 and .srt in ./framecut_<youtube-id>/ and skips the
    upload. Then sign in to your Framecut server, open /add, and upload the
    video (and srt) there.


TROUBLESHOOTING
---------------

  "HTTP Error 403" or "Sign in to confirm your age" from yt-dlp
      YouTube wants a logged-in session. Re-run with
      --cookies-from-browser chrome (or your browser). Make sure you are
      logged in to YouTube in that browser. If it still fails, update
      yt-dlp:  pip install -U yt-dlp  (YouTube changes often; an old
      yt-dlp is the most common cause of download failures).

  "yt-dlp is not installed" / "ffmpeg is not installed"
      Install the prerequisites above and make sure they are on your PATH.

  "server rejected upload (HTTP 401/403)"
      Your --api-key is wrong or missing. Check with your server admin,
      or fall back to --local-only and the /add web upload.

  Upload retries or times out
      Large videos produce many frames. Try --batch-size 5, or reduce
      --max-height / --jpeg-quality to shrink each frame.

  No captions in the editor
      The video has no English subtitles (not even auto-generated ones).
      Frames still upload fine; text search just won't match this video.
