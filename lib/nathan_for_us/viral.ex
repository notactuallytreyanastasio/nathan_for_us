defmodule NathanForUs.Viral do
  @moduledoc """
  Context for the public GIF feed: every generated GIF is browseable,
  and can be voted on Reddit-style (hot/top/new).
  """

  import Ecto.Query, warn: false
  alias NathanForUs.Repo
  alias NathanForUs.Viral.{BrowseableGif, GifVote}

  @doc """
  Categories users can tag a GIF with.
  """
  def categories do
    [
      "reaction",
      "funny",
      "music",
      "sports",
      "animals",
      "fails",
      "wholesome",
      "wtf"
    ]
  end

  @doc """
  Marks a generated GIF as posted to the public timeline.

  Finds the browseable entry for the GIF binary and stamps it with
  `posted_at` and the posting user.
  """
  def post_gif_to_timeline(gif_id, user_id, attrs \\ %{}) do
    browseable_gif =
      from(g in BrowseableGif,
        where: g.gif_id == ^gif_id,
        order_by: [desc: g.inserted_at],
        limit: 1
      )
      |> Repo.one()

    case browseable_gif do
      nil ->
        {:error, :not_found}

      browseable_gif ->
        browseable_gif
        |> BrowseableGif.changeset(
          Map.merge(attrs, %{posted_at: DateTime.utc_now(), created_by_user_id: user_id})
        )
        |> Repo.update()
    end
  end

  @doc """
  Gets GIFs posted to the public timeline, newest first.
  """
  def get_timeline_gifs(limit \\ 25) do
    from(g in BrowseableGif,
      where: not is_nil(g.posted_at) and g.is_public == true,
      order_by: [desc: g.posted_at],
      limit: ^limit,
      preload: [:video, :created_by_user, :gif]
    )
    |> Repo.all()
  end

  @doc """
  Creates a browseable GIF entry automatically when someone generates a GIF.
  This makes ALL generated GIFs browseable for inspiration, regardless of posting.
  """
  def create_browseable_gif(attrs \\ %{}) do
    %BrowseableGif{}
    |> BrowseableGif.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets recent browseable GIFs for the browse page.
  """
  def get_recent_browseable_gifs(limit \\ 50) do
    from(g in BrowseableGif,
      where: g.is_public == true,
      order_by: [desc: g.inserted_at],
      limit: ^limit,
      preload: [:video, :created_by_user, :gif]
    )
    |> Repo.all()
  end

  @doc """
  Gets browseable GIFs by category.
  """
  def get_browseable_gifs_by_category(category, limit \\ 20) do
    from(g in BrowseableGif,
      where: g.category == ^category and g.is_public == true,
      order_by: [desc: g.inserted_at],
      limit: ^limit,
      preload: [:video, :created_by_user, :gif]
    )
    |> Repo.all()
  end

  @doc """
  Gets browseable GIFs for a specific video.
  """
  def get_browseable_gifs_for_video(video_id, limit \\ 20) do
    from(g in BrowseableGif,
      where: g.video_id == ^video_id and g.is_public == true,
      order_by: [desc: g.inserted_at],
      limit: ^limit,
      preload: [:video, :created_by_user, :gif]
    )
    |> Repo.all()
  end

  # === VOTING SYSTEM ===

  @doc """
  Votes on a browseable GIF. Handles both authenticated and anonymous votes.
  """
  def vote_on_gif(browseable_gif_id, vote_type, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    session_id = Keyword.get(opts, :session_id)
    ip_address = Keyword.get(opts, :ip_address)

    attrs = %{
      browseable_gif_id: browseable_gif_id,
      vote_type: vote_type,
      user_id: user_id,
      session_id: session_id,
      ip_address: ip_address
    }

    case %GifVote{} |> GifVote.changeset(attrs) |> Repo.insert() do
      {:ok, vote} ->
        update_gif_vote_counts(browseable_gif_id)
        {:ok, vote}

      {:error, changeset} ->
        # Handle existing vote - update instead of insert
        if changeset.errors[:user_id] || changeset.errors[:session_id] do
          update_existing_vote(browseable_gif_id, vote_type, user_id, session_id)
        else
          {:error, changeset}
        end
    end
  end

  defp update_existing_vote(browseable_gif_id, vote_type, user_id, session_id) do
    query =
      if user_id do
        from(v in GifVote,
          where: v.browseable_gif_id == ^browseable_gif_id and v.user_id == ^user_id
        )
      else
        from(v in GifVote,
          where: v.browseable_gif_id == ^browseable_gif_id and v.session_id == ^session_id
        )
      end

    case Repo.update_all(query, set: [vote_type: vote_type, updated_at: DateTime.utc_now()]) do
      {1, _} ->
        update_gif_vote_counts(browseable_gif_id)
        {:ok, :updated}

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the current user's vote on a GIF.
  """
  def get_user_vote(browseable_gif_id, user_id: user_id) when not is_nil(user_id) do
    from(v in GifVote,
      where: v.browseable_gif_id == ^browseable_gif_id and v.user_id == ^user_id,
      select: v.vote_type
    )
    |> Repo.one()
  end

  def get_user_vote(browseable_gif_id, session_id: session_id) when not is_nil(session_id) do
    from(v in GifVote,
      where: v.browseable_gif_id == ^browseable_gif_id and v.session_id == ^session_id,
      select: v.vote_type
    )
    |> Repo.one()
  end

  def get_user_vote(_browseable_gif_id, _opts), do: nil

  @doc """
  Updates vote counts on the browseable GIF.
  """
  def update_gif_vote_counts(browseable_gif_id) do
    upvotes =
      from(v in GifVote,
        where: v.browseable_gif_id == ^browseable_gif_id and v.vote_type == "up",
        select: count(v.id)
      )
      |> Repo.one()

    downvotes =
      from(v in GifVote,
        where: v.browseable_gif_id == ^browseable_gif_id and v.vote_type == "down",
        select: count(v.id)
      )
      |> Repo.one()

    hot_score = calculate_hot_score(upvotes, downvotes, browseable_gif_id)

    from(g in BrowseableGif, where: g.id == ^browseable_gif_id)
    |> Repo.update_all(
      set: [
        upvotes_count: upvotes,
        downvotes_count: downvotes,
        hot_score: hot_score,
        hot_score_updated_at: DateTime.utc_now()
      ]
    )
  end

  @doc """
  Calculates Reddit-style hot score for ranking GIFs.
  """
  def calculate_hot_score(upvotes, downvotes, browseable_gif_id) do
    # Get GIF creation time
    gif_created_at =
      from(g in BrowseableGif,
        where: g.id == ^browseable_gif_id,
        select: g.inserted_at
      )
      |> Repo.one()

    if gif_created_at do
      calculate_hot_score_with_time(upvotes, downvotes, gif_created_at)
    else
      0.0
    end
  end

  defp calculate_hot_score_with_time(upvotes, downvotes, created_at) do
    # Reddit's hot algorithm with some modifications for our use case
    score = upvotes - downvotes

    # Time decay: newer posts get higher scores
    age_hours = DateTime.diff(DateTime.utc_now(), created_at, :hour)

    # Base score with logarithmic scaling for vote counts
    base_score =
      if score > 0 do
        :math.log10(max(score, 1))
      else
        -:math.log10(max(abs(score), 1))
      end

    # Time factor: posts lose points over time, but good content persists longer
    time_factor = :math.pow(age_hours + 2, 1.5)

    # Final hot score
    base_score / time_factor
  end

  @doc """
  Gets browseable GIFs ordered by hot score.
  """
  def get_hot_browseable_gifs(limit \\ 50) do
    from(g in BrowseableGif,
      where: g.is_public == true,
      order_by: [desc: g.hot_score, desc: g.inserted_at],
      limit: ^limit,
      preload: [:video, :created_by_user, :gif]
    )
    |> Repo.all()
  end

  @doc """
  Gets browseable GIFs ordered by total upvotes (all time).
  """
  def get_top_browseable_gifs(limit \\ 50) do
    from(g in BrowseableGif,
      where: g.is_public == true,
      order_by: [desc: g.upvotes_count, desc: g.inserted_at],
      limit: ^limit,
      preload: [:video, :created_by_user, :gif]
    )
    |> Repo.all()
  end

  @doc """
  Gets browseable GIFs ordered by recent upload time.
  """
  def get_new_browseable_gifs(limit \\ 50) do
    from(g in BrowseableGif,
      where: g.is_public == true,
      order_by: [desc: g.inserted_at],
      limit: ^limit,
      preload: [:video, :created_by_user, :gif]
    )
    |> Repo.all()
  end

  @doc """
  Bulk update hot scores for all GIFs (for background job).
  """
  def update_all_hot_scores do
    gifs =
      from(g in BrowseableGif,
        where: g.is_public == true,
        select: [:id, :upvotes_count, :downvotes_count, :inserted_at]
      )
      |> Repo.all()

    Enum.each(gifs, fn gif ->
      hot_score =
        calculate_hot_score_with_time(gif.upvotes_count, gif.downvotes_count, gif.inserted_at)

      from(g in BrowseableGif, where: g.id == ^gif.id)
      |> Repo.update_all(
        set: [
          hot_score: hot_score,
          hot_score_updated_at: DateTime.utc_now()
        ]
      )
    end)
  end
end
