defmodule NathanForUs.Admin do
  @moduledoc """
  Administrative functions for managing the application.
  """

  import Ecto.Query, warn: false
  alias NathanForUs.Repo
  alias NathanForUs.Accounts.User
  alias NathanForUs.Video.{Video, VideoFrame, VideoCaption}
  alias NathanForUs.Viral.BrowseableGif

  require Logger

  @doc """
  Returns high-level stats for the admin dashboard.
  """
  def get_stats do
    %{
      total_videos: Repo.aggregate(Video, :count),
      completed_videos:
        from(v in Video, where: v.status == "completed") |> Repo.aggregate(:count),
      total_frames: Repo.aggregate(VideoFrame, :count),
      total_captions: Repo.aggregate(VideoCaption, :count),
      total_gifs: Repo.aggregate(NathanForUs.Gif, :count),
      public_gifs:
        from(g in BrowseableGif, where: g.is_public == true) |> Repo.aggregate(:count),
      total_users: Repo.aggregate(User, :count)
    }
  end

  @doc """
  Checks if a user is an admin.
  """
  def is_admin?(%{is_admin: true}), do: true
  def is_admin?(_), do: false

  @doc """
  Generates usernames for all users without usernames based on their email.
  Returns the number of users updated.
  """
  def generate_usernames_from_emails do
    users_without_usernames =
      from(u in User,
        where: is_nil(u.username),
        select: u
      )
      |> Repo.all()

    Logger.info("Found #{length(users_without_usernames)} users without usernames")

    updated_count =
      users_without_usernames
      |> Enum.reduce(0, fn user, acc ->
        username = generate_username_from_email(user.email)

        case update_user_username(user, username) do
          {:ok, _updated_user} ->
            acc + 1

          {:error, reason} ->
            Logger.warning("Failed to update username for #{user.email}: #{inspect(reason)}")
            acc
        end
      end)

    Logger.info("Successfully updated #{updated_count} usernames")
    updated_count
  end

  defp generate_username_from_email(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.slice(0, 20)
  end

  defp update_user_username(user, username) do
    user
    |> User.changeset(%{username: username})
    |> Repo.update()
  end
end
