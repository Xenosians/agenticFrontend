## The reviewer queue for critiques and corrections (FR-089).
##
## Administrators read pending feedback with the saved subject and record one
## decision per record. A decision is review evidence only: it never changes
## the task, its approval, permissions or serving weights.

import std/[json, strutils, uri]

const reviewDecisions* = ["accepted", "dismissed"]
const reviewStatuses = ["pending_review", "accepted", "dismissed"]

type
  ReviewItem* = object
    feedbackId*, jobId*, chatId*, kind*, note*, correction*, createdAt*: string
    request*, answer*, taskStatus*, specialist*: string
    status*, decision*, reason*: string
    pending*: bool


proc text(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr
  else: ""


proc child(node: JsonNode, key: string): JsonNode =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JObject: node[key]
  else: nil

proc invalidReview() =
  raise newException(ValueError, "The review response was invalid. Refresh to check again.")

proc requiredText(node: JsonNode, key: string): string =
  result = text(node, key)
  if result.strip().len == 0: invalidReview()

proc optionalText(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key):
    if node[key].kind == JString: return node[key].getStr
    if node[key].kind != JNull: invalidReview()

proc validIdentity(identity: string): bool =
  identity.len == 32 and identity.allCharsInSet({'0'..'9', 'a'..'f'})


proc parseReviewQueue*(data: JsonNode): seq[ReviewItem] =
  ## Invalid observations are errors, distinct from a valid empty queue.
  if data == nil or data.kind != JObject or not data.hasKey("feedback") or data["feedback"].kind != JArray:
    invalidReview()
  var identities: seq[string]
  for row in data["feedback"]:
    let identity = text(row, "feedback_id")
    let status = text(row, "review_status")
    if not validIdentity(identity) or identity in identities or status notin reviewStatuses:
      invalidReview()
    identities.add identity
    let subject = child(row, "subject")
    let review = child(row, "review")
    let kind = requiredText(row, "kind")
    let correction = optionalText(row, "correction")
    if kind notin ["critique", "correction"] or (kind == "correction" and correction.strip().len == 0):
      invalidReview()
    let request = requiredText(subject, "request")
    let taskStatus = requiredText(subject, "status")
    if taskStatus notin ["waiting_approval", "completed", "failed", "denied", "outcome_unknown", "reconciliation_required"]:
      invalidReview()
    var decision, reason: string
    if status != "pending_review":
      decision = requiredText(review, "decision")
      reason = requiredText(review, "reason")
      if decision != status: invalidReview()
    result.add ReviewItem(
      feedbackId: identity, jobId: requiredText(row, "job_id"), chatId: optionalText(row, "chat_id"),
      kind: kind, note: requiredText(row, "note"), correction: correction,
      createdAt: requiredText(row, "created_at"), request: request,
      answer: optionalText(subject, "answer"), taskStatus: taskStatus,
      specialist: optionalText(subject, "selected_agent"), status: status,
      decision: decision, reason: reason,
      pending: status == "pending_review")

proc parseReviewReceipt*(data: JsonNode, feedbackId, decision, reason: string): ReviewItem =
  ## A transport success only confirms this exact saved decision when its
  ## returned identity and final state agree with what was submitted.
  if data == nil or data.kind != JObject or not data.hasKey("feedback"):
    invalidReview()
  let items = parseReviewQueue(%*{"feedback": [data["feedback"]]})
  if items.len != 1 or items[0].feedbackId != feedbackId or items[0].pending or
      items[0].status != decision or items[0].decision != decision or items[0].reason != reason.strip():
    raise newException(ValueError, "The saved decision could not be confirmed. Refresh the queue before deciding again.")
  items[0]


proc reviewPayload*(decision, reason: string): JsonNode =
  let reason = reason.strip()
  if decision notin reviewDecisions:
    raise newException(ValueError, "Choose accept or dismiss.")
  if reason.len == 0:
    raise newException(ValueError, "Give a reason for the decision.")
  %*{"decision": decision, "reason": reason}


proc reviewPath*(feedbackId: string): string =
  if feedbackId.len == 0:
    raise newException(ValueError, "A saved feedback record is required.")
  "/api/v1/feedback/" & encodeUrl(feedbackId, usePlus = false) & "/review"


proc reviewQueuePath*(showAll: bool): string =
  if showAll: "/api/v1/feedback/review?status=all" else: "/api/v1/feedback/review"


proc reviewStatusLabel*(status: string): string =
  case status
  of "pending_review": "Pending review"
  of "accepted": "Accepted"
  of "dismissed": "Dismissed"
  else: "Unknown"
