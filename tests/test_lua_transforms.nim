import std/[json, strutils, unittest]
import ../src/app/lua_transforms

proc preview(): JsonNode =
  %*{"schema": "lua-row-transform.v1", "input_rows": 12, "output_rows": 10, "elapsed_ms": 4,
     "isolation": ["process", "no_new_privileges", "network_namespace", "landlock", "resource_limits",
                   "no_new_descriptors"],
     "preview": [{"messages": [{"role": "user", "content": "Printer jam"}]}, {"text": "VPN"}]}

suite "lua row transforms":
  test "a preview is read with its counts, rows and isolation":
    let parsed = parseTransformPreview(preview())
    check parsed.inputRows == 12 and parsed.outputRows == 10 and parsed.elapsedMs == 4
    check parsed.rows.len == 2 and parsed.rows[1] == """{"text":"VPN"}"""
    check isolationLabel(parsed) ==
      "Ran in an isolated worker: no network, no file access, no new files or processes."

  test "a preview never carries the full text or an admitted dataset":
    for key, value in {"text": %"rows", "id": %("a".repeat(32))}.items:
      var data = preview()
      data[key] = value
      expect ValueError: discard parseTransformPreview(data)

  test "malformed previews are refused, never shown as empty":
    var cases: seq[JsonNode]
    for mutate in [
      proc(d: JsonNode) = d["schema"] = %"lua-row-transform.v2",
      proc(d: JsonNode) = d["output_rows"] = %0,
      proc(d: JsonNode) = d["input_rows"] = %"12",
      proc(d: JsonNode) = d["preview"] = newJArray(),
      proc(d: JsonNode) = d["preview"] = %*[1, 2],
      proc(d: JsonNode) = d["preview"] = %*[{}, {}, {}, {}, {}, {}],
      proc(d: JsonNode) = d["output_rows"] = %1,
      proc(d: JsonNode) = d["isolation"] = %*["no_new_privileges"],
      proc(d: JsonNode) = d.delete("isolation"),
      proc(d: JsonNode) = d["elapsed_ms"] = %(-1)]:
      let data = preview()
      mutate(data)
      cases.add data
    cases.add newJNull()
    cases.add %*[]
    for data in cases:
      expect ValueError: discard parseTransformPreview(data)

  test "without network or Landlock layers the label says only what held":
    var data = preview()
    data["isolation"] = %*["process", "no_new_privileges", "resource_limits", "no_new_descriptors"]
    check isolationLabel(parseTransformPreview(data)) ==
      "Ran in an isolated worker: no new files or processes."

  test "requests carry the script and rows, and apply carries the dataset fields":
    check transformPayload("s", "r") == %*{"script": "s", "text": "r", "apply": false}
    let applied = transformApplyPayload("s", "r", "Name", "Owned", "Internal", "training", true, "")
    check applied == %*{"script": "s", "text": "r", "apply": true, "name": "Name", "source": "Owned",
                         "license": "Internal", "purpose": "training", "reviewed": true}
    check transformApplyPayload("s", "r", "N", "S", "L", "rag", true, "b".repeat(32))["replaces"].getStr ==
      "b".repeat(32)

  test "the catalog says whether transforms can run":
    check transformAvailable(%*{"transforms": [{"id": "lua-row-transform", "available": true}]})
    check not transformAvailable(%*{"transforms": [{"id": "lua-row-transform", "available": false}]})
    check not transformAvailable(%*{"transforms": [{"id": "lua-row-transform", "available": "yes"}]})
    check not transformAvailable(%*{"transforms": [{"id": "other", "available": true}]})
    check not transformAvailable(%*{})
    check not transformAvailable(nil)

  test "the starter script maps question and answer fields to chat messages":
    check starterScript.contains("return function(row)")
    check starterScript.contains("row.question") and starterScript.contains("row.answer")
