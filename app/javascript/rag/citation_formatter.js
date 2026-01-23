// app/javascript/rag/citation_formatter.js

export function formatAnswer(answerText, citations = []) {
  const escapeHtml = (text = "") => {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  const citationMap = {}
  citations.forEach(c => {
    if (c.number) citationMap[c.number] = c
  })

  const pattern = /\[(\d+)\]/g
  const escapedText = escapeHtml(answerText)

  const html = escapedText.replace(pattern, (_, num) => {
    const citation = citationMap[num]
    const title = citation?.title || citation?.filename || "Document"
    const content = citation?.content || ""
    const snippet =
      content.length > 150 ? content.slice(0, 150) + "…" : content

    const tooltip = escapeHtml(
      snippet ? `${title} – ${snippet}` : title
    )

    return `
      <span
        class="citation"
        title="${tooltip}"
        data-citation-number="${num}">
        [${num}]
      </span>
    `
  })

  return html
}
