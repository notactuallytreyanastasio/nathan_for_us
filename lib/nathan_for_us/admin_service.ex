defmodule NathanForUs.AdminService do
  @moduledoc """
  Service module providing business logic for administrative operations.

  This module handles all admin-related business logic separate from LiveView concerns:

  - User access validation and authorization
  - Administrative statistics collection
  - FFMPEG availability checks and GIF generation
  """

  alias NathanForUs.Admin

  @doc """
  Validates admin access for a user.
  """
  @spec validate_admin_access(term()) :: :ok | {:error, :access_denied}
  def validate_admin_access(user) do
    if Admin.is_admin?(user) do
      :ok
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Gets comprehensive admin statistics.
  """
  @spec get_admin_stats() :: map()
  def get_admin_stats do
    try do
      Admin.get_stats()
      |> Map.put(:last_updated, DateTime.utc_now())
    rescue
      error ->
        %{error: Exception.message(error)}
    end
  end

  @doc """
  Generates usernames for all users without usernames based on their email.
  """
  @spec generate_usernames_from_emails() :: {:ok, integer()} | {:error, String.t()}
  def generate_usernames_from_emails do
    try do
      result = Admin.generate_usernames_from_emails()
      {:ok, result}
    rescue
      error ->
        {:error, Exception.message(error)}
    end
  end

  @doc """
  Tests if FFMPEG is available and accessible in the system PATH.
  """
  @spec test_ffmpeg_availability() :: {:ok, String.t()} | {:error, String.t()}
  def test_ffmpeg_availability do
    try do
      case System.cmd("which", ["ffmpeg"]) do
        {path, 0} ->
          path = String.trim(path)

          case System.cmd("ffmpeg", ["-version"]) do
            {version_output, 0} ->
              # Extract version from first line
              version_line = version_output |> String.split("\n") |> List.first()
              {:ok, "FFMPEG found at #{path}. #{version_line}"}

            {error_output, _exit_code} ->
              {:error, "FFMPEG found at #{path} but failed to get version: #{error_output}"}
          end

        {_output, _exit_code} ->
          {:error, "FFMPEG not found in system PATH"}
      end
    rescue
      error ->
        {:error, "Error testing FFMPEG: #{Exception.message(error)}"}
    end
  end

  @doc """
  Generates a GIF from selected frame sequence using FFMPEG.

  Takes a frame sequence and selected frame indices, extracts the frames
  in order, and creates an animated GIF with appropriate framerate based
  on the source video's timing.
  """
  @spec generate_gif_from_frames(map(), list()) :: {:ok, binary()} | {:error, String.t()}
  def generate_gif_from_frames(frame_sequence, selected_frame_indices) do
    try do
      # Validate inputs
      if Enum.empty?(selected_frame_indices) do
        {:error, "No frames selected for GIF generation"}
      else
        # Create temporary directory for frame processing
        temp_dir =
          System.tmp_dir!() |> Path.join("gif_generation_#{:os.system_time(:millisecond)}")

        File.mkdir_p!(temp_dir)

        try do
          # Extract selected frames and write to temp files
          frame_paths =
            extract_selected_frames_to_temp(frame_sequence, selected_frame_indices, temp_dir)

          # Calculate framerate from video metadata or timestamps
          framerate = calculate_gif_framerate(frame_sequence, selected_frame_indices)

          # Generate GIF using FFMPEG
          generate_gif_with_ffmpeg(frame_paths, framerate, temp_dir)
        after
          # Clean up temp directory
          File.rm_rf(temp_dir)
        end
      end
    rescue
      error ->
        {:error, "GIF generation failed: #{Exception.message(error)}"}
    end
  end

  # Private helper functions for GIF generation

  defp extract_selected_frames_to_temp(frame_sequence, selected_frame_indices, temp_dir) do
    selected_frame_indices
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.map(fn {frame_index, output_index} ->
      frame = Enum.at(frame_sequence.sequence_frames, frame_index)

      if frame && frame.image_data do
        # Decode image data and write to temp file
        # FFmpeg expects 1-based numbering, so add 1 to output_index
        output_path =
          Path.join(
            temp_dir,
            "frame_#{String.pad_leading(to_string(output_index + 1), 4, "0")}.jpg"
          )

        image_binary = decode_frame_image_data(frame.image_data)
        File.write!(output_path, image_binary)

        require Logger
        Logger.debug("Created frame file: #{output_path}")
        output_path
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_frame_image_data(hex_data) when is_binary(hex_data) do
    # The image data is stored as hex-encoded string starting with \x
    case String.starts_with?(hex_data, "\\x") do
      true ->
        # Remove the \x prefix and decode from hex
        hex_string = String.slice(hex_data, 2..-1//1)

        case Base.decode16(hex_string, case: :lower) do
          {:ok, binary_data} -> binary_data
          :error -> <<>>
        end

      false ->
        # Already binary data
        hex_data
    end
  end

  defp calculate_gif_framerate(frame_sequence, selected_frame_indices) do
    # Use the actual timestamp differences to maintain real-life timing
    calculate_framerate_from_timestamps(frame_sequence, selected_frame_indices)
  end

  defp calculate_framerate_from_timestamps(frame_sequence, selected_frame_indices) do
    if length(selected_frame_indices) < 2 do
      # Single frame gets reasonable default
      4.0
    else
      selected_frames =
        selected_frame_indices
        |> Enum.sort()
        |> Enum.map(&Enum.at(frame_sequence.sequence_frames, &1))
        |> Enum.reject(&is_nil/1)

      if length(selected_frames) >= 2 do
        # Calculate average time difference between frames
        timestamps = Enum.map(selected_frames, &Map.get(&1, :timestamp_ms, 0))

        time_diffs =
          timestamps
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [t1, t2] -> t2 - t1 end)
          |> Enum.reject(&(&1 <= 0))

        if Enum.empty?(time_diffs) do
          # Default fallback
          4.0
        else
          avg_diff_ms = Enum.sum(time_diffs) / length(time_diffs)

          # Since frames are extracted at 1fps (1000ms intervals) from 30fps source,
          # we need to play them faster to feel natural
          # Think of it as "key moments" that should flow smoothly
          cond do
            avg_diff_ms >= 1000 ->
              # 1-second extracted intervals: play at 4-6 fps for smooth flow
              5.0

            avg_diff_ms >= 500 ->
              # 0.5-second intervals: play at 3-4 fps
              4.0

            avg_diff_ms >= 200 ->
              # Faster extractions: moderate speed
              3.0

            true ->
              # Very fast extractions: calculate normally
              fps = 1000.0 / avg_diff_ms
              min(max(fps, 2.0), 8.0)
          end
        end
      else
        # Default fallback
        4.0
      end
    end
  end

  defp generate_gif_with_ffmpeg(frame_paths, framerate, temp_dir) do
    if Enum.empty?(frame_paths) do
      {:error, "No valid frames to process"}
    else
      require Logger
      Logger.info("Generating GIF with #{length(frame_paths)} frames at #{framerate} fps")
      output_path = Path.join(temp_dir, "output.gif")
      palette_path = Path.join(temp_dir, "palette.png")
      # Use 1-based numbering pattern to match our file naming
      input_pattern = Path.join(temp_dir, "frame_%04d.jpg")

      # Step 1: Generate optimized palette
      palette_args = [
        # Overwrite output file
        "-y",
        "-framerate",
        Float.to_string(framerate),
        # Start numbering from 1
        "-start_number",
        "1",
        "-i",
        input_pattern,
        "-vf",
        "scale=640:-1:flags=lanczos,palettegen=max_colors=256:reserve_transparent=0",
        palette_path
      ]

      Logger.info("Running palette generation: ffmpeg #{Enum.join(palette_args, " ")}")

      case System.cmd("ffmpeg", palette_args, stderr_to_stdout: true) do
        {_palette_output, 0} ->
          # Step 2: Create GIF using the generated palette
          gif_args = [
            # Overwrite output file
            "-y",
            "-framerate",
            Float.to_string(framerate),
            # Start numbering from 1
            "-start_number",
            "1",
            "-i",
            input_pattern,
            "-i",
            palette_path,
            "-lavfi",
            "scale=640:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5",
            "-r",
            Float.to_string(framerate),
            output_path
          ]

          Logger.info("Running GIF generation: ffmpeg #{Enum.join(gif_args, " ")}")

          case System.cmd("ffmpeg", gif_args, stderr_to_stdout: true) do
            {_gif_output, 0} ->
              # Read the generated GIF file
              case File.read(output_path) do
                {:ok, gif_data} ->
                  {:ok, gif_data}

                {:error, reason} ->
                  {:error, "Failed to read generated GIF: #{reason}"}
              end

            {error_output, exit_code} ->
              {:error, "GIF creation failed (exit code #{exit_code}): #{error_output}"}
          end

        {error_output, exit_code} ->
          {:error, "Palette generation failed (exit code #{exit_code}): #{error_output}"}
      end
    end
  end
end
