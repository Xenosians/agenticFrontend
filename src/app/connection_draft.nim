import types

proc clearUsageDraft*(state: AppState) =
  state.connectionOptionsId = ""
  state.connectionTpm = ""
  state.connectionRpm = ""
  state.connectionMaxWait = ""
  state.connectionReasoning = ""

proc clearConnectionDraft*(state: AppState) =
  state.clearUsageDraft()
  state.connectionName = ""
  state.connectionBackend = "http"
  state.connectionModel = ""
  state.connectionUrl = ""
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
