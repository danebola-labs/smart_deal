// app/javascript/rag/references_renderer.js

export function renderReferences(citations = []) {
  if (!citations.length) return ""

  const escape = (text = "") => {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  return `
    <div class="chat-references">
      <p class="chat-references-title">References</p>
      <ul class="chat-references-list">
        ${citations.map(c => {
          const title = escape(c.title || c.filename || "Document")
          const number = c.number || ""
          return `
            <li>
              <span class="citation-number">[${number}]</span>
              <span>${title}</span>
            </li>
          `
        }).join("")}
      </ul>
    </div>
  `
}
