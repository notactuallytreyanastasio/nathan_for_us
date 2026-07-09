defmodule NathanForUsWeb.Components.VideoTimeline.CaptionSearch do
  @moduledoc """
  Caption search for the GIF editor.

  Search runs asynchronously (the LiveView assigns a loading state, then
  executes the query in `handle_info`) and results render as a dropdown of
  `mm:ss — "caption"` rows. Clicking a result moves the playhead and scrolls
  the filmstrip; matches also show as amber ticks on the minimap.
  """

  use NathanForUsWeb, :html

  attr :search_term, :string, default: ""
  attr :loading, :boolean, default: false
  attr :results, :list, default: [], doc: "maps with :frame_number, :timestamp_ms, :text"
  attr :result_count, :integer, default: 0
  attr :results_open, :boolean, default: false
  attr :searched, :boolean, default: false
  attr :has_captions, :boolean, default: true

  def caption_search(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl px-4 pt-4">
      <%= if @has_captions do %>
        <form phx-change="caption_search_change" phx-submit="caption_search" class="relative max-w-xl">
          <label for="caption-search-input" class="sr-only">Search captions</label>
          <span class="hero-magnifying-glass-mini pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-stone-400">
          </span>
          <input
            type="text"
            id="caption-search-input"
            name="caption_search[term]"
            value={@search_term}
            placeholder="Search captions in this video…"
            class="input pl-9 pr-9"
            phx-debounce="300"
            autocomplete="off"
          />
          <div
            :if={@loading}
            class="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin rounded-full border-2 border-stone-300 border-t-brand"
          >
          </div>
          <button
            :if={@searched and not @loading}
            type="button"
            phx-click="clear_caption_search"
            class="absolute right-2 top-1/2 -translate-y-1/2 p-1 text-stone-400 hover:text-stone-700"
            aria-label="Clear caption search"
          >
            <span class="hero-x-mark-mini size-4"></span>
          </button>

          <div
            :if={@results_open and @searched and not @loading}
            class="absolute left-0 right-0 top-full z-40 mt-1 max-h-72 overflow-y-auto rounded-lg border border-stone-200 bg-white shadow-lg"
            phx-click-away="close_caption_results"
          >
            <%= if @results == [] do %>
              <p class="px-3 py-4 text-center font-mono text-sm text-stone-500">
                No captions match — try fewer words
              </p>
            <% else %>
              <div class="border-b border-stone-200 bg-stone-50 px-3 py-1 font-mono text-xs uppercase tracking-wider text-stone-500">
                {@result_count} {if @result_count == 1, do: "match", else: "matches"}
              </div>
              <button
                :for={result <- @results}
                type="button"
                phx-click="jump_to_frame"
                phx-value-frame_number={result.frame_number}
                class="flex w-full items-baseline gap-3 border-b border-stone-100 px-3 py-2 text-left last:border-b-0 hover:bg-stone-100"
              >
                <span class="shrink-0 font-mono text-xs text-stone-400">
                  {format_timestamp(result.timestamp_ms)}
                </span>
                <span class="truncate text-sm text-stone-700">"{result.text}"</span>
              </button>
            <% end %>
          </div>
        </form>
      <% else %>
        <p class="font-mono text-xs uppercase tracking-wider text-stone-500">
          Caption search
          <span class="normal-case tracking-normal text-stone-400">— no captions for this video</span>
        </p>
      <% end %>
    </div>
    """
  end

  defp format_timestamp(nil), do: "0:00"

  defp format_timestamp(ms) when is_integer(ms) do
    total_seconds = div(ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    "#{minutes}:#{String.pad_leading(to_string(seconds), 2, "0")}"
  end
end
