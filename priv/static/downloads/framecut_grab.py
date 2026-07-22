#!/usr/bin/env python3
"""
framecut_grab.py -- Framecut YouTube grabber.

Downloads a YouTube video with yt-dlp, extracts 1fps JPEG frames with ffmpeg,
parses the English subtitles, and uploads everything to a Framecut server.

Stdlib only. Requires the `yt-dlp` and `ffmpeg`/`ffprobe` binaries on PATH.

Usage:
    python3 framecut_grab.py <youtube-url> --server https://example.com --api-key KEY

Legal note: only grab content you own or have the rights to use.
"""

import argparse
import base64
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

LEGAL_NOTE = "Note: only grab content you own or have the rights to use."

SRT_TIME_RE = re.compile(
    r"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})"
)

YTDLP_FORMAT = "bv*[ext=mp4][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/b"


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def check_binaries():
    missing = []
    if shutil.which("yt-dlp") is None:
        missing.append("yt-dlp is not installed. Install it with:  pip install yt-dlp")
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            missing.append(
                f"{tool} is not installed. Install it with:  brew install ffmpeg  "
                "(macOS) or  apt install ffmpeg  (Debian/Ubuntu)"
            )
            break
    if missing:
        for line in missing:
            print(line, file=sys.stderr)
        sys.exit(1)


def run(cmd, **kwargs):
    """Run a command, exiting with the tool's stderr on failure."""
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        die(f"`{cmd[0]}` failed:\n{result.stderr.strip()}")
    return result.stdout


def fetch_video_info(url, cookies_from_browser):
    """Get the YouTube id and title without downloading."""
    cmd = ["yt-dlp", "--no-playlist", "--skip-download", "--print", "id", "--print", "title"]
    if cookies_from_browser:
        cmd += ["--cookies-from-browser", cookies_from_browser]
    cmd.append(url)
    lines = run(cmd).strip().splitlines()
    if len(lines) < 2:
        die("could not read video id/title from yt-dlp output")
    return lines[0].strip(), lines[1].strip()


def download_video(url, workdir, cookies_from_browser):
    """Download the mp4 + English subtitles into workdir. Returns the video path."""
    cmd = [
        "yt-dlp",
        "--no-playlist",
        "-f", YTDLP_FORMAT,
        "--merge-output-format", "mp4",
        "--write-auto-subs",
        "--write-subs",
        "--sub-langs", "en.*,en",
        "--convert-subs", "srt",
        "-o", os.path.join(workdir, "%(id)s.%(ext)s"),
    ]
    if cookies_from_browser:
        cmd += ["--cookies-from-browser", cookies_from_browser]
    cmd.append(url)
    run(cmd)

    candidates = [
        p for p in glob.glob(os.path.join(workdir, "*"))
        if os.path.splitext(p)[1].lower() in (".mp4", ".mkv", ".webm", ".m4v")
    ]
    if not candidates:
        die("yt-dlp finished but no video file was found in the work directory")
    return candidates[0]


def probe_duration_ms(video_path):
    out = run([
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        video_path,
    ])
    return int(float(out.strip()) * 1000)


def probe_dimensions(image_path):
    out = run([
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height",
        "-of", "csv=p=0",
        image_path,
    ])
    width, height = out.strip().split(",")[:2]
    return int(width), int(height)


def jpeg_quality_to_qv(quality):
    """Map a 0-100 JPEG quality to ffmpeg's -q:v scale (2 best .. 7 worst)."""
    quality = max(0, min(100, quality))
    return max(2, min(7, round(2 + (100 - quality) * 5 / 100)))


def extract_frames(video_path, frames_dir, fps, max_height, jpeg_quality):
    os.makedirs(frames_dir, exist_ok=True)
    vf = f"fps={fps},scale=-2:min({max_height}\\,ih)"
    run([
        "ffmpeg", "-hide_banner", "-y",
        "-i", video_path,
        "-vf", vf,
        "-q:v", str(jpeg_quality_to_qv(jpeg_quality)),
        os.path.join(frames_dir, "frame_%08d.jpg"),
    ])
    frames = sorted(glob.glob(os.path.join(frames_dir, "frame_*.jpg")))
    if not frames:
        die("ffmpeg produced no frames")
    return frames


