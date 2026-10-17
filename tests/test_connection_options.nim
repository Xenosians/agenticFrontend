import std/[json, unittest]
import ../src/api/connection_options
import ../src/app/[types, connection_draft]

suite "connection usage settings":
  test "empty settings omit configuration unless explicitly clearing a saved connection":
    check connectionOptionsPayload("", "", "", "").len == 0
    let cleared = connectionOptionsPayload("", "", "", "", clearEmpty = true)
    for key in ["provider_tokens_per_minute", "provider_requests_per_minute",
                "admission_max_wait_seconds", "reasoning_effort", "thinking_mode"]:
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

  test "endpoint-wide rows apply to every model on that exact endpoint":
    let catalog = %*{"inference_option_support": [
      {"backend": "http", "url": "https://api.anthropic.com",
       "reasoning_efforts": ["low", "medium", "high", "unlimited"],
       "thinking_modes": ["adaptive", "disabled", "enabled"]}]}
    for model in ["claude-sonnet-5-5", "claude-haiku-5-5"]:
      check reasoningEffortsFor(catalog, "http", model, "https://api.anthropic.com/") == @["low", "medium", "high"]
      check thinkingModesFor(catalog, "http", model, "https://api.anthropic.com") == @["adaptive", "disabled"]
    check thinkingModesFor(catalog, "http", "claude-sonnet-5-5", "https://api.anthropic.com.evil.test").len == 0
    check thinkingModesFor(catalog, "pi", "anthropic/claude-sonnet-5-5", "").len == 0

  test "thinking mode is an explicit, validated option":
    check connectionOptionsPayload("", "", "", "", thinking = "disabled")["thinking_mode"].getStr == "disabled"
    check connectionOptionsPayload("", "", "", "", clearEmpty = true)["thinking_mode"].kind == JNull
    check not connectionOptionsPayload("", "", "", "").hasKey("thinking_mode")
    expect ValueError:
      discard connectionOptionsPayload("", "", "", "", thinking = "enabled")

  test "new connection and logout cannot retain another connection or account draft":
    let state = AppState(connectionOptionsId: "old-resource", connectionName: "Old account model",
      connectionBackend: "pi", connectionModel: "old/model", connectionUrl: "https://old.test",
      connectionKey: "private-draft", connectionTpm: "8000", connectionRpm: "20",
      connectionMaxWait: "65", connectionReasoning: "low", connectionNetworkingInference: "selected_model", pluginSection: "limits",
      datasetName: "Private dataset", datasetSource: "Private source", datasetLicense: "Owned",
      datasetPurpose: "training", datasetText: "Private draft", datasetApiKey: "private", datasetReviewed: true)
    state.clearConnectionDraft()
    check state.connectionOptionsId == ""
    check state.connectionKey == "" and state.connectionName == ""
    check state.connectionModel == "" and state.connectionUrl == ""
    check state.connectionReasoning == "" and state.connectionTpm == ""
    check state.connectionNetworkingInference == ""
    state.clearExtensionDrafts()
    check state.pluginSection == "public"
    check state.datasetName == "" and state.datasetText == "" and state.datasetApiKey == ""
    check state.datasetSource == "" and state.datasetLicense == "" and not state.datasetReviewed

  test "networking choices come from server metadata without inventing unsupported entries":
    let catalog = %*{"networking_inference_options": {
      "default": "dedicated_local", "choices": [
        {"id": "dedicated_local", "label": "Dedicated networking model"},
        {"id": "selected_model", "label": "Use this connection for networking"},
        {"id": "selected_model", "label": "Duplicate"},
        {"id": "unsafe_override", "label": "Not supported"}]}}
    check networkingInferenceChoices(catalog) == @[
      ("dedicated_local", "Dedicated networking model"),
      ("selected_model", "Use this connection for networking")]
    check networkingInferenceDefault(catalog) == "dedicated_local"
    check networkingInferenceChoices(nil).len == 0
    check networkingInferenceChoices(%*{"networking_inference_options": {"choices": "invalid"}}).len == 0

  test "restoring a saved model defaults safely and clears credential drafts across all backends":
    for backend in ["http", "pi", "opencode", "local", "uploaded"]:
      let state = AppState(connectionKey: "private-draft", connectionNetworkingInference: "selected_model")
      state.loadConnectionOptions(%*{"id": "connection-1", "backend": backend, "name": "Model"})
      check state.connectionNetworkingInference == "dedicated_local"
      check state.connectionOptionsId == "connection-1"
      check state.connectionBackend == backend
      check state.connectionKey == ""
      state.loadConnectionOptions(%*{"id": "connection-1", "backend": backend, "networking_inference": "selected_model"})
      check state.connectionNetworkingInference == "selected_model"
      state.loadConnectionOptions(%*{"id": "connection-1", "backend": backend, "networking_inference": nil})
      check state.connectionNetworkingInference == "dedicated_local"

  test "networking options update every model type without credentials or provider-only options on local models":
    for backend in ["http", "pi", "opencode", "local", "uploaded"]:
      let payload = connectionOptionsPayload("", "", "", "", clearEmpty = true,
                                             networking = "selected_model", backend = backend)
      check payload["networking_inference"].getStr == "selected_model"
      check not payload.hasKey("api_key") and not payload.hasKey("model")
      if backend in ["local", "uploaded"]:
        check payload.len == 1
      else:
        check payload["provider_tokens_per_minute"].kind == JNull
      let reset = connectionOptionsPayload("", "", "", "", networking = "dedicated_local", backend = backend)
      check reset["networking_inference"].getStr == "dedicated_local"
    expect ValueError:
      discard connectionOptionsPayload("", "", "", "", networking = "all_tools_without_policy")
