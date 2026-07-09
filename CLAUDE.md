# Framecut

Framecut is a self-hostable GIF maker: any video gets sliced into 1fps JPEG frames stored in
Postgres, captions (SRT) are linked to frames by timestamp, and users select frame ranges in
a timeline editor to render GIFs. Brand: "Framecut" — tagline "Turn any video into GIFs,
frame by frame." Dark UI (bg-gray-900, font-mono accents). No Nathan Fielder references
anywhere user-facing (the `nathan_for_us` app/module names remain as internal legacy naming).

## Frame pipeline

- Frames: 1fps JPEGs stored as binary in `video_frames.image_data`
- Captions: SRT segments in `video_captions`, joined to frames by timestamp via `frame_captions`
- GIFs: `gifs` table, deduplicated by sha256 of `video_id` + frame ids
- Feed: `Viral.browseable_gifs` + `gif_votes` (hot/top/new); public timeline via
  `posted_at` flag — `Viral.post_gif_to_timeline/…` and `Viral.get_timeline_gifs(limit)`

## Ingest paths

1. **Browser** — `/add` (authenticated): client-side slicing via the `VideoFrameSlicer` JS
   hook (`assets/js/hooks/video_frame_slicer.js`), frames uploaded from the browser
2. **API** — `POST /api/videos/upload` (`Api.VideoUploadController`): JSON with video
   metadata + base64 frames + captions, authenticated by the `INGEST_API_KEY` env var;
   used by the YouTube grabber tool at `/downloads/framecut_grab.py`
3. **Server-side (optional)** — `NathanForUs.VideoProcessor` (ffmpeg frame extraction) and
   `NathanForUs.AdminService` (server GIF encode); ffmpeg only required for these paths

## Module map

- `NathanForUs.Video` — context (`lib/nathan_for_us/video.ex`) + schemas in `lib/nathan_for_us/video/`
- `NathanForUs.Gif` — GIF encoding/storage helpers
- `NathanForUs.Viral` — browseable GIF feed, votes, timeline posts
- `NathanForUs.SrtParser` — SRT caption parsing

## Routes

- `/` — `HomeLive` (video library)
- `/video/:video_id` — `VideoTimelineLive` (the GIF editor)
- `/gifs` — `GifBrowseLive` (hot/top/new voting feed)
- `/timeline` — `TimelineLive` (explicitly posted GIFs)
- `/add` — `AddVideoLive` (authenticated video ingest)
- `/api/videos/upload` — `Api.VideoUploadController`

## Conventions

- HEEx: inline `render/1` with `~H` in LiveViews/components
- Global nav lives in `lib/nathan_for_us_web/components/layouts/root.html.heex`
- Dev setup: `mix setup` then `mix phx.server`; tests with `mix test`
