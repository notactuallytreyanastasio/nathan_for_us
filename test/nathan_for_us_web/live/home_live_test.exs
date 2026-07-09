defmodule NathanForUsWeb.HomeLiveTest do
  use NathanForUsWeb.ConnCase

  import Phoenix.LiveViewTest
  import NathanForUs.AccountsFixtures

  describe "logged out" do
    test "/ renders the landing page, not the library", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Turn any video into GIFs, frame by frame."
      assert html =~ "Grab"
      assert html =~ "Upload"
      assert html =~ "Get started"
      refute html =~ "VIDEO LIBRARY"
    end

    test "landing links to register, feed, and log in", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s{a[href="/users/register"]})
      assert has_element?(view, ~s{a[href="/gifs"]})
      assert has_element?(view, ~s{a[href="/users/log_in"]})
    end
  end

  describe "logged in" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "/ renders the library", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "FRAMECUT"
      refute html =~ "Get started"
    end
  end
end
