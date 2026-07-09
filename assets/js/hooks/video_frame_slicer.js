// Slices an uploaded video into 1fps JPEG frames entirely in the browser
// (hidden <video> + <canvas> capture — no server-side ffmpeg) and streams
// them to AddVideoLive over the LiveView socket.
//
// Protocol (mirrored in lib/nathan_for_us_web/live/add_video_live.ex):
//   push "client_ingest_start"  {title, duration_ms, fps, frame_count, captions_text, filename}
//   recv "ingest_ack"           {video_id}
//   push "client_frame_batch"   {video_id, frames: [{frame_number, timestamp_ms, data, width, height}]}
//   recv "batch_ack"            {video_id, inserted}   -- flow control between batches
//   push "client_ingest_finish" {video_id}             -- server links captions and redirects
//   recv "ingest_error"         {message}              -- any step failed; aborts the run

const BATCH_SIZE = 10;
const MAX_FRAMES = 1800; // 30 minutes at 1fps -- mirrored server-side
const MAX_WIDTH = 640;
const JPEG_QUALITY = 0.85;
const ACK_TIMEOUT_MS = 30000;

const VideoFrameSlicer = {
  mounted() {
    this.titleInput = this.el.querySelector('[data-role="title-input"]');
    this.videoInput = this.el.querySelector('[data-role="video-input"]');
    this.captionsInput = this.el.querySelector('[data-role="captions-input"]');
    this.startButton = this.el.querySelector('[data-role="start"]');
    this.progressWrap = this.el.querySelector('[data-role="progress-wrap"]');
    this.progressBar = this.el.querySelector('[data-role="progress"]');
    this.statusText = this.el.querySelector('[data-role="status"]');

    this.busy = false;
    this.video = null;
    this.objectUrl = null;
    this.pendingAck = null;
    this.abortMessage = null;

    this.startButton.addEventListener('click', () => this.start());

    this.handleEvent('ingest_ack', (payload) => this.resolveAck('ingest_ack', payload));
    this.handleEvent('batch_ack', (payload) => this.resolveAck('batch_ack', payload));
    this.handleEvent('ingest_error', ({ message }) => {
      this.rejectAck(message || 'Upload failed on the server.');
    });
  },

  destroyed() {
    this.cleanupVideo();
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

    this.busy = true;
    this.abortMessage = null;
    this.startButton.disabled = true;
    this.progressWrap.classList.remove('hidden');
    this.setProgress(0, 1);

    try {
      await this.process(file, title);
      // On success the server push_navigates to the editor, destroying this hook.
    } catch (error) {
      console.error('Video slicing failed:', error);
      this.setStatus(`Failed: ${error.message || error}`, true);
      this.busy = false;
      this.startButton.disabled = false;
      this.cleanupVideo();
    }
  },

  async process(file, title) {
    this.setStatus('Reading captions…');
    const captionsFile = this.captionsInput.files && this.captionsInput.files[0];
    const captionsText = captionsFile ? await captionsFile.text() : null;

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
          'slicer caps out at 30 minutes. Use the grabber tool (see the "From YouTube" tab) ' +
          'for long videos.'
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
      captions_text: captionsText,
      filename: file.name
    });
    const { video_id: videoId } = await this.waitForAck('ingest_ack');

    let batch = [];
    for (let i = 0; i < frameCount; i++) {
      this.checkAborted();

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
        this.pushEvent('client_frame_batch', { video_id: videoId, frames: batch });
        await this.waitForAck('batch_ack');
        batch = [];
      }

      this.setProgress(i + 1, frameCount);
      this.setStatus(`Slicing frames… ${i + 1} / ${frameCount}`);
    }

    this.setStatus('Finishing up — linking captions…');
    this.pushEvent('client_ingest_finish', { video_id: videoId });
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
    } else {
      this.setStatus(`Failed: ${message}`, true);
      this.busy = false;
      this.startButton.disabled = false;
    }
  },

  checkAborted() {
    if (this.abortMessage) {
      throw new Error(this.abortMessage);
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

  setProgress(done, total) {
    if (this.progressBar) {
      this.progressBar.max = total;
      this.progressBar.value = done;
    }
  },

  setStatus(message, isError = false) {
    if (this.statusText) {
      this.statusText.textContent = message;
      this.statusText.classList.toggle('text-red-400', isError);
      this.statusText.classList.toggle('text-gray-400', !isError);
    }
  }
};

export default VideoFrameSlicer;
