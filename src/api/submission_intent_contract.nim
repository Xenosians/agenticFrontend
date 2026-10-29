## Typed public coordination receipt. It carries an existing operation identity;
## parsing a slot never dispatches or acknowledges work.
import std/[json, strutils]

type SubmissionIntent* = object
  id*, state*: string
  request*, context*, receipt*: JsonNode

proc hex(value: string, size: int): bool =
  value.len == size and value.allCharsInSet({'0'..'9', 'a'..'f'})

proc parseSubmissionIntent*(data: JsonNode, kind, target: string): SubmissionIntent =
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
