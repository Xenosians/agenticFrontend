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


proc parseReviewQueue*(data: JsonNode): seq[ReviewItem] =
  ## Records with an identity and a known review status, in the server's order.
  if data.kind != JObject or not data.hasKey("feedback") or data["feedback"].kind != JArray:
    return
  for row in data["feedback"]:
    let identity = text(row, "feedback_id")
    let status = text(row, "review_status")
    if identity.len == 0 or status notin reviewStatuses:
      continue
    let subject = child(row, "subject")
    let review = child(row, "review")
    result.add ReviewItem(
      feedbackId: identity, jobId: text(row, "job_id"), chatId: text(row, "chat_id"),
      kind: text(row, "kind"), note: text(row, "note"), correction: text(row, "correction"),
      createdAt: text(row, "created_at"), request: text(subject, "request"),
      answer: text(subject, "answer"), taskStatus: text(subject, "status"),
      specialist: text(subject, "selected_agent"), status: status,
      decision: text(review, "decision"), reason: text(review, "reason"),
      pending: status == "pending_review")


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
