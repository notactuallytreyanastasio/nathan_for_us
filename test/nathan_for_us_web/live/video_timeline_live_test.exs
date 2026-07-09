defmodule NathanForUsWeb.VideoTimelineLiveTest do
  use NathanForUsWeb.ConnCase

  import Phoenix.LiveViewTest

  alias NathanForUs.{Accounts, Repo}
  alias NathanForUs.Video.Video, as: VideoSchema
  alias NathanForUs.Video.VideoFrame

  setup do
    {:ok, regular_user} = create_regular_user()
    {:ok, video} = create_test_video()
    frames = create_test_frames(video, 50)
    {:ok, caption} = create_test_caption(video)

    %{regular_user: regular_user, video: video, frames: frames, caption: caption}
  end

  describe "mount and basic rendering" do
    test "mounts successfully with valid video ID", %{conn: conn, video: video} do
      {:ok, _view, html} = live(conn, "/video/#{video.id}")

      assert html =~ video.title
      assert html =~ "frames"
      assert html =~ "GENERATE GIF"
    end

    test "redirects with error for invalid video ID", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "Video not found"}}}} =
               live(conn, "/video/99999")
    end

    test "redirects with error for non-integer video ID", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "Invalid video ID"}}}} =
               live(conn, "/video/invalid")
    end

    test "renders the editor hooks and filmstrip", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      assert has_element?(view, "#editor-root[phx-hook='KeyboardShortcuts']")
      assert has_element?(view, "#editor-filmstrip[phx-hook='Filmstrip']")
      assert has_element?(view, "#stage-preview[phx-hook='RangePreview']")
    end

    test "sets page title to the edit form", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      assert page_title(view) =~ "Edit"
    end
  end

  describe "playhead" do
    test "clicking a frame sets the playhead", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "set_playhead", %{"frame_number" => 10})

      state = :sys.get_state(view.pid).socket.assigns
      # frame numbers start at 1, so frame 10 is index 9
      assert state.playhead == 9
    end

    test "move_playhead moves by delta and clamps at bounds", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "move_playhead", %{"delta" => 5})
      assert :sys.get_state(view.pid).socket.assigns.playhead == 5

      render_hook(view, "move_playhead", %{"delta" => -100})
      assert :sys.get_state(view.pid).socket.assigns.playhead == 0

      render_hook(view, "move_playhead", %{"delta" => 1000})
      assert :sys.get_state(view.pid).socket.assigns.playhead == 49
    end
  end

  describe "range selection" do
    test "select_range sets the range from frame numbers", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "select_range", %{"start_frame_number" => 5, "end_frame_number" => 12})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sel_start == 4
      assert state.sel_end == 11
    end

    test "select_range normalizes reversed bounds", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "select_range", %{"start_frame_number" => 12, "end_frame_number" => 5})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sel_start == 4
      assert state.sel_end == 11
    end

    test "set_range_point I/O builds a range around the playhead", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "move_playhead", %{"delta" => 10})
      render_hook(view, "set_range_point", %{"point" => "in"})
      render_hook(view, "move_playhead", %{"delta" => 5})
      render_hook(view, "set_range_point", %{"point" => "out"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sel_start == 10
      assert state.sel_end == 15
    end

    test "clear_range clears the selection", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "select_range", %{"start_frame_number" => 5, "end_frame_number" => 12})
      render_click(view, "clear_range")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sel_start == nil
      assert state.sel_end == nil
    end

    test "selection readout renders in the action bar", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      html =
        render_hook(view, "select_range", %{"start_frame_number" => 1, "end_frame_number" => 10})

      assert html =~ "10 frames"
      assert html =~ "1.0s"
    end
  end

  describe "fps control" do
    test "set_fps updates the playback speed", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "set_fps", %{"fps" => "15"})
      assert :sys.get_state(view.pid).socket.assigns.fps == 15
    end

    test "set_fps rejects values outside the allowed options", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "set_fps", %{"fps" => "99"})
      assert :sys.get_state(view.pid).socket.assigns.fps == 10
    end
  end

  describe "shortcuts overlay" do
    test "toggle and escape close the overlay", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      html = render_click(view, "toggle_shortcuts")
      assert html =~ "Keyboard shortcuts"

      render_hook(view, "editor_escape", %{})
      refute :sys.get_state(view.pid).socket.assigns.show_shortcuts
    end

    test "escape clears the range when no overlay is open", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "select_range", %{"start_frame_number" => 5, "end_frame_number" => 12})
      render_hook(view, "editor_escape", %{})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sel_start == nil
    end
  end

  describe "caption search" do
    test "search runs asynchronously and reports no matches", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_change(view, "caption_search_change", %{
        "caption_search" => %{"term" => "nothing here"}
      })

      # allow the async handle_info to run
      :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "No captions match"
      state = :sys.get_state(view.pid).socket.assigns
      assert state.caption_loading == false
      assert state.caption_searched == true
    end

    test "short terms reset search state", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_change(view, "caption_search_change", %{"caption_search" => %{"term" => "ab"}})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.caption_results == []
      assert state.caption_searched == false
    end

    test "jump_to_frame moves the playhead", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "jump_to_frame", %{"frame_number" => "20"})

      assert :sys.get_state(view.pid).socket.assigns.playhead == 19
    end
  end

  describe "GIF generation guards" do
    test "generate with no range is a no-op", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "keyboard_generate", %{})

      assert :sys.get_state(view.pid).socket.assigns.gif_generation_status == nil
    end

    test "single-frame range shows guidance instead of generating", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_hook(view, "set_range_point", %{"point" => "in"})
      html = render_hook(view, "keyboard_generate", %{})

      assert html =~ "Select at least 2 frames"
      assert :sys.get_state(view.pid).socket.assigns.gif_generation_status == nil
    end
  end

  describe "posting" do
    test "post without a generated GIF sets an error", %{
      conn: conn,
      regular_user: user,
      video: video
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Force a completed status without a browseable record
      :sys.replace_state(view.pid, fn state ->
        assigns =
          Map.merge(state.socket.assigns, %{
            gif_generation_status: :completed,
            generated_gif_id: 123,
            generated_browseable_gif_id: nil
          })

        %{state | socket: %{state.socket | assigns: assigns}}
      end)

      render_submit(view, "post_to_timeline", %{"post" => %{"title" => "My GIF"}})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.post_error =~ "regenerate"
      refute state.posted_to_timeline
    end
  end

  describe "URL parameter compatibility" do
    test "random parameters pre-select a range", %{conn: conn, video: video} do
      url = "/video/#{video.id}?random=true&start_frame=10&selected_indices=0,1,2,3,4"
      {:ok, view, _html} = live(conn, url)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sel_start == 9
      assert state.sel_end == 13
    end

    test "invalid random parameters flash an error", %{conn: conn, video: video} do
      url = "/video/#{video.id}?random=true&start_frame=invalid&selected_indices=0,1,2"
      {:ok, view, _html} = live(conn, url)

      # no selection was made
      state = :sys.get_state(view.pid).socket.assigns
      assert state.sel_start == nil
    end

    test "search parameter triggers a caption search", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}?search=test%20phrase")

      :sys.get_state(view.pid)
      state = :sys.get_state(view.pid).socket.assigns
      assert state.caption_search_term == "test phrase"
      assert state.caption_searched == true
    end
  end

  # Helper functions

  defp create_regular_user do
    attrs = %{
      email: "user@test.com",
      username: "testuser",
      password: "test123456789"
    }

    {:ok, user} = Accounts.register_user(attrs)
    user = %{user | confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)}
    user = Repo.update!(Accounts.User.confirm_changeset(user))

    {:ok, user}
  end

  defp create_test_video do
    %VideoSchema{}
    |> VideoSchema.changeset(%{
      title: "Test Video",
      file_path: "/test/video.mp4",
      duration_ms: 50000,
      fps: 30.0,
      frame_count: 50,
      status: "completed"
    })
    |> Repo.insert()
  end

  defp create_test_caption(video) do
    %NathanForUs.Video.VideoCaption{}
    |> NathanForUs.Video.VideoCaption.changeset(%{
      video_id: video.id,
      start_time_ms: 1000,
      end_time_ms: 3000,
      text: "the plan is simple",
      caption_index: 0
    })
    |> Repo.insert()
  end

  defp create_test_frames(video, count) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    frames =
      for i <- 1..count do
        %{
          frame_number: i,
          timestamp_ms: i * 1000,
          file_path: "frame_#{i}.jpg",
          file_size: 1000,
          width: 1920,
          height: 1080,
          video_id: video.id,
          inserted_at: now,
          updated_at: now
        }
      end

    {_count, frame_records} = Repo.insert_all(VideoFrame, frames, returning: true)
    frame_records
  end
end
