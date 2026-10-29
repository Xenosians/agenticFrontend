## Loads, edits, saves and runs the owner's workflows. Every server answer is
## bound to the request that asked for it; a stale answer is dropped.
include karax/prelude
import std/[asyncjs, json]
import ../api/workflows as workflowApi
import ../api/submission_intents
import workflow_request
import workflows
import types
import state
import request_context
import extension_bridge
import auth_bridge
import chat_bridge

proc workflowBusy*(state: AppState): bool =
  state.automationBusy or state.automationSaving or state.automationRunning

proc workflowUnconfirmed*(state: AppState): bool =
  state.automationPendingRun.payload != nil

proc workflowEditingBlocked*(state: AppState): bool =
  workflowBusy(state) or workflowUnconfirmed(state) or state.automationRecoveryError.len > 0

proc restoreWorkflowRecovery(state: AppState): bool =
  ## A pending run is read from the server when its workflow opens; the page
  ## keeps nothing of its own, so only a failed read blocks editing.
  state.auth.authenticated and state.automationRecoveryError.len == 0

proc clearWorkflowEditor(state: AppState) =
  ## Internal reset after a confirmed archive; keep the active request epoch.
  state.automationDraft = WorkflowDraft(name: "New workflow")
  state.automationSelectedNode = ""
  state.automationRuns = @[]
  state.automationError = ""
  state.automationNotice = ""
  state.automationDirty = false
  state.automationRunMessage = ""
  state.automationRunConfirmed = false
  state.automationAddCapability = ""
  state.automationAddAfter = ""

proc newWorkflowDraft*(state: AppState) =
  if not restoreWorkflowRecovery(state) or workflowEditingBlocked(state): return
  inc state.automationEpoch
  clearWorkflowEditor(state)

proc editWorkflow*(state: AppState, change: proc(draft: WorkflowDraft): WorkflowDraft) =
  ## Applies one local edit; a refused edit leaves the canvas unchanged.
  if not restoreWorkflowRecovery(state) or workflowEditingBlocked(state): return
  try:
    state.automationDraft = change(state.automationDraft)
    var sourceExists = false
    for node in state.automationDraft.nodes:
      if node.step.id == state.automationAddAfter: sourceExists = true
    if not sourceExists: state.automationAddAfter = ""
    state.automationDirty = true
    state.automationError = ""
    state.automationNotice = ""
  except ValueError as exc:
    state.automationError = exc.msg

proc setWorkflowRunMessage*(state: AppState, value: string) =
  if not restoreWorkflowRecovery(state) or workflowEditingBlocked(state): return
  state.automationRunMessage = value

proc refreshWorkflowRuns(state: AppState, request: OperationsRequestContext) {.async.} =
  let identity = state.automationDraft.id
  if identity.len == 0 or not matchesWorkflowRequest(state, request): return
  try:
    let response = await workflowApi.listWorkflowRuns(identity)
    if not matchesWorkflowRequest(state, request): return
    let runs = parseWorkflowRuns(response, identity)
    if matchesWorkflowRequest(state, request): state.automationRuns = runs
  except CatchableError as exc:
    if matchesWorkflowRequest(state, request): state.automationError = exc.msg

proc refreshWorkflows*(state: AppState) {.async.} =
  if not state.auth.authenticated or workflowBusy(state): return
  discard restoreWorkflowRecovery(state)
  let request = beginWorkflowRequest(state)
  state.automationBusy = true
  state.automationError = ""
  redraw(kxi)
  try:
    let rows = parseWorkflowList(await workflowApi.listWorkflows())
    if not matchesWorkflowRequest(state, request): return
    state.automationWorkflows = rows
    state.automationLoaded = true
    if state.extensionCatalog == nil:
      await refreshExtensions(state)
      if not matchesWorkflowRequest(state, request): return
    if state.automationDraft.id.len > 0:
      await refreshWorkflowRuns(state, request)
  except CatchableError as exc:
    if matchesWorkflowRequest(state, request): state.automationError = exc.msg
  finally:
    if matchesWorkflowRequest(state, request): state.automationBusy = false
    redraw(kxi)

