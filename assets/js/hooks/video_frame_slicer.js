// Slices an uploaded video into 1fps JPEG frames entirely in the browser
// (hidden <video> + <canvas> capture — no server-side ffmpeg) and streams
// them to AddVideoLive over the LiveView socket.
//
// Protocol (mirrored in lib/nathan_for_us_web/live/add_video_live.ex):
//   push "client_ingest_start"  {title, duration_ms, fps, frame_count, captions_text, filename}
//   recv "ingest_ack"           {video_id}
//   push "client_frame_batch"   {video_id, frames: [{frame_number, timestamp_ms, data, width, height}]}
//   recv "batch_ack"            {video_id, inserted}   -- flow control between batches
//   push "client_ingest_finish" {video_id}             -- server links captions
//   recv "finish_ack"           {video_id}             -- then redirects
//   push "client_ingest_resume" {video_id, captions_text} -- after socket reconnect
//   recv "ingest_ack"           {video_id, resume_from}   -- re-slice from this frame
//   push "client_ingest_cancel" {video_id}             -- deletes the partial video
//   recv "ingest_error"         {message}              -- any step failed; aborts the run

const BATCH_SIZE = 10;
const MAX_FRAMES = 1800; // 30 minutes at 1fps -- mirrored server-side
const MAX_WIDTH = 640;
const JPEG_QUALITY = 0.85;
const ACK_TIMEOUT_MS = 30000;
const EST_BYTES_PER_FRAME = 60 * 1024; // rough JPEG-at-640px estimate
const ETA_WINDOW = 30; // frames in the rolling frames/sec window

