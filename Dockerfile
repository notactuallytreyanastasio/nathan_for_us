# Reconstructed 2026-06-10 after the original (which lived only on the
# server at /opt/nathan) was removed by deploy.sh's `rsync --delete` —
# this copy lives in the rsync source so it ships with every deploy.
# Runtime stage matches `docker history` of the last working image
# (blog-nathan:latest); build stage mirrors the blog's Dockerfile.

ARG BUILDER_IMAGE="hexpm/elixir:1.18.1-erlang-27.3.4.8-debian-bookworm-20260202-slim"
ARG RUNNER_IMAGE="debian:bookworm-20260202-slim"

# Build the framecut-grab companion binaries (yt-dlp + ffmpeg embedded).
# Layer-cached on tools/grabber content, so the ~250MB of vendored tool
# downloads only re-run when the grabber changes.
FROM golang:1.22-bookworm AS grabber

WORKDIR /src
COPY tools/grabber ./
RUN FRAMECUT_GRAB_OUT=/out ./build.sh all

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git nodejs npm \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Prepare build dir
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ENV MIX_ENV="prod"

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv

COPY lib lib

COPY assets assets

# Install npm dependencies
RUN cd assets && npm install

# Compile assets
RUN mix assets.deploy

# Compile the release
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

# Copy release overlays (rel/overlays/bin/server + migrate) so `mix release`
# bakes the /app/bin/server and /app/bin/migrate wrapper scripts into the image.
COPY rel rel

RUN mix release

# Start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses5 locales ffmpeg imagemagick \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/nathan_for_us ./

# Grabber binaries go straight into the release's static dir, after
# phx.digest ran — digesting/gzipping ~450MB of binaries is pointless.
# (Path embeds the app version from mix.exs.)
COPY --from=grabber --chown=nobody:root /out/ ./lib/nathan_for_us-0.1.0/priv/static/downloads/

USER nobody

CMD ["/app/bin/server"]
