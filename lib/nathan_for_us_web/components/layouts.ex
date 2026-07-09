defmodule NathanForUsWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use NathanForUsWeb, :controller` and
  `use NathanForUsWeb, :live_view`.
  """
  use NathanForUsWeb, :html

  embed_templates "layouts/*"

  @doc """
  Returns the class list for a top-nav link, marking the link for the
  current page with the brand underline.

  Only usable where `@conn` is available (the root layout is rendered in
  the plug pipeline, so this covers both controllers and LiveViews on
  their initial request).
  """
  def nav_link_class(conn, path) do
    base = "inline-flex items-center h-12 border-b-2 transition-colors"

    if nav_link_active?(conn, path) do
      [base, "text-stone-900 border-brand"]
    else
      [base, "text-stone-500 hover:text-stone-900 border-transparent"]
    end
  end

  defp nav_link_active?(%Plug.Conn{} = conn, path) do
    Phoenix.Controller.current_path(conn, %{}) == path
  end

  defp nav_link_active?(_conn, _path), do: false
end