const VideoFrameSlicer = {
  mounted() {
    const q = (role) => this.el.querySelector(`[data-role="${role}"]`);

    this.titleInput = q('title-input');
    this.videoInput = q('video-input');
    this.captionsInput = q('captions-input');
    this.dropzone = q('dropzone');
    this.previewWrap = q('preview-wrap');
    this.preview = q('preview');
    this.stats = q('stats');
    this.capError = q('cap-error');
    this.capErrorText = q('cap-error-text');
    this.captionsInfo = q('captions-info');
    this.startButton = q('start');
    this.startLabel = q('start-label');
    this.spinner = q('spinner');
    this.cancelButton = q('cancel');
    this.progressWrap = q('progress-wrap');
    this.progressFill = q('progress-fill');
    this.progressText = q('progress-text');
    this.statusText = q('status');

    this.busy = false;
    this.cancelled = false;
    this.overCap = false;
    this.videoId = null;
    this.captionsText = null;
    this.video = null;
    this.objectUrl = null;
    this.previewUrl = null;
    this.pendingAck = null;
    this.pendingResume = null;
    this.abortMessage = null;
    this.frameTimes = [];

    // Dropzone: click/keyboard to browse, drag-and-drop to select.
    this.dropzone.addEventListener('click', () => {
      if (!this.busy) this.videoInput.click();
    });
    this.dropzone.addEventListener('keydown', (event) => {
      if (this.busy) return;
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        this.videoInput.click();
      }
    });
    ['dragenter', 'dragover'].forEach((name) => {
      this.dropzone.addEventListener(name, (event) => {
        event.preventDefault();
        if (this.busy) return;
        this.dropzone.classList.add('border-brand', 'bg-brand-tint/40');
      });
    });
    this.dropzone.addEventListener('dragleave', () => {
      this.dropzone.classList.remove('border-brand', 'bg-brand-tint/40');
    });
    this.dropzone.addEventListener('drop', (event) => {
      event.preventDefault();
      this.dropzone.classList.remove('border-brand', 'bg-brand-tint/40');
      if (this.busy) return;
      const files = event.dataTransfer && event.dataTransfer.files;
      if (files && files.length > 0) {
        this.videoInput.files = files;
        this.onFileSelected();
      }
    });

    this.videoInput.addEventListener('change', () => this.onFileSelected());
    this.captionsInput.addEventListener('change', () => this.onCaptionsSelected());
    this.startButton.addEventListener('click', () => this.start());
    this.cancelButton.addEventListener('click', () => this.cancel());

    this.beforeUnload = (event) => {
      if (this.busy) {
        event.preventDefault();
        event.returnValue = 'Your upload is still in progress';
      }
    };
    window.addEventListener('beforeunload', this.beforeUnload);

    this.handleEvent('ingest_ack', (payload) => {
      if (payload && payload.resume_from != null && this.busy && this.videoId != null) {
        this.requestResume(payload.resume_from);
      } else {
        this.resolveAck('ingest_ack', payload);
      }
    });
    this.handleEvent('batch_ack', (payload) => this.resolveAck('batch_ack', payload));
    this.handleEvent('finish_ack', (payload) => this.resolveAck('finish_ack', payload));
    this.handleEvent('ingest_error', ({ message }) => {
      this.rejectAck(message || 'Upload failed on the server.');
    });
  },

  // Fires when the LiveView socket re-establishes after a disconnect (deploy,
  // network blip, phone lock). The server remounted with no ingest state, so
  // ask it to re-adopt the video; it answers with ingest_ack{resume_from}.
  reconnected() {
    if (!this.busy || this.videoId == null) return;
    this.setStatus('Reconnected — resuming upload…');
    this.pushEvent('client_ingest_resume', {
      video_id: this.videoId,
      captions_text: this.captionsText
    });
  },

  destroyed() {
    window.removeEventListener('beforeunload', this.beforeUnload);
    this.cleanupVideo();
    if (this.previewUrl) {
      URL.revokeObjectURL(this.previewUrl);
      this.previewUrl = null;
    }
  },

  // --- file selection --------------------------------------------------------

  async onFileSelected() {
    const file = this.videoInput.files && this.videoInput.files[0];
    if (!file) return;

    this.overCap = false;
    this.capError.classList.add('hidden');
    this.startButton.disabled = false;
    this.setStatus('');

    // Auto-fill the title from the filename when the field is empty.
    if (!(this.titleInput.value || '').trim()) {
      this.titleInput.value = file.name
        .replace(/\.[^.]+$/, '')
        .replace(/_+/g, ' ')
        .trim();
    }

    // Muted looping preview.
    if (this.previewUrl) URL.revokeObjectURL(this.previewUrl);
    this.previewUrl = URL.createObjectURL(file);
    this.preview.src = this.previewUrl;
    this.previewWrap.classList.remove('hidden');
    this.preview.play().catch(() => {});

    await new Promise((resolve) => {
      if (this.preview.readyState >= 1) {
        resolve();
      } else {
        this.preview.addEventListener('loadedmetadata', resolve, { once: true });
        this.preview.addEventListener('error', resolve, { once: true });
      }
    });

    const duration = this.preview.duration;
    if (!isFinite(duration) || duration <= 0) {
      this.stats.textContent = 'Could not read video metadata — you can still try slicing.';
      return;
    }

    const frameCount = Math.max(1, Math.ceil(duration));
    const parts = [
      `duration ${this.formatDuration(Math.round(duration))}`,
      `${frameCount} / ${MAX_FRAMES} frames`
    ];
    if (this.preview.videoWidth && this.preview.videoHeight) {
      parts.push(`${this.preview.videoWidth}×${this.preview.videoHeight}`);
    }
    parts.push(`~${this.formatBytes(frameCount * EST_BYTES_PER_FRAME)} upload`);
    this.stats.textContent = parts.join(' · ');

    if (frameCount > MAX_FRAMES) {
      this.overCap = true;
      this.startButton.disabled = true;
      this.capErrorText.textContent =
        `This video needs ${frameCount} frames — the in-browser slicer caps out at ` +
        `${MAX_FRAMES} (30 minutes).`;
      this.capError.classList.remove('hidden');
    }
  },

  async onCaptionsSelected() {
    const file = this.captionsInput.files && this.captionsInput.files[0];
    if (!file) {
      this.captionsInfo.classList.add('hidden');
      return;
    }

    const text = await file.text();
    const cues = (text.match(/-->/g) || []).length;
    this.captionsInfo.classList.remove('hidden');
    this.captionsInfo.classList.toggle('text-amber-600', cues === 0);
    this.captionsInfo.classList.toggle('text-stone-500', cues > 0);
    this.captionsInfo.textContent =
      cues > 0
        ? `${cues} captions detected`
        : 'No captions detected in this file — the video will be added without captions.';
  },

  // --- main flow -----------------------------------------------------------

  async start() {
    if (this.busy) return;

    const file = this.videoInput.files && this.videoInput.files[0];
    const title = (this.titleInput.value || '').trim();

    if (!file) {
      this.setStatus('Choose a video file first.', true);
      return;
    }
    if (!title) {
      this.setStatus('Give the video a title first.', true);
      return;
    }
    if (this.overCap) {
      this.setStatus('This video is over the 30-minute cap — use the CLI grabber instead.', true);
      return;
    }

    this.busy = true;
    this.cancelled = false;
    this.abortMessage = null;
    this.pendingResume = null;
    this.videoId = null;
    this.frameTimes = [];
    this.setBusyUi(true);
    this.setBar(0, 'brand');
    this.progressText.textContent = '';
    this.progressWrap.classList.remove('hidden');

    try {
      await this.process(file, title);
      // On success the server push_navigates to the editor, destroying this hook.
    } catch (error) {
      if (this.cancelled) return; // cancel() already reset the UI
      console.error('Video slicing failed:', error);
      this.setStatus(`Failed: ${error.message || error}`, true);
      // Don't strand a duplicate "processing" record if the user retries.
      this.pushCancel();
      this.resetAfterRun();
    }
  },

  async process(file, title) {
    this.setStatus('Reading captions…');
    const captionsFile = this.captionsInput.files && this.captionsInput.files[0];
    this.captionsText = captionsFile ? await captionsFile.text() : null;

    this.setStatus('Loading video metadata…');
    const video = await this.loadVideo(file);

    const duration = video.duration;
    if (!isFinite(duration) || duration <= 0) {
      throw new Error(
        'Could not read the video duration. Try a different file (mp4/webm work best).'
      );
    }

    const frameCount = Math.max(1, Math.ceil(duration));
    if (frameCount > MAX_FRAMES) {
      throw new Error(
        `This video is about ${Math.round(duration / 60)} minutes long — the in-browser ` +
          'slicer caps out at 30 minutes. Use the "From a URL (CLI)" tab for long videos.'
      );
    }

    // Prime decoding -- some mobile browsers refuse canvas capture until
    // playback has started at least once.
    try {
      await video.play();
      video.pause();
    } catch (_error) {
      // Autoplay restrictions are fine; seeking still works.
    }

    const scale = Math.min(1, MAX_WIDTH / (video.videoWidth || MAX_WIDTH));
    const width = Math.max(1, Math.round(video.videoWidth * scale));
    const height = Math.max(1, Math.round(video.videoHeight * scale));

    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');

    this.setStatus('Registering video…');
    this.pushEvent('client_ingest_start', {
      title: title,
      duration_ms: Math.round(duration * 1000),
      fps: 1,
      frame_count: frameCount,
      captions_text: this.captionsText,
      filename: file.name
    });
    const ack = await this.waitForAck('ingest_ack');
    this.videoId = ack.video_id;

    // The slicing loop, restartable after a reconnect: frame i is second i,
    // so re-slicing from the server's acked count is deterministic.
    let from = 0;
    for (;;) {
      try {
        await this.sliceFrom(from, { video, ctx, canvas, width, height, duration, frameCount });
        return;
      } catch (error) {
        if (error && error.resumeFrom != null) {
          from = error.resumeFrom;
          this.frameTimes = [];
          this.setBar(Math.round((from / frameCount) * 100), 'brand');
          this.setStatus(`Resuming from frame ${from}…`);
          continue;
        }
        throw error;
      }
    }
  },

  async sliceFrom(startFrame, s) {
    const { video, ctx, canvas, width, height, duration, frameCount } = s;

    let batch = [];
    for (let i = startFrame; i < frameCount; i++) {
      this.checkAborted();
      this.checkResume();

      // Clamp the last frame slightly inside the file so the seek lands.
      const t = Math.min(i, Math.max(0, duration - 0.05));
      await this.seekTo(video, t);
      ctx.drawImage(video, 0, 0, width, height);

      const dataUrl = canvas.toDataURL('image/jpeg', JPEG_QUALITY);
      batch.push({
        frame_number: i,
        timestamp_ms: i * 1000,
        data: dataUrl.split(',')[1],
        width: width,
        height: height
      });

      if (batch.length >= BATCH_SIZE || i === frameCount - 1) {
        this.pushEvent('client_frame_batch', { video_id: this.videoId, frames: batch });
        await this.waitForAck('batch_ack');
        batch = [];
      }

      this.noteFrameDone();
      this.setProgress(i + 1, frameCount);
    }

    // Finish step: freeze the bar at 100% in emerald while the server links
    // captions, and wait for its ack so a stall surfaces instead of hanging.
    this.setBar(100, 'emerald');
    this.progressText.textContent = '';
    this.setStatus('Finishing up — linking captions…');
    this.pushEvent('client_ingest_finish', { video_id: this.videoId });
    await this.waitForAck('finish_ack');
  },

  cancel() {
    if (!this.busy) return;

    this.cancelled = true;
    this.busy = false;
    this.abortMessage = 'Upload cancelled.';
    if (this.pendingAck) {
      const { reject } = this.pendingAck;
      this.pendingAck = null;
      reject(new Error('Upload cancelled.'));
    }
    this.pushCancel();
    this.setBusyUi(false);
    this.cleanupVideo();
    this.setBar(0, 'brand');
    this.progressText.textContent = '';
    this.progressWrap.classList.add('hidden');
    this.setStatus('Upload cancelled.');
  },

  pushCancel() {
    const id = this.videoId;
    this.videoId = null;
    if (id != null) {
      try {
        this.pushEvent('client_ingest_cancel', { video_id: id });
      } catch (_error) {
        // Socket may be down; the record is cleaned up on the next resume attempt.
      }
    }
  },

  resetAfterRun() {
    this.busy = false;
    this.setBusyUi(false);
    this.cleanupVideo();
  },

  // --- ack plumbing (server replies via push_event) -------------------------

  waitForAck(kind) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingAck = null;
        reject(
          new Error('The server stopped responding — check your connection and try again.')
        );
      }, ACK_TIMEOUT_MS);

      this.pendingAck = {
        kind,
        resolve: (payload) => {
          clearTimeout(timer);
          resolve(payload);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        }
      };
    });
  },

  resolveAck(kind, payload) {
    if (this.pendingAck && this.pendingAck.kind === kind) {
      const { resolve } = this.pendingAck;
      this.pendingAck = null;
      resolve(payload);
    }
  },

  rejectAck(message) {
    this.abortMessage = message;
    if (this.pendingAck) {
      const { reject } = this.pendingAck;
      this.pendingAck = null;
      reject(new Error(message));
    } else if (!this.busy) {
      this.setStatus(`Failed: ${message}`, true);
    }
    // While busy with no pending ack, the slicing loop picks the message up
    // via checkAborted() on its next iteration.
  },

  requestResume(from) {
    const error = new Error('resuming');
    error.resumeFrom = from;
    if (this.pendingAck) {
      const { reject } = this.pendingAck;
      this.pendingAck = null;
      reject(error);
    } else {
      this.pendingResume = from;
    }
  },

  checkAborted() {
    if (this.abortMessage) {
      throw new Error(this.abortMessage);
    }
  },

  checkResume() {
    if (this.pendingResume != null) {
      const from = this.pendingResume;
      this.pendingResume = null;
      const error = new Error('resuming');
      error.resumeFrom = from;
      throw error;
    }
  },

  // --- video helpers ---------------------------------------------------------

  loadVideo(file) {
    return new Promise((resolve, reject) => {
      this.cleanupVideo();

      const video = document.createElement('video');
      video.preload = 'auto';
      video.muted = true;
      video.playsInline = true;
      video.setAttribute('playsinline', '');

      const onLoaded = () => {
        cleanup();
        resolve(video);
      };
      const onError = () => {
        cleanup();
        reject(new Error('Your browser could not decode this file as a video.'));
      };
      const cleanup = () => {
        video.removeEventListener('loadedmetadata', onLoaded);
        video.removeEventListener('error', onError);
      };

      video.addEventListener('loadedmetadata', onLoaded);
      video.addEventListener('error', onError);

      this.objectUrl = URL.createObjectURL(file);
      this.video = video;
      video.src = this.objectUrl;
    });
  },

  seekTo(video, t) {
    return new Promise((resolve, reject) => {
      // Some browsers skip the seek algorithm when the time doesn't change.
      if (Math.abs(video.currentTime - t) < 0.001 && video.readyState >= 2) {
        resolve();
        return;
      }

      const onSeeked = () => {
        cleanup();
        resolve();
      };
      const onError = () => {
        cleanup();
        reject(new Error('The video stopped decoding mid-slice.'));
      };
      const cleanup = () => {
        video.removeEventListener('seeked', onSeeked);
        video.removeEventListener('error', onError);
      };

      video.addEventListener('seeked', onSeeked);
      video.addEventListener('error', onError);
      video.currentTime = t;
    });
  },

  cleanupVideo() {
    if (this.video) {
      this.video.removeAttribute('src');
      this.video.load();
      this.video = null;
    }
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl);
      this.objectUrl = null;
    }
  },

  // --- UI helpers ------------------------------------------------------------

  setBusyUi(busy) {
    this.startButton.disabled = busy || this.overCap;
    this.startLabel.textContent = busy ? 'SLICING…' : 'SLICE + UPLOAD';
    this.spinner.classList.toggle('hidden', !busy);
    this.cancelButton.classList.toggle('hidden', !busy);
    this.titleInput.disabled = busy;
    this.videoInput.disabled = busy;
    this.captionsInput.disabled = busy;
  },

  setBar(percent, color) {
    this.progressFill.style.width = `${percent}%`;
    this.progressFill.classList.toggle('bg-brand', color === 'brand');
    this.progressFill.classList.toggle('bg-emerald-500', color === 'emerald');
  },

  noteFrameDone() {
    this.frameTimes.push(performance.now());
    if (this.frameTimes.length > ETA_WINDOW) this.frameTimes.shift();
  },

  setProgress(done, total) {
    const percent = total > 0 ? Math.round((done / total) * 100) : 0;
    this.setBar(percent, 'brand');

    let eta = '';
    if (this.frameTimes.length >= 2) {
      const elapsedMs = this.frameTimes[this.frameTimes.length - 1] - this.frameTimes[0];
      const rate = (this.frameTimes.length - 1) / (elapsedMs / 1000);
      if (rate > 0) {
        const secondsLeft = Math.max(0, Math.round((total - done) / rate));
        eta = ` · ~${this.formatDuration(secondsLeft)} left`;
      }
    }

    this.progressText.textContent = `frame ${done} / ${total} · ${percent}%${eta}`;
    this.setStatus('Slicing frames…');
  },

  formatDuration(totalSeconds) {
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    return `${minutes}:${String(seconds).padStart(2, '0')}`;
  },

  formatBytes(bytes) {
    const mb = bytes / (1024 * 1024);
    if (mb >= 100) return `${Math.round(mb)} MB`;
    if (mb >= 1) return `${mb.toFixed(1)} MB`;
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  },

  setStatus(message, isError = false) {
    if (this.statusText) {
      this.statusText.textContent = message;
      this.statusText.classList.toggle('text-red-600', isError);
      this.statusText.classList.toggle('text-stone-500', !isError);
    }
  }
};

export default VideoFrameSlicer;
