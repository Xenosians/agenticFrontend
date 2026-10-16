import std/[json, unittest]
import ../src/api/connection_options
import ../src/app/[types, connection_draft]

suite "connection usage settings":
  test "empty settings omit configuration unless explicitly clearing a saved connection":
    check connectionOptionsPayload("", "", "", "").len == 0
    let cleared = connectionOptionsPayload("", "", "", "", clearEmpty = true)
    for key in ["provider_tokens_per_minute", "provider_requests_per_minute",
                "admission_max_wait_seconds", "reasoning_effort"]:
      check cleared[key].kind == JNull
    check not cleared.hasKey("api_key")
    check not cleared.hasKey("model")
  test "valid numeric values remain numbers and reasoning remains an explicit option":
    let value = connectionOptionsPayload(" 8000 ", "30", "0.5", "low")
    check value["provider_tokens_per_minute"].getInt == 8000
    check value["provider_requests_per_minute"].getInt == 30
    check value["admission_max_wait_seconds"].getFloat == 0.5
    check value["reasoning_effort"].getStr == "low"
  test "invalid or partially numeric limits cannot be silently coerced":
    for text in ["0", "-1", "8k", "1.5", "1000000001"]:
      expect ValueError:
        discard connectionOptionsPayload(text, "", "", "")
    expect ValueError:
      discard connectionOptionsPayload("", "1000001", "", "")
  test "wait is finite and bounded and unsupported effort is rejected":
    for text in ["-1", "121", "NaN", "Inf", "-Inf", "3 seconds"]:
      expect ValueError:
        discard connectionOptionsPayload("", "", text, "")
    expect ValueError:
      discard connectionOptionsPayload("", "", "", "unlimited")

  test "reasoning choices come from exact server capability metadata":
    let catalog = %*{"inference_option_support": [
      {"backend": "http", "model": "example-model", "url": "https://example.test/v1",
       "reasoning_efforts": ["low", "high"]},
      {"backend": "pi", "model": "example/model", "url": "",
       "reasoning_efforts": ["low", "medium"]}]}
    check reasoningEffortsFor(catalog, "http", "example-model", "https://example.test/v1/") == @["low", "high"]
    check reasoningEffortsFor(catalog, "http", "other-model", "https://example.test/v1").len == 0
    check reasoningEffortsFor(catalog, "http", "example-model", "https://example.test.evil/v1").len == 0
    check reasoningEffortsFor(catalog, "opencode", "example/model", "").len == 0
    check reasoningEffortsFor(catalog, "pi", "example/model", "") == @["low", "medium"]
    check reasoningEffortsFor(nil, "http", "example-model", "https://example.test/v1").len == 0

  test "new connection and logout cannot retain another connection or account draft":
    let state = AppState(connectionOptionsId: "old-resource", connectionName: "Old account model",
      connectionBackend: "pi", connectionModel: "old/model", connectionUrl: "https://old.test",
      connectionKey: "private-draft", connectionTpm: "8000", connectionRpm: "20",
      connectionMaxWait: "65", connectionReasoning: "low", pluginSection: "limits",
      datasetName: "Private dataset", datasetSource: "Private source", datasetLicense: "Owned",
      datasetPurpose: "training", datasetText: "Private draft", datasetApiKey: "private", datasetReviewed: true)
    state.clearConnectionDraft()
    check state.connectionOptionsId == ""
    check state.connectionKey == "" and state.connectionName == ""
    check state.connectionModel == "" and state.connectionUrl == ""
    check state.connectionReasoning == "" and state.connectionTpm == ""
    state.clearExtensionDrafts()
    check state.pluginSection == "public"
    check state.datasetName == "" and state.datasetText == "" and state.datasetApiKey == ""
    check state.datasetSource == "" and state.datasetLicense == "" and not state.datasetReviewed
