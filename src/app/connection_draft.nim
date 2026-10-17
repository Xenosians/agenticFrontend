import types
import std/json
import ../api/connection_options

proc clearUsageDraft*(state: AppState) =
  state.connectionOptionsId = ""
  state.connectionTpm = ""
  state.connectionRpm = ""
  state.connectionMaxWait = ""
  state.connectionReasoning = ""
  state.connectionThinking = ""
  state.connectionNetworkingInference = ""

proc loadConnectionOptions*(state: AppState, item: JsonNode) =
  state.connectionOptionsId = optionText(item, "id")
  state.connectionName = optionText(item, "name")
  state.connectionBackend = optionText(item, "backend")
  state.connectionModel = optionText(item, "model")
  state.connectionUrl = optionText(item, "url")
  state.connectionTpm = optionText(item, "provider_tokens_per_minute")
  state.connectionRpm = optionText(item, "provider_requests_per_minute")
  state.connectionMaxWait = optionText(item, "admission_max_wait_seconds")
  state.connectionReasoning = optionText(item, "reasoning_effort")
  state.connectionThinking = optionText(item, "thinking_mode")
  state.connectionApiFormat = optionText(item, "api_format")
  state.connectionProviderId = optionText(item, "provider_id")
  let saved = optionText(item, "networking_inference")
  state.connectionNetworkingInference =
    if saved in ["dedicated_local", "selected_model"]: saved
    else: networkingInferenceDefault(state.extensionCatalog)
  state.connectionKey = ""

proc clearConnectionDraft*(state: AppState) =
  state.clearUsageDraft()
  state.connectionName = ""
  state.connectionBackend = "http"
  state.connectionModel = ""
  state.connectionUrl = ""
  state.connectionApiFormat = ""
  state.connectionProviderId = ""
  state.connectionModelChoices.setLen(0)
  state.connectionKey = ""

proc clearExtensionDrafts*(state: AppState) =
  state.clearConnectionDraft()
  state.pluginSection = "public"
  state.pluginSearchDraft = ""
  state.datasetName = ""
  state.datasetSource = ""
  state.datasetLicense = ""
  state.datasetPurpose = "rag"
  state.datasetText = ""
  state.datasetApiKey = ""
  state.datasetReviewed = false
