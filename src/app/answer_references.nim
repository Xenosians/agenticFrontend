## Citations under an answer (FR-083, V19-06): the reference passages its
## model was given. A citation names a dataset version and chunk; reopening one
## shows that exact passage, still as untrusted reference text.

import std/[json, sets, strutils]

const maxAnswerReferences* = 10

type
  AnswerReference* = object
    locator*, datasetId*, sha256*, contentSha256*, source*, license*: string
    chunk*: int


proc text(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr
  else: ""


proc hex(value: string, length: int): bool =
  value.len == length and value.allCharsInSet({'0'..'9', 'a'..'f'})


proc parseReference(node: JsonNode, row: var AnswerReference): bool =
  if node == nil or node.kind != JObject or node.len != 7 or not node.hasKey("chunk") or
      node["chunk"].kind != JInt or node["chunk"].getInt < 1:
    return false
  row = AnswerReference(locator: text(node, "locator"), datasetId: text(node, "dataset_id"),
    sha256: text(node, "sha256"), contentSha256: text(node, "content_sha256"),
    source: text(node, "source"), license: text(node, "license"), chunk: node["chunk"].getInt)
  hex(row.datasetId, 32) and hex(row.sha256, 64) and hex(row.contentSha256, 64) and
    row.source.len > 0 and row.license.len > 0 and
    row.locator == "dataset:" & row.datasetId & "#chunk:" & $row.chunk & "@" & row.sha256


proc parseAnswerReferences*(node: JsonNode): seq[AnswerReference] =
  ## Well-formed citations in order, once each, at most ten; anything else is dropped.
  if node == nil or node.kind != JArray:
    return
  var seen = initHashSet[string]()
  for item in node:
    var row: AnswerReference
    if result.len < maxAnswerReferences and parseReference(item, row) and row.locator notin seen:
      seen.incl row.locator
      result.add row


proc referenceLabel*(row: AnswerReference): string =
  row.source & " · chunk " & $row.chunk & " · " & row.sha256[0 ..< 8]


proc referenceResolvePayload*(row: AnswerReference): JsonNode =
  %*{"id": row.datasetId, "chunk": row.chunk, "sha256": row.sha256}


proc parseReopenedPassage*(data: JsonNode, row: AnswerReference): string =
  ## The passage text, only when the answer is the exact cited, untrusted, owner-private passage.
  if data == nil or data.kind != JObject or not data.hasKey("hit"):
    raise newException(ValueError, "The passage could not be reopened. Try again.")
  let hit = data["hit"]
  if text(hit, "schema") != "owner-retrieval.v1" or text(hit, "locator") != row.locator or
      text(hit, "trust") != "untrusted_retrieval" or text(hit, "scope") != "owner_private" or
      text(hit, "content").len == 0:
    raise newException(ValueError, "The reopened passage does not match its citation.")
  text(hit, "content")
