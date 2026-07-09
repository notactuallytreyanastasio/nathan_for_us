defmodule NathanForUsWeb.AdminLive do
  use NathanForUsWeb, :live_view

  import NathanForUsWeb.Components.AdminNav

  alias NathanForUs.AdminService

  on_mount {NathanForUsWeb.UserAuth, :ensure_authenticated}

  def mount(_params, _session, socket) do
    case AdminService.validate_admin_access(socket.assigns.current_user) do
      :ok ->
        stats = AdminService.get_admin_stats()

        {:ok,
         assign(socket,
           stats: stats,
           ffmpeg_test_result: nil,
           page_title: "Admin Dashboard",
           page_description: "Administrative functions"
         )}

      {:error, :access_denied} ->
        {:ok,
         socket
         |> put_flash(:error, "Access denied. Admin privileges required.")
         |> redirect(to: ~p"/")}
    end
  end

  def handle_event("refresh_stats", _params, socket) do
    stats = AdminService.get_admin_stats()
    {:noreply, assign(socket, stats: stats)}
  end

  def handle_event("fail_stale_processing", _params, socket) do
    count = NathanForUs.Video.fail_stale_processing()
    stats = AdminService.get_admin_stats()

    {:noreply,
     socket
     |> assign(stats: stats)
     |> put_flash(:info, "Marked #{count} stalled upload(s) as failed.")}
  end

  def handle_event("test_ffmpeg", _params, socket) do
    case AdminService.test_ffmpeg_availability() do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(ffmpeg_test_result: {:ok, message})
         |> put_flash(:info, "FFMPEG test successful!")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(ffmpeg_test_result: {:error, reason})
         |> put_flash(:error, "FFMPEG test failed: #{reason}")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <.page_header title="Admin Dashboard" subtitle="Site administration">
        <:actions>
          <button type="button" phx-click="refresh_stats" class="btn-secondary">
            <span class="hero-arrow-path-mini size-4"></span> Refresh stats
          </button>
        </:actions>
      </.page_header>

      <div class="max-w-7xl mx-auto px-6 py-6">
        <.admin_nav active={:dashboard} />

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
          <div class="card p-5">
            <p class="font-mono uppercase tracking-wider text-xs text-stone-500">Videos</p>
            <p class="mt-1 font-mono text-2xl font-bold text-stone-900">
              {Map.get(@stats, :total_videos, 0)}
            </p>
            <p class="text-xs text-stone-500 font-mono">
              {Map.get(@stats, :completed_videos, 0)} processed
            </p>
          </div>

          <div class="card p-5">
            <p class="font-mono uppercase tracking-wider text-xs text-stone-500">Frames</p>
            <p class="mt-1 font-mono text-2xl font-bold text-stone-900">
              {Map.get(@stats, :total_frames, 0)}
            </p>
          </div>

          <div class="card p-5">
            <p class="font-mono uppercase tracking-wider text-xs text-stone-500">GIFs</p>
            <p class="mt-1 font-mono text-2xl font-bold text-stone-900">
              {Map.get(@stats, :total_gifs, 0)}
            </p>
            <p class="text-xs text-stone-500 font-mono">
              {Map.get(@stats, :public_gifs, 0)} public
            </p>
          </div>

          <div class="card p-5">
            <p class="font-mono uppercase tracking-wider text-xs text-stone-500">Users</p>
            <p class="mt-1 font-mono text-2xl font-bold text-stone-900">
              {Map.get(@stats, :total_users, 0)}
            </p>
          </div>
        </div>

        <div class="card p-6 mb-6">
          <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-2">
            Stalled uploads
          </h2>
          <p class="text-sm text-stone-600 mb-4 max-w-2xl">
            A browser upload abandoned mid-slice leaves its video stuck in "processing".
            Mark anything processing for over 6 hours as failed.
          </p>

          <button type="button" phx-click="fail_stale_processing" class="btn-secondary">
            Clean up stalled uploads
          </button>
        </div>

        <div class="card p-6 mb-6">
          <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-2">
            FFMPEG availability
          </h2>
          <p class="text-sm text-stone-600 mb-4 max-w-2xl">
            Test if FFMPEG is installed and accessible in the system PATH. This is required
            for server-side video processing and GIF encoding.
          </p>

          <button type="button" phx-click="test_ffmpeg" class="btn-secondary">
            <span class="hero-check-circle-mini size-4"></span> Test FFMPEG
          </button>

          <%= if @ffmpeg_test_result do %>
            <div class={[
              "mt-6 p-4 rounded-lg border",
              if(elem(@ffmpeg_test_result, 0) == :ok,
                do: "bg-green-50 border-green-200",
                else: "bg-red-50 border-red-200"
              )
            ]}>
              <h3 class={[
                "font-mono uppercase tracking-wider text-xs mb-2",
                if(elem(@ffmpeg_test_result, 0) == :ok, do: "text-green-700", else: "text-red-700")
              ]}>
                {if elem(@ffmpeg_test_result, 0) == :ok,
                  do: "FFMPEG test successful",
                  else: "FFMPEG test failed"}
              </h3>
              <div class={[
                "font-mono text-sm",
                if(elem(@ffmpeg_test_result, 0) == :ok, do: "text-green-800", else: "text-red-800")
              ]}>
                {elem(@ffmpeg_test_result, 1)}
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
