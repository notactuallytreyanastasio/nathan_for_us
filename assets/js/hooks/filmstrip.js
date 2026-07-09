// Filmstrip hook — single pointer-based interaction model for the GIF editor.
//
// Handles, entirely client-side during the gesture:
//   * click on a slot        -> set the playhead
//   * drag across slots      -> select a frame range
//   * drag an IN/OUT handle  -> resize the current range
//   * click/drag the minimap -> scroll the strip proportionally
//
// On pointerup exactly ONE event is pushed to the server:
//   set_playhead  {frame_number}                      (plain click)
//   select_range  {start_frame_number, end_frame_number} (drag / handle)
// Numbers are sent as numbers, never strings.
//
// The server also pushes "filmstrip:scroll_to" {index} to center a slot.

const PREVIEW_OUTLINE = "2px solid #FD4F00"

const Filmstrip = {
  mounted() {
    this.strip = this.el.querySelector("[data-strip]")
    this.track = this.el.querySelector("[data-track]")
    this.minimap = this.el.querySelector("[data-minimap]")
    this.gesture = null
    this.rafPending = false
    this.lastPointer = null
    this.painted = []

    this.refreshSlots()

    this.onPointerDown = e => this.pointerDown(e)
    this.onPointerMove = e => this.pointerMove(e)
    this.onPointerUp = e => this.pointerUp(e)
    this.onPointerCancel = () => this.cancelGesture()
    this.onMinimapDown = e => this.minimapDown(e)

    this.strip.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerCancel)
    if (this.minimap) this.minimap.addEventListener("pointerdown", this.onMinimapDown)

    this.handleEvent("filmstrip:scroll_to", ({index}) => this.scrollToIndex(index))
  },

  updated() {
    this.refreshSlots()
  },

  destroyed() {
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerCancel)
  },

  // Browser took over (e.g. touch pan) — abandon the gesture quietly
  cancelGesture() {
    this.gesture = null
    this.clearPaint()
  },

  refreshSlots() {
    this.slots = Array.from(this.track.querySelectorAll("[data-slot-idx]"))
    const first = this.slots[0]
    this.slotWidth = (first && first.offsetWidth) || 112
  },

  frameNumberAt(idx) {
    const slot = this.slots[idx]
    return slot ? parseInt(slot.dataset.frameNumber, 10) : null
  },

  indexFromPointer(e) {
    if (this.slots.length === 0) return 0
    const rect = this.strip.getBoundingClientRect()
    const clamped = Math.min(Math.max(e.clientX, rect.left), rect.right)
    const x = clamped - rect.left + this.strip.scrollLeft
    const idx = Math.floor(x / this.slotWidth)
    return Math.min(Math.max(idx, 0), this.slots.length - 1)
  },

  pointerDown(e) {
    if (e.pointerType === "mouse" && e.button !== 0) return
    if (this.slots.length === 0) return

    const handle = e.target.closest("[data-handle]")

    if (handle) {
      this.gesture = {
        type: "handle",
        handle: handle.dataset.handle,
        selStart: parseInt(this.el.dataset.selStart, 10),
        selEnd: parseInt(this.el.dataset.selEnd, 10),
        moved: true
      }
      this.gesture.range = [this.gesture.selStart, this.gesture.selEnd]
    } else {
      const idx = this.indexFromPointer(e)
      this.gesture = {type: "select", anchor: idx, current: idx, moved: false, range: [idx, idx]}
    }

    this.lastPointer = e
    e.preventDefault()
  },

  pointerMove(e) {
    if (!this.gesture) return
    this.lastPointer = e
    if (this.rafPending) return
    this.rafPending = true
    requestAnimationFrame(() => {
      this.rafPending = false
      if (!this.gesture || !this.lastPointer) return
      this.applyPointer(this.lastPointer)
    })
  },

  applyPointer(e) {
    const g = this.gesture
    const idx = this.indexFromPointer(e)

    if (g.type === "select") {
      if (idx !== g.anchor) g.moved = true
      g.current = idx
      g.range = [Math.min(g.anchor, idx), Math.max(g.anchor, idx)]
    } else if (g.type === "handle") {
      if (g.handle === "in") {
        g.range = [Math.min(idx, g.selEnd), g.selEnd]
      } else {
        g.range = [g.selStart, Math.max(idx, g.selStart)]
      }
    }

    if (g.moved) this.paintRange(g.range[0], g.range[1])
    this.edgeScroll(e)
  },

  // Nudge the strip when dragging near its edges so long selections are possible
  edgeScroll(e) {
    const rect = this.strip.getBoundingClientRect()
    if (e.clientX > rect.right - 48) {
      this.strip.scrollLeft += 24
    } else if (e.clientX < rect.left + 48) {
      this.strip.scrollLeft -= 24
    }
  },

  paintRange(a, b) {
    this.clearPaint()
    for (let i = a; i <= b && i < this.slots.length; i++) {
      const slot = this.slots[i]
      if (!slot) continue
      slot.style.outline = PREVIEW_OUTLINE
      slot.style.outlineOffset = "-2px"
      this.painted.push(slot)
    }
  },

  clearPaint() {
    for (const slot of this.painted) {
      slot.style.outline = ""
      slot.style.outlineOffset = ""
    }
    this.painted = []
  },

  pointerUp(e) {
    if (!this.gesture) return
    const g = this.gesture
    this.gesture = null
    this.clearPaint()

    if (g.type === "select" && !g.moved) {
      const frameNumber = this.frameNumberAt(g.anchor)
      if (frameNumber !== null) this.pushEvent("set_playhead", {frame_number: frameNumber})
      return
    }

    const [a, b] = g.range
    const startFrame = this.frameNumberAt(a)
    const endFrame = this.frameNumberAt(b)
    if (startFrame !== null && endFrame !== null) {
      this.pushEvent("select_range", {
        start_frame_number: startFrame,
        end_frame_number: endFrame
      })
    }
  },

  minimapDown(e) {
    if (e.pointerType === "mouse" && e.button !== 0) return
    const move = ev => this.minimapScroll(ev)
    const up = () => {
      window.removeEventListener("pointermove", move)
      window.removeEventListener("pointerup", up)
    }
    window.addEventListener("pointermove", move)
    window.addEventListener("pointerup", up)
    this.minimapScroll(e)
    e.preventDefault()
  },

  minimapScroll(e) {
    const rect = this.minimap.getBoundingClientRect()
    const frac = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1)
    const target = frac * this.strip.scrollWidth - this.strip.clientWidth / 2
    this.strip.scrollLeft = Math.max(0, target)
  },

  scrollToIndex(index) {
    if (typeof index !== "number") return
    const target = index * this.slotWidth - this.strip.clientWidth / 2 + this.slotWidth / 2
    this.strip.scrollTo({left: Math.max(0, target), behavior: "smooth"})
  }
}

export default Filmstrip
