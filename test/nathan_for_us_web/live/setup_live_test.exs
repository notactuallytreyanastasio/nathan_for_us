defmodule NathanForUsWeb.SetupLiveTest do
  use NathanForUsWeb.ConnCase

  import Phoenix.LiveViewTest
  import NathanForUs.AccountsFixtures

  test "redirects anonymous visitors to log in", %{conn: conn} do
    assert {:error, redirect} = live(conn, ~p"/setup")
    assert {:redirect, %{to: "/users/log_in"}} = redirect
  end

  describe "logged in" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "shows the personal key, env one-liner, and downloads", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/setup")

      assert html =~ user.api_key
      assert html =~ "FRAMECUT_API_KEY"
      assert html =~ "FRAMECUT_SERVER"
      assert html =~ "/downloads/Framecut-Grabber-macos.zip"
      assert html =~ "Rip your first video"
    end

    test "regenerate replaces the key", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html = render_click(view, "regenerate_key")

      refute html =~ user.api_key
      reloaded = NathanForUs.Accounts.get_user!(user.id)
      assert html =~ reloaded.api_key
      refute reloaded.api_key == user.api_key
    end
  end
end
