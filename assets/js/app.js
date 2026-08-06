// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let Hooks = {}

Hooks.CopyInvite = {
  mounted() {
    this.button = this.el.querySelector("[data-copy-button]")
    this.input = this.el.querySelector("input")
    this.status = this.el.querySelector("[data-copy-status]")
    this.button.addEventListener("click", () => this.copy())
  },

  async copy() {
    try {
      await navigator.clipboard.writeText(this.input.value)
    } catch (_error) {
      // Clipboard access is blocked outside a secure context and in some
      // in-app browsers. Selecting the text at least lets the user copy it.
      this.input.focus()
      this.input.select()
      document.execCommand("copy")
    }

    this.status.textContent = "Copied"
    window.clearTimeout(this.resetTimer)
    this.resetTimer = window.setTimeout(() => { this.status.textContent = "" }, 1400)
  },

  destroyed() {
    window.clearTimeout(this.resetTimer)
  }
}

// Keyboard shortcuts for the action bar. Every shortcut clicks a real button,
// so a key can never submit an action the server would reject or that the UI
// has disabled.
const ACTION_KEYS = {
  f: ".act-fold",
  c: ".act-check, .act-call",
  r: ".act-raise",
  a: ".act-allin"
}

Hooks.TableKeys = {
  mounted() {
    this.onKeyDown = (event) => {
      if (event.metaKey || event.ctrlKey || event.altKey) { return }
      if (this.isTyping(event.target)) { return }

      const selector = ACTION_KEYS[event.key.toLowerCase()]
      if (!selector) { return }

      const button = this.el.querySelector(selector)
      if (!button || button.disabled) { return }

      event.preventDefault()
      button.click()
    }

    window.addEventListener("keydown", this.onKeyDown)
  },

  isTyping(target) {
    if (!target) { return false }
    if (target.isContentEditable) { return true }

    return ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown)
  }
}

// Keeps the chat pinned to the newest message unless the reader has scrolled up
// to look at history.
Hooks.StickToBottom = {
  mounted() { this.scrollToBottom() },

  updated() {
    if (this.wasAtBottom) { this.scrollToBottom() }
  },

  beforeUpdate() {
    const slack = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
    this.wasAtBottom = slack < 40
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#e0b054"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
