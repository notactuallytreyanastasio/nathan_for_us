defmodule NathanForUsWeb.GifController do
  @moduledoc """
  Serves rendered GIF binaries by id.

  The feed lists (`/timeline`, `/gifs`) reference GIFs by URL via this route
  rather than base64-inlining `gif_data` into the page, which keeps the heavy
  binaries out of the feed queries and the LiveView payloads. GIF bytes are
  content-addressed and immutable, so they can be cached aggressively.

  `GET /gif/:id?download=1` serves the same bytes as an attachment, and
  `GET /gif/:id/poster` serves the GIF's first frame as a static JPEG poster.
  """
  use NathanForUsWeb, :controller

  alias NathanForUs.{Gif, Repo, Viral}
  alias NathanForUs.Viral.BrowseableGif
  alias NathanForUs.Video.{FrameImage, VideoFrame}

  @doc """
  `GET /random` — redirects to a random posted GIF's permalink (`/g/:id`),
  or to the browse feed when no GIFs have been posted yet.
  """
  def random(conn, _params) do
    case Viral.get_random_public_gif() do
      %BrowseableGif{id: id} -> redirect(conn, to: ~p"/g/#{id}")
      _ -> redirect(conn, to: ~p"/gifs")
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {gif_id, ""} <- Integer.parse(id),
         %Gif{gif_data: data} when is_binary(data) <- Repo.get(Gif, gif_id) do
      conn
      |> put_resp_content_type("image/gif")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> maybe_put_download_header(params, gif_id)
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def poster(conn, %{"id" => id}) do
    with {gif_id, ""} <- Integer.parse(id),
         %Gif{frame_ids: [frame_id | _]} <- Repo.get(Gif, gif_id),
         %VideoFrame{image_data: image_data} <- Repo.get(VideoFrame, frame_id),
         jpeg when is_binary(jpeg) <- FrameImage.raw(image_data) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, jpeg)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp maybe_put_download_header(conn, %{"download" => download}, gif_id)
       when download in ["1", "true"] do
    put_resp_header(
      conn,
      "content-disposition",
      ~s(attachment; filename="framecut-#{gif_id}.gif")
    )
  end

  defp maybe_put_download_header(conn, _params, _gif_id), do: conn
end
