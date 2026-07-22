defmodule NathanForUsWeb.VideoTimelineLive do
  @moduledoc """
  The GIF editor (`/video/:video_id`).

  Selection is a contiguous frame range `{sel_start, sel_end}` (indices into
  a lightweight whole-video frame index) plus a playhead. Thumbnails and
  previews are served via `GET /frame/:id` — no frame binaries cross the
  websocket. Client interaction lives in three JS hooks: `Filmstrip`
  (pointer gestures), `RangePreview` (looping stage preview), and
  `KeyboardShortcuts`.
  """

  use NathanForUsWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias NathanForUs.{AdminService, Gif, Repo, Video, Viral}
  alias NathanForUs.Video.VideoFrame
  alias NathanForUs.Viral.BrowseableGif

  alias NathanForUsWeb.Components.VideoTimeline.{
    CaptionSearch,
    FrameDisplay,
    GifPreview
  }

  on_mount {NathanForUsWeb.UserAuth, :mount_current_user}

  require Logger

  @fps_options [5, 10, 15]
  @default_fps 10
  @generation_timeout_ms 60_000
  @max_caption_results 100

  # ── Mount / params ──────────────────────────────────────────────────────

  def mount(%{"video_id" => video_id}, _session, socket) do
    case Integer.parse(video_id) do
      {video_id, ""} -> mount_video(video_id, socket)
      _ -> {:ok, invalid_video_redirect(socket, "Invalid video ID")}
    end
  end

  defp mount_video(video_id, socket) do
    case Video.get_video(video_id) do
      {:error, :not_found} ->
        {:ok, invalid_video_redirect(socket, "Video not found")}

      {:ok, video} ->
        {:ok, frame_count} = Video.get_video_frame_count(video_id)
        video_duration_ms = Video.get_video_duration_ms(video_id)

        frame_index =
          if connected?(socket), do: Video.list_frame_index(video_id), else: []

        socket =
          socket
          |> assign(:video, video)
          |> assign(:page_title, "Edit · #{video.title}")
          # Set by the landing's "cut out a GIF" flow (/video/:id?post=1): the
          # first GIF generated here auto-posts to the global timeline.
          |> assign(:auto_post, false)
          |> assign(:frame_count, frame_count)
          |> assign(:video_duration_ms, video_duration_ms || 0)
          |> assign(:frame_index, frame_index)
          |> assign(:index_by_number, index_by_number(frame_index))
          |> assign(:playhead, 0)
          |> assign(:sel_start, nil)
          |> assign(:sel_end, nil)
          |> assign(:fps, @default_fps)
          |> assign(:show_shortcuts, false)
          |> assign(:has_captions, video_has_captions?(video_id))
          |> assign(:caption_search_term, "")
          |> assign(:caption_loading, false)
          |> assign(:caption_results, [])
          |> assign(:caption_result_count, 0)
          |> assign(:caption_results_open, false)
          |> assign(:caption_searched, false)
          |> assign(:caption_match_idxs, [])
          |> assign(:recent_gifs, Viral.get_timeline_gifs(12))
          |> reset_generation_assigns()
          |> refresh_preview()

        {:ok, socket}
    end
  end

  defp invalid_video_redirect(socket, message) do
    socket
    |> put_flash(:error, message)
    |> redirect(to: ~p"/")
  end

  def handle_params(params, _url, socket) do
    socket = assign(socket, :auto_post, params["post"] == "1" or socket.assigns.auto_post)

    if connected?(socket) and socket.assigns[:frame_index] not in [nil, []] do
      {:noreply, apply_url_params(socket, params)}
    else
      {:noreply, socket}
    end
  end

  # Backwards-compatible deep links from the library / feed:
  #   ?search=term[&context_frame=N]  — run a caption search, optionally jump
  #   ?random=true&start_frame=S&selected_indices=…  — pre-select a range
  defp apply_url_params(socket, %{"search" => term} = params) when term != "" do
    term = term |> URI.decode() |> String.trim()

    socket =
      if String.length(term) >= 3 do
        send(self(), {:run_caption_search, term})

        socket
        |> assign(:caption_search_term, term)
        |> assign(:caption_loading, true)
        |> assign(:caption_results_open, true)
      else
        socket
      end

    case parse_int(params["context_frame"]) do
      nil -> socket
      frame_number -> jump_playhead_to_frame_number(socket, frame_number)
    end
  end

  defp apply_url_params(socket, %{"random" => "true", "start_frame" => start_frame} = params) do
    with start_number when not is_nil(start_number) <- parse_int(start_frame),
         start_idx when not is_nil(start_idx) <-
           Map.get(socket.assigns.index_by_number, start_number) do
      count =
        params
        |> Map.get("selected_indices", "")
        |> URI.decode()
        |> String.split(",", trim: true)
        |> length()
        |> max(2)

      last_idx = min(start_idx + count - 1, length(socket.assigns.frame_index) - 1)

      socket
      |> assign(:sel_start, start_idx)
      |> assign(:sel_end, last_idx)
      |> assign(:playhead, start_idx)
      |> refresh_preview()
      |> push_event("filmstrip:scroll_to", %{index: start_idx})
    else
      _ -> put_flash(socket, :error, "Invalid random parameters")
    end
  end

  defp apply_url_params(socket, _params), do: socket

  # ── Playhead & range events ─────────────────────────────────────────────

  def handle_event("set_playhead", %{"frame_number" => frame_number}, socket) do
    case parse_int(frame_number) do
      nil -> {:noreply, socket}
      number -> {:noreply, jump_playhead_to_frame_number(socket, number, scroll: false)}
    end
  end

  def handle_event("move_playhead", %{"delta" => delta}, socket) do
    case parse_int(delta) do
      nil ->
        {:noreply, socket}

      delta ->
        max_idx = max(length(socket.assigns.frame_index) - 1, 0)
        playhead = clamp(socket.assigns.playhead + delta, 0, max_idx)

        socket =
          socket
          |> assign(:playhead, playhead)
          |> refresh_preview()
          |> push_event("filmstrip:scroll_to", %{index: playhead})

        {:noreply, socket}
    end
  end

  def handle_event("select_range", params, socket) do
    with start_number when not is_nil(start_number) <- parse_int(params["start_frame_number"]),
         end_number when not is_nil(end_number) <- parse_int(params["end_frame_number"]),
         start_idx when not is_nil(start_idx) <-
           Map.get(socket.assigns.index_by_number, start_number),
         end_idx when not is_nil(end_idx) <- Map.get(socket.assigns.index_by_number, end_number) do
      {sel_start, sel_end} = {min(start_idx, end_idx), max(start_idx, end_idx)}

      socket =
        socket
        |> assign(:sel_start, sel_start)
        |> assign(:sel_end, sel_end)
        |> assign(:playhead, sel_start)
        |> refresh_preview()

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_range_point", %{"point" => point}, socket)
      when point in ["in", "out"] do
    if socket.assigns.frame_index == [] do
      {:noreply, socket}
    else
      {:noreply, set_range_point(socket, point)}
    end
  end

  def handle_event("set_range_point", _params, socket), do: {:noreply, socket}

  def handle_event("clear_range", _params, socket) do
    {:noreply, clear_range(socket)}
  end

  def handle_event("set_fps", %{"fps" => fps}, socket) do
    case parse_int(fps) do
      fps when fps in @fps_options -> {:noreply, socket |> assign(:fps, fps)}
      _ -> {:noreply, socket}
    end
  end

  # ── Keyboard / overlay events ───────────────────────────────────────────

  def handle_event("toggle_shortcuts", _params, socket) do
    {:noreply, assign(socket, :show_shortcuts, !socket.assigns.show_shortcuts)}
  end

  def handle_event("close_shortcuts", _params, socket) do
    {:noreply, assign(socket, :show_shortcuts, false)}
  end

  def handle_event("keyboard_generate", _params, socket) do
    {:noreply, start_generation(socket)}
  end

  def handle_event("editor_escape", _params, socket) do
    socket =
      cond do
        socket.assigns.show_shortcuts -> assign(socket, :show_shortcuts, false)
        socket.assigns.show_post_form -> assign(socket, :show_post_form, false)
        socket.assigns.caption_results_open -> assign(socket, :caption_results_open, false)
        true -> clear_range(socket)
      end

    {:noreply, socket}
  end

  # ── Caption search (async so the loading state actually renders) ────────

  def handle_event("caption_search_change", %{"caption_search" => %{"term" => term}}, socket) do
    {:noreply, run_caption_search(socket, term)}
  end

  def handle_event("caption_search", %{"caption_search" => %{"term" => term}}, socket) do
    {:noreply, run_caption_search(socket, term)}
  end

  def handle_event("clear_caption_search", _params, socket) do
    socket =
      socket
      |> assign(:caption_search_term, "")
      |> assign(:caption_loading, false)
      |> assign(:caption_results, [])
      |> assign(:caption_result_count, 0)
      |> assign(:caption_results_open, false)
      |> assign(:caption_searched, false)
      |> assign(:caption_match_idxs, [])

    {:noreply, socket}
  end

  def handle_event("close_caption_results", _params, socket) do
    {:noreply, assign(socket, :caption_results_open, false)}
  end

  def handle_event("jump_to_frame", %{"frame_number" => frame_number}, socket) do
    case parse_int(frame_number) do
      nil ->
        {:noreply, socket}

      number ->
        socket =
          socket
          |> jump_playhead_to_frame_number(number)
          |> assign(:caption_results_open, false)

        {:noreply, socket}
    end
  end

  # ── GIF generation & posting ────────────────────────────────────────────

  def handle_event("generate_gif", _params, socket) do
    {:noreply, start_generation(socket)}
  end

  def handle_event("open_post_form", _params, socket) do
    socket =
      socket
      |> assign(:show_post_form, true)
      |> assign(:post_error, nil)
      |> assign(:post_title, default_post_title(socket))

    {:noreply, socket}
  end

  def handle_event("cancel_post_form", _params, socket) do
    {:noreply, assign(socket, :show_post_form, false)}
  end

  def handle_event("post_to_timeline", params, socket) do
    user = socket.assigns[:current_user]
    browseable_gif_id = socket.assigns.generated_browseable_gif_id
    title = params |> get_in(["post", "title"]) |> normalize_title()

    cond do
      is_nil(user) ->
        {:noreply, assign(socket, :post_error, "Log in to post to the timeline.")}

      is_nil(browseable_gif_id) ->
        {:noreply,
         assign(socket, :post_error, "This GIF isn't ready to post — regenerate and try again.")}

      true ->
        case Viral.post_browseable_gif_to_timeline(browseable_gif_id, user.id, title) do
          {:ok, _browseable_gif} ->
            socket =
              socket
              |> assign(:posted_to_timeline, true)
              |> assign(:show_post_form, false)
              |> assign(:post_error, nil)
              |> assign(:recent_gifs, Viral.get_timeline_gifs(12))

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, assign(socket, :post_error, post_error_message(reason))}
        end
    end
  end

  # ── handle_info ─────────────────────────────────────────────────────────

  def handle_info({:run_caption_search, term}, socket) do
    if term == socket.assigns.caption_search_term do
      frames = Video.get_video_frames_with_caption_text(socket.assigns.video.id, term)

      results =
        Enum.map(frames, fn frame ->
          %{
            frame_number: frame.frame_number,
            timestamp_ms: frame.timestamp_ms,
            text: Map.get(frame, :caption_texts) || ""
          }
        end)

      match_idxs =
        results
        |> Enum.map(&Map.get(socket.assigns.index_by_number, &1.frame_number))
        |> Enum.reject(&is_nil/1)

      socket =
        socket
        |> assign(:caption_loading, false)
        |> assign(:caption_searched, true)
        |> assign(:caption_results_open, true)
        |> assign(:caption_results, Enum.take(results, @max_caption_results))
        |> assign(:caption_result_count, length(results))
        |> assign(:caption_match_idxs, match_idxs)

      {:noreply, socket}
    else
      # A newer search superseded this one
      {:noreply, socket}
    end
  end

  def handle_info({ref, {:gif_result, result}}, socket) do
    if socket.assigns[:gif_generation_task] && socket.assigns.gif_generation_task.ref == ref do
      Process.demonitor(ref, [:flush])

      socket =
        case result do
          {:ok,
           %{gif_id: gif_id, browseable_gif_id: browseable_gif_id, fallback_base64: fallback}} ->
            socket
            |> assign(:gif_generation_status, :completed)
            |> assign(:gif_generation_task, nil)
            |> assign(:generated_gif_id, gif_id)
            |> assign(:generated_browseable_gif_id, browseable_gif_id)
            |> assign(:generated_gif_data, fallback)
            |> maybe_auto_post(browseable_gif_id)

          {:error, reason} ->
            Logger.warning("GIF generation failed: #{inspect(reason)}")

            socket
            |> assign(:gif_generation_status, :failed)
            |> assign(:gif_generation_task, nil)
            |> assign(:gif_error, humanize_generation_error(reason))
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if socket.assigns[:gif_generation_task] && socket.assigns.gif_generation_task.ref == ref do
      Logger.warning("GIF generation task crashed: #{inspect(reason)}")

      socket =
        socket
        |> assign(:gif_generation_status, :failed)
        |> assign(:gif_generation_task, nil)
        |> assign(:gif_error, "The encoder crashed unexpectedly.")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:gif_generation_timeout, ref}, socket) do
    task = socket.assigns[:gif_generation_task]

    if task && task.ref == ref && socket.assigns.gif_generation_status == :generating do
      Task.shutdown(task, :brutal_kill)

      socket =
        socket
        |> assign(:gif_generation_status, :failed)
        |> assign(:gif_generation_task, nil)
        |> assign(:gif_error, "Timed out after 60 seconds.")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <div id="editor-root" phx-hook="KeyboardShortcuts" class="flex min-h-screen flex-col bg-stone-50">
      <.page_header
        title={@video.title}
        subtitle={"#{@frame_count} frames · #{format_duration(@video_duration_ms)}"}
      >
        <:actions>
          <.link navigate={~p"/"} class="btn-ghost px-3 py-1 text-xs">
            <span class="hero-arrow-left-mini size-4"></span> Library
          </.link>
          <button
            type="button"
            phx-click="toggle_shortcuts"
            class="btn-ghost px-3 py-1 text-xs"
            title="Keyboard shortcuts"
            aria-label="Keyboard shortcuts"
          >
            ?
          </button>
        </:actions>
      </.page_header>

      <GifPreview.stage
        preview_frames={@preview_frames}
        fps={@fps}
        has_range={has_range?(assigns)}
        readout={selection_readout(assigns)}
      />

      <GifPreview.generation_panel
        :if={@gif_generation_status}
        status={@gif_generation_status}
        generating_frame_count={@generating_frame_count}
        error_message={@gif_error}
        gif_id={@generated_gif_id}
        fallback_base64={@generated_gif_data}
        browseable_gif_id={@generated_browseable_gif_id}
        posted={@posted_to_timeline}
        show_post_form={@show_post_form}
        post_title={@post_title}
        post_error={@post_error}
        current_user={@current_user}
      />

      <CaptionSearch.caption_search
        search_term={@caption_search_term}
        loading={@caption_loading}
        results={@caption_results}
        result_count={@caption_result_count}
        results_open={@caption_results_open}
        searched={@caption_searched}
        has_captions={@has_captions}
      />

      <FrameDisplay.filmstrip
        frame_index={@frame_index}
        frame_count={@frame_count}
        playhead={@playhead}
        sel_start={@sel_start}
        sel_end={@sel_end}
        caption_match_idxs={@caption_match_idxs}
      />

      <section :if={@recent_gifs != []} class="border-t border-stone-200 bg-white">
        <div class="mx-auto max-w-7xl px-4 py-8 pb-28">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="font-mono text-sm font-bold uppercase tracking-wider text-stone-700">
              Recently posted
            </h2>
            <.link navigate={~p"/gifs"} class="btn-ghost px-3 py-1 text-xs">Browse all</.link>
          </div>

          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6">
            <.link
              :for={gif <- @recent_gifs}
              navigate={~p"/g/#{gif.id}"}
              class="card card-hover group overflow-hidden"
              title={gif.title || "GIF"}
            >
              <div class="relative aspect-video overflow-hidden bg-stone-100">
                <img
                  :if={gif.gif}
                  src={~p"/gif/#{gif.gif.id}/poster"}
                  loading="lazy"
                  alt={gif.title || "GIF"}
                  class="h-full w-full object-cover"
                  onmouseenter={"this.src='/gif/#{gif.gif.id}'"}
                  onmouseleave={"this.src='/gif/#{gif.gif.id}/poster'"}
                />
              </div>
              <div class="truncate px-2 py-1.5 font-mono text-xs text-stone-600">
                {gif.title || "Untitled"}
              </div>
            </.link>
          </div>
        </div>
      </section>

      <div class="flex-1"></div>

      <div class="sticky bottom-0 z-30 border-t border-stone-200 bg-white">
        <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3 px-4 py-3">
          <div class="font-mono text-sm text-stone-500">
            <%= cond do %>
              <% selection_readout(assigns) -> %>
                {selection_readout(assigns)}
              <% selected_count(assigns) == 1 -> %>
                Select at least 2 frames
              <% true -> %>
                No range selected
            <% end %>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              phx-click="set_range_point"
              phx-value-point="in"
              class="btn-secondary px-3 py-1 text-xs"
              title="Set in point at playhead (I)"
            >
              IN
            </button>
            <button
              type="button"
              phx-click="set_range_point"
              phx-value-point="out"
              class="btn-secondary px-3 py-1 text-xs"
              title="Set out point at playhead (O)"
            >
              OUT
            </button>
            <button
              :if={has_range?(assigns)}
              type="button"
              phx-click="clear_range"
              class="btn-ghost"
              title="Clear range (Esc)"
            >
              Clear
            </button>
            <button
              type="button"
              phx-click="generate_gif"
              disabled={selected_count(assigns) < 2 or @gif_generation_status == :generating}
              class="btn-primary"
              title={
                if selected_count(assigns) < 2,
                  do: "Select at least 2 frames",
                  else: "Generate GIF (Enter)"
              }
            >
              GENERATE GIF
            </button>
          </div>
        </div>
      </div>

      <div
        :if={@show_shortcuts}
        class="fixed inset-0 z-50 flex items-center justify-center bg-stone-900/40 p-4"
      >
        <div
          class="card w-full max-w-md p-6"
          role="dialog"
          aria-modal="true"
          aria-label="Keyboard shortcuts"
          phx-click-away="close_shortcuts"
        >
          <div class="mb-4 flex items-center justify-between">
            <h2 class="font-mono text-sm font-bold uppercase tracking-wider text-stone-900">
              Keyboard shortcuts
            </h2>
            <button
              type="button"
              phx-click="close_shortcuts"
              class="p-1 text-stone-400 hover:text-stone-700"
              aria-label="Close"
            >
              <span class="hero-x-mark-mini size-5"></span>
            </button>
          </div>
          <dl class="space-y-2 font-mono text-sm">
            <div
              :for={{keys, action} <- shortcut_rows()}
              class="flex items-center justify-between gap-4"
            >
              <dt class="flex shrink-0 gap-1">
                <kbd
                  :for={key <- keys}
                  class="rounded border border-stone-300 bg-stone-100 px-1.5 py-0.5 text-xs text-stone-700"
                >
                  {key}
                </kbd>
              </dt>
              <dd class="text-right text-stone-500">{action}</dd>
            </div>
          </dl>
        </div>
      </div>
    </div>
    """
  end

  defp shortcut_rows do
    [
      {["←", "→"], "Move playhead ±1 frame (Shift: ±10)"},
      {["I"], "Set range in-point at playhead"},
      {["O"], "Set range out-point at playhead"},
      {["Space"], "Play / pause the preview"},
      {["Enter", "G"], "Generate GIF"},
      {["Esc"], "Clear range / close this overlay"},
      {["?"], "Show this overlay"}
    ]
  end

  # ── Selection helpers ───────────────────────────────────────────────────

  defp has_range?(%{sel_start: sel_start, sel_end: sel_end}) do
    is_integer(sel_start) and is_integer(sel_end)
  end

  defp selected_count(%{sel_start: sel_start, sel_end: sel_end}) do
    if is_integer(sel_start) and is_integer(sel_end), do: sel_end - sel_start + 1, else: 0
  end

  defp selection_readout(%{sel_start: sel_start, sel_end: sel_end} = assigns) do
    count = selected_count(assigns)

    if count >= 2 do
      first = Enum.at(assigns.frame_index, sel_start)
      last = Enum.at(assigns.frame_index, sel_end)
      seconds = Float.round(count / assigns.fps, 1)

      "Frames #{first.frame_number}–#{last.frame_number} · #{count} frames · #{seconds}s"
    end
  end

  defp selection_frames(socket) do
    %{sel_start: sel_start, sel_end: sel_end, frame_index: frame_index} = socket.assigns

    if is_integer(sel_start) and is_integer(sel_end) do
      Enum.slice(frame_index, sel_start..sel_end)
    else
      []
    end
  end

  defp clear_range(socket) do
    socket
    |> assign(:sel_start, nil)
    |> assign(:sel_end, nil)
    |> refresh_preview()
  end

  defp set_range_point(socket, point) do
    %{playhead: playhead, sel_start: sel_start, sel_end: sel_end} = socket.assigns

    {sel_start, sel_end} =
      case point do
        "in" ->
          if is_integer(sel_end) and sel_end >= playhead,
            do: {playhead, sel_end},
            else: {playhead, playhead}

        "out" ->
          if is_integer(sel_start) and sel_start <= playhead,
            do: {sel_start, playhead},
            else: {playhead, playhead}
      end

    socket
    |> assign(:sel_start, sel_start)
    |> assign(:sel_end, sel_end)
    |> refresh_preview()
  end

  defp jump_playhead_to_frame_number(socket, frame_number, opts \\ []) do
    case Map.get(socket.assigns.index_by_number, frame_number) do
      nil ->
        socket

      idx ->
        socket = socket |> assign(:playhead, idx) |> refresh_preview()

        if Keyword.get(opts, :scroll, true) do
          push_event(socket, "filmstrip:scroll_to", %{index: idx})
        else
          socket
        end
    end
  end

  # Frames shown in the stage preview: the selected range, or the playhead
  # frame when no range is set. Captions come from one batched query.
  defp refresh_preview(socket) do
    frames =
      case selection_frames(socket) do
        [] ->
          case Enum.at(socket.assigns.frame_index, socket.assigns.playhead) do
            nil -> []
            frame -> [frame]
          end

        frames ->
          frames
      end

    captions_by_id =
      case frames do
        [] -> %{}
        frames -> Video.get_frame_captions_for_ids(Enum.map(frames, & &1.id))
      end

    preview_frames =
      Enum.map(frames, fn frame ->
        %{
          id: frame.id,
          url: ~p"/frame/#{frame.id}",
          caption: captions_by_id |> Map.get(frame.id, []) |> Enum.join(" ")
        }
      end)

    assign(socket, :preview_frames, preview_frames)
  end

  # ── Caption search ──────────────────────────────────────────────────────

  defp run_caption_search(socket, term) do
    term = String.trim(term)
    socket = assign(socket, :caption_search_term, term)

    if String.length(term) >= 3 do
      send(self(), {:run_caption_search, term})

      socket
      |> assign(:caption_loading, true)
      |> assign(:caption_results_open, true)
    else
      socket
      |> assign(:caption_loading, false)
      |> assign(:caption_results, [])
      |> assign(:caption_result_count, 0)
      |> assign(:caption_results_open, false)
      |> assign(:caption_searched, false)
      |> assign(:caption_match_idxs, [])
    end
  end

  # ── GIF generation ──────────────────────────────────────────────────────

  defp reset_generation_assigns(socket) do
    socket
    |> assign(:gif_generation_status, nil)
    |> assign(:gif_generation_task, nil)
    |> assign(:generating_frame_count, 0)
    |> assign(:gif_error, nil)
    |> assign(:generated_gif_id, nil)
    |> assign(:generated_browseable_gif_id, nil)
    |> assign(:generated_gif_data, nil)
    |> assign(:posted_to_timeline, false)
    |> assign(:show_post_form, false)
    |> assign(:post_title, "")
    |> assign(:post_error, nil)
  end

  defp start_generation(socket) do
    frames = selection_frames(socket)

    cond do
      socket.assigns.gif_generation_status == :generating ->
        socket

      length(frames) < 2 ->
        socket

      true ->
        video = socket.assigns.video
        user = socket.assigns[:current_user]
        fps = socket.assigns.fps

        socket = reset_generation_assigns(socket)

        case Gif.find_or_prepare(video.id, frames, fps) do
          {:ok, existing_gif} ->
            browseable = ensure_browseable_gif(existing_gif, video, user, frames)

            socket
            |> assign(:gif_generation_status, :completed)
            |> assign(:generated_gif_id, existing_gif.id)
            |> assign(:generated_browseable_gif_id, browseable && browseable.id)

          {:generate, hash, frame_ids} ->
            task =
              Task.async(fn -> run_generation(hash, video, user, frames, frame_ids, fps) end)

            Process.send_after(
              self(),
              {:gif_generation_timeout, task.ref},
              @generation_timeout_ms
            )

            socket
            |> assign(:gif_generation_status, :generating)
            |> assign(:gif_generation_task, task)
            |> assign(:generating_frame_count, length(frames))
        end
    end
  end

  # Runs inside a Task: loads the heavy frame binaries (kept out of socket
  # assigns), encodes with ffmpeg at the chosen fps, saves, and creates the
  # (private) browseable draft record.
  defp run_generation(hash, video, user, frames_meta, frame_ids, fps) do
    full_frames =
      from(f in VideoFrame, where: f.id in ^frame_ids, order_by: f.frame_number)
      |> Repo.all()

    indices = Enum.to_list(0..(length(full_frames) - 1)//1)

    case AdminService.generate_gif_from_frames(%{sequence_frames: full_frames}, indices, fps: fps) do
      {:ok, gif_binary} ->
        case Gif.save_generated_gif(hash, video.id, frame_ids, gif_binary) do
          {:ok, saved_gif} ->
            browseable =
              create_browseable_gif_from_generation(frames_meta, video, user, saved_gif)

            {:gif_result,
             {:ok,
              %{
                gif_id: saved_gif.id,
                browseable_gif_id: browseable && browseable.id,
                fallback_base64: nil
              }}}

          {:error, reason} ->
            Logger.warning("Saving generated GIF failed: #{inspect(reason)}")

            {:gif_result,
             {:ok,
              %{
                gif_id: nil,
                browseable_gif_id: nil,
                fallback_base64: Base.encode64(gif_binary)
              }}}
        end

      {:error, reason} ->
        {:gif_result, {:error, reason}}
    end
  end

  # Generated drafts are PRIVATE (is_public: false) — nothing appears in the
  # public feed until the user explicitly posts it.
  defp create_browseable_gif_from_generation(frames_meta, video, user, saved_gif) do
    if length(frames_meta) >= 2 do
      first_frame = List.first(frames_meta)
      last_frame = List.last(frames_meta)

      frame_data =
        Jason.encode!(%{
          frame_ids: Enum.map(frames_meta, & &1.id),
          frame_numbers: Enum.map(frames_meta, & &1.frame_number),
          timestamps: Enum.map(frames_meta, & &1.timestamp_ms)
        })

      attrs = %{
        video_id: video.id,
        created_by_user_id: user && user.id,
        gif_id: saved_gif.id,
        start_frame_index: first_frame.frame_number,
        end_frame_index: last_frame.frame_number,
        category: nil,
        frame_data: frame_data,
        title: BrowseableGif.generate_title(nil, video.title),
        is_public: false
      }

      case Viral.create_browseable_gif(attrs) do
        {:ok, browseable_gif} ->
          browseable_gif

        {:error, reason} ->
          Logger.warning("Creating browseable GIF draft failed: #{inspect(reason)}")
          nil
      end
    end
  end

  # On a dedup cache hit, reuse this user's existing draft for the GIF (or
  # create one) so posting always goes by browseable_gif_id.
  defp ensure_browseable_gif(gif, video, user, frames_meta) do
    user_id = user && user.id

    base_query =
      from(b in BrowseableGif, where: b.gif_id == ^gif.id, order_by: [desc: b.id], limit: 1)

    query =
      if user_id do
        from(b in base_query, where: b.created_by_user_id == ^user_id)
      else
        from(b in base_query, where: is_nil(b.created_by_user_id))
      end

    case Repo.one(query) do
      nil -> create_browseable_gif_from_generation(frames_meta, video, user, gif)
      browseable_gif -> browseable_gif
    end
  end

  # The landing "cut out a GIF" flow (?post=1): once a GIF finishes generating,
  # post it to the global timeline automatically and jump to its permalink.
  # Requires a logged-in user (posting is attributed); if the user isn't logged
  # in or the post fails, we fall through to the normal manual post UI.
  defp maybe_auto_post(socket, browseable_gif_id) do
    user = socket.assigns[:current_user]

    if socket.assigns[:auto_post] and not is_nil(user) and not is_nil(browseable_gif_id) do
      title = socket |> default_post_title() |> normalize_title()

      case Viral.post_browseable_gif_to_timeline(browseable_gif_id, user.id, title) do
        {:ok, _browseable_gif} ->
          socket
          |> put_flash(:info, "GIF posted to the timeline.")
          |> push_navigate(to: ~p"/g/#{browseable_gif_id}")

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  defp default_post_title(socket) do
    caption =
      socket.assigns.preview_frames
      |> Enum.map(& &1.caption)
      |> Enum.find(&(&1 != "" and not is_nil(&1)))

    case caption do
      nil -> socket.assigns.video.title || ""
      caption -> caption |> String.split(" | ") |> List.first() |> String.slice(0, 120)
    end
  end

  defp normalize_title(nil), do: nil

  defp normalize_title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      title -> title
    end
  end

  defp post_error_message(:not_found), do: "This GIF no longer exists — regenerate and try again."
  defp post_error_message(:invalid), do: "This GIF couldn't be posted — regenerate and try again."
  defp post_error_message(_reason), do: "Couldn't post to the timeline — please try again."

  defp humanize_generation_error(reason) when is_binary(reason) do
    # ffmpeg errors are long and noisy; keep the first line for the alert
    reason |> String.split("\n") |> List.first() |> String.slice(0, 200)
  end

  defp humanize_generation_error(reason), do: inspect(reason)

  # ── Misc helpers ────────────────────────────────────────────────────────

  defp index_by_number(frame_index) do
    frame_index
    |> Enum.with_index()
    |> Map.new(fn {frame, idx} -> {frame.frame_number, idx} end)
  end

  defp video_has_captions?(video_id) do
    Repo.exists?(from(c in NathanForUs.Video.VideoCaption, where: c.video_id == ^video_id))
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(value) when is_float(value), do: round(value)
  defp parse_int(_value), do: nil

  defp clamp(value, min_value, max_value), do: value |> max(min_value) |> min(max_value)

  defp format_duration(nil), do: "0:00"

  defp format_duration(ms) when is_integer(ms) do
    total_seconds = div(ms, 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    if hours > 0 do
      "#{hours}:#{String.pad_leading(to_string(minutes), 2, "0")}:#{String.pad_leading(to_string(seconds), 2, "0")}"
    else
      "#{minutes}:#{String.pad_leading(to_string(seconds), 2, "0")}"
    end
  end
end
