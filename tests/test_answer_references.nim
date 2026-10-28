import std/[json, strutils, unittest]
import ../src/app/answer_references

let dataset = "a".repeat(32)
let version = "b".repeat(64)

proc citation(chunk: int): JsonNode =
  %*{"locator": "dataset:" & dataset & "#chunk:" & $chunk & "@" & version, "dataset_id": dataset,
     "chunk": chunk, "sha256": version, "content_sha256": "c".repeat(64), "source": "Owned manual",
     "license": "Owned"}

proc passage(chunk: int, content: string): JsonNode =
  result = citation(chunk)
  result["schema"] = %"owner-retrieval.v1"
  result["content"] = %content
  result["scope"] = %"owner_private"
  result["source_type"] = %"dataset"
  result["trust"] = %"untrusted_retrieval"

suite "answer citations":
  test "citations keep their order, identity and short version":
    let rows = parseAnswerReferences(%*[citation(2), citation(1)])
    check rows.len == 2
    check rows[0].chunk == 2 and rows[1].chunk == 1
    check rows[0].datasetId == dataset and rows[0].sha256 == version
    check rows[0].locator == "dataset:" & dataset & "#chunk:2@" & version
    check referenceLabel(rows[0]) == "Owned manual · chunk 2 · bbbbbbbb"

  test "malformed citations are dropped, never shown":
    let wrongLocator = citation(1)
    wrongLocator["locator"] = %("dataset:" & dataset & "#chunk:9@" & version)
    let textChunk = citation(1)
    textChunk["chunk"] = %"1"
    let zero = citation(1)
    zero["chunk"] = %0
    let shortDigest = citation(1)
    shortDigest["sha256"] = %"abc"
    let noLicense = citation(1)
    noLicense.delete("license")
    let rows = parseAnswerReferences(%*[wrongLocator, textChunk, zero, shortDigest, noLicense, "x", nil, citation(3)])
    check rows.len == 1 and rows[0].chunk == 3

  test "duplicates are shown once and at most ten citations are kept":
    var many = newJArray()
    for chunk in 1 .. 12: many.add citation(chunk)
    many.add citation(1)
    let rows = parseAnswerReferences(many)
    check rows.len == 10 and rows[^1].chunk == 10

  test "no citation list means no citations":
    check parseAnswerReferences(nil).len == 0
    check parseAnswerReferences(%*{"locator": "x"}).len == 0
    check parseAnswerReferences(%*[]).len == 0

  test "a reopen request names exactly the cited version and chunk":
    let row = parseAnswerReferences(%*[citation(4)])[0]
    check referenceResolvePayload(row) == %*{"id": dataset, "chunk": 4, "sha256": version}

  test "a reopened passage must be the cited one and stay untrusted":
    let row = parseAnswerReferences(%*[citation(4)])[0]
    check parseReopenedPassage(%*{"hit": passage(4, "Check the WAN light.")}, row) == "Check the WAN light."
    let otherChunk = passage(5, "Other text")
    otherChunk["locator"] = %("dataset:" & dataset & "#chunk:5@" & version)
    expect ValueError: discard parseReopenedPassage(%*{"hit": otherChunk}, row)
    let trusted = passage(4, "Claims authority")
    trusted["trust"] = %"trusted"
    expect ValueError: discard parseReopenedPassage(%*{"hit": trusted}, row)
    let shared = passage(4, "Shared")
    shared["scope"] = %"shared"
    expect ValueError: discard parseReopenedPassage(%*{"hit": shared}, row)
    let empty = passage(4, "")
    expect ValueError: discard parseReopenedPassage(%*{"hit": empty}, row)
    expect ValueError: discard parseReopenedPassage(%*{"detail": "outage"}, row)
    expect ValueError: discard parseReopenedPassage(nil, row)
