import std/json
import ../app/types
import tool_proposal

proc hasApprovalExecution*(data: JsonNode): bool =
  not data.isNil and data.kind == JObject and data.hasKey("result") and data["result"].kind == JObject and
    data["result"].hasKey("approval_execution")

proc approvalResultPresentations*(data: JsonNode): seq[ResultCard] =
  if not hasApprovalExecution(data):
    return
  let execution = data["result"]["approval_execution"]
  let proposal = parseToolProposal(data)
  if execution.kind != JObject or not execution.hasKey("approval_id") or
      execution["approval_id"].kind != JString or proposal.approvalId.len == 0 or
      execution["approval_id"].getStr() != proposal.approvalId or
      not execution.hasKey("execution_status") or execution["execution_status"].kind != JString or
      not data.hasKey("status") or data["status"].kind != JString:
    return
  let status = execution["execution_status"].getStr()
  let expectedJobStatus =
    case status
    of "succeeded": "completed"
    of "failed": "failed"
    of "rejected": "denied"
    of "unresolved": "outcome_unknown"
    else: ""
  if expectedJobStatus.len == 0 or data["status"].getStr() != expectedJobStatus:
    return
  let expectedDecision =
    case status
    of "succeeded": "approved"
    of "failed": "failed"
    of "unresolved": "executing"
    of "rejected": "rejected"
    else: ""
  if not execution.hasKey("approval_status") or execution["approval_status"].kind != JString or
      execution["approval_status"].getStr() != expectedDecision:
    return
  if status == "rejected" and execution.hasKey("result") and execution["result"].kind != JNull:
    return

  var card = ResultCard(schema: "result-card.v1", kind: "action", title: "Action result", status: status)
  card.fields.add(ResultCardField(label: "Action", value: proposal.tool))
  if execution.hasKey("approval_status") and execution["approval_status"].kind == JString:
    card.fields.add(ResultCardField(label: "Decision", value: execution["approval_status"].getStr()))
  card.sections.add(ResultCardSection(kind: "preformatted", title: "Saved arguments", content: pretty(proposal.arguments)))
  if execution.hasKey("error") and execution["error"].kind == JString and execution["error"].getStr().len > 0:
    card.sections.add(ResultCardSection(kind: "text", title: "Reason", content: execution["error"].getStr()))
  if execution.hasKey("result") and execution["result"].kind != JNull:
    card.sections.add(ResultCardSection(kind: "preformatted", title: "Tool result", content: pretty(execution["result"])))
  result.add(card)
