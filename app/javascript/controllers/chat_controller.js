import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["messages", "input", "form", "suggestions"]

  connect() {
    this.observeMessages()
    this.scrollToBottom()
  }

  suggest(event) {
    const query = event.currentTarget.dataset.chatQueryParam
    this.inputTarget.value = query
    this.formTarget.requestSubmit()
  }

  send(event) {
    const input = this.inputTarget
    if (!input.value.trim()) {
      event.preventDefault()
      return
    }

    if (this.hasSuggestionsTarget) {
      this.suggestionsTarget.remove()
    }

    setTimeout(() => this.scrollToBottom(), 100)
  }

  scrollToBottom() {
    const messages = this.messagesTarget
    messages.scrollTop = messages.scrollHeight
  }

  observeMessages() {
    const observer = new MutationObserver(() => this.scrollToBottom())
    observer.observe(this.messagesTarget, { childList: true, subtree: true, characterData: true })
  }
}
