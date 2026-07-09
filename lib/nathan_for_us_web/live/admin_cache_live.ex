defmodule NathanForUsWeb.AdminCacheLive do
  use NathanForUsWeb, :live_view

  import NathanForUsWeb.Components.AdminNav

  alias NathanForUs.{AdminService, FrameCache}

  on_mount {NathanForUsWeb.UserAuth, :ensure_authenticated}

  def mount(_params, _session, socket) do
    case AdminService.validate_admin_access(socket.assigns.current_user) do
      :ok ->
        {:ok,
         assign(socket,
           frame_stats: FrameCache.stats(),
           cache_entries: FrameCache.entries(20),
           page_title: "Cache Admin",
           page_description: "Cache management and inspection",
           entries_limit: 20
         )}

      {:error, :access_denied} ->
        {:ok,
         socket
         |> put_flash(:error, "Access denied. Admin privileges required.")
         |> redirect(to: ~p"/")}
    end
  end

  def handle_event("refresh_stats", _params, socket) do
    socket =
      socket
      |> assign(:frame_stats, FrameCache.stats())
      |> assign(:cache_entries, FrameCache.entries(socket.assigns.entries_limit))
      |> put_flash(:info, "Cache statistics refreshed")

    {:noreply, socket}
  end

  def handle_event("clear_frame_cache", _params, socket) do
    case FrameCache.clear() do
      :ok ->
        socket =
          socket
          |> assign(:frame_stats, FrameCache.stats())
          |> assign(:cache_entries, FrameCache.entries(socket.assigns.entries_limit))
          |> put_flash(:info, "Frame cache cleared successfully")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to clear cache: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("warm_cache", _params, socket) do
    FrameCache.warm_cache()

    socket = put_flash(socket, :info, "Cache warming started in background")
    {:noreply, socket}
  end

  def handle_event("load_more_entries", _params, socket) do
    new_limit = socket.assigns.entries_limit + 20

    socket =
      socket
      |> assign(:entries_limit, new_limit)
      |> assign(:cache_entries, FrameCache.entries(new_limit))

    {:noreply, socket}
  end

  def handle_event("evict_frame", %{"frame_id" => frame_id_str}, socket) do
    frame_id = String.to_integer(frame_id_str)
    FrameCache.evict(frame_id)

    socket =
      socket
      |> assign(:frame_stats, FrameCache.stats())
      |> assign(:cache_entries, FrameCache.entries(socket.assigns.entries_limit))
      |> put_flash(:info, "Frame #{frame_id} evicted from cache")

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <.page_header title="Cache Admin" subtitle="Monitor and manage the frame cache">
        <:actions>
          <button type="button" phx-click="refresh_stats" class="btn-secondary">
            <span class="hero-arrow-path-mini size-4"></span> Refresh stats
          </button>
        </:actions>
      </.page_header>

      <div class="max-w-7xl mx-auto px-6 py-6">
        <.admin_nav active={:cache} />

        <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
          <div class="card p-5">
            <p class="font-mono uppercase tracking-wider text-xs text-stone-500">Cached frames</p>
            <p class="mt-1 font-mono text-2xl font-bold text-stone-900">
              {@frame_stats.cached_frames}
            </p>
            <p class="text-xs text-stone-500 font-mono">max: {@frame_stats.max_capacity}</p>
          </div>

          <div class="card p-5">
            <p class="font-mono uppercase tracking-wider text-xs text-stone-500">Memory usage</p>
            <p class="mt-1 font-mono text-2xl font-bold text-stone-900">
              {@frame_stats.memory_usage_mb} MB
            </p>
            <p class="text-xs text-stone-500 font-mono">
              {@frame_stats.memory_usage_percent}% of {@frame_stats.max_memory_mb}MB
            </p>
          </div>

          <div class="card p-5">
            <p class="font-mono uppercase tracking-wider text-xs text-stone-500">Popular frames</p>
            <p class="mt-1 font-mono text-2xl font-bold text-stone-900">
              {@frame_stats.popular_frames}
            </p>
            <p class="text-xs text-stone-500 font-mono">accessed 3+ times</p>
          </div>

          <div class="card p-5">
            <p class="font-mono uppercase tracking-wider text-xs text-stone-500">GIF usage</p>
            <p class="mt-1 font-mono text-2xl font-bold text-stone-900">
              {@frame_stats.frames_used_in_gifs}
            </p>
            <p class="text-xs text-stone-500 font-mono">avg: {@frame_stats.avg_accesses}</p>
          </div>
        </div>

        <div class="card p-6 mb-6">
          <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-4">
            Cache management
          </h2>
          <div class="flex flex-wrap gap-3">
            <button type="button" phx-click="warm_cache" class="btn-secondary">
              Warm cache
            </button>

            <button
              type="button"
              phx-click="clear_frame_cache"
              class="btn-danger"
              data-confirm="Are you sure you want to clear the entire frame cache?"
            >
              Clear cache
            </button>
          </div>
        </div>

        <div class="card p-6">
          <div class="flex justify-between items-center mb-4">
            <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500">
              Cached frame entries
            </h2>
            <button
              :if={length(@cache_entries) >= @entries_limit}
              type="button"
              phx-click="load_more_entries"
              class="btn-ghost px-3 py-1 text-xs"
            >
              Load more (showing {@entries_limit})
            </button>
          </div>

          <%= if Enum.empty?(@cache_entries) do %>
            <div class="border-2 border-dashed border-stone-300 rounded-xl py-16 px-6 text-center">
              <span class="hero-circle-stack size-10 text-stone-300 mx-auto block"></span>
              <h3 class="mt-3 font-mono uppercase tracking-wider text-stone-700">Cache is empty</h3>
              <p class="mt-1 text-sm text-stone-500">
                No frames are currently cached. Warm the cache to preload frames from recent GIFs.
              </p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-stone-200">
                <thead class="bg-stone-100">
                  <tr>
                    <th class="px-6 py-3 text-left font-mono uppercase tracking-wider text-xs text-stone-500">
                      Frame ID
                    </th>
                    <th class="px-6 py-3 text-left font-mono uppercase tracking-wider text-xs text-stone-500">
                      Video
                    </th>
                    <th class="px-6 py-3 text-left font-mono uppercase tracking-wider text-xs text-stone-500">
                      Access count
                    </th>
                    <th class="px-6 py-3 text-left font-mono uppercase tracking-wider text-xs text-stone-500">
                      Last accessed
                    </th>
                    <th class="px-6 py-3 text-left font-mono uppercase tracking-wider text-xs text-stone-500">
                      GIF usage
                    </th>
                    <th class="px-6 py-3 text-left font-mono uppercase tracking-wider text-xs text-stone-500">
                      Size
                    </th>
                    <th class="px-6 py-3 text-left font-mono uppercase tracking-wider text-xs text-stone-500">
                      Actions
                    </th>
                  </tr>
                </thead>
                <tbody class="bg-white divide-y divide-stone-200">
                  <%= for entry <- @cache_entries do %>
                    <tr class="hover:bg-stone-50">
                      <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-stone-900">
                        {entry.frame_id}
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm">
                        <div class="font-medium text-stone-900">Video {entry.video_id}</div>
                        <div class="text-xs text-stone-500 font-mono">
                          Frame {entry.frame_number}
                        </div>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap">
                        <span class={
                          if(entry.access_count >= 3, do: "badge-success", else: "badge-neutral")
                        }>
                          {entry.access_count}
                        </span>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-stone-500 font-mono">
                        {time_ago(entry.last_accessed)}
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-stone-500 font-mono">
                        {entry.gif_usage_count || 0}
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-stone-500 font-mono">
                        {format_bytes(entry.size)}
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap">
                        <button
                          type="button"
                          phx-click="evict_frame"
                          phx-value-frame_id={entry.frame_id}
                          class="btn-danger px-3 py-1 text-xs"
                          data-confirm={"Evict frame #{entry.frame_id} from cache?"}
                        >
                          Evict
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp time_ago(datetime) do
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

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) do
    "#{bytes} B"
  end
end
