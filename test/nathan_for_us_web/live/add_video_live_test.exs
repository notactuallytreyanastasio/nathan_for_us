defmodule NathanForUsWeb.AddVideoLiveTest do
  use NathanForUsWeb.ConnCase

  import Phoenix.LiveViewTest
  import NathanForUs.AccountsFixtures
  import Ecto.Query

  alias NathanForUs.Repo
  alias NathanForUs.Video.{Video, VideoFrame, VideoCaption, FrameCaption}

  @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0xFF, 0xD9>>

  @srt """
  1
  00:00:00,000 --> 00:00:01,500
  hello from the browser

  2
  00:00:01,600 --> 00:00:03,000
  slicing frames client side
  """

  defp frame(n) do
    %{
      "frame_number" => n,
      "timestamp_ms" => (n - 1) * 1000,
      "data" => Base.encode64(@fake_jpeg),
      "width" => 640,
      "height" => 360
    }
  end

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "requires authentication", %{} do
    conn = build_conn()
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, "/add")
  end

  test "renders both tabs", %{conn: conn} do
    {:ok, view, html} = live(conn, "/add")

    assert html =~ "Add a video"
    assert html =~ "SLICE + UPLOAD"

    html = render_click(view, "switch_tab", %{"tab" => "cli"})
    assert html =~ "Download the app"
    assert html =~ "Framecut-Grabber-macos.zip"
    refute html =~ "chmod"
  end

  test "full client ingest protocol creates video, frames, captions and links", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/add")

    render_hook(view, "client_ingest_start", %{
      "title" => "Concert clip",
      "duration_ms" => 4000,
      "fps" => 1,
      "frame_count" => 4,
      "captions_text" => @srt,
      "filename" => "IMG 1234.MOV"
    })

    video = Repo.one(from v in Video, order_by: [desc: v.id], limit: 1)
    assert video.title == "Concert clip"
    assert video.status == "processing"
    assert video.file_path =~ "client-upload/"
    assert video.file_path =~ "img_1234.mov"

    render_hook(view, "client_frame_batch", %{
      "video_id" => video.id,
      "frames" => [frame(1), frame(2)]
    })

    render_hook(view, "client_frame_batch", %{
      "video_id" => video.id,
      "frames" => [frame(3), frame(4)]
    })

    assert Repo.aggregate(from(f in VideoFrame, where: f.video_id == ^video.id), :count) == 4

    # Finish: parses captions, links frames, completes video, navigates to editor
    render_hook(view, "client_ingest_finish", %{"video_id" => video.id})
    assert_redirect(view, "/video/#{video.id}")

    video = Repo.get!(Video, video.id)
    assert video.status == "completed"
    assert video.frame_count == 4

    captions = Repo.all(from c in VideoCaption, where: c.video_id == ^video.id)
    assert length(captions) == 2

    # Frames at 0s and 1s fall in caption 1; frames at 2s and 3s fall in caption 2
    link_count =
      Repo.aggregate(
        from(fc in FrameCaption,
          join: f in VideoFrame,
          on: fc.frame_id == f.id,
          where: f.video_id == ^video.id
        ),
        :count
      )

    assert link_count == 4
  end

  test "ingest works without captions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/add")

    render_hook(view, "client_ingest_start", %{
      "title" => "No captions",
      "duration_ms" => 1000,
      "fps" => 1,
      "frame_count" => 1,
      "captions_text" => nil,
      "filename" => "clip.mp4"
    })

    video = Repo.one(from v in Video, order_by: [desc: v.id], limit: 1)

    render_hook(view, "client_frame_batch", %{"video_id" => video.id, "frames" => [frame(1)]})
    render_hook(view, "client_ingest_finish", %{"video_id" => video.id})
    assert_redirect(view, "/video/#{video.id}")

    assert Repo.get!(Video, video.id).status == "completed"
    assert Repo.aggregate(from(c in VideoCaption, where: c.video_id == ^video.id), :count) == 0
  end

  test "rejects videos over the frame cap", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/add")

    render_hook(view, "client_ingest_start", %{
      "title" => "Feature film",
      "duration_ms" => 7_200_000,
      "fps" => 1,
      "frame_count" => 7200,
      "captions_text" => nil,
      "filename" => "movie.mp4"
    })

    assert Repo.aggregate(Video, :count) == 0
  end

  test "rejects frame batches for a mismatched session", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/add")

    render_hook(view, "client_frame_batch", %{"video_id" => 12_345, "frames" => [frame(1)]})

    assert Repo.aggregate(VideoFrame, :count) == 0
  end

  test "resume re-adopts an in-progress browser upload after a remount", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/add")

    render_hook(view, "client_ingest_start", %{
      "title" => "Interrupted",
      "duration_ms" => 4000,
      "fps" => 1,
      "frame_count" => 4,
      "captions_text" => @srt,
      "filename" => "clip.mp4"
    })

    video = Repo.one(from v in Video, order_by: [desc: v.id], limit: 1)

    render_hook(view, "client_frame_batch", %{
      "video_id" => video.id,
      "frames" => [frame(1), frame(2)]
    })

    # A reconnect remounts the LiveView with no ingest state.
    {:ok, view2, _html} = live(conn, "/add")

    render_hook(view2, "client_ingest_resume", %{
      "video_id" => video.id,
      "captions_text" => @srt
    })

    assert_push_event(view2, "ingest_ack", %{resume_from: 2})

    render_hook(view2, "client_frame_batch", %{
      "video_id" => video.id,
      "frames" => [frame(3), frame(4)]
    })

    render_hook(view2, "client_ingest_finish", %{"video_id" => video.id})
    assert_redirect(view2, "/video/#{video.id}")

    video = Repo.get!(Video, video.id)
    assert video.status == "completed"
    assert video.frame_count == 4
    assert Repo.aggregate(from(c in VideoCaption, where: c.video_id == ^video.id), :count) == 2
  end

  test "resume is refused for unknown or non-browser videos", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/add")

    render_hook(view, "client_ingest_resume", %{"video_id" => 999_999, "captions_text" => nil})
    assert_push_event(view, "ingest_error", %{message: _})
  end

  test "cancel deletes the partial upload", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/add")

    render_hook(view, "client_ingest_start", %{
      "title" => "Changed my mind",
      "duration_ms" => 2000,
      "fps" => 1,
      "frame_count" => 2,
      "captions_text" => nil,
      "filename" => "clip.mp4"
    })

    video = Repo.one(from v in Video, order_by: [desc: v.id], limit: 1)

    render_hook(view, "client_frame_batch", %{"video_id" => video.id, "frames" => [frame(1)]})
    render_hook(view, "client_ingest_cancel", %{"video_id" => video.id})

    assert Repo.get(Video, video.id) == nil
    assert Repo.aggregate(VideoFrame, :count) == 0
  end
end
