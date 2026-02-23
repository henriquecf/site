import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "button"]

  copy() {
    const text = this.sourceTarget.textContent
    navigator.clipboard.writeText(text).then(() => {
      const original = this.buttonTarget.textContent
      this.buttonTarget.textContent = "Copied!"
      this.buttonTarget.classList.add("share-btn--copied")

      setTimeout(() => {
        this.buttonTarget.textContent = original
        this.buttonTarget.classList.remove("share-btn--copied")
      }, 2000)
    })
  }
}
