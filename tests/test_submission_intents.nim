import std/[json, strutils, unittest]
import ../src/api/submission_intent_contract

proc saved(kind = "workflow", target = "a".repeat(32), state = "pending"): JsonNode =
  %*{"schema": "submission-intent-slot.v1", "kind": kind, "target_id": target,
    "intent": {"kind": kind, "target_id": target, "intent_id": "b".repeat(32),
      "state": state, "request_sha256": "c".repeat(64), "previous_id": nil,
      "request": {"version": 2, "submission_id": "retained-identity", "message": "Exact request"},
      "context": {"version": 2, "definition_sha256": "d".repeat(64)}, "receipt": nil}}

suite "server submission intent receipts":
  test "an empty slot must be an explicit valid server observation":
    let empty = %*{"schema": "submission-intent-slot.v1", "kind": "learning", "target_id": "candidate", "intent": nil}
    check parseSubmissionIntent(empty, "learning", "candidate").id == ""
    for malformed in [newJNull(), %*{}, %*{"kind": "learning", "target_id": "candidate", "intent": nil}]:
      expect ValueError: discard parseSubmissionIntent(malformed, "learning", "candidate")

  test "recovery is scoped to the exact requested operation and target":
    let original = saved()
    let parsed = parseSubmissionIntent(original, "workflow", "a".repeat(32))
    check parsed.id == "b".repeat(32)
    check parsed.request == original["intent"]["request"]
    check parsed.context == original["intent"]["context"]
    expect ValueError: discard parseSubmissionIntent(original, "chat", "a".repeat(32))
    expect ValueError: discard parseSubmissionIntent(original, "workflow", "e".repeat(32))
    var mismatch = original.copy
    mismatch["intent"]["target_id"] = %"e".repeat(32)
    expect ValueError: discard parseSubmissionIntent(mismatch, "workflow", "a".repeat(32))

  test "returned requests are snapshots, including immutable workflow context":
    var original = saved()
    let parsed = parseSubmissionIntent(original, "workflow", "a".repeat(32))
    original["intent"]["request"]["message"] = %"Changed request"
    original["intent"]["context"]["version"] = %3
    check parsed.request["message"].getStr == "Exact request"
    check parsed.context["version"].getInt == 2

  test "pending, acknowledged and rejected remain distinct coordination outcomes":
    for state in ["pending", "acknowledged", "rejected"]:
      check parseSubmissionIntent(saved(state = state), "workflow", "a".repeat(32)).state == state
    expect ValueError: discard parseSubmissionIntent(saved(state = "success"), "workflow", "a".repeat(32))

  test "missing or malformed request identities cannot become an empty slot":
    for field in ["intent_id", "request_sha256", "request", "context", "receipt"]:
      var broken = saved()
      broken["intent"].delete(field)
      expect ValueError: discard parseSubmissionIntent(broken, "workflow", "a".repeat(32))
    for field in ["intent_id", "request_sha256"]:
      var broken = saved()
      broken["intent"][field] = %"../changed"
      expect ValueError: discard parseSubmissionIntent(broken, "workflow", "a".repeat(32))
    var broken = saved()
    broken["intent"]["request"] = %*[]
    expect ValueError: discard parseSubmissionIntent(broken, "workflow", "a".repeat(32))
