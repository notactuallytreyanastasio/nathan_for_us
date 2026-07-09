// KeyboardShortcuts hook — keyboard-first controls for the GIF editor.
//
//   Left/Right   move playhead ±1 frame (Shift = ±10)
//   I / O        set range in/out point at the playhead
//   Space        play/pause the stage preview (client-side, via window event)
//   Enter or G   generate the GIF when the selection is valid
//   Escape       clear the range / close the shortcuts overlay
//   ?            open the shortcuts overlay
//
// Events are ignored while typing in inputs/textareas/selects.

const KeyboardShortcuts = {
  mounted() {
    this.onKeydown = e => {
      const t = e.target
      if (
        t &&
        (t.tagName === "INPUT" ||
          t.tagName === "TEXTAREA" ||
          t.tagName === "SELECT" ||
          t.isContentEditable)
      ) {
        return
      }

      // Let focused buttons/links keep their native Enter/Space activation
      if ((e.key === "Enter" || e.key === " ") && t && (t.tagName === "BUTTON" || t.tagName === "A")) {
        return
      }

      switch (e.key) {
        case "ArrowLeft":
          e.preventDefault()
          this.pushEvent("move_playhead", {delta: e.shiftKey ? -10 : -1})
          break
        case "ArrowRight":
          e.preventDefault()
          this.pushEvent("move_playhead", {delta: e.shiftKey ? 10 : 1})
          break
        case "i":
        case "I":
          this.pushEvent("set_range_point", {point: "in"})
          break
        case "o":
        case "O":
          this.pushEvent("set_range_point", {point: "out"})
          break
        case " ":
          e.preventDefault()
          window.dispatchEvent(new CustomEvent("framecut:toggle-play"))
          break
        case "Enter":
        case "g":
        case "G":
          this.pushEvent("keyboard_generate", {})
          break
        case "Escape":
          this.pushEvent("editor_escape", {})
          break
        case "?":
          this.pushEvent("toggle_shortcuts", {})
          break
      }
    }

    window.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
  }
}

export default KeyboardShortcuts
