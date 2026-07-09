defmodule NathanForUsWeb.AdminLive do
  use NathanForUsWeb, :live_view

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

  def handle_event("generate_usernames", _params, socket) do
    case AdminService.generate_usernames_from_emails() do
      {:ok, count} ->
        {:noreply,
         put_flash(socket, :info, "Successfully generated #{count} usernames from emails!")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate usernames: #{reason}")}
    end
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
    <div class="min-h-screen bg-zinc-50 p-6">
      <div class="max-w-6xl mx-auto">
        <div class="mb-8">
          <h1 class="text-3xl font-bold text-zinc-900 mb-2">Admin Dashboard</h1>
          <p class="text-zinc-600">Site administration</p>
        </div>

    <!-- Admin Navigation -->
        <div class="mb-8">
          <nav class="flex space-x-4">
            <.link
              navigate={~p"/admin"}
              class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
            >
              Dashboard
            </.link>
            <.link
              navigate={~p"/admin/upload"}
              class="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
            >
              Upload Video
            </.link>
            <.link
              navigate={~p"/admin/frames"}
              class="px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors"
            >
              Browse Frames
            </.link>
            <.link
              navigate={~p"/admin/cache"}
              class="px-4 py-2 bg-orange-600 text-white rounded-lg hover:bg-orange-700 transition-colors"
            >
              Cache Admin
            </.link>
            <.link
              navigate={~p"/admin/dashboard"}
              class="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition-colors"
            >
              🔍 System Monitor
            </.link>
          </nav>
        </div>

    <!-- Stats Section -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-6 mb-8">
          <div class="bg-white rounded-lg p-6 shadow-sm border border-zinc-200">
            <p class="text-sm font-medium text-zinc-600">Videos</p>
            <p class="text-2xl font-bold text-zinc-900">
              {Map.get(@stats, :total_videos, 0)}
              <span class="text-sm font-normal text-zinc-500">
                ({Map.get(@stats, :completed_videos, 0)} processed)
              </span>
            </p>
          </div>

          <div class="bg-white rounded-lg p-6 shadow-sm border border-zinc-200">
            <p class="text-sm font-medium text-zinc-600">Frames</p>
            <p class="text-2xl font-bold text-zinc-900">{Map.get(@stats, :total_frames, 0)}</p>
          </div>

          <div class="bg-white rounded-lg p-6 shadow-sm border border-zinc-200">
            <p class="text-sm font-medium text-zinc-600">GIFs</p>
            <p class="text-2xl font-bold text-green-600">
              {Map.get(@stats, :total_gifs, 0)}
              <span class="text-sm font-normal text-zinc-500">
                ({Map.get(@stats, :public_gifs, 0)} public)
              </span>
            </p>
          </div>

          <div class="bg-white rounded-lg p-6 shadow-sm border border-zinc-200">
            <p class="text-sm font-medium text-zinc-600">Users</p>
            <p class="text-2xl font-bold text-zinc-900">{Map.get(@stats, :total_users, 0)}</p>
          </div>
        </div>

        <div class="mb-8">
          <button
            type="button"
            phx-click="refresh_stats"
            class="inline-flex items-center px-4 py-2 border border-zinc-300 text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
          >
            Refresh Stats
          </button>
        </div>

    <!-- Username Generation Section -->
        <div class="bg-white rounded-lg p-6 shadow-sm border border-zinc-200 mb-8">
          <h2 class="text-xl font-bold text-zinc-900 mb-4">Username Generation</h2>
          <p class="text-zinc-600 mb-6">
            Generate usernames for all existing users who don't have one. Usernames will be created from the part of their email before the @ symbol.
          </p>

          <div class="flex items-center space-x-4">
            <button
              phx-click="generate_usernames"
              class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-purple-600 hover:bg-purple-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-purple-500"
            >
              Generate Usernames from Emails
            </button>
          </div>
        </div>

    <!-- FFMPEG Testing Section -->
        <div class="bg-white rounded-lg p-6 shadow-sm border border-zinc-200 mb-8">
          <h2 class="text-xl font-bold text-zinc-900 mb-4">FFMPEG Availability Test</h2>
          <p class="text-zinc-600 mb-6">
            Test if FFMPEG is installed and accessible in the system PATH. This is required for server-side video processing and GIF encoding.
          </p>

          <div class="flex items-center space-x-4">
            <button
              phx-click="test_ffmpeg"
              class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-orange-600 hover:bg-orange-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-orange-500"
            >
              <svg class="h-4 w-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                >
                </path>
              </svg>
              Test FFMPEG
            </button>
          </div>

    <!-- Test Results -->
          <%= if @ffmpeg_test_result do %>
            <div class={"mt-6 p-4 rounded-md #{if elem(@ffmpeg_test_result, 0) == :ok, do: "bg-green-50", else: "bg-red-50"}"}>
              <h3 class={"text-lg font-medium mb-2 #{if elem(@ffmpeg_test_result, 0) == :ok, do: "text-green-900", else: "text-red-900"}"}>
                {if elem(@ffmpeg_test_result, 0) == :ok,
                  do: "FFMPEG Test Successful",
                  else: "FFMPEG Test Failed"}
              </h3>
              <div class="text-sm">
                <div class={"font-mono #{if elem(@ffmpeg_test_result, 0) == :ok, do: "text-green-800", else: "text-red-800"}"}>
                  {elem(@ffmpeg_test_result, 1)}
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
