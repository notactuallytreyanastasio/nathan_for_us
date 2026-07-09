defmodule NathanForUs.VideoStaleProcessingTest do
  use NathanForUs.DataCase

  alias NathanForUs.Repo
  alias NathanForUs.Video
  alias NathanForUs.Video.Video, as: VideoSchema

  defp insert_video(status, updated_at) do
    {:ok, video} =
      %VideoSchema{}
      |> VideoSchema.changeset(%{
        title: "v-#{status}-#{System.unique_integer([:positive])}",
        file_path: "client-upload/#{System.unique_integer([:positive])}.mp4",
        status: status
      })
      |> Repo.insert()

    video
    |> Ecto.Changeset.change(updated_at: NaiveDateTime.truncate(updated_at, :second))
    |> Repo.update!()
  end

  test "fails only processing videos older than the cutoff" do
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -7, :hour)
    recent = NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :hour)

    stale = insert_video("processing", old)
    fresh = insert_video("processing", recent)
    done = insert_video("completed", old)

    assert Video.fail_stale_processing(6) == 1

    assert Repo.get!(VideoSchema, stale.id).status == "failed"
    assert Repo.get!(VideoSchema, fresh.id).status == "processing"
    assert Repo.get!(VideoSchema, done.id).status == "completed"
  end
end
