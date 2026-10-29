import std/[json, asyncjs]
import submission_intents

type PendingSubmission* = object
  identity*, message*: string
  workflowContract*: JsonNode

proc parsePending(node: JsonNode): PendingSubmission =
  if node.kind == JNull: return
  PendingSubmission(identity: node["submission_id"].getStr, message: node["message"].getStr,
    workflowContract: (if node.hasKey("workflow_contract"): node["workflow_contract"] else: nil))

proc clearOwnerSubmissions*(owner: string) =
  if owner.len > 0:
    clearIntentCache(owner)

proc serverPendingSubmission*(owner, chat: string): PendingSubmission =
  let slot = cachedIntent(owner, "chat", chat)
  if slot.state == "pending": result = parsePending(slot.request)

proc readServerSubmission*(owner, chat: string): Future[PendingSubmission] {.async.} =
  # In an async JS proc `result` is the Future itself: always return a value.
  let slot = await readIntent(owner, "chat", chat)
  return (if slot.state == "pending": parsePending(slot.request) else: PendingSubmission())

proc reserveServerSubmission*(owner, chat, message, csrf: string, contract: JsonNode): Future[PendingSubmission] {.async.} =
  var payload = %*{"chat_id": chat, "message": message}
  if contract != nil and contract.kind != JNull: payload["workflow_contract"] = contract
  let slot = await reserveIntent(owner, "chat", chat, payload, csrf)
  return parsePending(slot.request)

proc confirmServerSubmission*(owner, chat, submission, csrf: string): Future[void] {.async.} =
  let slot = cachedIntent(owner, "chat", chat)
  if slot.request == nil or slot.request{"submission_id"}.getStr("") != submission:
    raise newException(ValueError, "The accepted response did not match the saved request.")
  discard await acknowledgeIntent(owner, "chat", chat, slot.id, csrf)
