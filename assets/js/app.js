// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Client-side GIF generator (admin frame browser)
import ClientGifGenerator from './hooks/client_gif_generator.js'
// Client-side video frame slicer (used by /add)
import VideoFrameSlicer from './hooks/video_frame_slicer.js'
// GIF editor hooks (/video/:id)
import Filmstrip from './hooks/filmstrip.js'
import RangePreview from './hooks/range_preview.js'
import KeyboardShortcuts from './hooks/keyboard_shortcuts.js'

// Import analytics for custom event tracking
import './analytics.js'

let Hooks = {
  ClientGifGenerator,
  VideoFrameSlicer,
  Filmstrip,
  RangePreview,
  KeyboardShortcuts
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#FD4F00"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Copy text to the clipboard when the server pushes a copy_to_clipboard event
// (server side: push_event(socket, "copy_to_clipboard", %{text: ...}))
document.addEventListener("phx:copy_to_clipboard", e => {
  if (e.detail && e.detail.text) {
    navigator.clipboard.writeText(e.detail.text)
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
