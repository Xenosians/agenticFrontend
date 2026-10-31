include karax/prelude
import std/[asyncjs, json, strutils]
import types
import dataset_versions
import lua_transforms
import knowledge_crawl
import ../api/extensions
import ../api/connection_options
import ../config/runtime_config

proc sameSession(state: AppState, session: string): bool =
  state.auth.authenticated and state.auth.sessionId == session

proc loadExtensions(state: AppState, session: string) {.async.} =
  # The caller owns extensionBusy until its entire operation finishes.
  let catalog = await extensionCatalog()
  if not sameSession(state, session): return
  state.extensionCatalog = catalog
  state.tools.setLen(0)
  for item in state.extensionCatalog["capabilities"]:
    state.tools.add(ToolItem(id: item["id"].getStr, name: item["id"].getStr, enabled: true))
  state.extensionError = ""

proc refreshExtensions*(state: AppState) {.async.} =
  if state.extensionBusy or not state.auth.authenticated: return
  let session = state.auth.sessionId
  state.extensionBusy = true
  try:
    await loadExtensions(state, session)
  except CatchableError as exc:
    if sameSession(state, session): state.extensionError = exc.msg
  finally:
    if sameSession(state, session): state.extensionBusy = false
    redraw(kxi)

proc changeExtension*(state: AppState, action: string, payload: JsonNode) {.async.} =
  if state.extensionBusy or not state.auth.authenticated: return
  let session = state.auth.sessionId
  state.extensionBusy = true
  state.extensionError = ""
  try:
    let response = await extensionRequest(action, payload, state.auth.csrfToken)
    if not sameSession(state, session): return
    if action == "export_dataset": downloadTrainingDataset(cstring($response))
    state.toastMessage = if action == "probe": $response else: "Saved. Changes apply to your next request."
    state.connectionKey = ""
    state.datasetApiKey = ""
    await loadExtensions(state, session)
  except CatchableError as exc:
    if sameSession(state, session): state.extensionError = exc.msg
  finally:
    if sameSession(state, session): state.extensionBusy = false
    redraw(kxi)

proc saveConnectionOptions*(state: AppState, existing = false) {.async.} =
  try:
    let payload = connectionOptionsPayload(state.connectionTpm, state.connectionRpm,
      state.connectionMaxWait, state.connectionReasoning, clearEmpty = existing,
      networking = state.connectionNetworkingInference, backend = state.connectionBackend,
      thinking = state.connectionThinking)
    if existing:
      payload["id"] = %state.connectionOptionsId
      await changeExtension(state, "model_options", payload)
    else:
      payload["name"] = %state.connectionName
      payload["backend"] = %state.connectionBackend
      payload["model"] = %state.connectionModel
      payload["url"] = %state.connectionUrl
      if state.connectionBackend == "http" and state.connectionApiFormat.len > 0:
        payload["api_format"] = %state.connectionApiFormat
      if state.connectionBackend == "http" and state.connectionProviderId.strip().len > 0:
        payload["provider_id"] = %state.connectionProviderId.strip().toLowerAscii()
      payload["api_key"] = %state.connectionKey
      await changeExtension(state, "model", payload)
  except CatchableError:
    state.extensionError = "Check the model settings, usage limits and queue wait, then save again."
    redraw(kxi)

proc loadProviderModels*(state: AppState) {.async.} =
  ## Ask the provider which models this key can use. The key is sent once for
  ## the lookup and is not stored; saving the connection stores it encrypted.
  if state.extensionBusy or not state.auth.authenticated: return
  let session = state.auth.sessionId
  state.extensionBusy = true
  state.extensionError = ""
  try:
    var payload = %*{"url": state.connectionUrl, "api_key": state.connectionKey}
    if state.connectionApiFormat.len > 0:
      payload["api_format"] = %state.connectionApiFormat
    let response = await extensionRequest("models", payload, state.auth.csrfToken)
    if not sameSession(state, session): return
    state.connectionModelChoices.setLen(0)
    if response.kind == JObject and response.hasKey("models") and response["models"].kind == JArray:
      for row in response["models"]:
        if row.kind == JObject and row.hasKey("id") and row["id"].kind == JString:
          let name = if row.hasKey("name") and row["name"].kind == JString: row["name"].getStr else: row["id"].getStr
          state.connectionModelChoices.add((row["id"].getStr, name))
    if state.connectionModelChoices.len == 0:
      state.extensionError = "The provider returned no models for this key."
  except CatchableError as exc:
    if sameSession(state, session): state.extensionError = exc.msg
  finally:
    if sameSession(state, session): state.extensionBusy = false
    redraw(kxi)

