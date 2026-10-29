## Lua row transforms (SRS 1.9 FR-097, V19-11): the owner's optional script that
## reshapes their own JSON Lines rows before ordinary dataset admission. The
## browser never runs the script; it sends it and shows the isolated worker's
## preview or a curated refusal.

import std/[json, strutils]

const
  transformSchema* = "lua-row-transform.v1"
  maxPreviewRows* = 5
  starterScript* = """-- Map each row to a new one; return nil to drop it.
return function(row)
  return {messages = {
    {role = "user", content = row.question},
    {role = "assistant", content = row.answer},
  }}
end
"""

type
  TransformPreview* = object
    inputRows*, outputRows*, elapsedMs*: int
    rows*: seq[string]
    isolation*: seq[string]


proc invalid() =
  raise newException(ValueError, "The transform response was invalid. Try the preview again.")


proc count(node: JsonNode, key: string, minimum = 0): int =
  if node == nil or node.kind != JObject or not node.hasKey(key) or node[key].kind != JInt or
      node[key].getInt < minimum:
    invalid()
  node[key].getInt


proc transformAvailable*(catalog: JsonNode): bool =
  ## Whether the AI service can run Lua transforms on this host.
  if catalog == nil or catalog.kind != JObject or not catalog.hasKey("transforms") or
      catalog["transforms"].kind != JArray:
    return false
  for item in catalog["transforms"]:
    if item.kind == JObject and item.hasKey("id") and item["id"].kind == JString and
        item["id"].getStr == "lua-row-transform" and item.hasKey("available") and
        item["available"].kind == JBool:
      return item["available"].getBool
  false


proc parseTransformPreview*(data: JsonNode): TransformPreview =
  ## A preview admits nothing: it carries counts and at most five rows, never the full text.
  if data == nil or data.kind != JObject or data.hasKey("text") or data.hasKey("id"):
    invalid()
  if not data.hasKey("schema") or data["schema"].kind != JString or data["schema"].getStr != transformSchema:
    invalid()
  result.inputRows = count(data, "input_rows", 1)
  result.outputRows = count(data, "output_rows", 1)
  result.elapsedMs = count(data, "elapsed_ms")
  if result.outputRows > 10_000 or result.inputRows > 10_000:
    invalid()
  if not data.hasKey("preview") or data["preview"].kind != JArray or data["preview"].len == 0 or
      data["preview"].len > maxPreviewRows or data["preview"].len > result.outputRows:
    invalid()
  for row in data["preview"]:
    if row.kind != JObject:
      invalid()
    result.rows.add $row
  if not data.hasKey("isolation") or data["isolation"].kind != JArray:
    invalid()
  for layer in data["isolation"]:
    if layer.kind != JString or layer.getStr.len == 0 or layer.getStr.len > 40:
      invalid()
    result.isolation.add layer.getStr
  if "process" notin result.isolation or "no_new_descriptors" notin result.isolation:
    invalid()


proc transformPayload*(script, text: string): JsonNode =
  %*{"script": script, "text": text, "apply": false}


proc transformApplyPayload*(script, text, name, source, license, purpose: string,
                            reviewed: bool, replaces: string): JsonNode =
  result = %*{"script": script, "text": text, "apply": true, "name": name, "source": source,
              "license": license, "purpose": purpose, "reviewed": reviewed}
  if replaces.len > 0:
    result["replaces"] = %replaces


proc isolationLabel*(preview: TransformPreview): string =
  ## A short, readable account of how the script was isolated.
  var parts: seq[string]
  if "network_namespace" in preview.isolation or "landlock" in preview.isolation:
    parts.add "no network"
  if "landlock" in preview.isolation:
    parts.add "no file access"
  parts.add "no new files or processes"
  "Ran in an isolated worker: " & parts.join(", ") & "."
