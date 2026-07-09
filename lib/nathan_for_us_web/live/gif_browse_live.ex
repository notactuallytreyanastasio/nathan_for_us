defmodule NathanForUsWeb.GifBrowseLive do
  @moduledoc """
  Browse page for public GIFs with voting and sorting (hot / top / new).

  The feed is an infinite-scroll stream paginated 24 at a time; `?gif_id=`
  deep links resolve straight from the database so shared links work even
  when the GIF isn't in the loaded page.
  """

  use NathanForUsWeb, :live_view

  alias NathanForUs.{Video, Viral}
  alias NathanForUsWeb.Components.GifModal

  import NathanForUsWeb.Components.GifModal,
    only: [vote_button_class: 1, poster_name: 1, format_duration: 1, format_time_ago: 1]

  on_mount {NathanForUsWeb.UserAuth, :mount_current_user}

  @page_size 24
  @sorts ~w(hot top new)

  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "GIF feed")
      |> assign(:session_id, Map.get(session, "live_socket_id"))
      |> assign(:sort, nil)
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
    sort = normalize_sort(Map.get(params, "sort"))

    socket =
      if connected?(socket) and sort != socket.assigns.sort do
        load_feed(socket, sort)
      else
        assign(socket, :sort, sort)
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
    {:noreply, push_patch(socket, to: feed_path(socket.assigns.sort, gif_id))}
  end

  def handle_event("close_gif_modal", _params, socket) do
    {:noreply, push_patch(socket, to: feed_path(socket.assigns.sort))}
  end

  def handle_event("load_more", _params, socket) do
    %{sort: sort, page: page} = socket.assigns
    gifs = fetch_page(sort, page + 1) |> decorate(socket)

    socket =
      socket
      |> assign(:page, page + 1)
      |> assign(:end_of_feed?, length(gifs) < @page_size)
      |> stream(:gifs, gifs)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div>
      <.page_header title="Explore" subtitle="Every public GIF made here">
        <:actions>
          <button type="button" phx-click="random_gif" class="btn-secondary">Random GIF</button>
          <.link navigate={~p"/"} class="btn-primary">Make a GIF</.link>
        </:actions>
      </.page_header>

      <.register_prompt :if={@show_register_prompt} on_close="dismiss_register_prompt" />

      <div class="px-6 py-4">
        <div class="max-w-7xl mx-auto">
          <nav
            class="inline-flex bg-stone-100 border border-stone-200 rounded-lg p-1 font-mono text-sm"
            aria-label="Sort GIFs"
          >
            <.link
              patch={~p"/gifs"}
              class={tab_class(@sort == "hot")}
              aria-current={@sort == "hot" && "page"}
            >
              Hot
            </.link>
            <.link
              patch={~p"/gifs?sort=top"}
              class={tab_class(@sort == "top")}
              aria-current={@sort == "top" && "page"}
            >
              Top
            </.link>
            <.link
              patch={~p"/gifs?sort=new"}
              class={tab_class(@sort == "new")}
              aria-current={@sort == "new" && "page"}
            >
              New
            </.link>
          </nav>
        </div>
      </div>

      <div class="px-6 pb-10">
        <div class="max-w-7xl mx-auto">
          <%= cond do %>
            <% !@feed_loaded? -> %>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
                <div :for={_i <- 1..8} class="card overflow-hidden">
                  <div class="aspect-video bg-stone-200 animate-pulse"></div>
                  <div class="p-4 space-y-2">
                    <div class="h-3 w-3/4 rounded bg-stone-200 animate-pulse"></div>
                    <div class="h-3 w-1/2 rounded bg-stone-200 animate-pulse"></div>
                  </div>
                </div>
              </div>
            <% @feed_empty? -> %>
              <div class="max-w-xl mx-auto border-2 border-dashed border-stone-300 rounded-xl bg-white py-16 px-6 text-center">
                <span class="hero-film block h-10 w-10 text-stone-300 mx-auto"></span>
                <h2 class="mt-4 font-mono uppercase tracking-wider text-stone-700">
                  {empty_heading(@sort)}
                </h2>
                <p class="mt-1 text-sm text-stone-500">
                  GIFs show up here once their creators post them.
                </p>
                <.link navigate={~p"/"} class="btn-primary mt-6">Make a GIF</.link>
              </div>
            <% true -> %>
              <div
                id="gif-feed"
                phx-update="stream"
                class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6"
              >
                <div
                  :for={{dom_id, gif} <- @streams.gifs}
                  id={dom_id}
                  class="card card-hover overflow-hidden flex flex-col"
                >
                  <div
                    class="relative aspect-video bg-stone-100 border-b border-stone-200 overflow-hidden cursor-pointer"
                    phx-click="view_gif"
                    phx-value-gif_id={gif.id}
                    title="View GIF details"
                  >
                    <%= if gif.gif do %>
                      <img
                        src={~p"/gif/#{gif.gif.id}/poster"}
                        loading="lazy"
                        alt={gif.title || "GIF"}
                        class="w-full h-full object-cover"
                        onmouseenter={"this.src='/gif/#{gif.gif.id}'"}
                        onmouseleave={"this.src='/gif/#{gif.gif.id}/poster'"}
                        onfocus={"this.src='/gif/#{gif.gif.id}'"}
                        onblur={"this.src='/gif/#{gif.gif.id}/poster'"}
                      />
                      <span class="badge badge-neutral absolute top-2 right-2 bg-white/80 backdrop-blur">
                        GIF
                      </span>
                      <span :if={gif.posted_at} class="badge badge-brand absolute top-2 left-2">
                        POSTED
                      </span>
                    <% else %>
                      <div class="w-full h-full flex items-center justify-center font-mono text-xs text-stone-400">
                        This GIF is being rebuilt
                      </div>
                    <% end %>
                  </div>

                  <div class="p-4 flex flex-col flex-1">
                    <h3
                      :if={gif.title && gif.title != "Untitled GIF"}
                      class="font-mono text-sm text-stone-900 mb-1 truncate"
                    >
                      {gif.title}
                    </h3>

                    <div class="text-xs text-stone-500 leading-relaxed line-clamp-2 min-h-[2rem] mb-3">
                      <%= if gif.caption_preview != "" do %>
                        "{gif.caption_preview}"
                      <% else %>
                        From: {gif.video.title}
                      <% end %>
                    </div>

                    <div class="flex flex-wrap items-center gap-x-2 gap-y-1 font-mono text-xs text-stone-500 mb-3 mt-auto">
                      <span>by {poster_name(gif)}</span>
                      <span :if={gif.gif && gif.gif.duration_ms} aria-hidden="true">&middot;</span>
                      <span :if={gif.gif && gif.gif.duration_ms}>
                        {format_duration(gif.gif.duration_ms)}
                      </span>
                      <span aria-hidden="true">&middot;</span>
                      <span>{format_time_ago(gif.inserted_at)}</span>
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

  defp load_feed(socket, sort) do
    gifs = fetch_page(sort, 1) |> decorate(socket)

    socket
    |> assign(:sort, sort)
    |> assign(:page, 1)
    |> assign(:feed_loaded?, true)
    |> assign(:feed_empty?, gifs == [])
    |> assign(:end_of_feed?, length(gifs) < @page_size)
    |> stream(:gifs, gifs, reset: true)
  end

  defp fetch_page(sort, page) do
    offset = (page - 1) * @page_size

    case sort do
      "top" -> Viral.get_top_browseable_gifs(@page_size, offset)
      "new" -> Viral.get_new_browseable_gifs(@page_size, offset)
      _hot -> Viral.get_hot_browseable_gifs(@page_size, offset)
    end
  end

  # Adds :caption_preview and :user_vote to each GIF with two batched
  # queries (instead of one per GIF).
  defp decorate(gifs, socket) do
    frame_ids =
      gifs
      |> Enum.flat_map(fn gif -> (gif.gif && gif.gif.frame_ids) || [] end)
      |> Enum.uniq()

    captions_by_frame = Video.get_frame_captions_for_ids(frame_ids)
    votes = Viral.get_user_votes(Enum.map(gifs, & &1.id), vote_identity(socket))

    Enum.map(gifs, fn gif ->
      gif
      |> Map.put(:caption_preview, caption_preview(gif, captions_by_frame))
      |> Map.put(:user_vote, Map.get(votes, gif.id))
    end)
  end

  defp caption_preview(%{gif: %{frame_ids: frame_ids}}, captions_by_frame)
       when is_list(frame_ids) do
    text =
      frame_ids
      |> Enum.flat_map(&Map.get(captions_by_frame, &1, []))
      |> Enum.uniq()
      |> Enum.join(" ")

    if String.length(text) > 250 do
      String.slice(text, 0, 250) <> "…"
    else
      text
    end
  end

  defp caption_preview(_gif, _captions_by_frame), do: ""

  defp vote_identity(socket) do
    if user = socket.assigns.current_user do
      [user_id: user.id]
    else
      [session_id: socket.assigns.session_id]
    end
  end

  # Refreshes a single GIF in place after a vote (stream + open modal).
  defp refresh_gif(socket, gif_id) do
    case Viral.get_browseable_gif(gif_id) do
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
             %{} = gif <- Viral.get_browseable_gif(gif_id) do
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
             |> push_patch(to: feed_path(socket.assigns.sort))}
        end
    end
  end

  # Paths and presentation helpers

  defp feed_path("hot"), do: ~p"/gifs"
  defp feed_path(sort), do: ~p"/gifs?sort=#{sort}"

  defp feed_path("hot", gif_id), do: ~p"/gifs?gif_id=#{gif_id}"
  defp feed_path(sort, gif_id), do: ~p"/gifs?sort=#{sort}&gif_id=#{gif_id}"

  defp normalize_sort(sort) when sort in @sorts, do: sort
  defp normalize_sort(_sort), do: "hot"

  defp tab_class(true), do: "bg-white text-stone-900 rounded-md shadow-sm px-3 py-1.5"
  defp tab_class(false), do: "px-3 py-1.5 text-stone-500 hover:text-stone-800"

  defp empty_heading("top"), do: "No top GIFs yet"
  defp empty_heading("new"), do: "Nothing new — be the first"
  defp empty_heading(_sort), do: "Nothing hot yet"
end
