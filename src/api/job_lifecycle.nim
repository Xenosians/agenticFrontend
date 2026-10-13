import std/json

const publicJobStates* = ["pending", "processing", "waiting_approval", "completed", "failed", "denied", "outcome_unknown"]

proc validateJobV2*(data: JsonNode) =
  if data.kind != JObject or not data.hasKey("contract_version") or
      data["contract_version"].kind != JInt or data["contract_version"].getInt != 2:
    raise newException(ValueError, "Unsupported job response version.")
  if not data.hasKey("status") or data["status"].kind != JString or
      data["status"].getStr notin publicJobStates:
    raise newException(ValueError, "Unsupported job lifecycle state.")
