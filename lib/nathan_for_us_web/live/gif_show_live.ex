defmodule NathanForUsWeb.GifShowLive do
  @moduledoc """
  Public permalink page for a single posted GIF (`/g/:id`).

  Renders a shareable card for the GIF and sets Open Graph assigns
  (`page_og_image`, `page_og_url`, `page_og_image_type`) during mount so the
  static render unfurls correctly in link previews.
  """
  use NathanForUsWeb, :live_view

  import Ecto.Query

  alias NathanForUs.Repo
  alias NathanForUs.Viral.BrowseableGif

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case load_gif(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That GIF could not be found.")
         |> redirect(to: ~p"/gifs")}

      gif ->
        socket =
          socket
          |> assign(:gif, gif)
          |> assign(:page_title, gif.title || "GIF ##{gif.id}")
          |> assign(:page_og_url, url(~p"/g/#{gif.id}"))

        socket =
          if gif.gif_id do
            socket
            |> assign(:page_og_image, url(~p"/gif/#{gif.gif_id}"))
            |> assign(:page_og_image_type, "image/gif")
          else
            socket
          end

        {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-10">
      <div :if={@gif.gif} class="card overflow-hidden">
        <div class="checkerboard border-b border-stone-200">
          <img src={~p"/gif/#{@gif.gif_id}"} alt={@gif.title || "GIF"} class="w-full" />
        </div>
        <div class="p-6">
          <h1 class="font-mono text-lg font-bold text-stone-900">
            {@gif.title || "Untitled GIF"}
          </h1>
          <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-xs text-stone-500">
            <span>by {poster_name(@gif)}</span>
            <span aria-hidden="true">·</span>
            <span>{relative_time(@gif.posted_at || @gif.inserted_at)}</span>
            <%= if @gif.video do %>
              <span aria-hidden="true">·</span>
              <.link navigate={~p"/video/#{@gif.video_id}"} class="text-brand-deep hover:text-brand">
                From: {@gif.video.title}
              </.link>
            <% end %>
          </div>
          <div class="mt-6 flex flex-wrap gap-2">
            <a class="btn-secondary" href={~p"/gif/#{@gif.gif_id}" <> "?download=1"}>
              <span class="hero-arrow-down-tray-mini size-4"></span> Download
            </a>
            <button type="button" class="btn-secondary" data-copy={url(~p"/gif/#{@gif.gif_id}")}>
              Copy GIF link
            </button>
            <.link navigate={~p"/video/#{@gif.video_id}"} class="btn-primary">
              Open in editor
            </.link>
          </div>
        </div>
      </div>

      <div :if={is_nil(@gif.gif)} class="card py-16 px-6 text-center">
        <span class="hero-photo size-10 text-stone-300 mx-auto block"></span>
        <h1 class="mt-4 font-mono uppercase tracking-wider text-stone-700">
          This GIF is being rebuilt
        </h1>
        <p class="mt-2 text-sm text-stone-500">
          Check back in a moment, or explore other GIFs.
        </p>
        <.link navigate={~p"/gifs"} class="btn-primary mt-6">Explore GIFs</.link>
      </div>
    </div>
    """
  end

  defp load_gif(id) when is_binary(id) do
    case Integer.parse(id) do
      {gif_id, ""} ->
        from(g in BrowseableGif,
          where: g.id == ^gif_id and g.is_public == true,
          preload: [:video, :created_by_user, :gif]
        )
        |> Repo.one()

      _ ->
        nil
    end
  end

  defp poster_name(%BrowseableGif{created_by_user: %{username: username}})
       when is_binary(username) and username != "" do
    username
  end

  defp poster_name(%BrowseableGif{created_by_user: %{email: email}}) when is_binary(email) do
    email |> String.split("@") |> hd()
  end

  defp poster_name(_gif), do: "anonymous"

  defp relative_time(nil), do: ""

  defp relative_time(%NaiveDateTime{} = naive) do
    naive |> DateTime.from_naive!("Etc/UTC") |> relative_time()
  end

  defp relative_time(%DateTime{} = datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
