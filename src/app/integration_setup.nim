## Provider setup readiness (FR-081, NFR-036).
##
## The AI service reports, from its configuration, whether each provider
## family behind the capability catalog is set up. That is not a provider
## check: "Configured" means the settings are present, never that the
## provider answered or an action succeeded.

import std/json

type
  IntegrationSetup* = object
    id*, name*, state*: string
    missing*: seq[string]

const knownStates = ["configured", "simulated", "not_configured"]


proc text(node: JsonNode, key: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString: node[key].getStr
  else: ""


proc parseIntegrationSetup*(data: JsonNode): seq[IntegrationSetup] =
  ## One row per provider with an identity. A state this version does not
  ## know is "unknown", never set up.
  if data.kind != JObject or not data.hasKey("integrations") or data["integrations"].kind != JArray:
    return
  for item in data["integrations"]:
    let id = text(item, "id")
    if id.len == 0:
      continue
    var state = text(item, "state")
    if state.len == 0 and item.hasKey("configured") and item["configured"].kind == JBool:
      # An AI service from before per-provider states reports only this flag.
      state = if item["configured"].getBool: "configured" else: "not_configured"
    if state notin knownStates:
      state = "unknown"
    var missing: seq[string]
    if item.hasKey("missing") and item["missing"].kind == JArray:
      for name in item["missing"]:
        if name.kind == JString and name.getStr.len > 0:
          missing.add name.getStr
    result.add IntegrationSetup(id: id, name: (let name = text(item, "name"); if name.len > 0: name else: id),
                                state: state, missing: missing)


proc setupLabel*(state: string): string =
  case state
  of "configured": "Configured"
  of "simulated": "Simulated"
  of "not_configured": "Needs setup"
  else: "Setup unknown"