proc openWorkflow*(state: AppState, id: string) {.async.} =
  if not state.auth.authenticated or not restoreWorkflowRecovery(state) or workflowEditingBlocked(state): return
  let request = beginWorkflowRequest(state)
  state.automationBusy = true
  state.automationError = ""
  state.automationNotice = ""
  redraw(kxi)
  try:
    let draft = parseWorkflow(await workflowApi.getWorkflow(id))
    if not matchesWorkflowRequest(state, request): return
    if draft.id != id: raise newException(ValueError, "The opened workflow does not match the requested identity.")
    state.automationDraft = draft
    state.automationSelectedNode = ""
    state.automationAddCapability = ""
    state.automationAddAfter = ""
    state.automationDirty = false
    state.automationRuns = @[]
    state.automationRunMessage = ""
    let slot = await readIntent(request.account.userId, "workflow", id)
    if not matchesWorkflowRequest(state, request): return
    if slot.state == "pending":
      let frozen = parseWorkflow(%*{"workflow": slot.context})
      let pending = WorkflowPendingRun(draft: frozen, payload: slot.request.copy)
      if pending.payload != runPayload(frozen, pending.payload{"submission_id"}.getStr(""), pending.payload{"message"}.getStr("")):
        raise newException(ValueError, "The saved run does not match its original workflow.")
      state.automationPendingRun = pending
      state.automationDraft = frozen
      state.automationRunMessage = slot.request["message"].getStr
      state.automationNotice = "An earlier run is unconfirmed. Retry only that same run to reconcile it."
    await refreshWorkflowRuns(state, request)
  except CatchableError as exc:
    if matchesWorkflowRequest(state, request): state.automationError = exc.msg
  finally:
    if matchesWorkflowRequest(state, request): state.automationBusy = false
    redraw(kxi)

proc saveWorkflowDraft*(state: AppState) {.async.} =
  if not state.auth.authenticated or not restoreWorkflowRecovery(state) or workflowEditingBlocked(state): return
  let draft = state.automationDraft
  var payload: JsonNode
  try:
    payload = savePayload(draft)
  except ValueError as exc:
    state.automationError = exc.msg
    redraw(kxi)
    return
  let request = beginWorkflowRequest(state)
  state.automationSaving = true
  state.automationError = ""
  state.automationNotice = ""
  redraw(kxi)
  try:
    let response = await workflowApi.saveWorkflow(draft.id, payload, state.auth.csrfToken)
    if not matchesWorkflowRequest(state, request): return
    let saved = parseWorkflowSave(response, draft, payload)
    state.automationDraft = saved
    state.automationDirty = false
    state.automationNotice = "Saved version " & $saved.version & "."
    redraw(kxi)
    let rows = await workflowApi.listWorkflows()
    if not matchesWorkflowRequest(state, request): return
    state.automationWorkflows = parseWorkflowList(rows)
  except CatchableError as exc:
    if matchesWorkflowRequest(state, request): state.automationError = exc.msg
  finally:
    if matchesWorkflowRequest(state, request): state.automationSaving = false
    redraw(kxi)

