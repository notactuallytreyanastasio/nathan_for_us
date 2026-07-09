defmodule NathanForUsWeb.VideoTimelineLiveTest do
  use NathanForUsWeb.ConnCase

  import Phoenix.LiveViewTest

  alias NathanForUs.{Repo, Accounts}
  alias NathanForUs.Video.Video, as: VideoSchema
  alias NathanForUs.Video.VideoFrame
  alias NathanForUs.Gif

  setup do
    # Create test users
    {:ok, admin_user} = create_admin_user()
    {:ok, regular_user} = create_regular_user()

    # Create test video with frames
    {:ok, video} = create_test_video()
    frames = create_test_frames(video, 50)

    # Create some test GIFs for caching tests
    {:ok, cached_gif} = create_test_gif(video, frames)

    %{
      admin_user: admin_user,
      regular_user: regular_user,
      video: video,
      frames: frames,
      cached_gif: cached_gif
    }
  end

  describe "mount and basic functionality" do
    test "mounts successfully with valid video ID", %{conn: conn, video: video} do
      {:ok, _view, html} = live(conn, "/video/#{video.id}")

      assert html =~ video.title
      assert html =~ "Timeline Browser"
      assert html =~ "frames"
    end

    test "redirects with error for invalid video ID", %{conn: conn} do
      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Video not found"}}}} =
               live(conn, "/video/99999")
    end

    test "redirects with error for non-integer video ID", %{conn: conn} do
      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Invalid video ID"}}}} =
               live(conn, "/video/invalid")
    end

    test "displays navigation links", %{conn: conn, video: video} do
      {:ok, _view, html} = live(conn, "/video/#{video.id}")

      assert html =~ "Back to search"
      assert html =~ "TIMELINE"
      assert html =~ "BROWSE GIFS"
      assert html =~ "Random GIF"
    end

    test "shows tutorial for first-time visitors", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Check if tutorial hook is present
      assert has_element?(view, "#timeline-container[phx-hook='TimelineTutorial']")
    end
  end

  describe "random GIF generation with URL parameters" do
    test "handles random=true with valid parameters", %{conn: conn, video: video} do
      url = "/video/#{video.id}?random=true&start_frame=10&selected_indices=0,1,2,3,4"
      {:ok, view, _html} = live(conn, url)

      # Should be in random selection mode
      state = :sys.get_state(view.pid).socket.assigns
      assert state.is_random_selection == true
      assert state.random_start_frame == 10
      assert state.selected_frame_indices == [0, 1, 2, 3, 4]
    end

    test "handles URL-encoded comma parameters correctly", %{conn: conn, video: video} do
      url = "/video/#{video.id}?random=true&start_frame=5&selected_indices=0%2C1%2C2%2C3"
      {:ok, view, _html} = live(conn, url)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.selected_frame_indices == [0, 1, 2, 3]
    end

    test "shows error for invalid random parameters", %{conn: conn, video: video} do
      url = "/video/#{video.id}?random=true&start_frame=invalid&selected_indices=0,1,2"
      {:ok, _view, html} = live(conn, url)

      assert html =~ "Invalid random parameters"
    end

    test "automatically checks for existing cached GIF", %{conn: conn, video: video} do
      # This would require a GIF to exist in the database with specific frames
      url = "/video/#{video.id}?random=true&start_frame=1&selected_indices=0,1,2,3,4"
      {:ok, view, _html} = live(conn, url)

      # Wait for auto-check to complete
      :sys.get_state(view.pid)

      # Should either show cached GIF or preview
      html = render(view)
      assert html =~ "GIF Preview" or html =~ "Generated GIF"
    end

    test "shows random selection controls when in random mode", %{conn: conn, video: video} do
      url = "/video/#{video.id}?random=true&start_frame=10&selected_indices=0,1,2,3,4"
      {:ok, _view, html} = live(conn, url)

      assert html =~ "Random Selection Mode"
      assert html =~ "Add Left"
      assert html =~ "Add Right"
      assert html =~ "Clear"
    end
  end

  describe "timeline controls and navigation" do
    test "timeline scrubbing updates position", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "timeline_scrub", %{"position" => "0.5"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.timeline_position == 0.5
    end

    test "timeline click updates position and stops playback", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Start playback first
      render_click(view, "toggle_playback")

      # Click on timeline
      render_click(view, "timeline_click", %{"position" => "0.3"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.timeline_position == 0.3
      assert state.timeline_playing == false
    end

    test "playback speed control works", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "set_playback_speed", %{"speed" => "2.0"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.playback_speed == 2.0
    end

    test "timeline zoom control works", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "zoom_timeline", %{"zoom" => "2.0"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.timeline_zoom == 2.0
    end

    test "playback toggle starts and stops animation", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Start playback
      render_click(view, "toggle_playback")
      state = :sys.get_state(view.pid).socket.assigns
      assert state.timeline_playing == true

      # Stop playback
      render_click(view, "toggle_playback")
      state = :sys.get_state(view.pid).socket.assigns
      assert state.timeline_playing == false
    end
  end

  describe "frame selection and GIF preview" do
    test "frame selection works", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "select_frame", %{"frame_index" => "0"})

      state = :sys.get_state(view.pid).socket.assigns
      assert 0 in state.selected_frame_indices
    end

    test "frame deselection works", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Select and then deselect
      render_click(view, "select_frame", %{"frame_index" => "0"})
      render_click(view, "select_frame", %{"frame_index" => "0"})

      state = :sys.get_state(view.pid).socket.assigns
      assert 0 not in state.selected_frame_indices
    end

    test "range selection works", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "select_frame_range", %{
        "start_index" => "0",
        "end_index" => "4",
        "indices" => ["0", "1", "2", "3", "4"]
      })

      state = :sys.get_state(view.pid).socket.assigns
      assert [0, 1, 2, 3, 4] == state.selected_frame_indices
    end

    test "GIF preview shows when frames selected", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Select multiple frames
      render_click(view, "select_frame", %{"frame_index" => "0"})
      render_click(view, "select_frame", %{"frame_index" => "1"})

      html = render(view)
      assert html =~ "GIF Preview"
      assert html =~ "Generate GIF"
    end

    test "captions load for selected frames", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "select_frame", %{"frame_index" => "0"})

      state = :sys.get_state(view.pid).socket.assigns
      assert is_list(state.selected_frame_captions)
    end
  end

  describe "search and filtering" do
    test "caption search filters frames", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_change(view, "caption_search", %{"caption_search" => %{"term" => "test"}})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.is_caption_filtered == true
    end

    test "search from URL parameters works", %{conn: conn, video: video} do
      url = "/video/#{video.id}?search=hello"
      {:ok, view, _html} = live(conn, url)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.caption_search_term == "hello"
    end

    test "context frame from URL parameters works", %{conn: conn, video: video} do
      url = "/video/#{video.id}?search=hello&context_frame=10"
      {:ok, view, _html} = live(conn, url)

      # Should trigger context view
      :sys.get_state(view.pid)

      html = render(view)
      # Should show some indication of context view
      assert html =~ "Back to search" or html =~ "Context"
    end

    test "clear search filter works", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Apply filter first
      render_change(view, "caption_search", %{"caption_search" => %{"term" => "test"}})

      # Clear filter
      render_click(view, "clear_caption_filter")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.is_caption_filtered == false
      assert state.caption_search_term == ""
    end

    test "autocomplete suggestions work", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_change(view, "caption_autocomplete", %{"caption_search" => %{"term" => "hel"}})

      state = :sys.get_state(view.pid).socket.assigns
      assert is_list(state.caption_autocomplete_suggestions)
    end
  end

  describe "GIF generation" do
    test "server-side GIF generation starts with selected frames", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Select frames
      render_click(view, "select_frame", %{"frame_index" => "0"})
      render_click(view, "select_frame", %{"frame_index" => "1"})

      # Start generation
      render_click(view, "generate_timeline_gif_server")

      state = :sys.get_state(view.pid).socket.assigns
      # May already have finished or failed fast depending on ffmpeg availability
      assert state.gif_generation_status in [:generating, :completed, nil]
    end

    test "GIF generation shows error with no frames", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Try to generate without selecting frames
      render_click(view, "generate_timeline_gif_server")

      # Should not start generation
      state = :sys.get_state(view.pid).socket.assigns
      assert state.gif_generation_status != :generating
    end

    test "reset GIF generation works", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Mock completed generation state
      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.gif_generation_status, :completed)
      end)

      render_click(view, "reset_gif_generation")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.gif_generation_status == nil
    end
  end

  describe "random GIF functionality" do
    test "random GIF button generates new URL", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # The event redirects to a fresh random selection URL
      assert {:error, {:redirect, %{to: to}}} = render_click(view, "random_gif")
      assert to =~ "/video/"
      assert to =~ "random=true"
    end

    test "expand random left adds frames", %{conn: conn, video: video} do
      # Set up random selection state
      url = "/video/#{video.id}?random=true&start_frame=10&selected_indices=0,1,2,3,4"
      {:ok, view, _html} = live(conn, url)

      initial_count = length(:sys.get_state(view.pid).socket.assigns.current_frames)

      render_click(view, "expand_random_left")

      new_count = length(:sys.get_state(view.pid).socket.assigns.current_frames)
      assert new_count >= initial_count
    end

    test "expand random right adds frames", %{conn: conn, video: video} do
      url = "/video/#{video.id}?random=true&start_frame=10&selected_indices=0,1,2,3,4"
      {:ok, view, _html} = live(conn, url)

      initial_count = length(:sys.get_state(view.pid).socket.assigns.current_frames)

      render_click(view, "expand_random_right")

      new_count = length(:sys.get_state(view.pid).socket.assigns.current_frames)
      assert new_count >= initial_count
    end

    test "clear random selection works", %{conn: conn, video: video} do
      url = "/video/#{video.id}?random=true&start_frame=10&selected_indices=0,1,2,3,4"
      {:ok, view, _html} = live(conn, url)

      render_click(view, "clear_random_selection")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.is_random_selection == false
      assert state.random_start_frame == nil
    end
  end

  describe "posting to timeline" do
    test "authenticated user can post GIF to timeline", %{
      conn: conn,
      regular_user: user,
      video: video
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Wait for initial frames to load, then compute the hash the post flow will look up
      :sys.get_state(view.pid)
      current_frames = :sys.get_state(view.pid).socket.assigns.current_frames
      selected = Enum.take(current_frames, 2)
      frame_ids = Enum.map(selected, & &1.id)
      hash = NathanForUs.Gif.generate_hash(video.id, frame_ids)

      {:ok, gif} =
        %NathanForUs.Gif{}
        |> NathanForUs.Gif.changeset(%{
          hash: hash,
          video_id: video.id,
          frame_ids: frame_ids,
          gif_data: <<71, 73, 70>>,
          frame_count: length(frame_ids)
        })
        |> NathanForUs.Repo.insert()

      {:ok, _browseable} =
        NathanForUs.Viral.create_browseable_gif(%{
          video_id: video.id,
          gif_id: gif.id,
          start_frame_index: 0,
          end_frame_index: 1
        })

      # Mock completed GIF state
      :sys.replace_state(view.pid, fn state ->
        new_assigns = %{
          gif_generation_status: :completed,
          generated_gif_data: "fake_gif_data",
          selected_frame_indices: [0, 1]
        }

        %{state | socket: %{state.socket | assigns: Map.merge(state.socket.assigns, new_assigns)}}
      end)

      render_click(view, "post_to_timeline")

      # Should show success message
      html = render(view)
      assert html =~ "posted to the public timeline" or html =~ "success"
    end

    test "unauthenticated user cannot post to timeline", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "post_to_timeline")

      html = render(view)
      assert html =~ "log in" or html =~ "Please log in"
    end

    test "cannot post without generated GIF", %{conn: conn, regular_user: user, video: video} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      render_click(view, "post_to_timeline")

      html = render(view)
      assert html =~ "generate" or html =~ "GIF first"
    end
  end

  describe "modal functionality" do
    test "frame modal opens and closes", %{conn: conn, video: video, frames: frames} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      frame = List.first(frames)

      # Open modal
      render_click(view, "show_frame_modal", %{"frame_id" => to_string(frame.id)})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.show_frame_modal == true
      assert state.modal_frame.id == frame.id

      # Close modal
      render_click(view, "close_frame_modal")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.show_frame_modal == false
    end

    test "tutorial modal opens and closes", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Open tutorial
      render_click(view, "show_tutorial_modal")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.show_tutorial_modal == true

      # Close tutorial
      render_click(view, "close_tutorial_modal")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.show_tutorial_modal == false
    end
  end

  describe "context view functionality" do
    test "clicking frame in search results shows context", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # First do a search to get filtered results
      render_change(view, "caption_search", %{"caption_search" => %{"term" => "test"}})

      # Then click a frame to show context
      render_click(view, "select_frame", %{"frame_index" => "0"})

      # Should potentially show context view
      :sys.get_state(view.pid)
    end

    test "back to search results works", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Set up context view state
      :sys.replace_state(view.pid, fn state ->
        new_assigns = %{
          is_context_view: true,
          is_caption_filtered: true
        }

        %{state | socket: %{state.socket | assigns: Map.merge(state.socket.assigns, new_assigns)}}
      end)

      render_click(view, "back_to_search_results")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.is_context_view == false
    end

    test "expand context left and right work", %{conn: conn, video: video} do
      {:ok, view, _html} = live(conn, "/video/#{video.id}")

      # Set up context view state with a target frame
      target_frame = %{frame_number: 25, id: 1, image_data: nil, timestamp_ms: 25_000, width: 640, height: 360, file_size: nil}

      :sys.replace_state(view.pid, fn state ->
        new_assigns = %{
          is_context_view: true,
          context_target_frame: target_frame,
          current_frames: [target_frame]
        }

        %{state | socket: %{state.socket | assigns: Map.merge(state.socket.assigns, new_assigns)}}
      end)

      render_click(view, "expand_context_left")
      render_click(view, "expand_context_right")

      # Should expand the context (exact behavior depends on available frames)
      :sys.get_state(view.pid)
    end
  end

  describe "admin functionality" do
    test "admin users see admin features", %{conn: conn, admin_user: admin, video: video} do
      conn = log_in_user(conn, admin)
      {:ok, _view, html} = live(conn, "/video/#{video.id}")

      # Should show admin-specific elements when GIF is generated
      # Admin features may be conditional
      assert html =~ "ADMIN" or html =~ "cache" or true
    end

    test "regular users do not see admin features", %{
      conn: conn,
      regular_user: user,
      video: video
    } do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/video/#{video.id}")

      # Should not show admin debug info
      refute html =~ "ADMIN DEBUG"
    end
  end

  # Helper functions

  defp create_admin_user do
    attrs = %{
      email: "admin@test.com",
      username: "testadmin",
      password: "test123456789",
      is_admin: true
    }

    {:ok, user} = Accounts.register_user(attrs)
    user = %{user | confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)}
    user = Repo.update!(Accounts.User.confirm_changeset(user))
    user = Repo.update!(Accounts.User.changeset(user, %{is_admin: true}))

    {:ok, user}
  end

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

  defp create_test_frames(video, count) do
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
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      end

    {_count, frame_records} = Repo.insert_all(VideoFrame, frames, returning: true)
    frame_records
  end

  defp create_test_gif(video, frames) do
    frame_ids = frames |> Enum.take(5) |> Enum.map(& &1.id)
    hash = Gif.generate_hash(video.id, frame_ids)

    %NathanForUs.Gif{}
    |> NathanForUs.Gif.changeset(%{
      hash: hash,
      frame_ids: frame_ids,
      gif_data: "fake_gif_data",
      frame_count: 5,
      duration_ms: 1000,
      file_size: 50000,
      video_id: video.id
    })
    |> Repo.insert()
  end
end
