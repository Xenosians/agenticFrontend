include karax/prelude
import std/[asyncjs, json, strutils]
import types
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
      state.connectionMaxWait, state.connectionReasoning, clearEmpty = existing)
    if existing:
      payload["id"] = %state.connectionOptionsId
      await changeExtension(state, "model_options", payload)
    else:
      payload["name"] = %state.connectionName
      payload["backend"] = %state.connectionBackend
      payload["model"] = %state.connectionModel
      payload["url"] = %state.connectionUrl
      payload["api_key"] = %state.connectionKey
      await changeExtension(state, "model", payload)
  except CatchableError:
    state.extensionError = "Check the usage limits and queue wait, then save again."
    redraw(kxi)

proc saveDatasetFile*(state: AppState) {.async.} =
  let session = state.auth.sessionId
  try:
    let content = $(await datasetFileText())
    if not sameSession(state, session): return
    await changeExtension(state, "dataset", %*{"name": state.datasetName, "text": content,
      "source": state.datasetSource, "license": state.datasetLicense, "purpose": state.datasetPurpose,
      "reviewed": state.datasetReviewed})
  except CatchableError as exc:
    if sameSession(state, session): state.extensionError = exc.msg
    redraw(kxi)

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
