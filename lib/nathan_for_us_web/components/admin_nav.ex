defmodule NathanForUsWeb.Components.AdminNav do
  @moduledoc """
  Shared segmented-control navigation for the admin surfaces.

  Rendered at the top of every admin LiveView so each page can reach the
  others without copy-pasted per-page nav bars.
  """

  use NathanForUsWeb, :html

  attr :active, :atom,
    required: true,
    values: [:dashboard, :upload, :frames, :cache, :system],
    doc: "which admin section is currently displayed"

  def admin_nav(assigns) do
    ~H"""
    <nav class="mb-8 overflow-x-auto" aria-label="Admin sections">
      <div class="inline-flex bg-stone-100 border border-stone-200 rounded-lg p-1 font-mono text-sm">
        <.link
          navigate={~p"/admin"}
          class={tab_class(@active == :dashboard)}
          aria-current={aria_current(@active == :dashboard)}
        >
          Dashboard
        </.link>
        <.link
          navigate={~p"/admin/upload"}
          class={tab_class(@active == :upload)}
          aria-current={aria_current(@active == :upload)}
        >
          Upload Video
        </.link>
        <.link
          navigate={~p"/admin/frames"}
          class={tab_class(@active == :frames)}
          aria-current={aria_current(@active == :frames)}
        >
          Browse Frames
        </.link>
        <.link
          navigate={~p"/admin/cache"}
          class={tab_class(@active == :cache)}
          aria-current={aria_current(@active == :cache)}
        >
          Cache Admin
        </.link>
        <.link
          href={~p"/admin/dashboard"}
          class={tab_class(@active == :system)}
          aria-current={aria_current(@active == :system)}
        >
          System Monitor
        </.link>
      </div>
    </nav>
    """
  end

  defp tab_class(true), do: "bg-white text-stone-900 rounded-md shadow-sm px-3 py-1.5"
  defp tab_class(false), do: "px-3 py-1.5 text-stone-500 hover:text-stone-800"

  defp aria_current(true), do: "page"
  defp aria_current(false), do: nil
end
