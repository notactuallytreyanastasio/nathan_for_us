defmodule NathanForUsWeb.Components.GifModal do
  @moduledoc """
  Shared GIF modal function component for the feed and timeline, plus small
  formatting helpers both surfaces use on their cards.

  The hosting LiveView owns the `close_gif_modal` and `upvote_gif` events.
  """

  use NathanForUsWeb, :html

  attr :gif_data, :map, required: true, doc: "a BrowseableGif with :video and :gif preloaded"
  attr :captions, :list, default: []
  attr :user_vote, :string, default: nil, doc: ~s(the viewer's vote on this GIF, e.g. "up")

  def render(assigns) do
    ~H"""
    <div
      class="fixed inset-0 bg-stone-900/40 flex items-center justify-center z-50 p-4"
      phx-window-keydown="close_gif_modal"
      phx-key="escape"
    >
      <div
        class="card max-w-3xl w-full max-h-[90vh] overflow-y-auto"
        role="dialog"
        aria-modal="true"
        aria-label={@gif_data.title || "GIF details"}
        phx-click-away="close_gif_modal"
      >
        <div class="p-6">
          <div class="flex items-start justify-between gap-4 mb-4">
            <h2 class="font-mono text-lg font-bold text-stone-900 truncate">
              {@gif_data.title || "GIF"}
            </h2>
            <button
              type="button"
              phx-click="close_gif_modal"
              class="-m-1 p-1 text-stone-400 hover:text-stone-700 transition-colors"
              aria-label="Close"
            >
              <span class="hero-x-mark-mini h-5 w-5"></span>
            </button>
          </div>

          <div class="checkerboard border border-stone-200 rounded-xl overflow-hidden mb-6 p-4 flex items-center justify-center">
            <%= if @gif_data.gif do %>
              <img
                src={~p"/gif/#{@gif_data.gif.id}"}
                alt={@gif_data.title || "GIF"}
                class="max-w-full max-h-[55vh] object-contain rounded-lg"
              />
            <% else %>
              <div class="w-full py-16 text-center font-mono text-sm text-stone-500">
                This GIF is being rebuilt
              </div>
            <% end %>
          </div>

          <div class="flex flex-wrap gap-x-6 gap-y-1 font-mono text-xs text-stone-500 mb-6">
            <span class="min-w-0 truncate">
              <span class="text-stone-400">Source</span> {@gif_data.video.title}
            </span>
            <span :if={@gif_data.category}>
              <span class="text-stone-400">Category</span>
              <span class="capitalize">{String.replace(@gif_data.category, "_", " ")}</span>
            </span>
            <span :if={@gif_data.gif && @gif_data.gif.frame_count}>
              <span class="text-stone-400">Frames</span> {@gif_data.gif.frame_count}
            </span>
            <span :if={@gif_data.gif && @gif_data.gif.duration_ms}>
              <span class="text-stone-400">Duration</span> {format_duration(@gif_data.gif.duration_ms)}
            </span>
          </div>

          <div>
            <h3 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-2">
              Captions
            </h3>
            <%= if @captions == [] do %>
              <p class="text-sm text-stone-500">No captions found for this moment.</p>
            <% else %>
              <div class="space-y-2 max-h-48 overflow-y-auto">
                <div :for={caption <- @captions} class="bg-stone-100 rounded-lg p-3">
                  <p class="text-sm text-stone-700 leading-relaxed">"{caption}"</p>
                </div>
              </div>
            <% end %>
          </div>

          <div class="flex flex-wrap items-center gap-2 mt-6 pt-4 border-t border-stone-200">
            <button
              type="button"
              phx-click="upvote_gif"
              phx-value-gif_id={@gif_data.id}
              class={vote_button_class(@user_vote)}
              title="Upvote this GIF"
            >
              <span class="hero-arrow-up-mini h-4 w-4"></span>
              {@gif_data.upvotes_count}
            </button>

            <button type="button" class="btn-secondary" data-copy={url(~p"/g/#{@gif_data.id}")}>
              Share
            </button>

            <%= if @gif_data.gif do %>
              <.link href={~p"/gif/#{@gif_data.gif.id}?download=1"} class="btn-secondary">
                Download
              </.link>
              <button
                type="button"
                class="btn-secondary"
                data-copy={url(~p"/gif/#{@gif_data.gif.id}")}
              >
                Copy GIF link
              </button>
              <button type="button" class="btn-secondary" data-copy={embed_snippet(@gif_data)}>
                Copy embed
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp embed_snippet(gif_data) do
    alt =
      (gif_data.title || "GIF")
      |> String.replace("\"", "'")

    ~s(<img src="#{url(~p"/gif/#{gif_data.gif.id}")}" alt="#{alt}">)
  end

  @doc """
  Vote button classes per the design brief: brand fill when the viewer has
  voted, quiet white otherwise. The state change itself is the feedback.
  """
  def vote_button_class("up") do
    "inline-flex items-center gap-1 rounded-lg px-3 py-1.5 font-mono text-sm " <>
      "bg-brand border border-brand text-white transition-colors"
  end

  def vote_button_class(_) do
    "inline-flex items-center gap-1 rounded-lg px-3 py-1.5 font-mono text-sm " <>
      "bg-white border border-stone-300 text-stone-600 hover:border-brand hover:text-brand-deep transition-colors"
  end

  @doc """
  Display name for the GIF's creator ("anonymous" when unattributed).
  """
  def poster_name(%{created_by_user: %{} = user}) do
    user.username ||
      (user.email && user.email |> String.split("@") |> List.first()) ||
      "anonymous"
  end

  def poster_name(_gif), do: "anonymous"

  @doc """
  GIF duration in seconds, e.g. "2.5s".
  """
  def format_duration(duration_ms) when is_integer(duration_ms) do
    seconds = duration_ms / 1000

    if seconds == trunc(seconds) do
      "#{trunc(seconds)}s"
    else
      "#{Float.round(seconds, 1)}s"
    end
  end

  def format_duration(_), do: nil

  @doc """
  Compact relative timestamp, e.g. "3h ago".
  """
  def format_time_ago(nil), do: ""

  def format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "#{max(diff, 0)}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86_400)}d ago"
      true -> "#{div(diff, 2_592_000)}mo ago"
    end
  end
end
