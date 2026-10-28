## Citations under an answer: which reference passages its model was given.
## Each opens its exact passage on request, quoted as untrusted reference text.
include karax/prelude
import ../app/types
import ../app/answer_references
import ../app/knowledge_bridge

proc renderReference(state: AppState, row: AnswerReference): VNode =
  let passage = reopenedPassage(state, row.locator)
  let opening = state.referenceOpening == row.locator
  result = buildHtml(li(class = "answer-reference", `data-locator` = cstring(row.locator))):
    tdiv(class = "answer-reference-line"):
      span(class = "knowledge-meta"): text referenceLabel(row)
      if passage.len == 0:
        button(class = "answer-reference-open", disabled = opening or state.referenceOpening.len > 0,
            `aria-label` = cstring("Show passage: " & referenceLabel(row))):
          text (if opening: "Opening…" else: "Show passage")
          proc onclick(event: Event, node: VNode) = discard reopenAnswerReference(state, row)
    if passage.len > 0:
      # Quoted as material from a document, never as an instruction to follow.
      blockquote(class = "knowledge-content"): text passage
      p(class = "knowledge-meta knowledge-citation-line"):
        span: text "Citation "
        code(class = "knowledge-citation"): text row.locator
    if state.referenceError.len > 0 and state.referenceErrorLocator == row.locator:
      p(class = "operation-error", role = "alert"): text state.referenceError

proc renderAnswerReferences*(state: AppState, references: seq[AnswerReference]): VNode =
  result = buildHtml(section(class = "answer-references", `aria-label` = "Reference passages")):
    p(class = "answer-references-title"):
      strong: text "Reference passages given to the model"
      span(class = "knowledge-trust"): text "Untrusted reference"
    ul(class = "answer-reference-list"):
      for row in references:
        renderReference(state, row)
