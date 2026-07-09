defmodule NathanForUsWeb.TimelineLive do
  @moduledoc """
  Public timeline of GIFs that users explicitly posted.

  Unlike the main GIF feed (which lists every generated GIF), the timeline
  only shows GIFs that were deliberately shared via
  `NathanForUs.Viral.post_gif_to_timeline/3`, ordered by when they were posted.
  """

  use NathanForUsWeb, :live_view

  alias NathanForUs.Viral

  on_mount {NathanForUsWeb.UserAuth, :mount_current_user}

  @timeline_limit 50

  def mount(params, session, socket) do
    gifs = Viral.get_timeline_gifs(@timeline_limit)

    # Get session ID for anonymous voting
    session_id = Map.get(session, "live_socket_id")

    # Check if we should open a GIF modal based on query params
    {show_gif_modal, modal_gif, modal_captions} = find_modal_gif(gifs, params)

    socket =
      socket
      |> assign(:page_title, "Timeline")
      |> assign(:gifs, gifs)
      |> assign(:session_id, session_id)
      |> assign(:show_register_flash, false)
      |> assign(:show_gif_modal, show_gif_modal)
      |> assign(:modal_gif, modal_gif)
      |> assign(:modal_captions, modal_captions)
      |> load_user_votes()

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    {show_gif_modal, modal_gif, modal_captions} =
      find_modal_gif(socket.assigns.gifs, params)

    socket =
      socket
      |> assign(:show_gif_modal, show_gif_modal)
      |> assign(:modal_gif, modal_gif)
      |> assign(:modal_captions, modal_captions)

    {:noreply, socket}
  end

  def handle_event("upvote_gif", %{"gif_id" => gif_id}, socket) do
    if socket.assigns.current_user do
      gif_id = String.to_integer(gif_id)
      user_id = socket.assigns.current_user.id

      case Viral.vote_on_gif(gif_id, "up", user_id: user_id) do
        {:ok, _vote} ->
          socket =
            socket
            |> put_flash(:info, "GIF upvoted!")
            |> refresh_gifs()
            |> load_user_votes()

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to vote on GIF")
          {:noreply, socket}
      end
    else
      socket = assign(socket, :show_register_flash, true)
      {:noreply, socket}
    end
  end

  def handle_event("close_register_flash", _params, socket) do
    socket = assign(socket, :show_register_flash, false)
    {:noreply, socket}
  end

  def handle_event("view_gif", %{"gif_id" => gif_id}, socket) do
    gif_id_int = String.to_integer(gif_id)
    modal_gif = Enum.find(socket.assigns.gifs, fn gif -> gif.id == gif_id_int end)

    if modal_gif && modal_gif.gif && modal_gif.gif.frame_ids do
      captions = NathanForUs.Video.get_gif_captions(modal_gif.gif.frame_ids)

      socket =
        socket
        |> assign(:show_gif_modal, true)
        |> assign(:modal_gif, modal_gif)
        |> assign(:modal_captions, captions)
        |> push_patch(to: ~p"/timeline?gif_id=#{gif_id}")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_gif_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_gif_modal, false)
      |> assign(:modal_gif, nil)
      |> assign(:modal_captions, [])
      |> push_patch(to: ~p"/timeline")

    {:noreply, socket}
  end

  def handle_event("share_gif", %{"gif_id" => gif_id}, socket) do
    # Deep-link to this GIF on the timeline; the client copies it to the clipboard.
    url = url(socket, ~p"/timeline?gif_id=#{gif_id}")

    socket =
      socket
      |> push_event("copy_to_clipboard", %{text: url})
      |> put_flash(:info, "Link copied — share away!")

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-white">
      <!-- Header -->
      <div class="bg-gray-800 border-b border-gray-700 px-6 py-4">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold font-mono">PUBLIC TIMELINE</h1>
            <p class="text-gray-400 text-sm font-mono">
              GIFs people chose to post — newest first
            </p>
          </div>

          <div class="flex items-center gap-4">
            <.link
              navigate={~p"/gifs"}
              class="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg font-mono font-medium transition-colors"
            >
              BROWSE ALL GIFS
            </.link>
            <.link
              navigate={~p"/"}
              class="bg-green-600 hover:bg-green-700 text-white px-4 py-2 rounded-lg font-mono font-medium transition-colors"
            >
              MAKE A GIF
            </.link>
          </div>
        </div>
      </div>

    <!-- Custom Register Flash -->
      <%= if @show_register_flash do %>
        <div class="fixed top-2 right-2 mr-2 w-80 sm:w-96 z-50 rounded-lg p-3 ring-1 bg-rose-50 text-rose-900 shadow-md ring-rose-500 fill-rose-900">
          <p class="flex items-center gap-1.5 text-sm font-semibold leading-6">
            <svg class="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
              <path
                fill-rule="evenodd"
                d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12zM12 8.25a.75.75 0 01.75.75v3.75a.75.75 0 01-1.5 0V9a.75.75 0 01.75-.75zm0 8.25a.75.75 0 100-1.5.75.75 0 000 1.5z"
                clip-rule="evenodd"
              />
            </svg>
            Account Required
          </p>
          <p class="mt-2 text-sm leading-5">
            Create an account and log in to upvote GIFs.
            <.link navigate={~p"/users/register"} class="font-semibold underline hover:no-underline">
              Click here to register!
            </.link>
          </p>
          <button
            type="button"
            class="group absolute top-1 right-1 p-2"
            phx-click="close_register_flash"
            aria-label="close"
          >
            <svg
              class="h-5 w-5 opacity-40 group-hover:opacity-70"
              fill="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                d="M6 18L18 6M6 6l12 12"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
          </button>
        </div>
      <% end %>

    <!-- Timeline Feed -->
      <div class="px-4 py-6">
        <%= if Enum.empty?(@gifs) do %>
          <div class="text-center py-12">
            <div class="text-gray-400 font-mono mb-4">Nothing on the timeline yet</div>
            <.link
              navigate={~p"/"}
              class="text-blue-400 hover:text-blue-300 font-mono"
            >
              Make a GIF and post it →
            </.link>
          </div>
        <% else %>
          <div class="max-w-2xl mx-auto space-y-6">
            <%= for gif <- @gifs do %>
              <div class="bg-gray-800 rounded-lg overflow-hidden border border-gray-700 hover:border-gray-600 transition-colors">
                <!-- Post Header -->
                <div class="px-4 pt-4 flex items-center justify-between">
                  <div class="flex items-center gap-2 text-sm font-mono">
                    <span class="text-white font-medium">{poster_name(gif)}</span>
                    <span class="text-gray-500">·</span>
                    <span class="text-gray-500">{format_time_ago(gif.posted_at)}</span>
                  </div>
                </div>

    <!-- GIF Display -->
                <div
                  class="mt-3 bg-gray-700 flex items-center justify-center relative cursor-pointer hover:bg-gray-600 transition-colors"
                  phx-click="view_gif"
                  phx-value-gif_id={gif.id}
                  title="Click to view GIF details"
                >
                  <%= if gif.gif && gif.gif.gif_data do %>
                    <img
                      src={"data:image/gif;base64,#{NathanForUs.Gif.to_base64(gif.gif)}"}
                      alt={gif.title || "GIF"}
                      class="w-full object-contain max-h-[70vh]"
                    />
                  <% else %>
                    <div class="text-gray-400 font-mono text-sm text-center p-12">
                      <div>GIF</div>
                      <div class="text-xs mt-1">
                        Frames {gif.start_frame_index}-{gif.end_frame_index}
                      </div>
                    </div>
                  <% end %>
                </div>

    <!-- GIF Info & Actions -->
                <div class="p-4">
                  <h3 class="text-white font-mono text-sm mb-2 truncate">
                    {gif.title || "Untitled GIF"}
                  </h3>

                  <div class="text-gray-400 text-xs font-mono mb-3">
                    From: {gif.video.title}
                  </div>

    <!-- Vote and Action Row -->
                  <div class="flex items-center justify-between">
                    <!-- Upvote Button -->
                    <button
                      phx-click="upvote_gif"
                      phx-value-gif_id={gif.id}
                      class={[
                        "flex items-center gap-1 px-2 py-1 rounded text-xs font-mono transition-colors",
                        if(Map.get(@user_votes, gif.id) == "up",
                          do: "bg-orange-600 text-white",
                          else: "bg-gray-700 text-gray-300 hover:bg-orange-600 hover:text-white"
                        )
                      ]}
                      title="Upvote this GIF"
                    >
                      ⬆ {gif.upvotes_count}
                    </button>

    <!-- Share Button -->
                    <button
                      phx-click="share_gif"
                      phx-value-gif_id={gif.id}
                      class="bg-gray-700 hover:bg-gray-600 text-white px-3 py-1 rounded text-xs font-mono transition-colors flex items-center gap-1"
                      title="Copy a share link to this GIF"
                    >
                      <span>🔗</span> Share
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- GIF Modal -->
      <%= if @show_gif_modal and @modal_gif do %>
        <NathanForUsWeb.Components.GifModal.render
          gif_data={@modal_gif}
          captions={@modal_captions}
          show_share_button={@current_user != nil}
        />
      <% end %>
    </div>
    """
  end

  # Helper functions

  defp find_modal_gif(gifs, params) do
    case Map.get(params, "gif_id") do
      nil ->
        {false, nil, []}

      gif_id_str ->
        case Integer.parse(gif_id_str) do
          {gif_id_int, ""} ->
            case Enum.find(gifs, fn gif -> gif.id == gif_id_int end) do
              nil ->
                {false, nil, []}

              found_gif ->
                if found_gif.gif && found_gif.gif.frame_ids do
                  captions = NathanForUs.Video.get_gif_captions(found_gif.gif.frame_ids)
                  {true, found_gif, captions}
                else
                  {false, nil, []}
                end
            end

          _ ->
            {false, nil, []}
        end
    end
  end

  defp poster_name(gif) do
    case gif.created_by_user do
      nil ->
        "anonymous"

      user ->
        user.username ||
          (user.email && user.email |> String.split("@") |> List.first()) ||
          "anonymous"
    end
  end

  defp load_user_votes(socket) do
    user_id = socket.assigns.current_user && socket.assigns.current_user.id
    session_id = socket.assigns.session_id
    gif_ids = Enum.map(socket.assigns.gifs, & &1.id)

    user_votes =
      if user_id do
        Enum.reduce(gif_ids, %{}, fn gif_id, acc ->
          case Viral.get_user_vote(gif_id, user_id: user_id) do
            nil -> acc
            vote_type -> Map.put(acc, gif_id, vote_type)
          end
        end)
      else
        Enum.reduce(gif_ids, %{}, fn gif_id, acc ->
          case Viral.get_user_vote(gif_id, session_id: session_id) do
            nil -> acc
            vote_type -> Map.put(acc, gif_id, vote_type)
          end
        end)
      end

    assign(socket, :user_votes, user_votes)
  end

  defp refresh_gifs(socket) do
    assign(socket, :gifs, Viral.get_timeline_gifs(@timeline_limit))
  end

  defp format_time_ago(nil), do: ""

  defp format_time_ago(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86400)}d ago"
      true -> "#{div(diff, 2_592_000)}mo ago"
    end
  end
end