proc runWorkflowDraft*(state: AppState) {.async.} =
  if not state.auth.authenticated or workflowBusy(state): return
  if not restoreWorkflowRecovery(state):
    redraw(kxi)
    return
  if state.automationDirty and not workflowUnconfirmed(state):
    state.automationError = "Save your changes before running; a run uses the saved version."
    redraw(kxi)
    return
  let request = beginWorkflowRequest(state)
  state.automationRunning = true
  # The server reserves the exact request before dispatch. A lost reservation
  # reply is recovered by a read, never by creating another independent ID.
  try:
    if not workflowUnconfirmed(state):
      var proposal = runPayload(state.automationDraft, "", state.automationRunMessage)
      proposal.delete("submission_id")
      let slot = await reserveIntent(request.account.userId, "workflow", state.automationDraft.id,
        proposal, state.auth.csrfToken)
      if not matchesWorkflowRequest(state, request): return
      let frozen = parseWorkflow(%*{"workflow": slot.context})
      state.automationPendingRun = WorkflowPendingRun(draft: frozen, payload: slot.request.copy)
      state.automationRunConfirmed = false
  except CatchableError as exc:
    if matchesWorkflowRequest(state, request):
      state.automationError = exc.msg
      state.automationRunning = false
    redraw(kxi)
    return
  let pending = state.automationPendingRun
  let draft = pending.draft
  let payload = pending.payload.copy
  let submission = payload["submission_id"].getStr
  state.automationError = ""
  state.automationNotice = ""
  redraw(kxi)
  var started: WorkflowRun
  var confirmed = false
  try:
    let response = await workflowApi.runWorkflow(draft.id, payload, state.auth.csrfToken)
    if not matchesWorkflowRequest(state, request): return
    started = parseWorkflowRun(response, draft, submission)
    confirmed = true
    state.automationRunConfirmed = true
    state.automationNotice = "Run confirmed: " & runStatusLabel(started.status) & ". Open its chat for approvals and results."
    try:
      let slot = cachedIntent(request.account.userId, "workflow", draft.id)
      discard await acknowledgeIntent(request.account.userId, "workflow", draft.id, slot.id, state.auth.csrfToken)
      if not matchesWorkflowRequest(state, request): return
      state.automationPendingRun = WorkflowPendingRun()
      state.automationRunMessage = ""
      state.automationRunConfirmed = false
    except CatchableError:
      # A local cleanup failure cannot erase the valid durable-job receipt.
      state.automationError = "The run is confirmed, but its pending record could not be cleared. Confirm the same run again."
    redraw(kxi)
    await refreshWorkflowRuns(state, request)
  except CatchableError as exc:
    if matchesWorkflowRequest(state, request):
      state.automationError = exc.msg & " Retrying keeps the same run identity."
      if not confirmed:
        # Phoenix releases a run it refused before admission; its saved slot,
        # read without dispatching anything, is the authority for unlocking.
        try:
          let slot = await readIntent(request.account.userId, "workflow", draft.id)
          if matchesWorkflowRequest(state, request) and slot.state == "rejected" and slot.request == payload:
            state.automationPendingRun = WorkflowPendingRun()
            state.automationRunConfirmed = false
            state.automationError = exc.msg
        except CatchableError:
          discard # The run stays locked to its exact request until the server answers.
  finally:
    if matchesWorkflowRequest(state, request): state.automationRunning = false
    redraw(kxi)
  if confirmed and matchesWorkflowRequest(state, request):
    await refreshChatMetadata(state)

proc archiveWorkflowDraft*(state: AppState) {.async.} =
  if not state.auth.authenticated or not restoreWorkflowRecovery(state) or
      workflowEditingBlocked(state) or state.automationDraft.id.len == 0: return
  let identity = state.automationDraft.id
  let request = beginWorkflowRequest(state)
  state.automationSaving = true
  state.automationError = ""
  redraw(kxi)
  try:
    let receipt = await workflowApi.archiveWorkflow(identity, state.auth.csrfToken)
    if not matchesWorkflowRequest(state, request): return
    parseWorkflowArchive(receipt, identity)
    clearWorkflowEditor(state)
    state.automationNotice = "Workflow archived. Its past runs and chats are kept."
    redraw(kxi)
    let rows = await workflowApi.listWorkflows()
    if not matchesWorkflowRequest(state, request): return
    state.automationWorkflows = parseWorkflowList(rows)
  except CatchableError as exc:
    if matchesWorkflowRequest(state, request): state.automationError = exc.msg
  finally:
    if matchesWorkflowRequest(state, request): state.automationSaving = false
    redraw(kxi)

proc openRunChat*(state: AppState, chatId: string) =
  discard selectChat(state, chatId)

proc openWorkflows*(state: AppState) =
  setActiveView(state, viewNodeBuilder)
  discard refreshWorkflows(state)
