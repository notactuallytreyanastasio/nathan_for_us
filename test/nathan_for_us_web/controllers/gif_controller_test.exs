defmodule NathanForUsWeb.GifControllerTest do
  use NathanForUsWeb.ConnCase

  describe "GET /random" do
    test "redirects to the browse feed when no GIFs have been posted", %{conn: conn} do
      conn = get(conn, ~p"/random")
      assert redirected_to(conn) == ~p"/gifs"
    end
  end
end
