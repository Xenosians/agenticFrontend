## Dataset version identity (FR-085).
##
## A changed dataset is uploaded as a new version of the latest version of
## its history. The AI service owns the identity; this module only names it
## and builds the upload payload.

import std/json

type
  DatasetChoice* = object
    id*, label*: string


proc text(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString: node[key].getStr
  else: ""


proc datasetVersion*(row: JsonNode): int =
  ## A dataset saved before versioning is the first version of its own history.
  if row != nil and row.kind == JObject and row.hasKey("version") and row["version"].kind == JInt: row["version"].getInt
  else: 1


proc datasetTitle*(row: JsonNode): string =
  ## The dataset's name, with its version once the dataset has more than one.
  result = text(row, "name")
  if datasetVersion(row) > 1 or text(row, "superseded_by").len > 0:
    result.add " (v" & $datasetVersion(row) & ")"


proc datasets(catalog: JsonNode): seq[JsonNode] =
  if catalog != nil and catalog.kind == JObject and catalog.hasKey("resources") and
     catalog["resources"].kind == JArray:
    for row in catalog["resources"]:
      if text(row, "kind") == "dataset" and text(row, "id").len > 0:
        result.add row


proc versionLabel*(catalog, row: JsonNode): string =
  ## "v2 · cccc3333", plus "· replaced by v3" once a newer version exists.
  result = "v" & $datasetVersion(row)
  let digest = text(row, "sha256")
  if digest.len > 0:
    result.add " · " & digest[0 ..< min(8, digest.len)]
  let newer = text(row, "superseded_by")
  if newer.len > 0:
    result.add " · replaced"
    for other in datasets(catalog):
      if text(other, "id") == newer:
        result.add " by v" & $datasetVersion(other)


proc replaceableDatasets*(catalog: JsonNode, purpose: string): seq[DatasetChoice] =
  ## The latest version of each dataset history with this purpose, always
  ## named with the version a new upload would replace.
  if purpose.len == 0: return
  for row in datasets(catalog):
    if text(row, "purpose") == purpose and text(row, "superseded_by").len == 0:
      result.add DatasetChoice(id: text(row, "id"),
                               label: text(row, "name") & " (v" & $datasetVersion(row) & ")")


proc validReplacement*(catalog: JsonNode, purpose, chosen: string): string =
  ## The chosen version while it can still be replaced, otherwise none.
  for choice in replaceableDatasets(catalog, purpose):
    if choice.id == chosen: return chosen


proc datasetPayload*(name, text, source, license, purpose: string, reviewed: bool,
                     replaces: string): JsonNode =
  result = %*{"name": name, "text": text, "source": source, "license": license,
              "purpose": purpose, "reviewed": reviewed}
  if replaces.len > 0:
    result["replaces"] = %replaces
