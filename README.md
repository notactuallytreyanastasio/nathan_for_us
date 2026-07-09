# Framecut

**Turn any video into GIFs, frame by frame.**

Framecut is a self-hostable GIF maker built with Phoenix LiveView. Add a video and it gets
sliced into 1fps frames with captions linked by timestamp. From there you can:

- **Browse the library** (`/`) and open any video in the timeline editor
- **Search captions** to jump straight to the moment something was said
- **Cut GIFs** (`/video/:id`) by selecting frame ranges in a timeline editor
- **Vote** on GIFs in the hot/top/new feed (`/gifs`)
- **Post to the public timeline** (`/timeline`) to share your best cuts

## Architecture

- **Phoenix 1.7 + LiveView** — all UI is server-rendered LiveView; no SPA
- **Frames in Postgres** — videos are sliced to 1fps JPEG frames stored as binary data in
  `video_frames.image_data`; captions (SRT) are stored in `video_captions` and linked to
  frames by timestamp via `frame_captions`
- **GIF rendering** — users select frame ranges; GIFs are encoded and deduplicated by a
  sha256 of `video_id` + frame ids (`gifs` table)
- **Client-side slicing** — `/add` lets authenticated users add a video; frames are
  extracted in the browser (canvas) and uploaded, so the server never needs the video file
- **Ingest API** — `POST /api/videos/upload` accepts JSON (video metadata + base64 frames +
  captions), authenticated with the `INGEST_API_KEY` env var
- **YouTube grabber** — a companion Python tool served at `/downloads/framecut_grab.py`
  downloads a video + subtitles, slices frames locally, and pushes them to the ingest API
- **Server-side encode (optional)** — `NathanForUs.VideoProcessor` / `AdminService` can use
  ffmpeg for server-side frame extraction and GIF encoding when available

Key modules live under `lib/nathan_for_us/`: `Video` (context + schemas), `Gif`,
`Viral` (feed, votes, timeline posts), `SrtParser`.

## Development

```bash
# Install dependencies, create and migrate the database, build assets
mix setup

# Start the server
mix phx.server
# Visit http://localhost:4000
```

Requirements: Elixir/Erlang, PostgreSQL. `ffmpeg` is optional — it is only needed for the
server-side encode paths; the browser-based `/add` flow and the ingest API work without it.

Optional env vars:

- `INGEST_API_KEY` — shared secret for `POST /api/videos/upload`
- `GOOGLE_ANALYTICS_ID` — enables the analytics snippet

```bash
# Run tests
mix test
```
