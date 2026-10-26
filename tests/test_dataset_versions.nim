import std/[json, unittest]
import ../src/app/dataset_versions

let catalog = %*{"resources": [
  {"id": "manual-v1", "kind": "dataset", "name": "Manual", "purpose": "rag", "version": 1,
   "lineage_id": "manual-v1", "sha256": "aaaa1111bbbb2222", "superseded_by": "manual-v2"},
  {"id": "manual-v2", "kind": "dataset", "name": "Manual", "purpose": "rag", "version": 2,
   "lineage_id": "manual-v1", "previous_id": "manual-v1", "sha256": "cccc3333dddd4444"},
  {"id": "examples", "kind": "dataset", "name": "Examples", "purpose": "training",
   "sha256": "eeee5555ffff6666"},
  {"id": "model", "kind": "model", "name": "Model"}]}

suite "dataset versions":
  test "each dataset names its version and digest prefix":
    check versionLabel(catalog, catalog["resources"][0]) == "v1 · aaaa1111 · replaced by v2"
    check versionLabel(catalog, catalog["resources"][1]) == "v2 · cccc3333"
    # A dataset saved before versioning is its own first version.
    check versionLabel(catalog, catalog["resources"][2]) == "v1 · eeee5555"
    # A newer version that is not listed is still named as a replacement.
    check versionLabel(nil, catalog["resources"][0]) == "v1 · aaaa1111 · replaced"
    check datasetTitle(catalog["resources"][0]) == "Manual (v1)"
    check datasetTitle(catalog["resources"][1]) == "Manual (v2)"
    # A dataset with a single version keeps its plain name.
    check datasetTitle(catalog["resources"][2]) == "Examples"

  test "only the latest version of each history can be replaced":
    let choices = replaceableDatasets(catalog, "rag")
    check choices.len == 1
    check choices[0].id == "manual-v2"
    check choices[0].label == "Manual (v2)"
    check replaceableDatasets(catalog, "training")[0].id == "examples"
    # The choice always names the version a new upload replaces.
    check replaceableDatasets(catalog, "training")[0].label == "Examples (v1)"
    check replaceableDatasets(catalog, "").len == 0

  test "the upload names the version it replaces, or none for a new dataset":
    let fresh = datasetPayload("Manual", "text", "Owned", "Owned", "rag", true, "")
    check not fresh.hasKey("replaces")
    let next = datasetPayload("Manual", "text", "Owned", "Owned", "rag", true, "manual-v2")
    check next["replaces"].getStr == "manual-v2"
    check next["reviewed"].getBool

  test "a replaced choice that no longer applies is dropped":
    check validReplacement(catalog, "rag", "manual-v2") == "manual-v2"
    check validReplacement(catalog, "rag", "manual-v1") == ""
    check validReplacement(catalog, "training", "manual-v2") == ""
    check validReplacement(catalog, "rag", "") == ""
    check replaceableDatasets(nil, "rag").len == 0
