defmodule NathanForUsWeb.FrameController do
  @moduledoc """
  Serves individual video frame JPEGs by id.

  Templates reference frames by URL via this route rather than base64-inlining
  `video_frames.image_data` into pages and LiveView diffs. Frame bytes never
  change once ingested, so they are cached aggressively.
  """
  use NathanForUsWeb, :controller

  alias NathanForUs.Repo
  alias NathanForUs.Video.{FrameImage, VideoFrame}

  def show(conn, %{"id" => id}) do
    with {frame_id, ""} <- Integer.parse(id),
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
end
