defmodule NathanForUsWeb.SetupLive do
  @moduledoc """
  Post-signup onboarding: download the desktop tool, connect it with your
  personal API key, rip your first video. Registration lands here; the page
  stays reachable for whenever a user sets up a new machine.
  """

  use NathanForUsWeb, :live_view

  alias NathanForUs.Accounts

  on_mount {NathanForUsWeb.UserAuth, :ensure_authenticated}

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Get set up")
      |> assign(:base_url, String.trim_trailing(url(~p"/"), "/"))

    {:ok, socket}
  end

  def handle_event("regenerate_key", _params, socket) do
    case Accounts.regenerate_api_key(socket.assigns.current_user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(:info, "New key generated. The old one no longer works.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't regenerate the key. Try again.")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <.page_header title="You're in" subtitle="Three steps to your first GIF." />

      <div class="max-w-3xl mx-auto px-6 py-10 space-y-10">
        <!-- Step 1: download -->
        <section class="card p-6">
          <div class="flex items-baseline gap-4">
            <span class="font-mono text-3xl font-bold text-brand">1</span>
            <h2 class="font-mono uppercase tracking-wider text-lg font-bold text-stone-900">
              Download the tool
            </h2>
          </div>
          <p class="mt-2 text-stone-600">
            One binary with yt-dlp and ffmpeg built in — nothing else to install.
          </p>
          <div class="flex flex-wrap gap-2 mt-4">
            <a href="/downloads/Framecut-Grabber-macos.zip" download class="btn-secondary">
              macOS (universal .app)
            </a>
            <a href="/downloads/framecut-grabber-linux-amd64" download class="btn-secondary">
              Linux
            </a>
            <a href="/downloads/Framecut-Grabber-windows-amd64.exe" download class="btn-secondary">
              Windows
            </a>
          </div>
          <p class="mt-2 font-mono text-xs text-stone-500">
            macOS: unzip, right-click &rarr; Open the first time.
          </p>
        </section>
        
    <!-- Step 2: connect -->
        <section class="card p-6">
          <div class="flex items-baseline gap-4">
            <span class="font-mono text-3xl font-bold text-brand">2</span>
            <h2 class="font-mono uppercase tracking-wider text-lg font-bold text-stone-900">
              Connect it
            </h2>
          </div>
          <p class="mt-2 text-stone-600">
            This is your personal API key. The app asks for it the first time it opens
            &mdash; or set these once and it configures itself:
          </p>

          <div class="mt-4 rounded-lg bg-stone-100 border border-stone-200 p-4 font-mono text-sm text-stone-800 overflow-x-auto">
            <div>export FRAMECUT_SERVER={@base_url}</div>
            <div>export FRAMECUT_API_KEY={@current_user.api_key}</div>
          </div>

          <div class="flex flex-wrap items-center gap-2 mt-3">
            <button
              type="button"
              class="btn-secondary"
              data-copy={"export FRAMECUT_SERVER=#{@base_url}\nexport FRAMECUT_API_KEY=#{@current_user.api_key}"}
            >
              Copy both lines
            </button>
            <button type="button" class="btn-ghost" data-copy={@current_user.api_key}>
              Copy key only
            </button>
            <button
              type="button"
              phx-click="regenerate_key"
              data-confirm="This immediately invalidates your current key everywhere it's configured. Continue?"
              class="btn-ghost text-red-600 hover:text-red-700"
            >
              Regenerate
            </button>
          </div>
          <p class="mt-3 font-mono text-xs text-stone-500">
            Treat the key like a password &mdash; it lets anyone upload to your server.
          </p>
        </section>
        
    <!-- Step 3: first rip -->
        <section class="card p-6">
          <div class="flex items-baseline gap-4">
            <span class="font-mono text-3xl font-bold text-brand">3</span>
            <h2 class="font-mono uppercase tracking-wider text-lg font-bold text-stone-900">
              Rip your first video
            </h2>
          </div>
          <p class="mt-2 text-stone-600">
            Open the app, paste a YouTube link, hit <span class="font-mono">Grab</span>.
            When it finishes it hands you a link straight into the editor here &mdash;
            drag across the filmstrip and make your first GIF.
          </p>
          <p class="mt-4 text-sm text-stone-500">
            Have a video file already?
            <.link navigate={~p"/add"} class="text-brand-deep hover:text-brand">
              Upload it from the browser
            </.link>
            <span class="text-stone-300 mx-1">|</span>
            Terminal person?
            <a href="/downloads/GRABBER_README.txt" class="text-brand-deep hover:text-brand">
              grabber README
            </a>
          </p>
        </section>

        <p class="text-center text-sm text-stone-500">
          Done already?
          <.link navigate={~p"/"} class="text-brand-deep hover:text-brand">
            Go to your library &rarr;
          </.link>
        </p>
      </div>
    </div>
    """
  end
end
