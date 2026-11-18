import std/[json, strutils]
import ../app/types

proc parseToolProposal*(data: JsonNode): ToolProposal =
  ## Accept only the server's structured proposal. Prose and saved history
  ## cannot manufacture action details or an approval identity.
  if data.isNil or data.kind != JObject or not data.hasKey("proposed_tool"):
    return
  let proposal = data["proposed_tool"]
  if proposal.kind != JObject:
    return
  if not proposal.hasKey("tool") or proposal["tool"].kind != JString or
      not proposal.hasKey("arguments") or proposal["arguments"].kind != JObject:
    return
  result.tool = proposal["tool"].getStr()
  result.arguments = proposal["arguments"]
  if proposal.hasKey("approval_id") and proposal["approval_id"].kind == JString:
    result.approvalId = proposal["approval_id"].getStr()
  # A destructive action names the exact text to type; the approval authority checks it.
  if proposal.hasKey("confirmation_text") and proposal["confirmation_text"].kind == JString:
    result.confirmationText = proposal["confirmation_text"].getStr()

proc reviewableProposal*(proposal: ToolProposal): bool =
  proposal.tool.strip().len > 0 and proposal.approvalId.strip().len > 0 and
    not proposal.arguments.isNil and proposal.arguments.kind == JObject
