## Loads the reviewer queue and records decisions (FR-089).
include karax/prelude
import std/asyncjs
import ../api/feedback_review
import feedback_review
import types
import state
import request_context

proc entry(pairs: seq[(string, string)], key: string): string =
  for (name, value) in pairs:
    if name == key: return value

proc withEntry(pairs: seq[(string, string)], key, value: string): seq[(string, string)] =
  for (name, existing) in pairs:
    if name != key: result.add((name, existing))
  if value.len > 0: result.add((key, value))

proc reviewReason*(state: AppState, feedbackId: string): string =
  entry(state.reviewReasons, feedbackId)

proc setReviewReason*(state: AppState, feedbackId, reason: string) =
  state.reviewReasons = withEntry(state.reviewReasons, feedbackId, reason)

proc reviewItemError*(state: AppState, feedbackId: string): string =
  entry(state.reviewItemErrors, feedbackId)

proc refreshReview*(state: AppState) {.async.} =
  if not isReviewer(state) or state.reviewBusy: return
  let request = beginReviewRequest(state)
  state.reviewBusy = true
  state.reviewError = ""
  redraw(kxi)
  try:
    let items = await fetchReviewQueue(state.reviewShowDecided)
    if not matchesReviewRequest(state, request): return
    state.reviewItems = items
    state.reviewLoaded = true
    state.reviewItemErrors = @[]
  except CatchableError as exc:
    if matchesReviewRequest(state, request):
      state.reviewError = exc.msg
      state.reviewLoaded = false
  finally:
    if matchesReviewRequest(state, request): state.reviewBusy = false
    redraw(kxi)

proc decideReview*(state: AppState, feedbackId, decision: string) {.async.} =
  ## One decision in flight at a time; the result replaces the record, or the
  ## refusal is stated on it. Nothing is retried automatically.
  if not isReviewer(state) or state.reviewDeciding.len > 0: return
  let reason = reviewReason(state, feedbackId)
  let request = beginReviewRequest(state)
  state.reviewDeciding = feedbackId
  state.reviewItemErrors = withEntry(state.reviewItemErrors, feedbackId, "")
  redraw(kxi)
  try:
    let reviewed = await sendReview(feedbackId, decision, reason, state.auth.csrfToken)
    if not matchesReviewRequest(state, request): return
    var items: seq[ReviewItem]
    for item in state.reviewItems:
      if item.feedbackId != feedbackId: items.add item
      elif state.reviewShowDecided: items.add reviewed
    state.reviewItems = items
    state.reviewReasons = withEntry(state.reviewReasons, feedbackId, "")
  except CatchableError as exc:
    if matchesReviewRequest(state, request):
      state.reviewItemErrors = withEntry(state.reviewItemErrors, feedbackId, exc.msg)
  finally:
    if matchesReviewRequest(state, request): state.reviewDeciding = ""
    redraw(kxi)

proc openReview*(state: AppState) =
  if not isReviewer(state): return
  setActiveView(state, viewReview)
  discard refreshReview(state)
