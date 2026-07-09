// RangePreview hook — live looping preview for the GIF editor stage.
//
// Cycles an <img> through GET /frame/:id URLs of the selected range at the
// chosen fps (frames are browser-cached after the first loop, so playback is
// smooth and free). Also swaps in the caption of the currently shown frame.
//
// Reads from the hook element:
//   data-frames  JSON [{id, url, caption}] — the frames to loop
//   data-fps     playback speed (preview interval = 1000 / fps)
//
// Space (via the KeyboardShortcuts hook) dispatches "framecut:toggle-play"
// on window; the in-stage play/pause button ([data-play-toggle]) does the same
// job via a direct click binding.

const RangePreview = {
  mounted() {
    this.playing = true
    this.idx = 0
    this.timer = null

    this.onToggle = () => this.togglePlay()
    window.addEventListener("framecut:toggle-play", this.onToggle)

    this.bindControls()
    this.reload()
  },

  updated() {
    this.bindControls()
    this.reload()
  },

  destroyed() {
    this.stopTimer()
    window.removeEventListener("framecut:toggle-play", this.onToggle)
  },

  bindControls() {
    this.img = this.el.querySelector("[data-preview-img]")
    this.caption = this.el.querySelector("[data-preview-caption]")
    this.playToggle = this.el.querySelector("[data-play-toggle]")
    this.playIcon = this.el.querySelector("[data-icon-play]")
    this.pauseIcon = this.el.querySelector("[data-icon-pause]")

    if (this.playToggle && !this.playToggle.dataset.bound) {
      this.playToggle.dataset.bound = "true"
      this.playToggle.addEventListener("click", () => this.togglePlay())
    }
  },

  reload() {
    this.stopTimer()

    this.frames = JSON.parse(this.el.dataset.frames || "[]")
    this.fps = parseInt(this.el.dataset.fps, 10) || 10
    this.idx = 0

    // Warm the browser cache so the first loop is already smooth-ish
    for (const frame of this.frames) {
      const img = new Image()
      img.src = frame.url
    }

    this.showFrame()
    this.syncPlayIcon()
    if (this.playing) this.startTimer()
  },

  showFrame() {
    const frame = this.frames[this.idx]
    if (!frame || !this.img) return
    this.img.src = frame.url
    if (this.caption) this.caption.textContent = frame.caption || ""
  },

  startTimer() {
    this.stopTimer()
    if (this.frames.length <= 1) return
    this.timer = setInterval(() => {
      this.idx = (this.idx + 1) % this.frames.length
      this.showFrame()
    }, 1000 / this.fps)
  },

  stopTimer() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  },

  togglePlay() {
    this.playing = !this.playing
    if (this.playing) {
      this.startTimer()
    } else {
      this.stopTimer()
    }
    this.syncPlayIcon()
  },

  syncPlayIcon() {
    if (!this.playIcon || !this.pauseIcon) return
    this.playIcon.classList.toggle("hidden", this.playing)
    this.pauseIcon.classList.toggle("hidden", !this.playing)
  }
}

export default RangePreview
