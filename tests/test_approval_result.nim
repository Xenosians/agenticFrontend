import std/[json, unittest]
import ../src/api/approval_result

proc decisionResult(status, execution: string): JsonNode =
  %*{"status": status,
    "proposed_tool": {"tool": "workspace_mkdir", "arguments": {"relative_path": "reviewed"}, "approval_id": "approval"},
    "result": {"approval_execution": {"approval_id": "approval", "execution_status": execution,
      "approval_status": "approved", "result": {"ok": true, "path": "reviewed"}, "error": nil}}}

suite "persisted action result presentation":
  test "successful action displays exact saved arguments and actual tool output":
    let data = decisionResult("completed", "succeeded")
    let cards = approvalResultPresentations(data)
    check cards.len == 1
    check cards[0].status == "succeeded"
    check cards[0].fields[0].value == "workspace_mkdir"
    check parseJson(cards[0].sections[0].content) == data["proposed_tool"]["arguments"]
    check parseJson(cards[0].sections[1].content) == data["result"]["approval_execution"]["result"]
  test "human rejection uses server reason and no fabricated tool output":
    let data = decisionResult("denied", "rejected")
    data["result"]["approval_execution"]["approval_status"] = %"rejected"
    data["result"]["approval_execution"]["result"] = newJNull()
    data["result"]["approval_execution"]["error"] = %"Action rejected by the user. No tool was executed."
    let cards = approvalResultPresentations(data)
    check cards.len == 1
    check cards[0].status == "rejected"
    check cards[0].sections.len == 2
    check cards[0].sections[1].content == "Action rejected by the user. No tool was executed."
  test "mismatched identities and contradictory outcomes cannot produce a success card":
    let data = decisionResult("outcome_unknown", "succeeded")
    check approvalResultPresentations(data).len == 0
    data["status"] = %"completed"
    data["result"]["approval_execution"]["approval_id"] = %"another-approval"
    check approvalResultPresentations(data).len == 0
    data["result"]["approval_execution"] = %"untrusted prose"
    check approvalResultPresentations(data).len == 0
