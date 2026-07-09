defmodule NathanForUsWeb.Components.VideoTimeline.FrameDisplay do
  @moduledoc """
  Filmstrip and minimap for the GIF editor.

  Renders every frame of the video as a lazy-loaded thumbnail strip (images
  served via `GET /frame/:id`), the brand-colored selection overlay with
  draggable IN/OUT handles, and a proportional minimap. All pointer
  interaction is handled by the `Filmstrip` JS hook, which pushes
  `set_playhead` and `select_range` events.
  """

  use NathanForUsWeb, :html

  attr :frame_index, :list, required: true
  attr :frame_count, :integer, required: true
  attr :playhead, :integer, required: true
  attr :sel_start, :integer, default: nil
  attr :sel_end, :integer, default: nil
  attr :caption_match_idxs, :list, default: []

  def filmstrip(assigns) do
    ~H"""
    <div
      id="editor-filmstrip"
      phx-hook="Filmstrip"
      data-sel-start={@sel_start}
      data-sel-end={@sel_end}
    >
      <div class="mx-auto max-w-7xl px-4 pt-4">
        <div class="mb-1 flex items-center justify-between">
          <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Filmstrip</span>
          <span :if={@frame_index != []} class="font-mono text-xs text-stone-400">
            Frame {frame_number_at(@frame_index, @playhead)} / {@frame_count}
          </span>
        </div>

        <div
          data-minimap
          class="relative h-2 w-full cursor-pointer touch-none overflow-hidden rounded border border-stone-200 bg-stone-100"
          aria-hidden="true"
        >
          <div
            :if={@sel_start && @sel_end}
            class="absolute inset-y-0 rounded bg-brand"
            style={"left: #{pct(@sel_start, length(@frame_index))}%; width: #{max(pct(@sel_end - @sel_start + 1, length(@frame_index)), 0.5)}%"}
          >
          </div>
          <div
            :for={idx <- @caption_match_idxs}
            class="absolute inset-y-0 w-0.5 bg-amber-400"
            style={"left: #{pct(idx, length(@frame_index))}%"}
          >
          </div>
          <div
            :if={@frame_index != []}
            class="absolute inset-y-0 w-0.5 bg-stone-500"
            style={"left: #{pct(@playhead, length(@frame_index))}%"}
          >
          </div>
        </div>
      </div>

      <div
        data-strip
        class="mt-2 w-full overflow-x-auto border-y border-stone-200 bg-white"
        style="touch-action: pan-x;"
      >
        <%= if @frame_index == [] do %>
          <div class="flex h-20 items-center gap-px px-4">
            <div :for={_i <- 1..10} class="h-16 w-28 shrink-0 animate-pulse rounded-sm bg-stone-200">
            </div>
          </div>
        <% else %>
          <div data-track class="flex h-20 w-max items-center">
            <div
              :for={{frame, idx} <- Enum.with_index(@frame_index)}
              id={"strip-slot-#{frame.id}"}
              data-slot-idx={idx}
              data-frame-number={frame.frame_number}
              class="relative h-16 w-28 shrink-0 cursor-pointer select-none border-r border-stone-200 bg-stone-100"
              style="content-visibility: auto; contain-intrinsic-size: 112px 64px;"
            >
              <img
                loading="lazy"
                src={~p"/frame/#{frame.id}"}
                alt={"Frame #{frame.frame_number}"}
                class="pointer-events-none h-full w-full select-none object-cover"
                draggable="false"
              />
              <div
                :if={selected?(idx, @sel_start, @sel_end)}
                class="pointer-events-none absolute inset-0 border-y-2 border-brand bg-brand/15"
              >
              </div>
              <div
                :if={idx == @playhead}
                class="pointer-events-none absolute inset-y-0 left-0 w-0.5 bg-brand-deep"
              >
              </div>
              <div
                :if={idx == @sel_start && @sel_end}
                data-handle="in"
                class="absolute inset-y-0 left-0 z-10 flex w-11 cursor-ew-resize touch-none justify-start"
                aria-label="Drag to adjust the start of the range"
              >
                <div class="h-full w-3 rounded-r bg-brand"></div>
              </div>
              <div
                :if={idx == @sel_end && @sel_start}
                data-handle="out"
                class="absolute inset-y-0 right-0 z-10 flex w-11 cursor-ew-resize touch-none justify-end"
                aria-label="Drag to adjust the end of the range"
              >
                <div class="h-full w-3 rounded-l bg-brand"></div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp selected?(_idx, nil, _sel_end), do: false
  defp selected?(_idx, _sel_start, nil), do: false
  defp selected?(idx, sel_start, sel_end), do: idx >= sel_start and idx <= sel_end

  defp frame_number_at(frame_index, playhead) do
    case Enum.at(frame_index, playhead) do
      nil -> "-"
      frame -> frame.frame_number
    end
  end

  defp pct(_value, 0), do: 0.0
  defp pct(value, count), do: Float.round(value / count * 100, 3)
end
