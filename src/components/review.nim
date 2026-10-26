## The reviewer queue for critiques and corrections (FR-089).
include karax/prelude
import ../app/types
import ../app/feedback_review
import ../app/review_bridge
import ../app/request_context

proc localTimestamp(value: cstring): cstring {.
  importjs: "((v) => { const d = new Date(v); return Number.isNaN(d.getTime()) ? v : d.toLocaleString(); })(#)".}

proc labelled(label, value: string): VNode =
  result = buildHtml(tdiv(class = "review-field")):
    span(class = "review-label"): text label
    p(class = "review-subject"): text value

proc renderDecision(state: AppState, item: ReviewItem): VNode =
  # One invocation owns each record; handlers capture its identity only.
  let reason = reviewReason(state, item.feedbackId)
  let deciding = state.reviewDeciding == item.feedbackId
  let blocked = state.reviewBusy or state.reviewDeciding.len > 0 or reason.len == 0
  result = buildHtml(tdiv(class = "review-decision")):
    label(class = "review-label", `for` = cstring("reason-" & item.feedbackId)):
      text "Reason"
    textarea(id = cstring("reason-" & item.feedbackId), class = "review-reason", rows = "2",
        maxlength = "2000", value = cstring(reason)):
      proc oninput(event: Event, node: VNode) =
        setReviewReason(state, item.feedbackId, $node.value)
        redraw(kxi)
    tdiv(class = "review-actions"):
      button(class = "primary-action", disabled = blocked):
        text (if deciding: "Saving…" else: "Accept")
        proc onclick(event: Event, node: VNode) =
          discard decideReview(state, item.feedbackId, "accepted")
      button(class = "secondary-action", disabled = blocked):
        text "Dismiss"
        proc onclick(event: Event, node: VNode) =
          discard decideReview(state, item.feedbackId, "dismissed")

proc renderReviewItem(state: AppState, item: ReviewItem): VNode =
  let error = reviewItemError(state, item.feedbackId)
  result = buildHtml(article(class = "review-item", `data-feedback-id` = cstring(item.feedbackId),
      `data-review-status` = cstring(item.status))):
    tdiv(class = "operation-job-heading"):
      tdiv:
        strong: text (if item.kind == "correction": "Correction" else: "Critique")
        p(class = "operation-note"):
          text "Saved " & $localTimestamp(cstring(item.createdAt)) &
            (if item.specialist.len > 0: " · " & item.specialist else: "")
      span(class = "review-status"): text reviewStatusLabel(item.status)
    labelled("Feedback", item.note)
    if item.correction.len > 0:
      labelled("Correct result", item.correction)
    labelled("Request", (if item.request.len > 0: item.request else: "No request was recorded"))
    labelled("Answer", (if item.answer.len > 0: item.answer else: "No answer was recorded"))
    if item.pending:
      renderDecision(state, item)
    else:
      labelled("Decision", reviewStatusLabel(item.decision) & " · " & item.reason)
    if error.len > 0:
      p(class = "operation-error", role = "alert"): text error

proc renderReviewPanel*(state: AppState): VNode =
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view review-panel"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2: text "Review"
          p: text "Critiques and corrections people saved on task results."
        tdiv(class = "review-actions"):
          button(class = "secondary-action", disabled = state.reviewBusy or state.reviewDeciding.len > 0, `aria-pressed` =
              (if state.reviewShowDecided: cstring"true" else: cstring"false")):
            text (if state.reviewShowDecided: "Show only pending" else: "Show decided")
            proc onclick(event: Event, node: VNode) =
              state.reviewShowDecided = not state.reviewShowDecided
              discard refreshReview(state)
          button(class = "secondary-action", disabled = state.reviewBusy or state.reviewDeciding.len > 0, `aria-label` = "Refresh review"):
            text (if state.reviewBusy: "Refreshing…" else: "Refresh")
            proc onclick(event: Event, node: VNode) =
              discard refreshReview(state)
      p(class = "operation-note"):
        text "A decision is review evidence only: it never changes the task, its approval, permissions or the serving model."
      if state.reviewError.len > 0:
        p(class = "operation-error", role = "alert"): text state.reviewError
      if state.reviewBusy and not state.reviewLoaded:
        p(class = "operation-note", role = "status"): text "Loading feedback for review…"
      elif state.reviewLoaded:
        if state.reviewItems.len == 0:
          tdiv(class = "empty-card"):
            text (if state.reviewShowDecided: "No feedback was returned." else: "No feedback waits for review.")
        else:
          for item in reviewQueueItems(state):
            renderReviewItem(state, item)
