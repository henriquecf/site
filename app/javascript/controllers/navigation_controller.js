import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu"]

  toggle() {
    this.menuTarget.classList.toggle("open")
  }

  // Close menu when a link is clicked (mobile)
  menuTargetConnected() {
    this.menuTarget.querySelectorAll("a").forEach(link => {
      link.addEventListener("click", () => {
        this.menuTarget.classList.remove("open")
      })
    })
  }
}