def find_srt(workdir):
    srts = sorted(glob.glob(os.path.join(workdir, "*.srt")))
    if not srts:
        return None
    for path in srts:
        if ".en" in os.path.basename(path):
            return path
    return srts[0]


def srt_time_to_ms(h, m, s, ms):
    return ((int(h) * 60 + int(m)) * 60 + int(s)) * 1000 + int(ms.ljust(3, "0"))


def parse_srt(path):
    """Parse an SRT file into caption dicts. Returns [] on any trouble."""
    if path is None:
        return []
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            content = f.read()
    except OSError:
        return []

    captions = []
    for block in re.split(r"\n\s*\n", content):
        lines = [line.strip() for line in block.strip().splitlines() if line.strip()]
        if not lines:
            continue
        match = None
        text_start = 0
        for i, line in enumerate(lines[:2]):
            match = SRT_TIME_RE.search(line)
            if match:
                text_start = i + 1
                break
        if not match:
            continue
        g = match.groups()
        text = " ".join(lines[text_start:]).strip()
        if not text:
            continue
        captions.append({
            "start_time_ms": srt_time_to_ms(*g[0:4]),
            "end_time_ms": srt_time_to_ms(*g[4:8]),
            "text": text,
            "caption_index": len(captions) + 1,
        })
    return captions


def build_frame_payload(frame_paths, start_index, fps, width, height):
    frames = []
    for offset, path in enumerate(frame_paths):
        frame_number = start_index + offset + 1
        with open(path, "rb") as f:
            data = f.read()
        frames.append({
            "frame_number": frame_number,
            "timestamp_ms": round((frame_number - 1) * 1000 / fps),
            "file_size": len(data),
            "width": width,
            "height": height,
            "image_data": base64.b64encode(data).decode("ascii"),
            "compression_ratio": 1.0,
        })
    return frames


def post_batch(server, api_key, payload):
    request = urllib.request.Request(
        f"{server}/api/videos/upload",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "X-API-Key": api_key,
            # A real browser-ish UA: the default Python-urllib/x.y signature
            # trips Cloudflare's bot rule (HTTP 403, error 1010) in front of
            # some Framecut servers, so the request never reaches the app.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        },
        method="POST",
    )
    last_error = None
    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            if 500 <= e.code < 600 and attempt < 3:
                last_error = f"HTTP {e.code}: {body}"
            else:
                die(f"server rejected upload (HTTP {e.code}): {body}")
        except urllib.error.URLError as e:
            if attempt < 3:
                last_error = str(e.reason)
            else:
                die(f"could not reach {server}: {e.reason}")
        wait = 2 ** attempt
        print(f"  retrying in {wait}s ({last_error})")
        time.sleep(wait)
    die(f"upload failed after 3 attempts: {last_error}")


def upload(server, api_key, video_meta, frame_paths, captions, fps, batch_size, width, height):
    total = len(frame_paths)
    batches = [frame_paths[i:i + batch_size] for i in range(0, total, batch_size)]
    video_id = None
    for i, batch in enumerate(batches):
        payload = {
            "video": video_meta,
            "frames": build_frame_payload(batch, i * batch_size, fps, width, height),
            # Captions only in the first batch: the server clears and rebuilds
            # frames/captions whenever captions are present.
            "captions": captions if i == 0 else [],
        }
        print(f"Uploading batch {i + 1}/{len(batches)} "
              f"({i * batch_size + 1}-{i * batch_size + len(batch)} of {total} frames)...")
        response = post_batch(server, api_key, payload)
        video_id = response.get("video_id", video_id)
    return video_id


