defmodule NathanForUsWeb.HomeLive do
  @moduledoc """
  Framecut landing page (`/`).

  One screen, three doors: cut a GIF (the whole point of the app), browse the
  feed, or jump to a random GIF. The primary button drops you into the
  gif-centric flow — add a video, cut a range, and it auto-posts to the global
  timeline (see the `?post=1` flag threaded through `/add` → the editor).

  The video library and caption search moved to `/library`
  (`NathanForUsWeb.LibraryLive`).
  """

  use NathanForUsWeb, :live_view

  on_mount {NathanForUsWeb.UserAuth, :mount_current_user}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Turn any video into GIFs")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-[100dvh] bg-stone-950 text-white flex flex-col">
      <header class="px-6 pt-6">
        <span class="font-mono font-bold tracking-wider text-lg">
          FRAMECUT <span class="text-brand">&#9654;</span>
        </span>
      </header>

      <main class="flex-1 flex items-center justify-center px-5 py-10">
        <div class="w-full max-w-2xl">
          <.link
            href={if @current_user, do: ~p"/add?post=1", else: ~p"/users/register"}
            class="group block w-full rounded-2xl bg-brand hover:bg-brand-hover transition-colors
                   px-8 py-14 sm:py-20 text-center shadow-2xl shadow-brand/20"
          >
            <span class="block font-mono font-black uppercase tracking-tight leading-[1.03]
                         text-3xl sm:text-5xl text-white">
              Add a video,<br />cut out a GIF
            </span>
            <span class="mt-4 block font-mono text-xs sm:text-base text-white/80">
              <%= if @current_user do %>
                paste a link &rarr; drag a range &rarr; it posts to the timeline
              <% else %>
                free account &rarr; paste a link &rarr; cut &amp; post your first GIF
              <% end %>
            </span>
          </.link>

          <div class="mt-4 grid grid-cols-2 gap-4">
            <.link
              navigate={~p"/gifs"}
              class="rounded-2xl border border-stone-700 bg-stone-900 hover:bg-stone-800
                     hover:border-stone-600 transition-colors px-4 py-8 text-center
                     font-mono font-bold uppercase tracking-wide text-base sm:text-xl"
            >
              Browse GIFs
            </.link>
            <.link
              href={~p"/random"}
              class="rounded-2xl border border-stone-700 bg-stone-900 hover:bg-stone-800
                     hover:border-stone-600 transition-colors px-4 py-8 text-center
                     font-mono font-bold uppercase tracking-wide text-base sm:text-xl"
            >
              Random GIF
            </.link>
          </div>
        </div>
      </main>

      <footer class="px-6 pb-6 text-center font-mono text-xs text-stone-500">
        <.link navigate={~p"/timeline"} class="hover:text-stone-300">timeline</.link>
        <span class="mx-2 text-stone-700">·</span>
        <.link navigate={~p"/library"} class="hover:text-stone-300">library &amp; search</.link>
      </footer>
    </div>
    """
  end
end
