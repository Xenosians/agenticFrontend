include karax/prelude
import std/[asyncjs, json]
import ../api/learning as learningApi
import learning
import types
import state
import request_context

proc invalidateLearningPreflight*(state: AppState) =
  inc state.learningEpoch
  state.learningChecking = false
  state.learningPreflight = LearningPreflight()
  state.learningCheckedRequest = nil
  state.learningError = ""

proc normalizeLearningSelection(state: AppState) =
  let catalog = state.learningCatalog
  var valid = false
  for item in catalog.methods:
    if item.id == state.learningMethod: valid = true
  if not valid:
    state.learningMethod = catalog.methods[0].id
    for item in catalog.methods:
      if item.id == "sft": state.learningMethod = item.id
  let contract = methodById(catalog, state.learningMethod)
  if state.learningRole notin contract.roles:
    state.learningRole = contract.roles[0]
    if "hub" in contract.roles: state.learningRole = "hub"
  if state.learningTuning notin contract.tuning:
    state.learningTuning = contract.tuning[0]
    if "qlora" in contract.tuning: state.learningTuning = "qlora"
  valid = false
  for item in catalog.models:
    if item.id == state.learningModel and item.state == "ready": valid = true
  if not valid:
    state.learningModel = ""
    for item in catalog.models:
      if item.state == "ready" and state.learningModel.len == 0: state.learningModel = item.id
    for item in catalog.models:
      if item.state == "ready" and item.sourceKind == "local":
        state.learningModel = item.id
        break
  valid = false
  for item in catalog.datasets:
    if item.id == state.learningDataset and item.state == "ready" and item.supersededBy.len == 0: valid = true
  if not valid:
    state.learningDataset = ""
    for item in catalog.datasets:
      if item.state == "ready" and item.supersededBy.len == 0:
        state.learningDataset = item.id
        break

proc changeLearningSelection*(state: AppState, field, value: string) =
  if state.learningBusy or not state.learningLoaded: return
  invalidateLearningPreflight(state)
  case field
  of "method": state.learningMethod = value
  of "role": state.learningRole = value
  of "tuning": state.learningTuning = value
  of "model": state.learningModel = value
  of "dataset": state.learningDataset = value
  else: return
  normalizeLearningSelection(state)

proc refreshLearning*(state: AppState) {.async.} =
  if not state.auth.authenticated or state.learningBusy: return
  invalidateLearningPreflight(state)
  let request = beginLearningRequest(state)
  state.learningBusy = true
  state.learningLoaded = false
  redraw(kxi)
  try:
    let catalog = parseLearningCatalog(await learningApi.fetchLearningCatalog())
    if not matchesLearningRequest(state, request): return
    state.learningCatalog = catalog
    normalizeLearningSelection(state)
    state.learningLoaded = true
  except CatchableError as exc:
    if matchesLearningRequest(state, request):
      state.learningCatalog = LearningCatalog()
      state.learningError = exc.msg
  finally:
    if matchesLearningRequest(state, request): state.learningBusy = false
    redraw(kxi)

proc preflightLearning*(state: AppState) {.async.} =
  if not state.auth.authenticated or not state.learningLoaded or state.learningBusy or state.learningChecking: return
  var payload: JsonNode
  try:
    payload = learningPreflightPayload(state.learningCatalog, state.learningMethod, state.learningRole,
      state.learningTuning, state.learningModel, state.learningDataset)
  except ValueError as exc:
    state.learningError = exc.msg
    redraw(kxi)
    return
  let catalog = state.learningCatalog
  let request = beginLearningRequest(state)
  state.learningPreflight = LearningPreflight()
  state.learningCheckedRequest = nil
  state.learningChecking = true
  state.learningError = ""
  redraw(kxi)
  try:
    let response = await learningApi.checkLearningReadiness(payload, state.auth.csrfToken)
    if not matchesLearningRequest(state, request): return
    state.learningPreflight = parseLearningPreflight(response, payload, catalog)
    state.learningCheckedRequest = payload
  except CatchableError as exc:
    if matchesLearningRequest(state, request): state.learningError = exc.msg
  finally:
    if matchesLearningRequest(state, request): state.learningChecking = false
    redraw(kxi)

proc learningRunActive*(state: AppState): bool =
  for run in state.learningRuns:
    if run.state == "running": return true

proc refreshLearningRuns*(state: AppState) {.async.} =
  if not state.auth.authenticated: return
  let request = beginLearningRunsRequest(state)
  try:
    let runs = parseLearningRuns(await learningApi.fetchLearningRuns())
    if not matchesLearningRunsRequest(state, request): return
    state.learningRuns = runs
    state.learningRunsLoaded = true
    state.learningRunError = ""
  except CatchableError as exc:
    if matchesLearningRunsRequest(state, request): state.learningRunError = exc.msg
  finally:
    if matchesLearningRunsRequest(state, request): redraw(kxi)

proc startLearningRun*(state: AppState) {.async.} =
  ## Starts one candidate run from the exact ready check on screen; a refusal is stated, never retried.
  if not state.auth.authenticated or state.learningStarting or learningRunActive(state): return
  var payload: JsonNode
  try:
    payload = learningRunPayload(state.learningCheckedRequest, state.learningPreflight)
  except ValueError as exc:
    state.learningRunError = exc.msg
    redraw(kxi)
    return
  let request = beginLearningRunsRequest(state)
  state.learningStarting = true
  state.learningRunError = ""
  redraw(kxi)
  try:
    let run = parseLearningRun(await learningApi.startLearningRun(payload, state.auth.csrfToken))
    if not matchesLearningRunsRequest(state, request): return
    state.learningRuns.insert(run, 0)
    # A started check is spent; the next run needs a fresh check.
    invalidateLearningPreflight(state)
  except CatchableError as exc:
    if matchesLearningRunsRequest(state, request): state.learningRunError = exc.msg
  finally:
    if matchesLearningRunsRequest(state, request): state.learningStarting = false
    redraw(kxi)

proc cancelLearningRun*(state: AppState, runId: string) {.async.} =
  if not state.auth.authenticated or state.learningCancelling.len > 0: return
  let request = beginLearningRunsRequest(state)
  state.learningCancelling = runId
  state.learningRunError = ""
  redraw(kxi)
  try:
    let run = parseLearningRun(await learningApi.cancelLearningRun(runId, state.auth.csrfToken))
    if not matchesLearningRunsRequest(state, request): return
    if run.id != runId: raise newException(ValueError, "The learning response was invalid. Refresh to check again.")
    for index, row in state.learningRuns:
      if row.id == runId: state.learningRuns[index] = run
  except CatchableError as exc:
    if matchesLearningRunsRequest(state, request): state.learningRunError = exc.msg
  finally:
    if matchesLearningRunsRequest(state, request): state.learningCancelling = ""
    redraw(kxi)

proc openLearning*(state: AppState) =
  setActiveView(state, viewLearning)
  discard refreshLearning(state)
  discard refreshLearningRuns(state)
