include karax/prelude
import std/[asyncjs, json]
import ../api/learning as learningApi
import ../api/submission_intents
import learning
import types
import state
import request_context

proc learningStartPending*(state: AppState): bool = state.learningPendingRequest != nil

proc restoreLearningRecovery(state: AppState): bool =
  state.auth.authenticated and state.learningRecoveryChecked and state.learningRecoveryError.len == 0

proc readLearningRecovery(state: AppState) {.async.} =
  let account = accountContext(state)
  state.learningRecoveryChecked = false
  state.learningRecoveryError = ""
  try:
    let slot = await readIntent(account.userId, "learning", "candidate")
    if not matchesAccount(state, account): return
    if slot.state == "pending":
      validateLearningRunRequest(slot.request)
      state.learningPendingRequest = slot.request.copy
    else:
      state.learningPendingRequest = nil
    state.learningRecoveryError = ""
    state.learningRecoveryChecked = true
  except CatchableError as exc:
    if matchesAccount(state, account): state.learningRecoveryError = exc.msg
  redraw(kxi)

proc learningMutationBusy(state: AppState): bool =
  state.learningStarting or state.learningCancelling.len > 0 or state.learningReconciling

proc learningEditingBlocked*(state: AppState): bool =
  not state.learningRecoveryChecked or learningStartPending(state) or learningMutationBusy(state) or state.learningRecoveryError.len > 0

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
  if state.learningBusy or not state.learningLoaded or learningEditingBlocked(state): return
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
  if not state.auth.authenticated or not state.learningLoaded or state.learningBusy or state.learningChecking or
      learningEditingBlocked(state): return
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
    if run.state in activeLearningRunStates: return true

proc putLearningRun(state: AppState, run: LearningRun) =
  for index, row in state.learningRuns:
    if row.id == run.id:
      state.learningRuns[index] = run
      return
  state.learningRuns.insert(run, 0)
  if state.learningRuns.len > 20: state.learningRuns.setLen(20)

proc clearPendingLearning(state: AppState) {.async.} =
  if not learningStartPending(state): return
  let account = accountContext(state)
  let pending = state.learningPendingRequest.copy
  try:
    let slot = cachedIntent(account.userId, "learning", "candidate")
    discard await acknowledgeIntent(account.userId, "learning", "candidate", slot.id, state.auth.csrfToken)
    if not matchesAccount(state, account) or state.learningPendingRequest != pending: return
    state.learningPendingRequest = nil
    state.learningRecoveryError = ""
  except CatchableError as exc:
    if matchesAccount(state, account): state.learningRecoveryError = exc.msg

proc confirmLearningStart(state: AppState, run: LearningRun, payload: JsonNode) {.async.} =
  requireMatchingLearningRun(run, payload)
  putLearningRun(state, run)
  # Lists started before this receipt cannot replace its authoritative result.
  inc state.learningRunsEpoch
  invalidateLearningPreflight(state)
  await clearPendingLearning(state)
  state.learningRunError = ""

proc refreshLearningRuns*(state: AppState) {.async.} =
  if not state.auth.authenticated: return
  let request = beginLearningRunsRequest(state)
  try:
    let runs = parseLearningRuns(await learningApi.fetchLearningRuns())
    if not matchesLearningRunsRequest(state, request): return
    state.learningRuns = runs
    state.learningRunsLoaded = true
    state.learningRunsError = ""
    if learningStartPending(state):
      let pending = state.learningPendingRequest
      for run in runs:
        if run.submissionId == pending["submission_id"].getStr:
          await confirmLearningStart(state, run, pending)
          break
  except CatchableError as exc:
    if matchesLearningRunsRequest(state, request): state.learningRunsError = exc.msg
  finally:
    if matchesAccount(state, request.account): redraw(kxi)

