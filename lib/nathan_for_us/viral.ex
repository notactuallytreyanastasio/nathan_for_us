defmodule NathanForUs.Viral do
  @moduledoc """
  Context for the public GIF feed and timeline.

  Generated GIFs become browseable records; posting one to the timeline
  (`post_gif_to_timeline/3` / `post_browseable_gif_to_timeline/3`) makes it
  public and stamps `posted_at`. Public GIFs can be voted on Reddit-style
  (hot/top/new).
  """

  import Ecto.Query, warn: false
  alias NathanForUs.{Gif, Repo}
  alias NathanForUs.Viral.{BrowseableGif, GifVote}

  # GIF columns loaded for feed previews. The heavy `gif_data` blob is excluded
  # and served on demand via `/gif/:id` (see NathanForUsWeb.GifController) rather
  # than base64-inlined into every feed page and LiveView diff.
  @gif_preview_fields [
    :id,
    :hash,
    :frame_ids,
    :frame_count,
    :duration_ms,
    :file_size,
    :video_id,
    :inserted_at,
    :updated_at
  ]

  defp gif_preview_query do
    from(g in Gif, select: struct(g, @gif_preview_fields))
  end

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
  Marks a generated GIF as posted to the public timeline, looked up by the
  GIF binary id (`gifs.id`).

  Posting flips `is_public` to true, stamps `posted_at`, persists the given
  title (when present in `attrs`), and attributes the post to `user_id` only
  when the browseable GIF has no creator yet — hash-deduplicated GIFs keep
  their original attribution.
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
        do_post_to_timeline(browseable_gif, user_id, Map.get(attrs, :title) || attrs["title"])
    end
  end

  @doc """
  Posts a browseable GIF to the public timeline by its own id
  (`browseable_gifs.id`), with an optional title.

  Same semantics as `post_gif_to_timeline/3`. Returns the updated
  `%BrowseableGif{}` (handy for deep-link flashes) or `{:error, atom}`.
  """
  def post_browseable_gif_to_timeline(browseable_gif_id, user_id, title \\ nil) do
    case Repo.get(BrowseableGif, browseable_gif_id) do
      nil -> {:error, :not_found}
      browseable_gif -> do_post_to_timeline(browseable_gif, user_id, title)
    end
  end

  defp do_post_to_timeline(%BrowseableGif{} = browseable_gif, user_id, title) do
    attrs =
      %{posted_at: DateTime.utc_now(), is_public: true}
      |> maybe_put_title(title)
      |> maybe_put_creator(browseable_gif, user_id)

    case browseable_gif |> BrowseableGif.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :invalid}
    end
  end

  defp maybe_put_title(attrs, title) when is_binary(title) and title != "",
    do: Map.put(attrs, :title, title)

  defp maybe_put_title(attrs, _title), do: attrs

  # Never reassign attribution: hash-deduplicated GIFs keep their creator.
  defp maybe_put_creator(attrs, %BrowseableGif{created_by_user_id: nil}, user_id)
       when not is_nil(user_id),
       do: Map.put(attrs, :created_by_user_id, user_id)

  defp maybe_put_creator(attrs, _browseable_gif, _user_id), do: attrs

  @doc """
  Gets GIFs posted to the public timeline, newest first.
  """
  def get_timeline_gifs(limit \\ 25, offset \\ 0) do
    from(g in BrowseableGif,
      where: not is_nil(g.posted_at) and g.is_public == true,
      order_by: [desc: g.posted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single public browseable GIF by id with feed preloads, or nil.

  Used to resolve `?gif_id=` deep links independently of whatever page of
  the feed happens to be loaded.
  """
  def get_browseable_gif(id) do
    from(g in BrowseableGif,
      where: g.id == ^id and g.is_public == true,
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
    )
    |> Repo.one()
  end

  @doc """
  Gets a single timeline GIF (public AND posted) by id with feed preloads,
  or nil.
  """
  def get_timeline_gif(id) do
    from(g in BrowseableGif,
      where: g.id == ^id and g.is_public == true and not is_nil(g.posted_at),
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
    )
    |> Repo.one()
  end

  @doc """
  Creates a browseable GIF entry when someone generates a GIF.

  Callers decide visibility via `is_public` (generation creates private
  drafts; posting to the timeline flips them public).
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
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
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
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
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
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
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
  Gets the current user's votes for many GIFs in one query.

  Returns a `%{browseable_gif_id => vote_type}` map. Pass either
  `user_id: id` or `session_id: sid`; anything else returns an empty map.
  """
  def get_user_votes(gif_ids, opts)

  def get_user_votes([], _opts), do: %{}

  def get_user_votes(gif_ids, user_id: user_id) when not is_nil(user_id) do
    from(v in GifVote,
      where: v.browseable_gif_id in ^gif_ids and v.user_id == ^user_id,
      select: {v.browseable_gif_id, v.vote_type}
    )
    |> Repo.all()
    |> Map.new()
  end

  def get_user_votes(gif_ids, session_id: session_id) when not is_nil(session_id) do
    from(v in GifVote,
      where: v.browseable_gif_id in ^gif_ids and v.session_id == ^session_id,
      select: {v.browseable_gif_id, v.vote_type}
    )
    |> Repo.all()
    |> Map.new()
  end

  def get_user_votes(_gif_ids, _opts), do: %{}

  @doc """
  Removes the user's vote on a GIF (vote toggle-off) and refreshes the
  GIF's cached vote counts.
  """
  def remove_vote(browseable_gif_id, opts) do
    query =
      case opts do
        [user_id: user_id] when not is_nil(user_id) ->
          from(v in GifVote,
            where: v.browseable_gif_id == ^browseable_gif_id and v.user_id == ^user_id
          )

        [session_id: session_id] when not is_nil(session_id) ->
          from(v in GifVote,
            where: v.browseable_gif_id == ^browseable_gif_id and v.session_id == ^session_id
          )

        _ ->
          nil
      end

    case query && Repo.delete_all(query) do
      {count, _} when count > 0 ->
        update_gif_vote_counts(browseable_gif_id)
        {:ok, :removed}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Toggles an upvote: removes the vote when the user already upvoted the
  GIF, otherwise records/updates an upvote.

  `opts` takes `user_id:` or `session_id:` like `get_user_votes/2`.
  """
  def toggle_upvote(browseable_gif_id, opts) do
    case get_user_votes([browseable_gif_id], opts)[browseable_gif_id] do
      "up" -> remove_vote(browseable_gif_id, opts)
      _ -> vote_on_gif(browseable_gif_id, "up", opts)
    end
  end

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

  The hot score is computed in SQL at query time (same formula as
  `calculate_hot_score/3`, with age-based decay), so the ranking never goes
  stale — the persisted `hot_score` column is only a cached display value.
  """
  def get_hot_browseable_gifs(limit \\ 50, offset \\ 0) do
    from(g in BrowseableGif,
      where: g.is_public == true,
      order_by: [
        desc:
          fragment(
            """
            (CASE WHEN ? - ? > 0
                  THEN LOG(GREATEST((? - ?)::numeric, 1))
                  ELSE -LOG(GREATEST(ABS(? - ?)::numeric, 1))
             END)
            / POWER(EXTRACT(EPOCH FROM (NOW() AT TIME ZONE 'UTC' - ?)) / 3600 + 2, 1.5)
            """,
            g.upvotes_count,
            g.downvotes_count,
            g.upvotes_count,
            g.downvotes_count,
            g.upvotes_count,
            g.downvotes_count,
            g.inserted_at
          ),
        desc: g.inserted_at
      ],
      limit: ^limit,
      offset: ^offset,
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
    )
    |> Repo.all()
  end

  @doc """
  Gets browseable GIFs ordered by total upvotes (all time).
  """
  def get_top_browseable_gifs(limit \\ 50, offset \\ 0) do
    from(g in BrowseableGif,
      where: g.is_public == true,
      order_by: [desc: g.upvotes_count, desc: g.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
    )
    |> Repo.all()
  end

  @doc """
  Gets browseable GIFs ordered by recent upload time.
  """
  def get_new_browseable_gifs(limit \\ 50, offset \\ 0) do
    from(g in BrowseableGif,
      where: g.is_public == true,
      order_by: [desc: g.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:video, :created_by_user, gif: ^gif_preview_query()]
    )
    |> Repo.all()
  end

  @doc """
  Bulk update hot scores for all GIFs.

  No longer required for feed correctness — `get_hot_browseable_gifs/2`
  ranks in SQL at query time — but kept so the cached `hot_score` column
  can be refreshed on demand (e.g. from an admin console).
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
