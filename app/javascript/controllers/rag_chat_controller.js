// app/javascript/controllers/rag_chat_controller.js

import { Controller } from "@hotwired/stimulus"
import { formatAnswer } from "rag/citation_formatter"
import { renderReferences } from "rag/references_renderer"

export default class extends Controller {
  static targets = ["input", "sendButton", "messages", "chatContainer"]

  connect() {
    this.inputTarget?.focus()
  }

  async sendMessage(event) {
    event.preventDefault()

    const question = this.inputTarget.value.trim()
    if (!question) return

    this.disableForm()
    this.addMessage(question, "user")
    this.inputTarget.value = ""

    const loadingId = this.addMessage("Thinking…", "assistant", true)

    try {
      const data = await this.ask(question)
      this.removeMessage(loadingId)

      if (data.status !== "success") {
        throw new Error(data.message || "Unknown error")
      }

      const answerHtml = formatAnswer(data.answer, data.citations)
      this.addMessageHtml(answerHtml, "assistant")

      if (data.citations?.length) {
        this.addMessageHtml(renderReferences(data.citations), "assistant")
      }

      // Update metrics using Turbo Stream (Hotwire handles DOM updates automatically)
      this.updateMetrics()
    } catch (error) {
      this.removeMessage(loadingId)
      this.addMessage(`Error: ${error.message}`, "error")
    } finally {
      this.enableForm()
    }
  }

  async ask(question) {
    const response = await fetch("/rag/ask", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
      },
      credentials: "same-origin",
      body: JSON.stringify({ question })
    })

    if (!response.ok) {
      throw new Error(`Server error (${response.status})`)
    }

    return response.json()
  }

  /* UI helpers */

  disableForm() {
    this.inputTarget.disabled = true
    this.sendButtonTarget?.setAttribute("disabled", true)
  }

  enableForm() {
    this.inputTarget.disabled = false
    this.sendButtonTarget?.removeAttribute("disabled")
    this.inputTarget.focus()
  }

  addMessage(text, type, temporary = false) {
    const id = `msg-${Date.now()}`
    const div = document.createElement("div")

    div.id = id
    div.className = `chat-message chat-message-${type}`
    if (temporary) div.dataset.temporary = true

    div.textContent = text
    this.messagesTarget.appendChild(div)
    this.scroll()

    return id
  }

  addMessageHtml(html, type) {
    const div = document.createElement("div")
    div.className = `chat-message chat-message-${type}`
    div.innerHTML = html
    this.messagesTarget.appendChild(div)
    this.scroll()
  }

  removeMessage(id) {
    document.getElementById(id)?.remove()
    this.messagesTarget
      .querySelectorAll("[data-temporary]")
      .forEach(el => el.remove())
  }

  scroll() {
    this.chatContainerTarget.scrollTop =
      this.chatContainerTarget.scrollHeight
  }

  handleKeyPress(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.sendMessage(event)
    }
  }

  async updateMetrics() {
    // Only update if we're on the home page
    if (window.location.pathname !== '/' && window.location.pathname !== '/home') {
      return
    }

    try {
      const response = await fetch('/home/metrics', {
        method: 'GET',
        headers: {
          'Accept': 'text/vnd.turbo-stream.html',
          'X-CSRF-Token': document.querySelector('meta[name=csrf-token]')?.content
        },
        credentials: 'same-origin'
      })

      if (!response.ok) return

      // Turbo automatically processes streams when added to DOM
      const html = await response.text()
      const parser = new DOMParser()
      const doc = parser.parseFromString(html, 'text/html')
      const streams = doc.querySelectorAll('turbo-stream')

      streams.forEach(stream => {
        const clone = stream.cloneNode(true)
        document.body.appendChild(clone)
        // Turbo processes synchronously, remove after a brief delay
        setTimeout(() => clone.remove(), 100)
      })
    } catch (error) {
      // Silently fail - metrics update is not critical
      console.error('Error updating metrics:', error)
    }
  }
}