proc startLearningRun*(state: AppState) {.async.} =
  ## An explicit retry sends the same frozen request; refresh/reload never dispatches.
  if not state.auth.authenticated or learningMutationBusy(state) or not restoreLearningRecovery(state): return
  if not learningStartPending(state) and learningRunActive(state): return
  let request = beginLearningMutationRequest(state)
  state.learningStarting = true
  var payload: JsonNode
  try:
    if learningStartPending(state):
      payload = state.learningPendingRequest.copy
    else:
      let proposal = learningRunProposal(state.learningCheckedRequest, state.learningPreflight)
      let slot = await reserveIntent(request.account.userId, "learning", "candidate", proposal, state.auth.csrfToken)
      if not matchesLearningMutationRequest(state, request): return
      payload = slot.request.copy
      validateLearningRunRequest(payload)
      state.learningPendingRequest = payload.copy
  except CatchableError as exc:
    if matchesLearningMutationRequest(state, request):
      state.learningRunError = exc.msg
      state.learningStarting = false
    redraw(kxi)
    return
  state.learningRunError = ""
  redraw(kxi)
  try:
    let run = parseStartedLearningRun(await learningApi.startLearningRun(payload, state.auth.csrfToken), payload)
    if not matchesLearningMutationRequest(state, request): return
    await confirmLearningStart(state, run, payload)
  except learningApi.LearningRequestError as exc:
    if matchesLearningMutationRequest(state, request) and learningStartPending(state):
      # Only explicit pre-admission refusals prove that this request did not start.
      if exc.status in [409, 422] and exc.code in ["learning_host_busy", "invalid_learning_request",
          "learning_resource_unavailable", "learning_dataset_not_training", "learning_dataset_changed",
          "learning_dataset_superseded", "learning_training_membership_invalid", "learning_check_changed",
          "learning_run_not_ready"]:
        let slot = await readIntent(request.account.userId, "learning", "candidate")
        if not matchesLearningMutationRequest(state, request): return
        if slot.state == "rejected" and slot.request == payload:
          state.learningPendingRequest = nil
        invalidateLearningPreflight(state)
      state.learningRunError = exc.msg
  except CatchableError as exc:
    if matchesLearningMutationRequest(state, request) and learningStartPending(state):
      state.learningRunError = "The start is unconfirmed. Check the previous start or retry its exact request. " & exc.msg
  finally:
    if matchesLearningMutationRequest(state, request): state.learningStarting = false
    redraw(kxi)

proc cancelLearningRun*(state: AppState, runId: string) {.async.} =
  if not state.auth.authenticated or learningMutationBusy(state): return
  var original: LearningRun
  for run in state.learningRuns:
    if run.id == runId: original = run
  if original.id.len == 0: return
  let request = beginLearningMutationRequest(state)
  state.learningCancelling = runId
  state.learningRunError = ""
  redraw(kxi)
  try:
    let run = parseLearningRun(await learningApi.cancelLearningRun(runId, state.auth.csrfToken))
    if not matchesLearningMutationRequest(state, request): return
    requireSameLearningRun(run, original)
    inc state.learningRunsEpoch
    putLearningRun(state, run)
  except CatchableError as exc:
    if matchesLearningMutationRequest(state, request): state.learningRunError = exc.msg
  finally:
    if matchesLearningMutationRequest(state, request): state.learningCancelling = ""
    redraw(kxi)

proc reconcileLearningStart*(state: AppState) {.async.} =
  if not state.auth.authenticated or learningMutationBusy(state): return
  await readLearningRecovery(state)
  if not restoreLearningRecovery(state) or not learningStartPending(state):
    redraw(kxi)
    return
  let payload = state.learningPendingRequest.copy
  let request = beginLearningMutationRequest(state)
  state.learningReconciling = true
  redraw(kxi)
  try:
    let run = parseStartedLearningRun(await learningApi.resolveLearningRun(payload["submission_id"].getStr), payload)
    if not matchesLearningMutationRequest(state, request): return
    await confirmLearningStart(state, run, payload)
  except CatchableError as exc:
    if matchesLearningMutationRequest(state, request) and learningStartPending(state):
      state.learningRunError = "The previous start is still unconfirmed; its identity is retained. " & exc.msg
  finally:
    if matchesLearningMutationRequest(state, request): state.learningReconciling = false
    redraw(kxi)

proc openLearning*(state: AppState) =
  setActiveView(state, viewLearning)
  discard readLearningRecovery(state)
  discard refreshLearning(state)
  discard refreshLearningRuns(state)
