defmodule NathanForUsWeb.PageController do
  use NathanForUsWeb, :controller

  # Redirects for routes from the previous incarnation of this app.

  def redirect_to_home(conn, _params) do
    redirect(conn, to: ~p"/")
  end

  def redirect_to_gifs(conn, _params) do
    redirect(conn, to: ~p"/gifs")
  end

  def redirect_to_timeline(conn, _params) do
    redirect(conn, to: ~p"/timeline")
  end

  def redirect_to_video(conn, %{"video_id" => video_id}) do
    redirect(conn, to: ~p"/video/#{video_id}")
  end
end