def parse_args():
    parser = argparse.ArgumentParser(
        description="Grab a YouTube video, slice it into frames, and upload it to a Framecut server.",
        epilog=LEGAL_NOTE,
    )
    parser.add_argument("url", help="YouTube video URL")
    parser.add_argument("--server", help="Framecut server base URL, e.g. https://example.com")
    parser.add_argument("--api-key", help="API key sent as the X-API-Key header")
    parser.add_argument("--fps", type=float, default=1.0, help="frames per second to extract (default: 1.0)")
    parser.add_argument("--jpeg-quality", type=int, default=85,
                        help="JPEG quality 0-100 (default: 85)")
    parser.add_argument("--max-height", type=int, default=480,
                        help="max frame height in pixels; smaller videos are kept as-is (default: 480)")
    parser.add_argument("--batch-size", type=int, default=10,
                        help="frames per upload request (default: 10)")
    parser.add_argument("--cookies-from-browser", metavar="BROWSER",
                        help="passed through to yt-dlp, e.g. chrome, firefox, safari")
    parser.add_argument("--keep-files", action="store_true",
                        help="keep the downloaded files and extracted frames")
    parser.add_argument("--local-only", action="store_true",
                        help="skip the upload; keep the mp4 + srt for the /add web upload flow")
    parser.add_argument("--title", help="override the video title")
    args = parser.parse_args()

    if not args.local_only:
        if not args.server:
            parser.error("--server is required (or pass --local-only)")
        if not args.api_key:
            parser.error("--api-key is required (or pass --local-only)")
    if args.fps <= 0:
        parser.error("--fps must be positive")
    if args.batch_size < 1:
        parser.error("--batch-size must be at least 1")
    return args


def main():
    args = parse_args()
    check_binaries()
    print(LEGAL_NOTE)

    print("Fetching video info...")
    youtube_id, fetched_title = fetch_video_info(args.url, args.cookies_from_browser)
    title = args.title or fetched_title
    print(f"  {title} ({youtube_id})")

    keep = args.keep_files or args.local_only
    if keep:
        workdir = os.path.abspath(f"framecut_{youtube_id}")
        os.makedirs(workdir, exist_ok=True)
    else:
        workdir = tempfile.mkdtemp(prefix="framecut-")

    try:
        print("Downloading video (yt-dlp)...")
        video_path = download_video(args.url, workdir, args.cookies_from_browser)

        duration_ms = probe_duration_ms(video_path)
        print(f"  duration: {duration_ms / 1000:.1f}s")

        print(f"Extracting frames at {args.fps} fps (ffmpeg)...")
        frame_paths = extract_frames(
            video_path, os.path.join(workdir, "frames"),
            args.fps, args.max_height, args.jpeg_quality,
        )
        width, height = probe_dimensions(frame_paths[0])
        print(f"  {len(frame_paths)} frames at {width}x{height}")

        srt_path = find_srt(workdir)
        captions = parse_srt(srt_path)
        if captions:
            print(f"  parsed {len(captions)} captions from {os.path.basename(srt_path)}")
        else:
            print("  no subtitles found (that's fine, continuing without captions)")

        if args.local_only:
            print("\n--local-only: skipping upload. Your files:")
            print(f"  video:  {video_path}")
            print(f"  srt:    {srt_path or '(none)'}")
            print(f"  frames: {os.path.join(workdir, 'frames')}")
            print("Use the /add page on your Framecut server to upload the video and srt.")
            return

        server = args.server.rstrip("/")
        video_meta = {
            "title": title,
            "file_path": f"youtube/{youtube_id}.mp4",
            "duration_ms": duration_ms,
            "fps": args.fps,
            "frame_count": len(frame_paths),
            "metadata": {"source": "youtube", "url": args.url, "youtube_id": youtube_id},
        }
        video_id = upload(server, args.api_key, video_meta, frame_paths,
                          captions, args.fps, args.batch_size, width, height)

        print("\nDone!")
        if video_id is not None:
            print(f"  {server}/video/{video_id}")
    finally:
        if keep:
            print(f"Files kept in {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)

    print(LEGAL_NOTE)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
