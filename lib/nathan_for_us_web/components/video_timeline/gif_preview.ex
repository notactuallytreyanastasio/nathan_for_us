defmodule NathanForUsWeb.Components.VideoTimeline.GifPreview do
  @moduledoc """
  Stage (live looping preview) and generation panel for the GIF editor.

  The stage cycles through `GET /frame/:id` URLs client-side via the
  `RangePreview` JS hook — no frame binaries ever cross the websocket.
  The generation panel renders the encoding spinner, the failure alert,
  and the result card (GIF served via `GET /gif/:id`).
  """

  use NathanForUsWeb, :html

  @doc """
  Live preview stage: checkerboard media well, current-frame caption,
  play/pause, fps segmented control, and selection readout.
  """
  attr :preview_frames, :list, required: true, doc: "maps with :id, :url, :caption"
  attr :fps, :integer, required: true
  attr :has_range, :boolean, required: true
  attr :readout, :string, default: nil

  def stage(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-4xl px-4 pt-6">
      <div
        id="stage-preview"
        phx-hook="RangePreview"
        data-frames={Jason.encode!(@preview_frames)}
        data-fps={@fps}
      >
        <div class="checkerboard flex min-h-[16rem] items-center justify-center overflow-hidden rounded-xl border border-stone-200">
          <%= if @preview_frames == [] do %>
            <p class="font-mono text-sm text-stone-500">No frames to preview yet</p>
          <% else %>
            <img
              data-preview-img
              src={hd(@preview_frames).url}
              alt="Frame preview"
              class="max-h-[60vh] w-auto max-w-full"
            />
          <% end %>
        </div>

        <p data-preview-caption class="mt-3 min-h-[3rem] text-center text-stone-700">
          {first_caption(@preview_frames)}
        </p>

        <div class="flex flex-wrap items-center justify-center gap-x-4 gap-y-2">
          <button
            type="button"
            data-play-toggle
            disabled={not @has_range}
            class="btn-ghost"
            title="Play/pause (Space)"
            aria-label="Play or pause the preview"
          >
            <span data-icon-pause class="hero-pause-mini size-5"></span>
            <span data-icon-play class="hero-play-mini hidden size-5"></span>
          </button>

          <div
            class="inline-flex rounded-lg border border-stone-200 bg-stone-100 p-1 font-mono text-sm"
            role="group"
            aria-label="Playback speed"
          >
            <button
              :for={fps <- [5, 10, 15]}
              type="button"
              phx-click="set_fps"
              phx-value-fps={fps}
              aria-pressed={to_string(@fps == fps)}
              class={
                if @fps == fps,
                  do: "rounded-md bg-white px-3 py-1.5 text-stone-900 shadow-sm",
                  else: "px-3 py-1.5 text-stone-500 hover:text-stone-800"
              }
            >
              {fps} fps
            </button>
          </div>

          <p :if={@readout} class="font-mono text-sm text-stone-500">{@readout}</p>
        </div>

        <p :if={not @has_range} class="mt-2 text-center font-mono text-xs text-stone-500">
          Drag across the filmstrip or press I / O to set a range
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Generation status panel: encoding spinner, failure alert with retry,
  or the result card with download / copy link / post-to-timeline actions.
  """
  attr :status, :atom, required: true, doc: ":generating, :failed or :completed"
  attr :generating_frame_count, :integer, default: 0
  attr :error_message, :string, default: nil
  attr :gif_id, :integer, default: nil
  attr :fallback_base64, :string, default: nil, doc: "only set when the DB save failed"
  attr :browseable_gif_id, :integer, default: nil
  attr :posted, :boolean, default: false
  attr :show_post_form, :boolean, default: false
  attr :post_title, :string, default: ""
  attr :post_error, :string, default: nil
  attr :current_user, :map, default: nil

  def generation_panel(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-4xl px-4 pt-4">
      <%= case @status do %>
        <% :generating -> %>
          <div class="card flex items-center gap-3 p-4">
            <div class="h-4 w-4 animate-spin rounded-full border-2 border-stone-300 border-t-brand">
            </div>
            <p class="font-mono text-sm text-stone-700">
              Encoding {@generating_frame_count} frames…
            </p>
          </div>
        <% :failed -> %>
          <div class="rounded-xl border border-red-200 bg-red-50 p-4">
            <div class="flex items-start gap-2">
              <span class="hero-exclamation-circle-mini mt-0.5 size-5 shrink-0 text-red-500"></span>
              <div>
                <p class="font-mono text-sm font-medium text-red-700">GIF generation failed</p>
                <p :if={@error_message} class="mt-1 text-xs text-red-600">{@error_message}</p>
              </div>
            </div>
            <button type="button" phx-click="generate_gif" class="btn-secondary mt-3">
              Try again
            </button>
          </div>
        <% :completed -> %>
          <div class="card p-4">
            <div class="mb-2 font-mono text-xs uppercase tracking-wider text-stone-500">
              Your GIF
            </div>

            <div class="checkerboard flex justify-center overflow-hidden rounded-xl border border-stone-200 p-2">
              <%= if @gif_id do %>
                <img src={~p"/gif/#{@gif_id}"} alt="Generated GIF" class="max-h-96 max-w-full" />
              <% else %>
                <img
                  src={"data:image/gif;base64,#{@fallback_base64}"}
                  alt="Generated GIF"
                  class="max-h-96 max-w-full"
                />
              <% end %>
            </div>

            <div class="mt-4 flex flex-wrap items-center gap-2">
              <%= if @gif_id do %>
                <a href={~p"/gif/#{@gif_id}?download=1"} class="btn-secondary">
                  <span class="hero-arrow-down-tray-mini size-4"></span> Download
                </a>
                <button type="button" class="btn-secondary" data-copy={url(~p"/gif/#{@gif_id}")}>
                  Copy GIF link
                </button>
              <% else %>
                <a
                  href={"data:image/gif;base64,#{@fallback_base64}"}
                  download="framecut.gif"
                  class="btn-secondary"
                >
                  <span class="hero-arrow-down-tray-mini size-4"></span> Download
                </a>
                <p class="font-mono text-xs text-amber-700">
                  Saving failed — this GIF can't be linked or posted
                </p>
              <% end %>

              <%= cond do %>
                <% @posted && @browseable_gif_id -> %>
                  <.link navigate={~p"/timeline?gif_id=#{@browseable_gif_id}"} class="btn-secondary">
                    <span class="hero-check-circle-mini size-4 text-emerald-500"></span>
                    Posted — view timeline
                  </.link>
                <% is_nil(@current_user) -> %>
                  <.link :if={@gif_id} navigate={~p"/users/register"} class="btn-secondary">
                    Sign up to post
                  </.link>
                <% @show_post_form -> %>
                  <form phx-submit="post_to_timeline" class="flex flex-wrap items-center gap-2">
                    <input
                      type="text"
                      name="post[title]"
                      value={@post_title}
                      maxlength="120"
                      placeholder="Title (optional)"
                      class="input w-64"
                      autocomplete="off"
                    />
                    <button type="submit" class="btn-secondary">Post</button>
                    <button type="button" phx-click="cancel_post_form" class="btn-ghost">
                      Cancel
                    </button>
                  </form>
                <% true -> %>
                  <button
                    :if={@browseable_gif_id}
                    type="button"
                    phx-click="open_post_form"
                    class="btn-secondary"
                  >
                    Post to timeline
                  </button>
              <% end %>
            </div>

            <p :if={@post_error} class="mt-2 font-mono text-xs text-red-600">{@post_error}</p>
          </div>
        <% _ -> %>
      <% end %>
    </div>
    """
  end

  defp first_caption([]), do: ""
  defp first_caption([frame | _]), do: frame.caption || ""
end
