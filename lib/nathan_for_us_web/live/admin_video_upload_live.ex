defmodule NathanForUsWeb.AdminVideoUploadLive do
  use NathanForUsWeb, :live_view

  import NathanForUsWeb.Components.AdminNav

  alias NathanForUs.{Video, VideoProcessor}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Admin Video Upload")
      |> assign(:uploaded_files, [])
      |> assign(:processing_status, nil)
      |> assign(:processing_progress, 0)
      |> assign(:error_message, nil)
      |> assign(:success_message, nil)
      |> assign(:video_title, "")
      |> assign(:video_description, "")
      |> allow_upload(:video,
        accept: ~w(.mp4 .mov .avi .mkv),
        max_entries: 1,
        # 5GB
        max_file_size: 5_000_000_000
      )
      |> allow_upload(:captions,
        accept: ~w(.srt .vtt),
        max_entries: 1,
        # 10MB
        max_file_size: 10_000_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"video_upload" => params}, socket) do
    socket =
      socket
      |> assign(:video_title, Map.get(params, "title", ""))
      |> assign(:video_description, Map.get(params, "description", ""))

    {:noreply, socket}
  end

  @impl true
  def handle_event("upload", %{"video_upload" => params}, socket) do
    video_title = Map.get(params, "title", "")
    video_description = Map.get(params, "description", "")

    # Validate required fields
    cond do
      video_title == "" ->
        socket = assign(socket, :error_message, "Video title is required")
        {:noreply, socket}

      socket.assigns.uploads.video.entries == [] ->
        socket = assign(socket, :error_message, "Video file is required")
        {:noreply, socket}

      true ->
        # Start processing
        send(self(), {:start_processing, video_title, video_description})

        socket =
          socket
          |> assign(:processing_status, "Starting upload...")
          |> assign(:processing_progress, 0)
          |> assign(:error_message, nil)
          |> assign(:success_message, nil)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :video, ref)}
  end

  @impl true
  def handle_event("cancel-caption-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :captions, ref)}
  end

  @impl true
  def handle_info({:start_processing, title, description}, socket) do
    # Uploads MUST be consumed in the LiveView process, so save the files
    # here before handing the heavy processing off to a task.
    case save_uploads(socket) do
      {:ok, video_file_path, caption_file_path} ->
        lv = self()

        task =
          Task.async(fn ->
            process_video_upload(lv, title, description, video_file_path, caption_file_path)
          end)

        socket =
          socket
          |> assign(:processing_task, task)
          |> assign(:processing_status, "Creating video record...")
          |> assign(:processing_progress, 20)

        {:noreply, socket}

      {:error, message} ->
        socket =
          socket
          |> assign(:processing_status, nil)
          |> assign(:processing_progress, 0)
          |> assign(:error_message, message)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:processing_update, status, progress}, socket) do
    socket =
      socket
      |> assign(:processing_status, status)
      |> assign(:processing_progress, progress)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:processing_complete, result}, socket) do
    case result do
      {:ok, video} ->
        socket =
          socket
          |> assign(:processing_status, "Complete!")
          |> assign(:processing_progress, 100)
          |> assign(
            :success_message,
            "Video '#{video.title}' uploaded and processed successfully!"
          )
          |> assign(:error_message, nil)
          |> reset_form()

        {:noreply, socket}

      {:error, error} ->
        error_text = if is_binary(error), do: error, else: inspect(error)

        socket =
          socket
          |> assign(:processing_status, nil)
          |> assign(:processing_progress, 0)
          |> assign(:error_message, "Processing failed: #{error_text}")
          |> assign(:success_message, nil)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    # Handle task completion
    Process.demonitor(ref, [:flush])
    send(self(), {:processing_complete, result})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    # Task crashed
    socket =
      socket
      |> assign(:processing_status, nil)
      |> assign(:processing_progress, 0)
      |> assign(:error_message, "Processing failed unexpectedly")

    {:noreply, socket}
  end

  defp save_uploads(socket) do
    video_file_path = save_upload_file(socket, :video)
    caption_file_path = maybe_save_caption_file(socket)
    {:ok, video_file_path, caption_file_path}
  rescue
    error ->
      {:error, "Failed to save uploaded files: #{Exception.message(error)}"}
  end

  defp process_video_upload(lv, title, description, video_file_path, caption_file_path) do
    try do
      # Create video record
      video_params = %{
        title: title,
        description: description,
        file_path: video_file_path,
        status: "processing"
      }

      {:ok, video} = Video.create_video(video_params)

      send(lv, {:processing_update, "Processing video frames...", 30})

      # Process video using VideoProcessor
      case VideoProcessor.process_video_with_captions(
             video.id,
             video_file_path,
             caption_file_path
           ) do
        {:ok, _result} ->
          send(lv, {:processing_update, "Finalizing...", 90})

          # Update video status
          Video.update_video(video, %{status: "completed"})

          {:ok, video}

        {:error, reason} ->
          # Update video status to failed
          Video.update_video(video, %{status: "failed"})
          {:error, reason}
      end
    rescue
      error ->
        {:error, "Unexpected error: #{inspect(error)}"}
    end
  end

  defp maybe_save_caption_file(socket) do
    case socket.assigns.uploads.captions.entries do
      [] -> nil
      _entries -> save_upload_file(socket, :captions)
    end
  end

  defp save_upload_file(socket, upload_key) do
    [entry] = socket.assigns.uploads[upload_key].entries

    # Create uploads directory if it doesn't exist
    upload_dir = Path.join([Application.app_dir(:nathan_for_us, "priv"), "uploads"])
    File.mkdir_p!(upload_dir)

    # Generate unique filename
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    filename = "#{timestamp}_#{entry.client_name}"
    file_path = Path.join(upload_dir, filename)

    # Consume upload and save file
    consume_uploaded_entry(socket, entry, fn %{path: temp_path} ->
      File.cp!(temp_path, file_path)
      {:ok, file_path}
    end)
  end

  defp reset_form(socket) do
    socket
    |> assign(:video_title, "")
    |> assign(:video_description, "")
    |> assign(:uploaded_files, [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <.page_header
        title="Upload Video"
        subtitle="Server-side ingest: frames are extracted with ffmpeg on this machine"
      />

      <div class="max-w-7xl mx-auto px-6 py-6">
        <.admin_nav active={:upload} />

        <div class="max-w-3xl">
          <div :if={@error_message} class="card border-l-4 border-l-red-500 p-4 mb-6">
            <p class="font-mono text-sm text-red-700">{@error_message}</p>
          </div>

          <div :if={@success_message} class="card border-l-4 border-l-emerald-500 p-4 mb-6">
            <p class="font-mono text-sm text-emerald-700">{@success_message}</p>
          </div>

          <div :if={@processing_status} class="card p-4 mb-6">
            <p class="font-mono text-sm text-stone-700 mb-2">{@processing_status}</p>
            <div class="w-full bg-stone-100 rounded-full h-2">
              <div
                class="bg-brand h-2 rounded-full transition-all duration-300"
                style={"width: #{@processing_progress}%"}
              >
              </div>
            </div>
            <p class="font-mono text-xs text-stone-500 mt-1">{@processing_progress}% complete</p>
          </div>

          <form phx-submit="upload" phx-change="validate" class="space-y-6">
            <div class="card p-6">
              <h2 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-4">
                Video details
              </h2>

              <div class="space-y-4">
                <div>
                  <label
                    for="title"
                    class="block font-mono uppercase tracking-wider text-xs text-stone-500 mb-1"
                  >
                    Title *
                  </label>
                  <input
                    type="text"
                    name="video_upload[title]"
                    id="title"
                    value={@video_title}
                    class="input"
                    placeholder="Enter video title"
                    required
                  />
                </div>

                <div>
                  <label
                    for="description"
                    class="block font-mono uppercase tracking-wider text-xs text-stone-500 mb-1"
                  >
                    Description
                  </label>
                  <textarea
                    name="video_upload[description]"
                    id="description"
                    rows="3"
                    class="input"
                    placeholder="Enter video description"
                  ><%= @video_description %></textarea>
                </div>
              </div>
            </div>

            <div class="grid md:grid-cols-2 gap-6">
              <!-- Video Upload -->
              <div class="card p-6">
                <h3 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-4">
                  Video file *
                </h3>

                <div
                  class="border-2 border-dashed border-stone-300 rounded-xl p-6 text-center hover:border-stone-400 transition-colors"
                  phx-drop-target={@uploads.video.ref}
                >
                  <span class="hero-film size-10 text-stone-300 mx-auto block mb-3"></span>

                  <label for={@uploads.video.ref} class="cursor-pointer">
                    <span class="font-mono text-sm text-brand-deep hover:text-brand">
                      Choose a video
                    </span>
                    <span class="text-sm text-stone-500">or drag and drop</span>
                  </label>

                  <p class="font-mono text-xs text-stone-400 mt-2">MP4, MOV, AVI, MKV up to 5GB</p>

                  <.live_file_input upload={@uploads.video} class="sr-only" />
                </div>

                <div
                  :for={entry <- @uploads.video.entries}
                  class="mt-4 p-3 bg-stone-100 border border-stone-200 rounded-lg flex items-center justify-between gap-2"
                >
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-stone-900 truncate">{entry.client_name}</p>
                    <p class="font-mono text-xs text-stone-500">
                      {format_file_size(entry.client_size)}
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="cancel-upload"
                    phx-value-ref={entry.ref}
                    class="btn-ghost px-2 py-1"
                    aria-label="Remove video file"
                  >
                    <span class="hero-x-mark-mini size-4"></span>
                  </button>
                </div>
              </div>
              
    <!-- Caption Upload -->
              <div class="card p-6">
                <h3 class="font-mono uppercase tracking-wider text-xs text-stone-500 mb-4">
                  Caption file (optional)
                </h3>

                <div
                  class="border-2 border-dashed border-stone-300 rounded-xl p-6 text-center hover:border-stone-400 transition-colors"
                  phx-drop-target={@uploads.captions.ref}
                >
                  <span class="hero-document-text size-10 text-stone-300 mx-auto block mb-3"></span>

                  <label for={@uploads.captions.ref} class="cursor-pointer">
                    <span class="font-mono text-sm text-brand-deep hover:text-brand">
                      Choose a caption file
                    </span>
                    <span class="text-sm text-stone-500">or drag and drop</span>
                  </label>

                  <p class="font-mono text-xs text-stone-400 mt-2">SRT, VTT up to 10MB</p>

                  <.live_file_input upload={@uploads.captions} class="sr-only" />
                </div>

                <div
                  :for={entry <- @uploads.captions.entries}
                  class="mt-4 p-3 bg-stone-100 border border-stone-200 rounded-lg flex items-center justify-between gap-2"
                >
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-stone-900 truncate">{entry.client_name}</p>
                    <p class="font-mono text-xs text-stone-500">
                      {format_file_size(entry.client_size)}
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="cancel-caption-upload"
                    phx-value-ref={entry.ref}
                    class="btn-ghost px-2 py-1"
                    aria-label="Remove caption file"
                  >
                    <span class="hero-x-mark-mini size-4"></span>
                  </button>
                </div>
              </div>
            </div>

            <div>
              <button type="submit" disabled={@processing_status != nil} class="btn-primary">
                {if @processing_status, do: "Processing...", else: "Upload and process video"}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp format_file_size(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
