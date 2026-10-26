import std/[json, strutils, unittest]
import ../src/app/feedback_review

let queue = %*{"feedback": [
  {"feedback_id": "a".repeat(32), "job_id": "b".repeat(32), "chat_id": "chat-1", "kind": "correction",
   "note": "It missed the VPN tickets", "correction": "List SUP-14 too", "review_status": "pending_review",
   "created_at": "2026-10-26T09:00:00Z",
   "subject": {"request": "List the open VPN tickets", "answer": "No open VPN tickets.",
               "status": "completed", "selected_agent": "jira-specialist"}},
  {"feedback_id": "c".repeat(32), "job_id": "d".repeat(32), "kind": "critique", "note": "Too slow",
   "correction": nil, "review_status": "accepted", "created_at": "2026-10-26T08:00:00Z",
   "review": {"decision": "accepted", "reason": "Valid", "reviewer_id": "admin-1",
              "reviewed_at": "2026-10-26T10:00:00Z"},
   "subject": {"request": "Show my tickets", "answer": nil, "status": "failed"}}]}

suite "feedback review queue":
  test "each record keeps its note, correction, subject and decision":
    let items = parseReviewQueue(queue)
    check items.len == 2
    check items[0].feedbackId == "a".repeat(32)
    check items[0].note == "It missed the VPN tickets"
    check items[0].correction == "List SUP-14 too"
    check items[0].request == "List the open VPN tickets"
    check items[0].answer == "No open VPN tickets."
    check items[0].pending
    check not items[1].pending
    check items[1].decision == "accepted"
    check items[1].reason == "Valid"
    # A task without an answer is shown as such, never as an empty answer.
    check items[1].answer == ""

  test "records without an identity or a known review status are left out":
    let items = parseReviewQueue(%*{"feedback": [
      {"feedback_id": "", "note": "No identity", "review_status": "pending_review"},
      {"feedback_id": "e".repeat(32), "note": "Unknown", "review_status": "applied"},
      {"feedback_id": "f".repeat(32), "note": "Kept", "review_status": "dismissed"}]})
    check items.len == 1
    check items[0].feedbackId == "f".repeat(32)
    check parseReviewQueue(%*{"detail": "outage"}).len == 0

  test "a decision needs one of the two outcomes and a reason":
    check reviewPayload("accepted", "  Valid: dropped a filter  ") ==
      %*{"decision": "accepted", "reason": "Valid: dropped a filter"}
    expect ValueError: discard reviewPayload("approved", "Reason")
    expect ValueError: discard reviewPayload("dismissed", "   ")

  test "the review path escapes the identity and refuses an empty one":
    check reviewPath("a".repeat(32)) == "/api/v1/feedback/" & "a".repeat(32) & "/review"
    expect ValueError: discard reviewPath("")
    check reviewQueuePath(showAll = false) == "/api/v1/feedback/review"
    check reviewQueuePath(showAll = true) == "/api/v1/feedback/review?status=all"
