defmodule NathanForUsWeb.Api.VideoUploadControllerTest do
  use NathanForUsWeb.ConnCase

  import NathanForUs.AccountsFixtures

  @shared_key "test-shared-ingest-key"

  setup %{conn: conn} do
    conn = put_req_header(conn, "content-type", "application/json")
    %{conn: conn, user: user_fixture()}
  end

  defp payload(file_path) do
    %{
      "video" => %{
        "title" => "API Test Video",
        "file_path" => file_path,
        "duration_ms" => 2000,
        "fps" => 1.0,
        "frame_count" => 1
      },
      "frames" => [
        %{
          "frame_number" => 1,
          "timestamp_ms" => 0,
          "file_size" => 3,
          "width" => 2,
          "height" => 2,
          "image_data" => Base.encode64(<<0xFF, 0xD8, 0xFF>>)
        }
      ],
      "captions" => [
        %{"start_time_ms" => 0, "end_time_ms" => 1000, "text" => "hi", "caption_index" => 0}
      ]
    }
  end

  defp with_shared_key(_context) do
    previous = Application.get_env(:nathan_for_us, :ingest_api_key)
    Application.put_env(:nathan_for_us, :ingest_api_key, @shared_key)
    on_exit(fn -> Application.put_env(:nathan_for_us, :ingest_api_key, previous) end)
    :ok
  end

  describe "authentication" do
    test "a user's personal api key is accepted", %{conn: conn, user: user} do
      assert String.starts_with?(user.api_key, "fc_")

      conn =
        conn
        |> put_req_header("x-api-key", user.api_key)
        |> post(~p"/api/videos/upload", payload("/api-test/personal.mp4"))

      assert %{"success" => true, "video_id" => video_id, "url" => url} =
               json_response(conn, 201)

      assert url == "/video/#{video_id}"
    end

    test "a missing api key is rejected", %{conn: conn} do
      conn = post(conn, ~p"/api/videos/upload", payload("/api-test/missing.mp4"))
      assert json_response(conn, 401)["error"] == "missing api key"
    end

    test "an unknown api key is rejected", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-api-key", "fc_definitely_not_a_real_key")
        |> post(~p"/api/videos/upload", payload("/api-test/unknown.mp4"))

      assert json_response(conn, 401)["error"] == "invalid api key"
    end

    test "a regenerated key invalidates the old one", %{conn: conn, user: user} do
      {:ok, updated} = NathanForUs.Accounts.regenerate_api_key(user)
      refute updated.api_key == user.api_key

      conn =
        conn
        |> put_req_header("x-api-key", user.api_key)
        |> post(~p"/api/videos/upload", payload("/api-test/stale.mp4"))

      assert json_response(conn, 401)["error"] == "invalid api key"
    end
  end

  describe "authentication with a shared key configured" do
    setup :with_shared_key

    test "the legacy shared key still works", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-api-key", @shared_key)
        |> post(~p"/api/videos/upload", payload("/api-test/shared.mp4"))

      assert %{"success" => true} = json_response(conn, 201)
    end

    test "personal keys work alongside the shared key", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("x-api-key", user.api_key)
        |> post(~p"/api/videos/upload", payload("/api-test/personal-alongside.mp4"))

      assert %{"success" => true} = json_response(conn, 201)
    end
  end
end
