defmodule NathanForUsWeb.TimelineLive do
  @moduledoc """
  Public timeline of GIFs their creators explicitly posted.

  Unlike the explore feed (every public GIF), the timeline only shows GIFs
  shared via `NathanForUs.Viral.post_gif_to_timeline/3` or
  `post_browseable_gif_to_timeline/3`, ordered by when they were posted.
  Paginated as an infinite-scroll stream; `?gif_id=` deep links resolve
  straight from the database.
  """

  use NathanForUsWeb, :live_view

  alias NathanForUs.{Video, Viral}
  alias NathanForUsWeb.Components.GifModal

  import NathanForUsWeb.Components.GifModal,
    only: [vote_button_class: 1, poster_name: 1, format_duration: 1, format_time_ago: 1]

  on_mount {NathanForUsWeb.UserAuth, :mount_current_user}

  @page_size 24

  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Public timeline")
      |> assign(:session_id, Map.get(session, "live_socket_id"))
      |> assign(:page, 1)
      |> assign(:feed_loaded?, false)
      |> assign(:feed_empty?, true)
      |> assign(:end_of_feed?, false)
      |> assign(:show_register_prompt, false)
      |> assign(:show_gif_modal, false)
      |> assign(:modal_gif, nil)
      |> assign(:modal_captions, [])
      |> stream(:gifs, [])

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    socket =
      if connected?(socket) and not socket.assigns.feed_loaded? do
        load_feed(socket)
      else
        socket
      end

    resolve_modal(socket, params)
  end

  def handle_event("upvote_gif", %{"gif_id" => gif_id}, socket) do
    if user = socket.assigns.current_user do
      gif_id = String.to_integer(gif_id)
      Viral.toggle_upvote(gif_id, user_id: user.id)

      {:noreply, refresh_gif(socket, gif_id)}
    else
      {:noreply, assign(socket, :show_register_prompt, true)}
    end
  end

  def handle_event("dismiss_register_prompt", _params, socket) do
    {:noreply, assign(socket, :show_register_prompt, false)}
  end

  def handle_event("random_gif", _params, socket) do
    case Video.get_random_video_sequence(15) do
      {:ok, video_id, start_frame} ->
        indices_param = Enum.join(0..14, ",")

        path =
          ~p"/video/#{video_id}?random=true&start_frame=#{start_frame}&selected_indices=#{indices_param}"

        {:noreply, redirect(socket, to: path)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No suitable videos found for a random GIF")}
    end
  end

  def handle_event("view_gif", %{"gif_id" => gif_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/timeline?gif_id=#{gif_id}")}
  end

  def handle_event("close_gif_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/timeline")}
  end

  def handle_event("load_more", _params, socket) do
    page = socket.assigns.page + 1
    gifs = fetch_page(page) |> decorate(socket)

    socket =
      socket
      |> assign(:page, page)
      |> assign(:end_of_feed?, length(gifs) < @page_size)
      |> stream(:gifs, gifs)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div>
      <.page_header title="Timeline" subtitle="GIFs their creators chose to post">
        <:actions>
          <button type="button" phx-click="random_gif" class="btn-secondary">Random GIF</button>
          <.link navigate={~p"/"} class="btn-primary">Make a GIF</.link>
        </:actions>
      </.page_header>

      <.register_prompt :if={@show_register_prompt} on_close="dismiss_register_prompt" />

      <div class="px-6 py-8">
        <div class="max-w-2xl mx-auto">
          <%= cond do %>
            <% !@feed_loaded? -> %>
              <div class="space-y-6">
                <div :for={_i <- 1..3} class="card overflow-hidden">
                  <div class="p-4 space-y-2">
                    <div class="h-3 w-1/3 rounded bg-stone-200 animate-pulse"></div>
                  </div>
                  <div class="aspect-video bg-stone-200 animate-pulse"></div>
                  <div class="p-4 space-y-2">
                    <div class="h-3 w-3/4 rounded bg-stone-200 animate-pulse"></div>
                    <div class="h-3 w-1/2 rounded bg-stone-200 animate-pulse"></div>
                  </div>
                </div>
              </div>
            <% @feed_empty? -> %>
              <div class="border-2 border-dashed border-stone-300 rounded-xl bg-white py-16 px-6 text-center">
                <span class="hero-megaphone block h-10 w-10 text-stone-300 mx-auto"></span>
                <h2 class="mt-4 font-mono uppercase tracking-wider text-stone-700">
                  Nothing posted yet
                </h2>
                <p class="mt-1 text-sm text-stone-500">
                  The timeline is where finished GIFs get showcased.
                </p>
                <.link navigate={~p"/"} class="btn-primary mt-6">Make a GIF</.link>
              </div>
            <% true -> %>
              <div id="timeline-feed" phx-update="stream" class="space-y-6">
                <div :for={{dom_id, gif} <- @streams.gifs} id={dom_id} class="card overflow-hidden">
                  <div class="px-4 pt-4 flex items-center gap-3">
                    <div
                      class="w-8 h-8 rounded-full bg-brand text-white font-mono font-medium flex items-center justify-center shrink-0"
                      aria-hidden="true"
                    >
                      {poster_initial(gif)}
                    </div>
                    <div class="flex items-center gap-2 font-mono text-sm min-w-0">
                      <span class="text-stone-900 font-medium truncate">{poster_name(gif)}</span>
                      <span class="text-stone-400" aria-hidden="true">&middot;</span>
                      <span class="text-stone-500 shrink-0">{format_time_ago(gif.posted_at)}</span>
                    </div>
                  </div>

                  <div
                    class="mt-3 relative bg-stone-100 border-y border-stone-200 overflow-hidden cursor-pointer"
                    phx-click="view_gif"
                    phx-value-gif_id={gif.id}
                    title="View GIF details"
                  >
                    <%= if gif.gif do %>
                      <img
                        src={~p"/gif/#{gif.gif.id}/poster"}
                        loading="lazy"
                        alt={gif.title || "GIF"}
                        class="w-full object-contain max-h-[70vh]"
                        onmouseenter={"this.src='/gif/#{gif.gif.id}'"}
                        onmouseleave={"this.src='/gif/#{gif.gif.id}/poster'"}
                        onfocus={"this.src='/gif/#{gif.gif.id}'"}
                        onblur={"this.src='/gif/#{gif.gif.id}/poster'"}
                      />
                      <span class="badge badge-neutral absolute top-2 right-2 bg-white/80 backdrop-blur">
                        GIF
                      </span>
                    <% else %>
                      <div class="py-16 text-center font-mono text-sm text-stone-500">
                        This GIF is being rebuilt
                      </div>
                    <% end %>
                  </div>

                  <div class="p-4">
                    <h3
                      :if={gif.title && gif.title != "Untitled GIF"}
                      class="font-mono text-sm text-stone-900 mb-1 truncate"
                    >
                      {gif.title}
                    </h3>

                    <div class="text-xs mb-3 flex flex-wrap items-center gap-x-2 gap-y-1">
                      <.link
                        navigate={~p"/video/#{gif.video_id}"}
                        class="text-brand-deep hover:text-brand font-mono"
                      >
                        From: {gif.video.title} &rarr; make your own cut
                      </.link>
                      <span :if={gif.gif && gif.gif.duration_ms} class="font-mono text-stone-500">
                        {format_duration(gif.gif.duration_ms)}
                      </span>
                    </div>

                    <div class="flex items-center justify-between">
                      <button
                        type="button"
                        phx-click="upvote_gif"
                        phx-value-gif_id={gif.id}
                        class={vote_button_class(gif.user_vote)}
                        title="Upvote this GIF"
                      >
                        <span class="hero-arrow-up-mini h-4 w-4"></span>
                        {gif.upvotes_count}
                      </button>

                      <button
                        type="button"
                        class="btn-secondary px-3 py-1 text-xs"
                        data-copy={url(~p"/g/#{gif.id}")}
                      >
                        Share
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div id="feed-tail" phx-viewport-bottom={!@end_of_feed? && "load_more"}></div>

              <div :if={@end_of_feed?} class="text-center py-10 font-mono text-sm text-stone-500">
                You've seen it all —
                <.link navigate={~p"/"} class="text-brand-deep hover:text-brand">make one</.link>
              </div>
          <% end %>
        </div>
      </div>

      <GifModal.render
        :if={@show_gif_modal && @modal_gif}
        gif_data={@modal_gif}
        captions={@modal_captions}
        user_vote={Map.get(@modal_gif, :user_vote)}
      />
    </div>
    """
  end

  # Feed loading

  defp load_feed(socket) do
    gifs = fetch_page(1) |> decorate(socket)

    socket
    |> assign(:page, 1)
    |> assign(:feed_loaded?, true)
    |> assign(:feed_empty?, gifs == [])
    |> assign(:end_of_feed?, length(gifs) < @page_size)
    |> stream(:gifs, gifs, reset: true)
  end

  defp fetch_page(page) do
    Viral.get_timeline_gifs(@page_size, (page - 1) * @page_size)
  end

  # Adds :user_vote to each GIF with one batched query.
  defp decorate(gifs, socket) do
    votes = Viral.get_user_votes(Enum.map(gifs, & &1.id), vote_identity(socket))
    Enum.map(gifs, &Map.put(&1, :user_vote, Map.get(votes, &1.id)))
  end

  defp vote_identity(socket) do
    if user = socket.assigns.current_user do
      [user_id: user.id]
    else
      [session_id: socket.assigns.session_id]
    end
  end

  # Refreshes a single GIF in place after a vote (stream + open modal).
  defp refresh_gif(socket, gif_id) do
    case Viral.get_timeline_gif(gif_id) do
      nil ->
        socket

      fresh ->
        [fresh] = decorate([fresh], socket)
        socket = stream_insert(socket, :gifs, fresh)

        if socket.assigns.modal_gif && socket.assigns.modal_gif.id == gif_id do
          assign(socket, :modal_gif, fresh)
        else
          socket
        end
    end
  end

  # Modal deep links

  defp resolve_modal(socket, params) do
    case Map.get(params, "gif_id") do
      nil ->
        {:noreply, assign(socket, show_gif_modal: false, modal_gif: nil, modal_captions: [])}

      gif_id_str ->
        with {gif_id, ""} <- Integer.parse(gif_id_str),
             %{} = gif <- Viral.get_timeline_gif(gif_id) do
          captions =
            if gif.gif && gif.gif.frame_ids do
              Video.get_gif_captions(gif.gif.frame_ids)
            else
              []
            end

          [gif] = decorate([gif], socket)

          {:noreply,
           assign(socket, show_gif_modal: true, modal_gif: gif, modal_captions: captions)}
        else
          _ ->
            {:noreply,
             socket
             |> assign(show_gif_modal: false, modal_gif: nil, modal_captions: [])
             |> put_flash(:error, "That GIF is gone or private")
             |> push_patch(to: ~p"/timeline")}
        end
    end
  end

  defp poster_initial(gif) do
    gif
    |> poster_name()
    |> String.first()
    |> String.upcase()
  end
end
