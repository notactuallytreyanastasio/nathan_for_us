defmodule NathanForUsWeb.AddVideoLive do
  @moduledoc """
  Add a video to the library.

  Two flows:

    * "Upload a video" — client-side frame slicing. The browser decodes the
      file, extracts one JPEG frame per second onto a canvas, and streams the
      frames to this LiveView over the socket in small batches (see
      assets/js/hooks/video_frame_slicer.js). No server-side ffmpeg required,
      so this works for phone footage on any deploy.

    * "From YouTube" — instructions for the companion grabber script that
      rips a video locally (yt-dlp + ffmpeg) and POSTs it to the ingest API.

  Client ingest protocol (hook <-> this LiveView):

      push "client_ingest_start"  {title, duration_ms, fps, frame_count, captions_text, filename}
      recv "ingest_ack"           {video_id}
      push "client_frame_batch"   {video_id, frames: [...]}   # batches of 10
      recv "batch_ack"            {video_id, inserted}        # flow control
      push "client_ingest_finish" {video_id}                  # server links captions, redirects
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

    {:ok, socket}
  end

  def handle_params(_params, uri, socket) do
    case base_url_from_uri(uri) do
      nil -> {:noreply, socket}
      base_url -> {:noreply, assign(socket, :base_url, base_url)}
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ["upload", "youtube"] do
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
           "That video needs #{frame_count} frames — the in-browser slicer caps out at #{@max_frames} (30 minutes). Use the grabber tool instead."
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
          Logger.error("Client ingest frame batch failed for video #{video_id}: #{inspect(reason)}")

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
    <div class="min-h-screen bg-gray-900 text-white">
      <!-- Header -->
      <div class="bg-gray-800 border-b border-gray-700 px-6 py-4">
        <div class="flex items-center justify-between max-w-4xl mx-auto">
          <div>
            <h1 class="text-2xl font-bold font-mono">ADD A VIDEO</h1>
            <p class="text-gray-400 text-sm font-mono">
              Turn any video into GIFs, frame by frame.
            </p>
          </div>

          <.link
            navigate={~p"/"}
            class="bg-gray-700 hover:bg-gray-600 text-white px-4 py-2 rounded-lg font-mono font-medium transition-colors"
          >
            ← LIBRARY
          </.link>
        </div>
      </div>

    <!-- Tabs -->
      <div class="bg-gray-800 border-b border-gray-700 px-6 py-3">
        <div class="flex items-center gap-1 max-w-4xl mx-auto">
          <button
            phx-click="switch_tab"
            phx-value-tab="upload"
            class={[
              "px-4 py-2 rounded font-mono font-medium transition-colors text-sm",
              if(@tab == "upload",
                do: "bg-green-600 text-white",
                else: "text-gray-400 hover:text-white hover:bg-gray-700"
              )
            ]}
          >
            📼 Upload a video
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="youtube"
            class={[
              "px-4 py-2 rounded font-mono font-medium transition-colors text-sm",
              if(@tab == "youtube",
                do: "bg-red-600 text-white",
                else: "text-gray-400 hover:text-white hover:bg-gray-700"
              )
            ]}
          >
            ▶ From YouTube
          </button>
        </div>
      </div>

      <div class="px-4 py-8">
        <!-- Upload tab (hidden, never removed, so the hook survives tab switches mid-upload) -->
        <div class={["max-w-2xl mx-auto", @tab != "upload" && "hidden"]}>
          <div class="bg-gray-800 rounded-lg border border-gray-700 p-6">
            <div id="video-frame-slicer" phx-hook="VideoFrameSlicer" phx-update="ignore">
              <div class="space-y-5">
                <div>
                  <label class="block text-sm font-mono text-gray-300 mb-2">TITLE</label>
                  <input
                    type="text"
                    data-role="title-input"
                    placeholder="What's in this video?"
                    class="w-full bg-gray-900 border border-gray-600 rounded px-3 py-2 text-white font-mono text-sm focus:outline-none focus:border-green-500"
                  />
                </div>

                <div>
                  <label class="block text-sm font-mono text-gray-300 mb-2">VIDEO FILE</label>
                  <input
                    type="file"
                    accept="video/*"
                    data-role="video-input"
                    class="block w-full text-sm text-gray-400 font-mono file:mr-4 file:py-2 file:px-4 file:rounded file:border-0 file:bg-gray-700 file:text-white file:font-mono file:cursor-pointer hover:file:bg-gray-600"
                  />
                  <p class="text-xs text-gray-500 font-mono mt-2">
                    Up to 30 minutes. Sliced into 1 frame per second right here in your browser —
                    nothing is uploaded until slicing starts. Phone footage works great.
                  </p>
                </div>

                <div>
                  <label class="block text-sm font-mono text-gray-300 mb-2">
                    CAPTIONS (OPTIONAL)
                  </label>
                  <input
                    type="file"
                    accept=".srt,.vtt"
                    data-role="captions-input"
                    class="block w-full text-sm text-gray-400 font-mono file:mr-4 file:py-2 file:px-4 file:rounded file:border-0 file:bg-gray-700 file:text-white file:font-mono file:cursor-pointer hover:file:bg-gray-600"
                  />
                  <p class="text-xs text-gray-500 font-mono mt-2">
                    An .srt or .vtt file makes the video searchable by what was said.
                  </p>
                </div>

                <button
                  type="button"
                  data-role="start"
                  class="w-full bg-green-600 hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed text-white px-4 py-3 rounded-lg font-mono font-medium transition-colors"
                >
                  SLICE + UPLOAD
                </button>

                <div data-role="progress-wrap" class="hidden">
                  <progress data-role="progress" value="0" max="100" class="w-full h-2"></progress>
                </div>
                <div data-role="status" class="text-sm font-mono text-gray-400 min-h-5"></div>
              </div>
            </div>
          </div>
        </div>

    <!-- YouTube tab -->
        <div class={["max-w-2xl mx-auto", @tab != "youtube" && "hidden"]}>
          <div class="bg-gray-800 rounded-lg border border-gray-700 p-6 space-y-4">
            <h2 class="text-lg font-bold font-mono">RIP FROM YOUTUBE</h2>

            <p class="text-gray-400 text-sm font-mono leading-relaxed">
              YouTube blocks servers from downloading videos, so Framecut can't rip them for
              you. Instead, run the grabber on your own machine — a single binary with
              yt-dlp and ffmpeg built in (nothing to install). It downloads the video,
              slices it into frames, grabs captions automatically, and uploads everything
              to this site.
            </p>

            <ol class="list-decimal list-inside text-sm text-gray-300 font-mono space-y-2">
              <li>
                Download the grabber for your machine:
                <div class="flex flex-wrap gap-2 mt-2 ml-4">
                  <a
                    href="/downloads/framecut-grab-darwin-arm64"
                    download
                    class="bg-gray-700 hover:bg-gray-600 text-blue-300 px-3 py-1.5 rounded text-xs"
                  >
                     macOS (Apple Silicon)
                  </a>
                  <a
                    href="/downloads/framecut-grab-darwin-amd64"
                    download
                    class="bg-gray-700 hover:bg-gray-600 text-blue-300 px-3 py-1.5 rounded text-xs"
                  >
                     macOS (Intel)
                  </a>
                  <a
                    href="/downloads/framecut-grab-linux-amd64"
                    download
                    class="bg-gray-700 hover:bg-gray-600 text-blue-300 px-3 py-1.5 rounded text-xs"
                  >
                    🐧 Linux
                  </a>
                  <a
                    href="/downloads/framecut-grab-windows-amd64.exe"
                    download
                    class="bg-gray-700 hover:bg-gray-600 text-blue-300 px-3 py-1.5 rounded text-xs"
                  >
                    ⊞ Windows
                  </a>
                </div>
              </li>
              <li>Make it executable and run it with the video URL:</li>
            </ol>

            <pre class="bg-gray-900 border border-gray-700 rounded p-4 text-xs text-green-400 font-mono overflow-x-auto">chmod +x framecut-grab-*
    ./framecut-grab-* "https://www.youtube.com/watch?v=..." \
      --server {@base_url} \
      --api-key YOUR_API_KEY</pre>

            <p class="text-gray-500 text-xs font-mono leading-relaxed">
              Prefer Python? The original
              <a href="/downloads/framecut_grab.py" download class="text-blue-400 underline">
                framecut_grab.py
              </a>
              does the same job if you have yt-dlp and ffmpeg installed.
            </p>

            <p class="text-gray-400 text-sm font-mono leading-relaxed">
              The video appears in the library as soon as the upload finishes.
            </p>

            <p class="text-gray-500 text-xs font-mono leading-relaxed">
              Age-restricted video? Add
              <code class="bg-gray-900 px-1.5 py-0.5 rounded">--cookies-from-browser chrome</code>
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

    link_captions(video_id, socket.assigns.ingest_captions_text)

    case Video.update_video(video, %{
           status: "completed",
           processed_at: DateTime.utc_now(),
           frame_count: socket.assigns.ingest_frames_inserted
         }) do
      {:ok, _video} ->
        socket =
          socket
          |> assign(:ingest_video_id, nil)
          |> assign(:ingest_captions_text, nil)
          |> put_flash(:info, "Video added — pick some frames and make a GIF!")
          |> push_navigate(to: ~p"/video/#{video_id}")

        {:noreply, socket}

      {:error, changeset} ->
        Logger.error("Client ingest failed to finalize video #{video_id}: #{inspect(changeset.errors)}")

        {:noreply,
         push_event(socket, "ingest_error", %{
           message: "The video was uploaded but could not be finalized. Please try again."
         })}
    end
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

    with true <- trimmed != "",
         {:ok, entries} when entries != [] <-
           SrtParser.parse_content(normalize_captions(trimmed)) do
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

      captions =
        case caption_rows do
          [] ->
            []

          rows ->
            {_count, captions} =
              Repo.insert_all(VideoCaption, rows, returning: [:id, :start_time_ms, :end_time_ms])

            captions
        end

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
    else
      _ -> :ok
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
