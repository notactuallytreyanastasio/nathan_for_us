defmodule NathanForUsWeb.GifBrowseLiveTest do
  use NathanForUsWeb.ConnCase

  import Phoenix.LiveViewTest

  alias NathanForUs.{Repo, Accounts}
  alias NathanForUs.Video.Video, as: VideoSchema
  alias NathanForUs.Video.VideoFrame
  alias NathanForUs.Viral
  alias NathanForUs.Viral.BrowseableGif
  alias NathanForUs.Gif

  setup do
    # Create test users
    {:ok, admin_user} = create_admin_user()
    {:ok, regular_user1} = create_regular_user("user1@test.com", "testuser1")
    {:ok, regular_user2} = create_regular_user("user2@test.com", "testuser2")

    # Create test video with frames
    {:ok, video} = create_test_video()
    frames = create_test_frames(video, 20)

    # Create test GIFs for browsing
    {:ok, cached_gif} = create_test_gif(video, frames)

    {:ok, browseable_gif1} =
      create_browseable_gif(video, regular_user1, cached_gif, "Crowd Wisdom", 5)

    {:ok, browseable_gif2} =
      create_browseable_gif(video, regular_user2, cached_gif, "Awkward Moments", 3)

    %{
      admin_user: admin_user,
      regular_user1: regular_user1,
      regular_user2: regular_user2,
      video: video,
      frames: frames,
      cached_gif: cached_gif,
      browseable_gif1: browseable_gif1,
      browseable_gif2: browseable_gif2
    }
  end

  describe "mount and basic functionality" do
    test "mounts successfully with default hot sort", %{conn: conn} do
      {:ok, view, html} = live(conn, "/gifs")

      assert html =~ "Explore"
      assert html =~ "Hot"
      assert html =~ "Top"
      assert html =~ "New"

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sort == "hot"
    end

    test "displays page actions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gifs")

      assert html =~ "Random GIF"
      assert html =~ "Make a GIF"
    end

    test "shows browseable GIFs", %{conn: conn, browseable_gif1: gif1, browseable_gif2: gif2} do
      {:ok, _view, html} = live(conn, "/gifs")

      assert html =~ gif1.title
      assert html =~ gif2.title
    end

    test "cards link posters and permalinks", %{conn: conn, browseable_gif1: gif1} do
      {:ok, _view, html} = live(conn, "/gifs")

      # Static poster in the media well, permalink on the share button
      assert html =~ "/gif/#{gif1.gif_id}/poster"
      assert html =~ "/g/#{gif1.id}"
    end

    test "handles empty GIF list gracefully", %{conn: conn} do
      Repo.delete_all(BrowseableGif)

      {:ok, _view, html} = live(conn, "/gifs")

      assert html =~ "Nothing hot yet"
      assert html =~ "Make a GIF"
    end
  end

  describe "sorting functionality" do
    test "can sort by top", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gifs?sort=top")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sort == "top"
    end

    test "can sort by new", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gifs?sort=new")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sort == "new"
    end

    test "invalid sort defaults to hot", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gifs?sort=invalid")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sort == "hot"
    end

    test "empty sorts get sort-specific empty states", %{conn: conn} do
      Repo.delete_all(BrowseableGif)

      {:ok, _view, html} = live(conn, "/gifs?sort=top")
      assert html =~ "No top GIFs yet"

      {:ok, _view, html} = live(conn, "/gifs?sort=new")
      assert html =~ "Nothing new"
    end
  end

  describe "upvoting functionality" do
    test "authenticated user can upvote GIF", %{
      conn: conn,
      regular_user1: user,
      browseable_gif2: gif
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/gifs")

      render_click(view, "upvote_gif", %{"gif_id" => to_string(gif.id)})

      assert Viral.get_user_votes([gif.id], user_id: user.id) == %{gif.id => "up"}

      # The active vote state is the feedback — no flash
      html = render(view)
      refute html =~ "GIF upvoted!"
    end

    test "upvoting again removes the vote (toggle off)", %{
      conn: conn,
      regular_user1: user,
      browseable_gif2: gif
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/gifs")

      render_click(view, "upvote_gif", %{"gif_id" => to_string(gif.id)})
      render_click(view, "upvote_gif", %{"gif_id" => to_string(gif.id)})

      assert Viral.get_user_votes([gif.id], user_id: user.id) == %{}
      assert Repo.get(BrowseableGif, gif.id).upvotes_count == 0
    end

    test "unauthenticated user sees register prompt when upvoting", %{
      conn: conn,
      browseable_gif1: gif
    } do
      {:ok, view, _html} = live(conn, "/gifs")

      render_click(view, "upvote_gif", %{"gif_id" => to_string(gif.id)})

      html = render(view)
      assert html =~ "Account required"
      assert html =~ "/users/register"
    end

    test "register prompt can be dismissed", %{conn: conn, browseable_gif1: gif} do
      {:ok, view, _html} = live(conn, "/gifs")

      render_click(view, "upvote_gif", %{"gif_id" => to_string(gif.id)})
      render_click(view, "dismiss_register_prompt")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.show_register_prompt == false
      refute render(view) =~ "Account required"
    end
  end

  describe "GIF modal deep links" do
    test "?gif_id opens the modal even for GIFs outside the loaded page", %{
      conn: conn,
      browseable_gif1: gif
    } do
      {:ok, _view, html} = live(conn, "/gifs?gif_id=#{gif.id}")

      assert html =~ ~s(role="dialog")
      assert html =~ "Download"
      assert html =~ "Copy GIF link"
    end

    test "missing/private gif_id patches away with an error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gifs")

      render_patch(view, "/gifs?gif_id=999999")

      assert render(view) =~ "That GIF is gone or private"

      state = :sys.get_state(view.pid).socket.assigns
      assert state.show_gif_modal == false
    end

    test "close_gif_modal patches the gif_id away", %{conn: conn, browseable_gif1: gif} do
      {:ok, view, _html} = live(conn, "/gifs?gif_id=#{gif.id}")

      render_click(view, "close_gif_modal")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.show_gif_modal == false
      refute render(view) =~ ~s(role="dialog")
    end
  end

  describe "random GIF functionality" do
    test "random GIF button redirects to a video editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gifs")

      assert {:error, {:redirect, %{to: to}}} = render_click(view, "random_gif")
      assert to =~ "/video/"
    end

    test "random GIF handles no videos gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gifs")

      Repo.delete_all(NathanForUs.Viral.GifVote)
      Repo.delete_all(BrowseableGif)
      Repo.delete_all(Gif)
      Repo.delete_all(VideoFrame)
      Repo.delete_all(VideoSchema)

      render_click(view, "random_gif")

      assert render(view) =~ "No suitable videos"
    end
  end

  describe "loading and pagination" do
    test "feed is loaded after connected mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gifs")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.feed_loaded? == true
      assert state.feed_empty? == false
      assert state.page == 1
    end

    test "a short first page marks the end of the feed", %{conn: conn} do
      {:ok, view, html} = live(conn, "/gifs")

      state = :sys.get_state(view.pid).socket.assigns
      # Only 2 GIFs exist (< page size), so the feed is complete
      assert state.end_of_feed? == true
      assert html =~ "seen it all"
    end

    test "feed queries paginate", %{
      video: video,
      regular_user1: user,
      cached_gif: gif
    } do
      for i <- 1..30 do
        {:ok, _} = create_browseable_gif(video, user, gif, "Test GIF #{i}", i)
      end

      page1 = Viral.get_new_browseable_gifs(24, 0)
      page2 = Viral.get_new_browseable_gifs(24, 24)

      assert length(page1) == 24
      assert length(page2) == 32 - 24
      assert MapSet.disjoint?(MapSet.new(page1, & &1.id), MapSet.new(page2, & &1.id))
    end
  end

  describe "error handling" do
    test "invalid GIF ID for upvote", %{conn: conn, regular_user1: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/gifs")

      render_click(view, "upvote_gif", %{"gif_id" => "999999"})

      # Page should still work
      assert render(view) =~ "Explore"
    end

    test "anonymous upvote with any gif_id shows the register prompt", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gifs")

      render_click(view, "upvote_gif", %{"gif_id" => "999999"})

      assert render(view) =~ "Account required"
    end
  end

  describe "posting semantics (Viral context)" do
    test "posting flips is_public and stamps posted_at with a title", %{
      video: video,
      regular_user1: user,
      cached_gif: cached_gif
    } do
      {:ok, draft} =
        Viral.create_browseable_gif(%{
          video_id: video.id,
          gif_id: cached_gif.id,
          start_frame_index: 1,
          end_frame_index: 5,
          is_public: false
        })

      assert {:ok, posted} =
               Viral.post_browseable_gif_to_timeline(draft.id, user.id, "My cut")

      assert posted.is_public == true
      assert posted.posted_at != nil
      assert posted.title == "My cut"
      assert posted.created_by_user_id == user.id
    end

    test "posting never reassigns an existing creator", %{
      browseable_gif1: gif,
      regular_user2: other_user
    } do
      original_creator_id = gif.created_by_user_id

      assert {:ok, posted} =
               Viral.post_browseable_gif_to_timeline(gif.id, other_user.id, nil)

      assert posted.created_by_user_id == original_creator_id
    end

    test "posting an unknown id returns an error" do
      assert {:error, :not_found} = Viral.post_browseable_gif_to_timeline(999_999, nil, nil)
    end

    test "posted GIFs appear on the timeline query", %{
      browseable_gif1: gif,
      regular_user1: user
    } do
      assert Viral.get_timeline_gif(gif.id) == nil

      {:ok, _posted} = Viral.post_browseable_gif_to_timeline(gif.id, user.id, nil)

      assert %BrowseableGif{} = Viral.get_timeline_gif(gif.id)
      assert Enum.any?(Viral.get_timeline_gifs(24, 0), &(&1.id == gif.id))
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

  defp create_regular_user(email, username) do
    attrs = %{
      email: email,
      username: username,
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
      duration_ms: 30000,
      fps: 30.0,
      frame_count: 20,
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

  defp create_browseable_gif(video, user, cached_gif, title, upvote_count) do
    frame_data =
      Jason.encode!(%{
        frame_ids: [1, 2, 3, 4, 5],
        frame_numbers: [1, 2, 3, 4, 5],
        timestamps: [1000, 2000, 3000, 4000, 5000]
      })

    attrs = %{
      video_id: video.id,
      created_by_user_id: user.id,
      gif_id: cached_gif.id,
      start_frame_index: 1,
      end_frame_index: 5,
      category: "wisdom",
      frame_data: frame_data,
      title: title,
      is_public: true,
      upvotes_count: upvote_count
    }

    Viral.create_browseable_gif(attrs)
  end
end
