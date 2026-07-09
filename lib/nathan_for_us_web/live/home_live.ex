defmodule NathanForUsWeb.HomeLive do
  @moduledoc """
  Framecut home page.

  Hero, global caption search across the whole video library (with
  suggestion prompts), the video library grid, and a random GIF shortcut.
  """

  use NathanForUsWeb, :live_view

  import Ecto.Query
  alias NathanForUs.{Video, Repo}
  alias NathanForUs.Video.Video, as: VideoModel

  on_mount {NathanForUsWeb.UserAuth, :mount_current_user}

  def mount(_params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, mount_library(socket)}
    else
      # Logged-out visitors get the landing page — no library queries needed.
      {:ok, assign(socket, :page_title, "Turn any video into GIFs")}
    end
  end

  defp mount_library(socket) do
    # The suggestions query uses ORDER BY RANDOM(); only run it once the
    # socket is connected so it doesn't execute twice per visit.
    random_quotes =
      if connected?(socket), do: Video.get_sample_caption_suggestions(18), else: []

    all_videos =
      Video.list_videos()
      |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})

    thumbnails = Video.get_video_thumbnails(Enum.map(all_videos, & &1.id))

    socket
    |> assign(:page_title, "Turn any video into GIFs")
    |> assign(:search_term, "")
    |> assign(:search_form, to_form(%{}))
    |> assign(:random_quotes, random_quotes)
    |> assign(:all_videos, all_videos)
    |> assign(:thumbnails, thumbnails)
    |> assign(:search_results, [])
    |> assign(:loading, false)
    |> assign(:has_searched, false)
    |> assign(:search_hint, nil)
  end

  def handle_event("search", %{"search" => %{"term" => raw_term}} = params, socket) do
    term = String.trim(raw_term)
    typed? = Map.has_key?(params, "_target")

    cond do
      String.length(term) >= 3 and (not typed? or term != socket.assigns.search_term) ->
        start_search(socket, term)

      String.length(term) >= 3 ->
        # phx-change fired with the term we already searched — nothing to do
        {:noreply, socket}

      typed? ->
        # Still typing a short term: keep the input in sync, no hint yet
        {:noreply, socket |> assign(:search_term, raw_term) |> assign(:search_hint, nil)}

      true ->
        {:noreply, assign(socket, :search_hint, "Type at least 3 characters")}
    end
  end

  def handle_event("select_quote", %{"quote" => quote}, socket) do
    start_search(socket, quote)
  end

  def handle_event("clear_search", _params, socket) do
    socket =
      socket
      |> assign(:search_term, "")
      |> assign(:search_results, [])
      |> assign(:has_searched, false)
      |> assign(:loading, false)
      |> assign(:search_hint, nil)

    {:noreply, socket}
  end

  def handle_event("random_gif", _params, socket) do
    case Video.get_random_video_sequence(15) do
      {:ok, video_id, start_frame} ->
        # Generate a range of 15 frame indices starting from the random frame
        frame_indices = Enum.to_list(0..14)
        indices_param = Enum.join(frame_indices, ",")

        # Navigate to the video timeline with pre-selected frames
        path =
          ~p"/video/#{video_id}?random=true&start_frame=#{start_frame}&selected_indices=#{indices_param}"

        {:noreply, push_navigate(socket, to: path)}

      {:error, _reason} ->
        socket = put_flash(socket, :error, "No suitable videos found for random GIF generation")
        {:noreply, socket}
    end
  end

  def handle_info({:run_search, term}, socket) do
    if term == socket.assigns.search_term do
      grouped_results =
        term
        |> Video.search_frames_by_text_simple()
        |> group_results_by_video()

      socket =
        socket
        |> assign(:search_results, grouped_results)
        |> assign(:loading, false)

      {:noreply, socket}
    else
      # A newer search superseded this one; skip the stale results
      {:noreply, socket}
    end
  end

  defp start_search(socket, term) do
    send(self(), {:run_search, term})

    socket =
      socket
      |> assign(:search_term, term)
      |> assign(:loading, true)
      |> assign(:has_searched, true)
      |> assign(:search_hint, nil)

    {:noreply, socket}
  end

  def render(%{current_user: nil} = assigns) do
    ~H"""
    <div class="min-h-screen bg-white">
      <div class="max-w-3xl mx-auto px-6 py-20 sm:py-28 text-center">
        <h1 class="text-5xl sm:text-6xl font-bold font-mono tracking-tight text-stone-900">
          FRAMECUT <span class="text-brand">&#9654;</span>
        </h1>
        <p class="mt-4 text-xl sm:text-2xl text-stone-700">
          Turn any video into GIFs, frame by frame.
        </p>

        <div class="mt-16 space-y-12 text-left">
          <div class="flex items-start gap-6">
            <span class="font-mono text-5xl sm:text-6xl font-bold text-brand shrink-0 w-16">1</span>
            <div>
              <h2 class="font-mono uppercase tracking-wider text-2xl font-bold text-stone-900">
                Grab
              </h2>
              <p class="mt-1 text-lg text-stone-600">
                Paste a video link into the desktop tool.
                It slices the video into frames — one for every second.
              </p>
            </div>
          </div>
          <div class="flex items-start gap-6">
            <span class="font-mono text-5xl sm:text-6xl font-bold text-brand shrink-0 w-16">2</span>
            <div>
              <h2 class="font-mono uppercase tracking-wider text-2xl font-bold text-stone-900">
                Upload
              </h2>
              <p class="mt-1 text-lg text-stone-600">
                The frames and captions land here automatically, searchable by what was said.
              </p>
            </div>
          </div>
          <div class="flex items-start gap-6">
            <span class="font-mono text-5xl sm:text-6xl font-bold text-brand shrink-0 w-16">3</span>
            <div>
              <h2 class="font-mono uppercase tracking-wider text-2xl font-bold text-stone-900">
                GIF
              </h2>
              <p class="mt-1 text-lg text-stone-600">
                Drag across the filmstrip, pick a range, get a GIF. Share it anywhere.
              </p>
            </div>
          </div>
        </div>

        <div class="mt-16">
          <.link navigate={~p"/users/register"} class="btn-primary px-8 py-4 text-lg">
            Get started &mdash; one form
          </.link>
          <p class="mt-6 text-stone-500">
            <.link navigate={~p"/gifs"} class="text-brand-deep hover:text-brand">
              See GIFs made here &rarr;
            </.link>
            <span class="text-stone-300 mx-2">|</span>
            <.link navigate={~p"/users/log_in"} class="text-brand-deep hover:text-brand">
              Log in
            </.link>
          </p>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <!-- Hero -->
      <div class="bg-white border-b border-stone-200 px-6 py-12">
        <div class="max-w-4xl mx-auto text-center">
          <h1 class="text-4xl sm:text-5xl font-bold font-mono tracking-tight text-stone-900">
            FRAMECUT <span class="text-brand">&#9654;</span>
          </h1>
          <p class="text-stone-500 font-mono mt-3">
            Turn any video into GIFs, frame by frame.
          </p>

          <%= if Enum.empty?(@all_videos) do %>
            <div class="mt-10">
              <.link navigate={~p"/add"} class="btn-primary px-6 py-3 text-base">
                + Add your first video
              </.link>
              <p class="mt-4 text-sm text-stone-500">
                Or grab one straight from YouTube with
                <.link navigate={~p"/add?tab=cli"} class="text-brand-deep hover:text-brand">
                  the desktop app
                </.link>
              </p>
            </div>
          <% else %>
            <div class="flex flex-wrap items-center justify-center gap-3 mt-8">
              <.link navigate={~p"/add"} class="btn-primary">
                + Add a video
              </.link>
              <.link navigate={~p"/gifs"} class="btn-secondary">
                Browse the GIF feed
              </.link>
              <.link navigate={~p"/timeline"} class="btn-secondary">
                Public timeline
              </.link>
              <button
                type="button"
                phx-click="random_gif"
                class="btn-secondary"
                title="Jump into the editor with a random clip"
              >
                Random GIF
              </button>
            </div>
          <% end %>
        </div>
      </div>

      <%= unless Enum.empty?(@all_videos) do %>
        <div class="px-6 py-8">
          <div class="max-w-6xl mx-auto">
            <!-- Search -->
            <div class="max-w-4xl mx-auto mb-10">
              <.form for={@search_form} phx-submit="search" phx-change="search">
                <div class="flex gap-3">
                  <input
                    type="text"
                    name="search[term]"
                    value={@search_term}
                    placeholder="Search everything said in the library..."
                    class="input flex-1"
                    phx-debounce="500"
                    autocomplete="off"
                  />
                  <button type="submit" class="btn-secondary" disabled={@loading}>
                    Search
                  </button>
                  <button :if={@has_searched} type="button" phx-click="clear_search" class="btn-ghost">
                    Clear
                  </button>
                </div>
              </.form>
              <p :if={@search_hint} class="mt-2 font-mono text-xs text-stone-500">
                {@search_hint}
              </p>
            </div>

            <%= unless @has_searched do %>
              <!-- Caption suggestions -->
              <div :if={@random_quotes != []} class="mb-10">
                <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-3">
                  Try searching for these lines
                </h2>
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                  <button
                    :for={quote <- @random_quotes}
                    type="button"
                    phx-click="select_quote"
                    phx-value-quote={quote}
                    class="card card-hover p-4 text-left"
                  >
                    <p class="text-sm leading-relaxed text-stone-700">
                      "{quote}"
                    </p>
                  </button>
                </div>
              </div>
              
    <!-- Video library -->
              <div>
                <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-3">
                  Video library
                </h2>
                <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
                  <%= for video <- @all_videos do %>
                    <%= if video.status == "completed" do %>
                      <.link
                        navigate={~p"/video/#{video.id}"}
                        class="card card-hover overflow-hidden block"
                      >
                        <.video_thumb video={video} thumb_id={@thumbnails[video.id]} />
                        <div class="p-3">
                          <h3 class="text-sm font-medium text-stone-900 truncate">
                            {video.title}
                          </h3>
                          <div class="mt-1 flex items-center gap-3 font-mono text-xs text-stone-500">
                            <span :if={video.frame_count}>{video.frame_count} frames</span>
                            <span :if={video.duration_ms}>{format_duration(video.duration_ms)}</span>
                          </div>
                        </div>
                      </.link>
                    <% else %>
                      <div class="card overflow-hidden">
                        <.video_thumb video={video} thumb_id={@thumbnails[video.id]} />
                        <div class="p-3">
                          <h3 class="text-sm font-medium text-stone-700 truncate">
                            {video.title}
                          </h3>
                          <p class="mt-1 font-mono text-xs text-stone-500">
                            {status_note(video.status)}
                          </p>
                        </div>
                      </div>
                    <% end %>
                  <% end %>
                </div>
              </div>
            <% end %>
            
    <!-- Search loading skeletons -->
            <div :if={@loading} class="space-y-4" aria-busy="true">
              <div :for={_i <- 1..3} class="card p-6">
                <div class="h-5 w-1/3 rounded bg-stone-200 animate-pulse"></div>
                <div class="mt-4 grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4">
                  <div :for={_j <- 1..6} class="aspect-video rounded-lg bg-stone-200 animate-pulse">
                  </div>
                </div>
              </div>
            </div>
            
    <!-- Search results -->
            <%= if @has_searched and not @loading do %>
              <%= if Enum.empty?(@search_results) do %>
                <div class="border-2 border-dashed border-stone-300 rounded-xl bg-white py-16 px-6 text-center">
                  <span class="hero-magnifying-glass size-10 text-stone-300 mx-auto block"></span>
                  <h3 class="mt-4 font-mono uppercase tracking-wider text-stone-700">
                    No matches for "{@search_term}"
                  </h3>
                  <p class="mt-2 text-sm text-stone-500">
                    Try a different phrase, or let the library surprise you with a random clip.
                  </p>
                  <div class="mt-6 flex flex-wrap items-center justify-center gap-3">
                    <button type="button" phx-click="random_gif" class="btn-secondary">
                      Random GIF
                    </button>
                    <button type="button" phx-click="clear_search" class="btn-ghost">
                      Clear search
                    </button>
                  </div>
                </div>
              <% else %>
                <div class="space-y-6">
                  <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500">
                    Found {total_frame_count(@search_results)} frames across {length(@search_results)} videos
                  </h2>

                  <div :for={{video, frames} <- @search_results} class="card p-6">
                    <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
                      <div>
                        <h3 class="text-lg font-bold font-mono text-stone-900">
                          {video.title}
                        </h3>
                        <p class="font-mono text-xs text-stone-500">
                          {length(frames)} matching frames
                        </p>
                      </div>
                      <.link
                        navigate={build_timeline_link(video.id, frames, @search_term)}
                        class="btn-secondary"
                      >
                        Create GIF
                      </.link>
                    </div>

                    <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4">
                      <div :for={frame <- Enum.take(frames, 12)}>
                        <.link
                          navigate={build_frame_context_link(video.id, frame, @search_term)}
                          class="relative block group"
                        >
                          <div class="aspect-video rounded-lg border border-stone-200 bg-stone-100 overflow-hidden group-hover:border-stone-300 transition-colors">
                            <img
                              src={~p"/frame/#{frame.id}"}
                              alt={"Frame ##{frame.frame_number}"}
                              loading="lazy"
                              class="w-full h-full object-cover"
                            />
                          </div>
                          <span class="absolute bottom-1 right-1 rounded border border-stone-200 bg-white/80 backdrop-blur px-1 py-0.5 font-mono text-xs text-stone-700">
                            #{frame.frame_number}
                          </span>
                        </.link>

                        <p
                          :if={frame.caption_texts && frame.caption_texts != ""}
                          class="mt-1 text-xs text-stone-500 line-clamp-2"
                        >
                          "{String.slice(frame.caption_texts, 0, 100)}{if String.length(
                                                                            frame.caption_texts
                                                                          ) > 100,
                                                                          do: "..."}"
                        </p>
                      </div>

                      <div :if={length(frames) > 12} class="col-span-full text-center mt-2">
                        <span class="font-mono text-xs text-stone-500">
                          + {length(frames) - 12} more frames
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :video, :map, required: true
  attr :thumb_id, :integer, default: nil

  defp video_thumb(assigns) do
    ~H"""
    <div class="relative aspect-video bg-stone-100 border-b border-stone-200 overflow-hidden">
      <img
        :if={@thumb_id}
        src={~p"/frame/#{@thumb_id}"}
        alt={@video.title}
        loading="lazy"
        class="w-full h-full object-cover"
      />
      <div :if={is_nil(@thumb_id)} class="w-full h-full flex items-center justify-center">
        <span class="hero-film size-10 text-stone-300"></span>
      </div>
      <%= case status_badge(@video.status) do %>
        <% nil -> %>
        <% {badge_class, label} -> %>
          <span class={["badge absolute top-2 right-2 bg-white/80 backdrop-blur", badge_class]}>
            {label}
          </span>
      <% end %>
    </div>
    """
  end

  # Helper functions

  defp group_results_by_video(search_results) do
    # Get unique video IDs from results
    video_ids = search_results |> Enum.map(& &1.video_id) |> Enum.uniq()

    # Get video information
    videos =
      VideoModel
      |> where([v], v.id in ^video_ids)
      |> Repo.all()
      |> Enum.into(%{}, fn video -> {video.id, video} end)

    # Group frames by video
    search_results
    |> Enum.group_by(& &1.video_id)
    |> Enum.map(fn {video_id, frames} ->
      video = Map.get(videos, video_id)
      {video, frames}
    end)
    |> Enum.reject(fn {video, _frames} -> is_nil(video) end)
    |> Enum.sort_by(fn {video, _frames} -> video.title end)
  end

  defp total_frame_count(grouped_results) do
    grouped_results
    |> Enum.map(fn {_video, frames} -> length(frames) end)
    |> Enum.sum()
  end

  defp build_timeline_link(video_id, _frames, search_term) do
    encoded_search_term = URI.encode(search_term)
    ~p"/video/#{video_id}?search=#{encoded_search_term}"
  end

  defp build_frame_context_link(video_id, frame, search_term) do
    encoded_search_term = URI.encode(search_term)

    ~p"/video/#{video_id}?search=#{encoded_search_term}&context_frame=#{frame.frame_number}"
  end

  defp format_duration(duration_ms) when is_integer(duration_ms) do
    total_seconds = div(duration_ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(seconds), 2, "0")}"
  end

  defp format_duration(_), do: "Unknown"

  # Completed videos get no badge; only in-flight or failed states are marked.
  defp status_badge("processing"), do: {"badge-warning animate-pulse", "processing"}
  defp status_badge("pending"), do: {"badge-neutral", "pending"}
  defp status_badge("failed"), do: {"badge-danger", "failed"}
  defp status_badge(_), do: nil

  defp status_note("failed"), do: "Failed"
  defp status_note(_), do: "Processing — check back soon"
end
