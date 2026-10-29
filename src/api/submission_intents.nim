## Server-held request identity; this cache is only a view of that record.
## Reload reads the original intent. It never dispatches or acknowledges work.
import std/[asyncjs, jsfetch, jsheaders, json, tables, strutils, uri]
from std/httpcore import HttpGet, HttpPost
import ../config/runtime_config
import http_call

type SubmissionIntent* = object
  id*, state*: string
  request*, context*, receipt*: JsonNode

var slots = initTable[string, SubmissionIntent]()

proc slotKey(owner, kind, target: string): string = $(%*[frontendConfig.backendBaseUrl, owner, kind, target])
proc hex(value: string, size: int): bool = value.len == size and value.allCharsInSet({'0'..'9', 'a'..'f'})

proc parseSlot(data: JsonNode, kind, target: string): SubmissionIntent =
  if data == nil or data.kind != JObject or data.len != 4 or
      data{"schema"}.getStr("") != "submission-intent-slot.v1" or
      data{"kind"}.getStr("") != kind or data{"target_id"}.getStr("") != target or not data.hasKey("intent"):
    raise newException(ValueError, "The server did not confirm this request slot. Reload before sending.")
  let item = data["intent"]
  if item.kind == JNull: return
  if item.kind != JObject or not hex(item{"intent_id"}.getStr(""), 32) or
      item{"kind"}.getStr("") != kind or item{"target_id"}.getStr("") != target or
      item{"state"}.getStr("") notin ["pending", "acknowledged", "rejected"] or
      not item.hasKey("request") or item["request"].kind != JObject or
      not item.hasKey("context") or not item.hasKey("receipt") or
      not hex(item{"request_sha256"}.getStr(""), 64):
    raise newException(ValueError, "The saved request is invalid. Check it before sending another request.")
  result = SubmissionIntent(id: item["intent_id"].getStr, state: item["state"].getStr,
    request: item["request"].copy, context: item["context"].copy, receipt: item["receipt"].copy)

proc readIntent*(owner, kind, target: string): Future[SubmissionIntent] {.async.} =
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/submission-intents?kind=" &
    encodeUrl(kind) & "&target_id=" & encodeUrl(target),
    newFetchOptions(metod = HttpGet, credentials = fcInclude, mode = fmCors))
  if not response.ok: raise newException(ValueError, "The saved request could not be checked. Reload before sending another request.")
  let parsed = parseSlot(decodeJson(response.body), kind, target)
  slots[slotKey(owner, kind, target)] = parsed
  return parsed

proc cachedIntent*(owner, kind, target: string): SubmissionIntent =
  let key = slotKey(owner, kind, target)
  if not slots.hasKey(key): raise newException(ValueError, "Wait for the saved request to be checked before sending.")
  slots[key]

proc slotError(body: string): string =
  ## A refusal names its reason; anything else leaves the slot unconfirmed.
  var code = ""
  try:
    let data = decodeJson(body)
    if data.kind == JObject: code = data{"error"}.getStr("")
  except CatchableError: discard
  case code
  of "invalid_submission_intent": "The server refused this request as invalid. Review it before sending."
  of "submission_intent_conflict": "An earlier request is unconfirmed. Reload to check that saved request before starting another."
  else: "The saved request could not be confirmed. Check it again before sending another request."

proc postSlot(path: string, payload: JsonNode, csrf: string): Future[JsonNode] {.async.} =
  let headers = newHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-CSRF-Token"] = csrf
  let response = await sendRequest(frontendConfig.backendBaseUrl & path,
    newFetchOptions(metod = HttpPost, credentials = fcInclude, mode = fmCors, headers = headers, body = cstring($payload)))
  if not response.ok: raise newException(ValueError, slotError(response.body))
  return decodeJson(response.body)

proc reserveIntent*(owner, kind, target: string, request: JsonNode, csrf: string): Future[SubmissionIntent] {.async.} =
  # A slot this page has not read yet (a new chat, a newly saved workflow) is
  # read first, so the reservation names the server's current predecessor.
  let key = slotKey(owner, kind, target)
  let previous = if slots.hasKey(key): slots[key] else: await readIntent(owner, kind, target)
  # A pending record is immutable, including across tabs and reloads.
  if previous.state == "pending":
    var original = previous.request.copy
    original.delete("submission_id")
    if original != request: raise newException(ValueError, "An earlier request is unconfirmed. Check that saved request before starting another.")
    return previous
  let expected = if previous.id.len == 0: newJNull() else: %previous.id
  let response = await postSlot("/api/v1/submission-intents",
    %*{"kind": kind, "target_id": target, "expected_id": expected, "request": request}, csrf)
  let parsed = parseSlot(response, kind, target)
  var original = parsed.request.copy
  original.delete("submission_id")
  if parsed.state != "pending" or original != request:
    raise newException(ValueError, "The reservation did not confirm the exact request. Check it before dispatching.")
  slots[slotKey(owner, kind, target)] = parsed
  return parsed

proc acknowledgeIntent*(owner, kind, target, intentId: string, csrf: string): Future[SubmissionIntent] {.async.} =
  let original = cachedIntent(owner, kind, target)
  if original.id != intentId: raise newException(ValueError, "A newer request owns this slot. Reload its current state.")
  let parsed = parseSlot(await postSlot("/api/v1/submission-intents/acknowledge",
    %*{"kind": kind, "target_id": target, "intent_id": intentId}, csrf), kind, target)
  if parsed.id != intentId or parsed.state != "acknowledged" or parsed.request != original.request:
    raise newException(ValueError, "The server did not confirm the original accepted request.")
  slots[slotKey(owner, kind, target)] = parsed
  return parsed

proc clearIntentCache*(owner: string) =
  var keys: seq[string]
  for key in slots.keys:
    let scope = parseJson(key)
    if scope[1].getStr == owner: keys.add key
  for key in keys: slots.del(key)
