---
name: verify
description: Build, run, and drive Framecut (Phoenix LiveView) to verify changes end-to-end
---

# Verifying Framecut changes

## Build + launch

```bash
mix assets.build                  # esbuild + tailwind + gif.worker.js copy
PORT=4100 mix phx.server          # dev.exs honors PORT; default 4001 is often
                                  # held by the owner's own dev server — don't kill it
```

Wait for `curl -s -o /dev/null -w "%{http_code}" http://localhost:4100/` to return 200.
Avoid port 4045 (and other Chromium "unsafe ports") — headless Chrome refuses them
with ERR_UNSAFE_PORT.

Dev DB (`nathan_for_us_dev`) has a few real videos/frames/captions/GIFs — enough to
drive every surface. `psql` is not on PATH; query via `mix run -e '...'` and tag your
output line (e.g. `IO.puts("IDS ...")`) because debug logs interleave.

## Drive

Playwright is available via a scratchpad `npm i playwright` (browsers already cached
in `~/Library/Caches/ms-playwright`; use `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`).
ffmpeg is at /opt/homebrew/bin/ffmpeg, so server-side GIF generation works e2e.

Flows worth driving:
- `/` thumbnails (`img[src^="/frame/"]` naturalWidth > 0) + caption search
- `/gifs` cards + modal (inner click must NOT close; Escape must), vote toggle
- `/video/:id` editor: drag across `#editor-filmstrip`, keys ←/→ I O ? Space,
  GENERATE GIF → result card `img[src^="/gif/"]` (real ffmpeg encode, ~2s)
- `/g/:id` permalink: check og:image/og:url in static HTML via curl
- media endpoints: `/frame/:id`, `/gif/:id`, `/gif/:id?download=1`, `/gif/:id/poster`
- register → `/add` (upload + CLI tabs, `?tab=cli` deep link)
- mobile 375px: nav `<details>` hamburger

## Gotchas

- First request after editing an .ex file triggers the code reloader (can take ~30s,
  may drop the connection with ERR_EMPTY_RESPONSE — just retry).
- Feeds/editor gate data loading on `connected?`; static HTML shows skeletons/empty
  filmstrip by design. Judge connected behavior in the browser, not via curl.
- Dev HTML contains `NathanForUs` module names in HEEx debug annotations — not
  user-facing brand violations.
- Full-page screenshots make the sticky editor action bar look mid-page and leave
  lazy filmstrip images unloaded; that's a screenshot artifact.
