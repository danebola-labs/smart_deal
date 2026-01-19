// app/javascript/controllers/rag_chat_controller.js

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "sendButton", "messages", "chatContainer"]

  connect() {
    console.log("RAG chat controller connected")
    // Focus on input when connected
    if (this.hasInputTarget) {
      this.inputTarget.focus()
    }
  }

  async sendMessage(event) {
    event.preventDefault()
    
    const question = this.inputTarget.value.trim()
    
    if (!question) {
      return
    }

    // Disable input and button
    this.inputTarget.disabled = true
    if (this.hasSendButtonTarget) {
      this.sendButtonTarget.disabled = true
      this.sendButtonTarget.textContent = "Sending..."
    }

    // Add user message to chat
    this.addMessage(question, "user")

    // Clear input
    this.inputTarget.value = ""

    // Show loading message
    const loadingId = this.addMessage("Thinking...", "assistant", true)

    try {
      const response = await fetch('/rag/ask', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
        },
        credentials: 'same-origin',
        body: JSON.stringify({ question: question })
      })

      const data = await response.json()

      // Remove loading message
      this.removeMessage(loadingId)

      if (data.status === 'success') {
        // Add assistant response
        this.addMessage(data.answer, "assistant")
        
        // Update metrics after successful query
        this.updateMetrics()
        
        // Show citations with details if available (minimalist design)
        if (data.citations && data.citations.length > 0) {
          const citationCount = data.citations.length
          const citationText = citationCount === 1 ? 'fuente consultada' : 'fuentes consultadas'
          
          // Escape HTML to prevent injection and ensure proper rendering
          const escapeHtml = (text) => {
            const div = document.createElement('div')
            div.textContent = text
            return div.innerHTML
          }
          
          let citationsHtml = `<div style="margin-top: 0.75rem; padding-top: 0.75rem; border-top: 1px solid rgba(0,0,0,0.08); max-width: 100%; box-sizing: border-box; text-align: left; overflow: hidden;">`
          citationsHtml += `<p style="font-size: 0.75rem; color: rgba(107, 114, 128, 0.7); margin: 0 0 0.5rem 0; font-weight: 400; text-align: left; max-width: 100%; box-sizing: border-box; overflow-wrap: break-word; word-wrap: break-word;">${escapeHtml(citationCount + ' ' + citationText)}</p>`
          citationsHtml += `<ul style="list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 0.5rem; max-width: 100%; box-sizing: border-box; text-align: left; overflow: hidden;">`
          
          data.citations.forEach((citation) => {
            const fileName = citation.file_name || 'Document'
            const chunk = citation.chunk || ''
            const similarityScore = citation.similarity_score 
              ? Math.round(citation.similarity_score * 100) 
              : 'N/A'
            
            const titleAttr = `title="${escapeHtml(fileName)}"`
            
            // Minimalist citation: chunk on first line (truncated by CSS to fit width), score on second line
            citationsHtml += `<li style="font-size: 0.75rem; color: rgba(107, 114, 128, 0.6); display: flex; flex-direction: column; gap: 0.125rem; line-height: 1.5; max-width: 100%; box-sizing: border-box; text-align: left; align-items: flex-start; min-width: 0; overflow: hidden;">`
            // First line: chunk text (truncated by CSS ellipsis to fit available width, with tooltip showing file_name)
            citationsHtml += `  <span style="color: rgba(107, 114, 128, 0.6); cursor: help; transition: color 0.15s ease; display: block; max-width: 100%; box-sizing: border-box; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; text-align: left; min-width: 0;" ${titleAttr} onmouseover="this.style.color='rgba(107, 114, 128, 0.8)'" onmouseout="this.style.color='rgba(107, 114, 128, 0.6)'">${escapeHtml(chunk)}</span>`
            // Second line: score
            citationsHtml += `  <span style="font-size: 0.6875rem; color: rgba(107, 114, 128, 0.4); text-align: left; max-width: 100%; box-sizing: border-box; overflow-wrap: break-word;">score: ${escapeHtml(similarityScore.toString())}%</span>`
            citationsHtml += `</li>`
          })
          
          citationsHtml += `</ul></div>`
          
          // Add citations as a system message with HTML content
          this.addMessageWithHtml(citationsHtml, "system")
        } else {
          // Warn if no citations found
          this.addMessage("⚠️ No documents found related to your question.", "system")
        }
      } else {
        throw new Error(data.message || 'Unknown error')
      }
    } catch (error) {
      console.error('RAG query error:', error)
      // Remove loading message
      this.removeMessage(loadingId)
      // Show error
      this.addMessage(`Error: ${error.message}`, "error")
    } finally {
      // Re-enable input and button
      this.inputTarget.disabled = false
      if (this.hasSendButtonTarget) {
        this.sendButtonTarget.disabled = false
        this.sendButtonTarget.textContent = "Send"
      }
      // Focus on input for next question
      this.inputTarget.focus()
    }
  }

  addMessage(text, type = "user", isTemporary = false) {
    if (!this.hasMessagesTarget) return null

    const messageDiv = document.createElement("div")
    const messageId = `msg-${Date.now()}-${Math.random()}`
    messageDiv.id = messageId
    messageDiv.className = `chat-message chat-message-${type}`
    
    if (isTemporary) {
      messageDiv.dataset.temporary = "true"
    }

    const messageText = document.createElement("div")
    messageText.className = "chat-message-text"
    messageText.textContent = text
    messageDiv.appendChild(messageText)

    this.messagesTarget.appendChild(messageDiv)
    
    // Auto-scroll to bottom
    this.scrollToBottom()

    return messageId
  }

  addMessageWithHtml(html, type = "user", isTemporary = false) {
    if (!this.hasMessagesTarget) return null

    const messageDiv = document.createElement("div")
    const messageId = `msg-${Date.now()}-${Math.random()}`
    messageDiv.id = messageId
    messageDiv.className = `chat-message chat-message-${type}`
    
    if (isTemporary) {
      messageDiv.dataset.temporary = "true"
    }

    const messageText = document.createElement("div")
    messageText.className = "chat-message-text"
    messageText.innerHTML = html
    messageDiv.appendChild(messageText)

    this.messagesTarget.appendChild(messageDiv)
    
    // Auto-scroll to bottom
    this.scrollToBottom()

    return messageId
  }

  removeMessage(messageId) {
    const message = document.getElementById(messageId)
    if (message) {
      message.remove()
    } else {
      // Try to remove temporary messages
      const temporaryMessages = this.messagesTarget.querySelectorAll('[data-temporary="true"]')
      temporaryMessages.forEach(msg => msg.remove())
    }
  }

  scrollToBottom() {
    if (this.hasChatContainerTarget) {
      this.chatContainerTarget.scrollTop = this.chatContainerTarget.scrollHeight
    } else if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }

  handleKeyPress(event) {
    // Send on Enter, but allow Shift+Enter for new line
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.sendMessage(event)
    }
  }

  async updateMetrics() {
    try {
      // Only update metrics if we're on the home page
      const isHomePage = window.location.pathname === '/' || window.location.pathname === '/home'
      if (!isHomePage) {
        return
      }

      const response = await fetch('/home/metrics', {
        method: 'GET',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
        },
        credentials: 'same-origin'
      })

      if (!response.ok) {
        throw new Error('Failed to fetch metrics')
      }

      const data = await response.json()
      
      // Use requestAnimationFrame to ensure DOM updates don't break layout
      requestAnimationFrame(() => {
        // Use data attributes for very specific selection - avoids any side effects
        const tokensValue = document.querySelector('[data-metric-value="tokens"]')
        const queriesValue = document.querySelector('[data-metric-value="queries"]')
        
        if (tokensValue) {
          const formattedValue = new Intl.NumberFormat().format(data.today_tokens)
          if (tokensValue.textContent !== formattedValue) {
            tokensValue.textContent = formattedValue
          }
        }
        
        if (queriesValue) {
          const queryValue = data.today_queries.toString()
          if (queriesValue.textContent !== queryValue) {
            queriesValue.textContent = queryValue
          }
        }
      })
    } catch (error) {
      console.error('Error updating metrics:', error)
      // Silently fail - metrics update is not critical
    }
  }
}

