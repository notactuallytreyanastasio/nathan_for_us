defmodule NathanForUsWeb.HomeLiveTest do
  use NathanForUsWeb.ConnCase

  import Phoenix.LiveViewTest
  import NathanForUs.AccountsFixtures

  describe "landing page" do
    test "/ renders the one-button landing, not the library", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "cut out a GIF"
      assert html =~ "Browse GIFs"
      assert html =~ "Random GIF"
      refute html =~ "Video library"
      refute html =~ "Search everything said"
    end

    test "logged out: the primary button goes to register", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s{a[href="/users/register"]})
      refute has_element?(view, ~s{a[href="/add?post=1"]})
      assert has_element?(view, ~s{a[href="/gifs"]})
      assert has_element?(view, ~s{a[href="/random"]})
    end

    test "suppresses the global nav chrome (full-screen, one button)", %{conn: conn} do
      # Dead render so the root layout (which holds the nav) is included.
      response = conn |> get(~p"/") |> html_response(200)

      refute response =~ "<nav"
      refute response =~ "Explore"
    end

    test "logged in: same landing, but the button drops into the flow", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, "/")

      assert html =~ "cut out a GIF"
      refute html =~ "Video library"
      # The primary button carries ?post=1 so the editor auto-posts the cut GIF.
      assert has_element?(view, ~s{a[href="/add?post=1"]})
      refute has_element?(view, ~s{a[href="/users/register"]})
    end
  end
end
