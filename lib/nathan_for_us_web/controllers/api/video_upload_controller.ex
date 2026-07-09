defmodule NathanForUsWeb.Api.VideoUploadController do
  use NathanForUsWeb, :controller

  alias NathanForUs.Video
  alias NathanForUs.Repo

  plug NathanForUsWeb.Plugs.ApiAuth

  @doc """
  Accepts a complete video dataset and uploads it to production.

  Requires a valid "x-api-key" request header (see NathanForUsWeb.Plugs.ApiAuth).
  The "captions" list is optional — videos can be ingested without captions.

  Multi-batch uploads (the grabber) POST repeatedly with the same
  `video.file_path`: the first request (with captions) resets the video, later
  requests append frames. The video stays `processing` until the accumulated
  frame count reaches `video.frame_count`, then flips to `completed`.
  Appending to an already-completed video without starting a new session
  (i.e. without captions) is rejected with 409.

  Expected payload format:
  {
    "video": {
      "title": "string",
      "file_path": "string",
      "duration_ms": integer,
      "fps": float,
      "frame_count": integer,
      "metadata": map
    },
    "frames": [
      {
        "frame_number": integer,
        "timestamp_ms": integer,
        "file_path": "string (optional)",
        "file_size": integer,
        "width": integer,
        "height": integer,
        "image_data": "base64 encoded binary data",
        "compression_ratio": float
      }
    ],
    "captions": [  // optional, may be omitted or empty
      {
        "start_time_ms": integer,
        "end_time_ms": integer,
        "text": "string",
        "caption_index": integer
      }
    ]
  }
  """
  def upload(conn, params) do
    case upload_video_data(params) do
      {:ok, video} ->
        conn
        |> put_status(:created)
        |> json(%{
          success: true,
          video_id: video.id,
          url: "/video/#{video.id}",
          message: "Video uploaded successfully",
          stats: get_upload_stats(video.id)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          success: false,
          errors: format_changeset_errors(changeset)
        })

      {:error, {:invalid_frame_data, message}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          success: false,
          error: message
        })

      {:error, :already_completed} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          success: false,
          error: "video already ingested"
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          success: false,
          error: to_string(reason)
        })
    end
  end

  defp upload_video_data(%{"video" => video_params, "frames" => frames_params} = params) do
    # Captions are optional — a video with frames alone is a valid upload
    captions_params = Map.get(params, "captions") || []

    with {:ok, decoded_frames} <- decode_frames(frames_params),
         {:ok, video} <- find_or_create_video(prepare_video_attrs(video_params)),
         :ok <- ensure_appendable(video, captions_params) do
      Repo.transaction(fn ->
        # Only clear existing data if captions are provided (first batch)
        if length(captions_params) > 0 do
          Video.delete_video_frames(video.id)
          Video.delete_video_captions(video.id)
        end

        # Create captions first (frames reference them) - only if provided
        captions =
          if length(captions_params) > 0 do
            caption_attrs = prepare_captions_attrs(captions_params, video.id)
            create_captions_batch(caption_attrs)
          else
            # Get existing captions for linking
            Video.get_video_captions(video.id)
          end

        # Create frames with image data
        frame_attrs = prepare_frames_attrs(decoded_frames, video.id)
        frames = create_frames_batch(frame_attrs)

        # Link frames to captions based on timestamp overlap
        link_frames_to_captions(frames, captions)

        # Only mark the video completed once every expected frame has arrived;
        # mid-upload multi-batch ingests stay "processing". Legacy single-shot
        # uploads send all frames at once and complete immediately.
        case Video.update_video(video, completion_attrs(video)) do
          {:ok, updated_video} -> updated_video
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  defp upload_video_data(_), do: {:error, "Invalid payload format"}

  defp find_or_create_video(video_attrs) do
    case Video.create_video(video_attrs) do
      {:ok, video} ->
        {:ok, video}

      {:error, changeset} ->
        # Check if it's a duplicate file_path error
        case changeset.errors[:file_path] do
          {"has already been taken", _} ->
            # Find existing video by file_path (multi-batch append)
            case Video.get_video_by_file_path(video_attrs.file_path) do
              nil -> {:error, changeset}
              existing_video -> {:ok, existing_video}
            end

          _ ->
            {:error, changeset}
        end
    end
  end

  # Captions signal a fresh ingest session (existing frames/captions are
  # cleared), so re-uploads are allowed; caption-less appends to a video
  # that already finished are duplicates and get rejected.
  defp ensure_appendable(%{status: "completed"}, [] = _captions_params),
    do: {:error, :already_completed}

  defp ensure_appendable(_video, _captions_params), do: :ok

  defp completion_attrs(video) do
    target = video.frame_count
    inserted_total = Video.count_video_frames(video.id)

    if is_integer(target) and target > 0 and inserted_total < target do
      %{status: "processing"}
    else
      %{status: "completed", processed_at: DateTime.utc_now()}
    end
  end

  defp prepare_video_attrs(video_params) do
    %{
      title: video_params["title"],
      file_path: video_params["file_path"],
      duration_ms: video_params["duration_ms"],
      fps: video_params["fps"],
      frame_count: video_params["frame_count"],
      metadata: video_params["metadata"] || %{},
      status: "processing"
    }
  end

  defp prepare_captions_attrs(captions_params, video_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Enum.map(captions_params, fn caption ->
      %{
        video_id: video_id,
        start_time_ms: caption["start_time_ms"],
        end_time_ms: caption["end_time_ms"],
        text: caption["text"],
        caption_index: caption["caption_index"],
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  # Validates every frame's base64 payload up front so malformed input gets a
  # 422 with a pointer at the offending frame instead of a decode crash.
  defp decode_frames(frames_params) when is_list(frames_params) do
    frames_params
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {frame, index}, {:ok, acc} ->
      case decode_image_data(frame["image_data"]) do
        {:ok, image_data} ->
          {:cont, {:ok, [{frame, image_data} | acc]}}

        :error ->
          n = frame["frame_number"] || index
          {:halt, {:error, {:invalid_frame_data, "frame #{n}: image_data is not valid base64"}}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_frames(_), do: {:error, {:invalid_frame_data, "frames must be a list"}}

  defp decode_image_data(nil), do: {:ok, nil}
  defp decode_image_data(base64) when is_binary(base64), do: Base.decode64(base64)
  defp decode_image_data(_), do: :error

  defp prepare_frames_attrs(decoded_frames, video_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Enum.map(decoded_frames, fn {frame, image_data} ->
      %{
        video_id: video_id,
        frame_number: frame["frame_number"],
        timestamp_ms: frame["timestamp_ms"],
        file_path: frame["file_path"],
        file_size: frame["file_size"],
        width: frame["width"],
        height: frame["height"],
        image_data: image_data,
        compression_ratio: to_float(frame["compression_ratio"]),
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  # insert_all bypasses changeset casting, and JSON clients may send whole
  # floats as integers (e.g. Go marshals 1.0 as 1)
  defp to_float(nil), do: nil
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value

  defp create_captions_batch(caption_attrs) do
    Repo.insert_all(Video.VideoCaption, caption_attrs, returning: true)
    |> elem(1)
  end

  defp create_frames_batch(frame_attrs) do
    Repo.insert_all(Video.VideoFrame, frame_attrs, returning: true)
    |> elem(1)
  end

  defp link_frames_to_captions(frames, captions) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    frame_caption_links =
      for frame <- frames,
          caption <- captions,
          frame_in_caption_timerange?(frame, caption) do
        %{
          frame_id: frame.id,
          caption_id: caption.id,
          inserted_at: now,
          updated_at: now
        }
      end

    if frame_caption_links != [] do
      Repo.insert_all(Video.FrameCaption, frame_caption_links)
    end
  end

  defp frame_in_caption_timerange?(frame, caption) do
    frame.timestamp_ms >= caption.start_time_ms and
      frame.timestamp_ms <= caption.end_time_ms
  end

  defp get_upload_stats(video_id) do
    %{
      frame_count: Video.count_video_frames(video_id),
      caption_count: Video.count_video_captions(video_id),
      frame_caption_links: Video.count_frame_caption_links(video_id)
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
