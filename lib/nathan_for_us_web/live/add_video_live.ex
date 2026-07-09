defmodule NathanForUsWeb.AddVideoLive do
  @moduledoc """
  Add a video to the library.

  Two flows:

    * "Upload a video" — client-side frame slicing. The browser decodes the
      file, extracts one JPEG frame per second onto a canvas, and streams the
      frames to this LiveView over the socket in small batches (see
      assets/js/hooks/video_frame_slicer.js). No server-side ffmpeg required,
      so this works for phone footage on any deploy.

    * "From a URL (CLI)" — instructions for the companion grabber binary that
      rips a video locally (yt-dlp + ffmpeg) and POSTs it to the ingest API.

  Client ingest protocol (hook <-> this LiveView):

      push "client_ingest_start"  {title, duration_ms, fps, frame_count, captions_text, filename}
      recv "ingest_ack"           {video_id}
      push "client_frame_batch"   {video_id, frames: [...]}   # batches of 10
      recv "batch_ack"            {video_id, inserted}        # flow control
      push "client_ingest_finish" {video_id}                  # server links captions
      recv "finish_ack"           {video_id}                  # then redirects
      push "client_ingest_resume" {video_id, captions_text}   # after socket reconnect
      recv "ingest_ack"           {video_id, resume_from}     # re-slice from this frame
      push "client_ingest_cancel" {video_id}                  # deletes the partial video
      recv "ingest_error"         {message}                   # any step failed
  """

  use NathanForUsWeb, :live_view

  import Ecto.Query, warn: false

  require Logger

  alias NathanForUs.Repo
  alias NathanForUs.SrtParser
  alias NathanForUs.Video
  alias NathanForUs.Video.{VideoFrame, VideoCaption, FrameCaption}

  on_mount {NathanForUsWeb.UserAuth, :ensure_authenticated}

  # 30 minutes at 1fps — mirrored in video_frame_slicer.js
  @max_frames 1800
  @valid_extensions [".mp4", ".mov", ".avi", ".mkv", ".webm"]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Add a video")
      |> assign(:tab, "upload")
      |> assign(:base_url, String.trim_trailing(url(~p"/"), "/"))
      |> assign(:ingest_video_id, nil)
      |> assign(:ingest_captions_text, nil)
      |> assign(:ingest_frames_inserted, 0)
      |> assign_cli_commands()

    {:ok, socket}
  end

  def handle_params(_params, uri, socket) do
    case base_url_from_uri(uri) do
      nil ->
        {:noreply, socket}

      base_url ->
        {:noreply, socket |> assign(:base_url, base_url) |> assign_cli_commands()}
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ["upload", "cli"] do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("client_ingest_start", params, socket) do
    %{
      "title" => title,
      "duration_ms" => duration_ms,
      "frame_count" => frame_count,
      "filename" => filename
    } = params

    captions_text = Map.get(params, "captions_text")

    if is_integer(frame_count) and frame_count > @max_frames do
      {:noreply,
       push_event(socket, "ingest_error", %{
         message:
           "That video needs #{frame_count} frames — the in-browser slicer caps out at #{@max_frames} (30 minutes). Use the CLI grabber instead."
       })}
    else
      attrs = %{
        title: title,
        file_path: client_upload_path(filename),
        duration_ms: duration_ms,
        fps: 1.0,
        frame_count: frame_count,
        status: "processing",
        metadata: %{"source" => "browser", "original_filename" => filename}
      }

      case Video.create_video(attrs) do
        {:ok, video} ->
          socket =
            socket
            |> assign(:ingest_video_id, video.id)
            |> assign(:ingest_captions_text, captions_text)
            |> assign(:ingest_frames_inserted, 0)

          {:noreply, push_event(socket, "ingest_ack", %{video_id: video.id})}

        {:error, changeset} ->
          Logger.error("Client ingest failed to create video: #{inspect(changeset.errors)}")

          {:noreply,
           push_event(socket, "ingest_error", %{
             message: "Could not create the video record: #{changeset_error_message(changeset)}"
           })}
      end
    end
  end

  def handle_event("client_frame_batch", %{"video_id" => video_id, "frames" => frames}, socket) do
    if socket.assigns.ingest_video_id == video_id do
      case insert_frame_batch(video_id, frames) do
        {:ok, count} ->
          inserted = socket.assigns.ingest_frames_inserted + count
          socket = assign(socket, :ingest_frames_inserted, inserted)

          {:noreply, push_event(socket, "batch_ack", %{video_id: video_id, inserted: inserted})}

        {:error, reason} ->
          Logger.error(
            "Client ingest frame batch failed for video #{video_id}: #{inspect(reason)}"
          )

          {:noreply,
           push_event(socket, "ingest_error", %{
             message: "A batch of frames could not be saved. Please try the upload again."
           })}
      end
    else
      {:noreply,
       push_event(socket, "ingest_error", %{
         message: "Upload session mismatch — please reload the page and try again."
       })}
    end
  end

  # A socket reconnect (deploy, network blip, phone lock) remounts this
  # LiveView with ingest_video_id=nil. The hook detects the reconnect and asks
  # to resume; we re-adopt the video and tell the client where to restart
  # slicing from, trusting the DB frame count rather than the client's.
  def handle_event("client_ingest_resume", %{"video_id" => video_id} = params, socket) do
    with {:ok, video} <- Video.get_video(video_id),
         true <- browser_ingest?(video),
         "processing" <- video.status do
      inserted = Video.count_video_frames(video.id)

      socket =
        socket
        |> assign(:ingest_video_id, video.id)
        |> assign(:ingest_captions_text, Map.get(params, "captions_text"))
        |> assign(:ingest_frames_inserted, inserted)

      {:noreply, push_event(socket, "ingest_ack", %{video_id: video.id, resume_from: inserted})}
    else
      _ ->
        {:noreply,
         push_event(socket, "ingest_error", %{
           message: "This upload can no longer be resumed — please start it again."
         })}
    end
  end

  def handle_event("client_ingest_cancel", %{"video_id" => video_id}, socket) do
    with {:ok, video} <- Video.get_video(video_id),
         true <- browser_ingest?(video),
         "processing" <- video.status do
      # Frames, captions, and frame-caption links cascade via FK on_delete.
      case Repo.delete(video) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Client ingest cancel failed to delete video #{video_id}: #{inspect(reason)}"
          )
      end
    else
      _ -> :ok
    end

    {:noreply, reset_ingest_assigns(socket)}
  end

  def handle_event("client_ingest_finish", %{"video_id" => video_id}, socket) do
    if socket.assigns.ingest_video_id == video_id do
      finalize_ingest(socket, video_id)
    else
      {:noreply,
       push_event(socket, "ingest_error", %{
         message: "Upload session mismatch — please reload the page and try again."
       })}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <.page_header title="Add a video" subtitle="Turn any video into GIFs, frame by frame." />

      <div class="max-w-3xl mx-auto px-4 py-8">
        <div
          class="mb-6 inline-flex bg-stone-100 border border-stone-200 rounded-lg p-1 font-mono text-sm"
          role="tablist"
        >
          <button
            phx-click="switch_tab"
            phx-value-tab="upload"
            role="tab"
            aria-selected={to_string(@tab == "upload")}
            class={
              if @tab == "upload",
                do: "bg-white text-stone-900 rounded-md shadow-sm px-3 py-1.5",
                else: "px-3 py-1.5 text-stone-500 hover:text-stone-800"
            }
          >
            Upload a video
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="cli"
            role="tab"
            aria-selected={to_string(@tab == "cli")}
            class={
              if @tab == "cli",
                do: "bg-white text-stone-900 rounded-md shadow-sm px-3 py-1.5",
                else: "px-3 py-1.5 text-stone-500 hover:text-stone-800"
            }
          >
            From a URL (CLI)
          </button>
        </div>
        
    <!-- Upload tab (hidden, never removed, so the hook survives tab switches mid-upload) -->
        <div class={@tab != "upload" && "hidden"}>
          <div class="card p-6">
            <div id="video-frame-slicer" phx-hook="VideoFrameSlicer" phx-update="ignore">
              <div class="space-y-5">
                <div>
                  <label
                    for="ingest-title"
                    class="block font-mono uppercase tracking-wider text-xs text-stone-500 mb-2"
                  >
                    Title
                  </label>
                  <input
                    type="text"
                    id="ingest-title"
                    data-role="title-input"
                    placeholder="What's in this video?"
                    class="input"
                  />
                </div>

                <div>
                  <span
                    id="ingest-video-label"
                    class="block font-mono uppercase tracking-wider text-xs text-stone-500 mb-2"
                  >
                    Video file
                  </span>
                  <input
                    type="file"
                    accept="video/*"
                    id="ingest-video-file"
                    data-role="video-input"
                    aria-labelledby="ingest-video-label"
                    class="sr-only"
                  />
                  <div
                    data-role="dropzone"
                    role="button"
                    tabindex="0"
                    aria-controls="ingest-video-file"
                    class="border-2 border-dashed border-stone-300 rounded-xl bg-white hover:border-brand cursor-pointer text-center py-10 px-6 transition-colors"
                  >
                    <span class="hero-film h-10 w-10 text-stone-300 mx-auto block" aria-hidden="true">
                    </span>
                    <p class="mt-3 font-mono text-sm text-stone-700">
                      Drop a video or click to browse
                    </p>
                    <p class="mt-1 text-xs text-stone-500">
                      Up to 30 minutes. Sliced into 1 frame per second right here in your
                      browser — nothing is uploaded until slicing starts. Phone footage works great.
                    </p>
                  </div>

                  <div data-role="preview-wrap" class="hidden mt-3">
                    <div class="rounded-lg border border-stone-200 bg-stone-100 overflow-hidden flex justify-center">
                      <video data-role="preview" muted loop playsinline class="max-h-48 w-auto">
                      </video>
                    </div>
                    <div data-role="stats" class="mt-2 font-mono text-xs text-stone-500"></div>
                  </div>

                  <div
                    data-role="cap-error"
                    class="hidden mt-3 rounded-lg border border-red-200 bg-red-50 p-3"
                  >
                    <p data-role="cap-error-text" class="font-mono text-sm text-red-700"></p>
                    <button
                      type="button"
                      phx-click="switch_tab"
                      phx-value-tab="cli"
                      class="btn-secondary px-3 py-1 text-xs mt-2"
                    >
                      Use the CLI grabber instead
                    </button>
                  </div>
                </div>

                <div>
                  <label
                    for="ingest-captions-file"
                    class="block font-mono uppercase tracking-wider text-xs text-stone-500 mb-2"
                  >
                    Captions (optional)
                  </label>
                  <input
                    type="file"
                    accept=".srt,.vtt"
                    id="ingest-captions-file"
                    data-role="captions-input"
                    class="block w-full text-sm text-stone-500 font-mono file:mr-4 file:py-2 file:px-4 file:rounded-lg file:border-0 file:bg-stone-100 file:text-stone-700 file:font-mono file:cursor-pointer hover:file:bg-stone-200"
                  />
                  <p class="text-xs text-stone-500 mt-2">
                    An .srt or .vtt file makes the video searchable by what was said.
                  </p>
                  <div data-role="captions-info" class="hidden mt-1 font-mono text-xs text-stone-500">
                  </div>
                </div>

                <button type="button" data-role="start" class="btn-primary w-full py-3">
                  <svg
                    data-role="spinner"
                    class="hidden animate-spin h-4 w-4"
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                  >
                    <circle
                      class="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      stroke-width="4"
                    >
                    </circle>
                    <path
                      class="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z"
                    >
                    </path>
                  </svg>
                  <span data-role="start-label">SLICE + UPLOAD</span>
                </button>

                <button type="button" data-role="cancel" class="btn-secondary w-full hidden">
                  CANCEL
                </button>

                <div data-role="progress-wrap" class="hidden">
                  <div class="bg-stone-200 rounded-full h-2 overflow-hidden">
                    <div
                      data-role="progress-fill"
                      class="bg-brand h-full transition-all"
                      style="width: 0%"
                    >
                    </div>
                  </div>
                  <div data-role="progress-text" class="mt-1 font-mono text-xs text-stone-500"></div>
                </div>

                <div
                  data-role="status"
                  aria-live="polite"
                  class="text-sm font-mono text-stone-500 min-h-5"
                >
                </div>
              </div>
            </div>
          </div>
        </div>
        
    <!-- CLI tab -->
        <div class={@tab != "cli" && "hidden"}>
          <div class="card p-6 space-y-4">
            <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500">
              Ingest from a URL
            </h2>

            <p class="text-sm text-stone-700 leading-relaxed">
              Works with YouTube and 1000+ sites via yt-dlp — and it's the path for videos
              longer than 30 minutes.
            </p>

            <p class="text-sm text-stone-500 leading-relaxed">
              YouTube blocks servers from downloading videos, so Framecut can't rip them for
              you. Instead, run the grabber on your own machine — a single binary with
              yt-dlp and ffmpeg built in (nothing to install). It downloads the video,
              slices it into frames, grabs captions automatically, and uploads everything
              to this site.
            </p>

            <p :if={!@api_key_configured?} class="badge badge-warning">
              No INGEST_API_KEY configured on this server
            </p>

            <ol class="list-decimal list-inside text-sm text-stone-700 font-mono space-y-2">
              <li>
                Download the grabber for your machine:
                <div class="flex flex-wrap gap-2 mt-2 ml-4">
                  <a
                    href="/downloads/framecut-grab-darwin-arm64"
                    download
                    class="btn-secondary px-3 py-1 text-xs"
                  >
                    macOS (Apple Silicon)
                  </a>
                  <a
                    href="/downloads/framecut-grab-darwin-amd64"
                    download
                    class="btn-secondary px-3 py-1 text-xs"
                  >
                    macOS (Intel)
                  </a>
                  <a
                    href="/downloads/framecut-grab-linux-amd64"
                    download
                    class="btn-secondary px-3 py-1 text-xs"
                  >
                    Linux
                  </a>
                  <a
                    href="/downloads/framecut-grab-windows-amd64.exe"
                    download
                    class="btn-secondary px-3 py-1 text-xs"
                  >
                    Windows
                  </a>
                </div>
              </li>
              <li>Run it with the video URL:</li>
            </ol>

            <div>
              <div class="flex items-center justify-between mb-2">
                <span class="font-mono uppercase tracking-wider text-xs text-stone-500">
                  macOS / Linux
                </span>
                <button
                  type="button"
                  class="btn-secondary px-3 py-1 text-xs"
                  data-copy={@unix_copy_command}
                >
                  COPY
                </button>
              </div>
              <pre class="bg-stone-100 border border-stone-200 rounded-lg p-4 text-xs text-stone-800 font-mono overflow-x-auto">{@unix_command}</pre>
            </div>

            <div>
              <div class="flex items-center justify-between mb-2">
                <span class="font-mono uppercase tracking-wider text-xs text-stone-500">
                  Windows
                </span>
                <button
                  type="button"
                  class="btn-secondary px-3 py-1 text-xs"
                  data-copy={@windows_command}
                >
                  COPY
                </button>
              </div>
              <pre class="bg-stone-100 border border-stone-200 rounded-lg p-4 text-xs text-stone-800 font-mono overflow-x-auto">{@windows_command}</pre>
            </div>

            <p :if={!@admin? and @api_key_configured?} class="text-xs text-stone-500 leading-relaxed">
              Ask your server admin for the ingest API key (INGEST_API_KEY).
            </p>

            <p class="text-sm text-stone-700 leading-relaxed">
              The video appears in the library as soon as the upload finishes.
            </p>

            <p class="text-xs text-stone-500 leading-relaxed">
              Prefer Python? The original
              <a
                href="/downloads/framecut_grab.py"
                download
                class="text-brand-deep hover:text-brand underline"
              >
                framecut_grab.py
              </a>
              does the same job if you have yt-dlp and ffmpeg installed.
            </p>

            <p class="text-xs text-stone-500 leading-relaxed">
              Age-restricted video? Add
              <code class="bg-stone-100 border border-stone-200 px-1.5 py-0.5 rounded">
                --cookies-from-browser chrome
              </code>
              (or firefox/safari) so yt-dlp can use your logged-in session. Captions are grabbed
              automatically when the video has them.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Ingest helpers -------------------------------------------------------

  defp finalize_ingest(socket, video_id) do
    video = Video.get_video!(video_id)

    captions_result = link_captions(video_id, socket.assigns.ingest_captions_text)

    case Video.update_video(video, %{
           status: "completed",
           processed_at: DateTime.utc_now(),
           frame_count: Video.count_video_frames(video_id)
         }) do
      {:ok, _video} ->
        socket =
          socket
          |> reset_ingest_assigns()
          |> put_finalize_flash(captions_result)
          |> push_event("finish_ack", %{video_id: video_id})
          |> push_navigate(to: ~p"/video/#{video_id}")

        {:noreply, socket}

      {:error, changeset} ->
        Logger.error(
          "Client ingest failed to finalize video #{video_id}: #{inspect(changeset.errors)}"
        )

        {:noreply,
         push_event(socket, "ingest_error", %{
           message: "The video was uploaded but could not be finalized. Please try again."
         })}
    end
  end

  defp put_finalize_flash(socket, :ok),
    do: put_flash(socket, :info, "Video added — pick some frames and make a GIF!")

  defp put_finalize_flash(socket, {:error, _reason}),
    do: put_flash(socket, :error, "Video added, but captions could not be parsed.")

  defp reset_ingest_assigns(socket) do
    socket
    |> assign(:ingest_video_id, nil)
    |> assign(:ingest_captions_text, nil)
    |> assign(:ingest_frames_inserted, 0)
  end

  defp browser_ingest?(video) do
    (video.metadata || %{})["source"] == "browser"
  end

  defp insert_frame_batch(video_id, frames) when is_list(frames) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    decoded =
      Enum.map(frames, fn frame ->
        case Base.decode64(frame["data"] || "") do
          {:ok, image_data} ->
            {:ok,
             %{
               video_id: video_id,
               frame_number: frame["frame_number"],
               timestamp_ms: frame["timestamp_ms"],
               width: frame["width"],
               height: frame["height"],
               image_data: image_data,
               file_size: byte_size(image_data),
               inserted_at: now,
               updated_at: now
             }}

          :error ->
            :error
        end
      end)

    if Enum.all?(decoded, &match?({:ok, _}, &1)) do
      rows = Enum.map(decoded, fn {:ok, row} -> row end)
      {count, _} = Repo.insert_all(VideoFrame, rows)
      {:ok, count}
    else
      {:error, :invalid_frame_data}
    end
  end

  defp insert_frame_batch(_video_id, _frames), do: {:error, :invalid_frame_data}

  defp link_captions(_video_id, nil), do: :ok

  defp link_captions(video_id, captions_text) when is_binary(captions_text) do
    trimmed = String.trim(captions_text)

    if trimmed == "" do
      {:error, :empty_captions}
    else
      case SrtParser.parse_content(normalize_captions(trimmed)) do
        {:ok, entries} when is_list(entries) and entries != [] ->
          insert_caption_links(video_id, entries)

        _ ->
          {:error, :parse_failed}
      end
    end
  end

  defp insert_caption_links(video_id, entries) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    caption_rows =
      entries
      |> Enum.filter(&(&1.end_time > &1.start_time))
      |> Enum.map(fn entry ->
        %{
          video_id: video_id,
          start_time_ms: entry.start_time,
          end_time_ms: entry.end_time,
          text: entry.text,
          caption_index: entry.index,
          inserted_at: now,
          updated_at: now
        }
      end)

    case caption_rows do
      [] ->
        {:error, :no_valid_captions}

      rows ->
        {_count, captions} =
          Repo.insert_all(VideoCaption, rows, returning: [:id, :start_time_ms, :end_time_ms])

        frames =
          Repo.all(
            from f in VideoFrame,
              where: f.video_id == ^video_id,
              select: %{id: f.id, timestamp_ms: f.timestamp_ms}
          )

        # Same containment rule as the API upload controller: a frame belongs to
        # every caption whose [start, end] window contains its timestamp.
        links =
          for frame <- frames,
              caption <- captions,
              frame.timestamp_ms >= caption.start_time_ms and
                frame.timestamp_ms <= caption.end_time_ms do
            %{
              frame_id: frame.id,
              caption_id: caption.id,
              inserted_at: now,
              updated_at: now
            }
          end

        links
        |> Enum.chunk_every(5000)
        |> Enum.each(&Repo.insert_all(FrameCaption, &1))

        :ok
    end
  end

  # SrtParser only speaks SRT; convert WebVTT into SRT-shaped blocks first
  # (comma milliseconds, numeric index per cue, headers/notes dropped).
  defp normalize_captions(text) do
    if String.match?(text, ~r/\AWEBVTT/) do
      vtt_to_srt(text)
    else
      text
    end
  end

  defp vtt_to_srt(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/(\d{2}:\d{2}:\d{2})\.(\d{3})/, "\\1,\\2")
    |> String.replace(~r/(^|\s)(\d{1,2}:\d{2})\.(\d{3})/, "\\g{1}00:\\g{2},\\g{3}")
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.contains?(&1, "-->"))
    |> Enum.with_index(1)
    |> Enum.map(fn {block, index} ->
      lines = String.split(block, "\n")
      {_cue_id, timing_and_text} = Enum.split_while(lines, &(not String.contains?(&1, "-->")))
      "#{index}\n#{Enum.join(timing_and_text, "\n")}"
    end)
    |> Enum.join("\n\n")
  end

  defp client_upload_path(filename) when is_binary(filename) do
    sanitized =
      filename
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "_")
      |> String.slice(0, 120)

    sanitized =
      if String.ends_with?(sanitized, @valid_extensions) do
        sanitized
      else
        sanitized <> ".mp4"
      end

    "client-upload/#{System.system_time(:millisecond)}_#{sanitized}"
  end

  defp client_upload_path(_filename), do: client_upload_path("upload.mp4")

  defp base_url_from_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        default_port = if scheme == "https", do: 443, else: 80

        if port in [nil, default_port] do
          "#{scheme}://#{host}"
        else
          "#{scheme}://#{host}:#{port}"
        end

      _ ->
        nil
    end
  end

  # --- CLI tab helpers ------------------------------------------------------

  defp assign_cli_commands(socket) do
    base_url = socket.assigns.base_url
    configured_key = Application.get_env(:nathan_for_us, :ingest_api_key)
    key_configured? = is_binary(configured_key) and configured_key != ""

    admin? =
      case socket.assigns[:current_user] do
        %{is_admin: true} -> true
        _ -> false
      end

    shown_key = if admin? and key_configured?, do: configured_key, else: "YOUR_API_KEY"

    example_url = "https://www.youtube.com/watch?v=..."

    unix_run = ~s(./framecut-grab-* "#{example_url}" --server #{base_url} --api-key #{shown_key})

    unix_command =
      "chmod +x framecut-grab-*\n" <>
        ~s(./framecut-grab-* "#{example_url}" \\\n) <>
        "  --server #{base_url} \\\n" <>
        "  --api-key #{shown_key}"

    windows_command =
      ~s(.\\framecut-grab-windows-amd64.exe "#{example_url}" --server #{base_url} --api-key #{shown_key})

    socket
    |> assign(:admin?, admin?)
    |> assign(:api_key_configured?, key_configured?)
    |> assign(:unix_command, unix_command)
    |> assign(:unix_copy_command, unix_run)
    |> assign(:windows_command, windows_command)
  end

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
