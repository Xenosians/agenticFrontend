## The reviewer queue for feedback (FR-089).
import std/[asyncjs, jsfetch, json]
from std/httpcore import HttpGet, HttpPost
import ../config/runtime_config
import ../app/feedback_review
import http_call

proc publicDetail(body: string, fallback: string): string =
  try:
    let data = parseJson(body)
    if data.kind == JObject and data.hasKey("detail") and data["detail"].kind == JString:
      return data["detail"].getStr
  except CatchableError:
    discard
  fallback

proc fetchReviewQueue*(showAll: bool): Future[seq[ReviewItem]] {.async.} =
  var response: HttpReply
  try:
    response = await sendRequest(frontendConfig.backendBaseUrl & reviewQueuePath(showAll),
      newFetchOptions(metod = HttpGet, mode = fmCors, credentials = fcInclude))
  except CatchableError:
    raise newException(ValueError, "Review could not be reached. Check the connection, then refresh.")
  if not response.ok:
    raise newException(ValueError, publicDetail(response.body,
      "Feedback for review could not be loaded (HTTP " & $response.status & ")."))
  try:
    result = parseReviewQueue(decodeJson(response.body))
  except CatchableError:
    raise newException(ValueError, "The review response was invalid. Refresh to check again.")

proc sendReview*(feedbackId, decision, reason, csrfToken: string): Future[ReviewItem] {.async.} =
  ## Records one decision. The server keeps the first decision; a different
  ## one is refused and stated, never retried automatically.
  let payload = reviewPayload(decision, reason)
  let body = $payload
  let headers = newHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-CSRF-Token"] = csrfToken
  var response: HttpReply
  try:
    response = await sendRequest(frontendConfig.backendBaseUrl & reviewPath(feedbackId),
      newFetchOptions(metod = HttpPost, body = cstring(body), mode = fmCors,
        credentials = fcInclude, headers = headers))
  except CatchableError:
    raise newException(ValueError,
      "The decision could not be confirmed. Refresh the queue before deciding again.")
  if not response.ok:
    raise newException(ValueError, publicDetail(response.body,
      "The decision was not saved (HTTP " & $response.status & ")."))
  try:
    result = parseReviewReceipt(decodeJson(response.body), feedbackId,
      payload["decision"].getStr, payload["reason"].getStr)
  except CatchableError:
    raise newException(ValueError,
      "The decision response was invalid. Refresh the queue before deciding again.")