proc saveDatasetFile*(state: AppState) {.async.} =
  let session = state.auth.sessionId
  try:
    let content = $(await datasetFileText())
    if not sameSession(state, session): return
    # A replacement that no longer applies (a newer version arrived) uploads nothing as a version.
    let replaces = validReplacement(state.extensionCatalog, state.datasetPurpose, state.datasetReplaces)
    await changeExtension(state, "dataset", datasetPayload(state.datasetName, content,
      state.datasetSource, state.datasetLicense, state.datasetPurpose, state.datasetReviewed, replaces))
  except CatchableError as exc:
    if sameSession(state, session): state.extensionError = exc.msg
    redraw(kxi)

proc changeDatasetScript*(state: AppState, script: string) =
  ## A changed script needs a fresh preview before it can be applied.
  state.datasetScript = script
  state.datasetTransformPreviewed = false
  inc state.datasetTransformEpoch

proc previewDatasetTransform*(state: AppState) {.async.} =
  ## Runs the owner's script over the chosen file in the AI service's isolated worker; admits nothing.
  if state.extensionBusy or not state.auth.authenticated: return
  let session = state.auth.sessionId
  inc state.datasetTransformEpoch
  let epoch = state.datasetTransformEpoch
  state.extensionBusy = true
  state.extensionError = ""
  state.datasetTransformPreviewed = false
  redraw(kxi)
  try:
    let content = $(await datasetFileText())
    if not sameSession(state, session) or epoch != state.datasetTransformEpoch: return
    let preview = parseTransformPreview(await extensionRequest("dataset_transform",
      transformPayload(state.datasetScript, content), state.auth.csrfToken))
    if not sameSession(state, session) or epoch != state.datasetTransformEpoch: return
    state.datasetTransformPreview = preview
    state.datasetTransformPreviewed = true
  except CatchableError as exc:
    if sameSession(state, session) and epoch == state.datasetTransformEpoch: state.extensionError = exc.msg
  finally:
    if sameSession(state, session): state.extensionBusy = false
    redraw(kxi)

proc applyDatasetTransform*(state: AppState) {.async.} =
  ## Admits the script's output exactly like an upload; only after a preview of this script.
  if not state.datasetTransformPreviewed: return
  let session = state.auth.sessionId
  let epoch = state.datasetTransformEpoch
  try:
    let content = $(await datasetFileText())
    if not sameSession(state, session) or epoch != state.datasetTransformEpoch: return
    let replaces = validReplacement(state.extensionCatalog, state.datasetPurpose, state.datasetReplaces)
    await changeExtension(state, "dataset_transform", transformApplyPayload(state.datasetScript, content,
      state.datasetName, state.datasetSource, state.datasetLicense, state.datasetPurpose,
      state.datasetReviewed, replaces))
    if sameSession(state, session) and state.extensionError.len == 0:
      state.datasetTransformPreviewed = false
  except CatchableError as exc:
    if sameSession(state, session): state.extensionError = exc.msg
    redraw(kxi)

proc crawlSite*(state: AppState) {.async.} =
  ## Crawls one page tree of a site the machine's profile declares into reference knowledge.
  ## A start page outside every declared site is never sent.
  if crawlSiteOf(state.datasetCrawlUrl, crawlSources(state.extensionCatalog)).len == 0: return
  let replaces = validReplacement(state.extensionCatalog, "rag", state.datasetReplaces)
  await changeExtension(state, "dataset_crawl", crawlPayload(state.datasetCrawlUrl, state.datasetName,
    state.datasetLicense, state.datasetReviewed, replaces))

proc uploadUserModel*(state: AppState) {.async.} =
  if state.extensionBusy or not state.auth.authenticated: return
  let session = state.auth.sessionId
  let name = state.connectionName.strip()
  let uploadName = if name.len > 0: name else: "Uploaded local model"
  state.extensionBusy = true
  try:
    discard await uploadModelFiles(cstring(frontendConfig.backendBaseUrl), cstring(state.auth.csrfToken), cstring(uploadName))
    if not sameSession(state, session): return
    state.toastMessage = "Model uploaded and format checked. Test its compatibility before relying on it."
    await loadExtensions(state, session)
  except CatchableError as exc:
    if sameSession(state, session): state.extensionError = exc.msg
  finally:
    if sameSession(state, session): state.extensionBusy = false
    redraw(kxi)
