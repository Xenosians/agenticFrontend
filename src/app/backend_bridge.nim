include karax/prelude

import std/[asyncjs, json]

import ../api/client
import ../api/chat_history
import ../api/job_socket
import ../config/runtime_config

import types
import state
import job_decision
import extension_bridge


proc applyJobState(
  state: AppState,
  job: JobResponse
) =

  state.run.active = true
  state.run.jobId = job.jobId
  state.run.status = job.status
  state.run.agent = job.selectedAgent
  state.run.tool = job.proposedTool
  state.run.proposal = job.proposal
  state.run.decisionError = ""
  state.run.presentations = job.presentations


proc jobFailureMessage(
  job: JobResponse
): string =

  if job.error.len > 0:
    return job.error

  return "The backend job could not be completed."


proc finishCompletedJob(
  state: AppState,
  job: JobResponse,
  restoreHistory: bool = false
) =

  let answer =
    if job.answer.len > 0:
      job.answer
    else:
      "Job completed successfully."

  if restoreHistory:
    restoreAssistantJobMessage(state, job.jobId, answer, job.presentations)
  else:
    addAssistantMessage(state, answer, job.presentations, job.jobId)

  if job.presentations.len > 0:
    addRunEvent(
      state,
      "result",
      "Received structured result data from the completed job."
    )

  addRunEvent(
    state,
    "completion",
    "Phoenix reported the durable job completed."
  )

  showToast(
    state,
    "Completed."
  )


proc finishFailedJob(
  state: AppState,
  job: JobResponse,
  restoreHistory: bool = false
) =

  let failureMessage =
    jobFailureMessage(
      job
    )

  if restoreHistory:
    restoreAssistantJobMessage(state, job.jobId, failureMessage, job.presentations)
  else:
    addAssistantMessage(state, failureMessage, job.presentations, job.jobId)

  addRunEvent(
    state,
    "failure",
    "Phoenix reported the durable job failed."
  )

  showToast(
    state,
    "Request could not be completed."
  )


proc finishDeniedJob(state: AppState, job: JobResponse, restoreHistory: bool = false) =
  let message =
    if job.error.len > 0: job.error
    elif job.answer.len > 0: job.answer
    else: "The requested action did not proceed."
  if restoreHistory:
    restoreAssistantJobMessage(state, job.jobId, message, job.presentations)
  else:
    addAssistantMessage(state, message, job.presentations, job.jobId)
  addRunEvent(state, "denied", "Phoenix reported that the action did not proceed. The saved response contains the reason.")
  showToast(state, "Action did not proceed.")


proc finishReconciliationRequired(
  state: AppState,
  job: JobResponse,
  restoreHistory: bool = false
) =

  let message =
    if job.error.len > 0:
      job.error
    else:
      "The approved action has an unresolved execution outcome. Automatic retry is disabled; trusted reconciliation is required."

  if restoreHistory:
    restoreAssistantJobMessage(state, job.jobId, message, job.presentations)
  else:
    addAssistantMessage(state, message, job.presentations, job.jobId)

  addRunEvent(
    state,
    "reconciliation",
    "Phoenix reported an unresolved approval outcome. Automatic retry is disabled."
  )

  showToast(
    state,
    "Reconciliation required."
  )


proc finishWaitingApproval(
  state: AppState,
  job: JobResponse,
  addMessage: bool,
  restoreHistory: bool = false
) =

  if addMessage or restoreHistory:
    let approvalMessage =
      if job.answer.len > 0:
        job.answer
      else:
        "This action requires your approval before it can continue."

    if restoreHistory:
      restoreAssistantJobMessage(state, job.jobId, approvalMessage, job.presentations)
    else:
      addAssistantMessage(state, approvalMessage, job.presentations, job.jobId)

  addRunEvent(
    state,
    "approval",
    "Phoenix reported that explicit approval is required."
  )

  showToast(
    state,
    "Waiting for your approval."
  )


proc pollBackendJob*(
  state: AppState,
  jobId: string,
  addWaitingMessage: bool = true,
  restoreHistory: bool = false
) {.async.} =

  if jobId.len == 0:
    return

  let sessionId = state.auth.sessionId
  let chatId = state.currentChatId
  inc state.jobObservationEpoch
  let observationEpoch = state.jobObservationEpoch
  var waitingPresented = false

  proc isCurrent(): bool =
    state.auth.authenticated and state.auth.sessionId == sessionId and
      state.currentChatId == chatId and state.run.jobId == jobId and
      state.jobObservationEpoch == observationEpoch

  proc updateMode(mode: cstring) =
    if isCurrent():
      state.run.observationMode = $mode
      redraw(kxi)

  proc updateProgress(stage: cstring) =
    if isCurrent() and state.run.status in ["pending", "processing"]:
      state.run.progressStage = $stage
      redraw(kxi)

  let observer = observeJob(cstring(frontendConfig.backendBaseUrl), cstring(jobId),
    cstring(state.auth.csrfToken), frontendConfig.pollIntervalMs,
    isCurrent, updateMode, updateProgress)

  # A durable job outlives one failed read (a brief backend or storage
  # outage). Retry at the observer's pace; give up only after repeated
  # failures so a real outage still surfaces.
  const maxReadFailures = 6
  var readFailures = 0

  try:
    while true:
      if not isCurrent():
        return

      let previousStatus =
        state.run.status
      let previousApprovalId = state.run.proposal.approvalId

      var job: JobResponse
      try:
        job = await getJob(jobId)
        readFailures = 0
      except CatchableError:
        inc readFailures
        if readFailures >= maxReadFailures:
          raise
        if not isCurrent():
          return
        addRunEvent(state, "connection",
          "Reading the job failed; retrying (" & $readFailures & "/" & $maxReadFailures & ").")
        await observer.waitForUpdate()
        continue

      # A delayed response belongs to its original account, chat and job.
      if not isCurrent():
        return

      applyJobState(
        state,
        job
      )

      if job.status != previousStatus:
        state.run.progressStage = ""
        addRunEvent(
          state,
          "status",
          "Durable job state changed: " &
          previousStatus &
          " -> " &
          job.status
        )

      redraw(
        kxi
      )

      case job.status

      of "completed":
        finishCompletedJob(
          state,
          job,
          restoreHistory or waitingPresented
        )
        redraw(kxi)
        return

      of "denied":
        finishDeniedJob(state, job, restoreHistory or waitingPresented)
        redraw(kxi)
        return

      of "failed":
        finishFailedJob(
          state,
          job,
          restoreHistory or waitingPresented
        )
        redraw(kxi)
        return

      of "waiting_approval":
        if not waitingPresented or previousStatus != job.status or previousApprovalId != job.proposal.approvalId:
          finishWaitingApproval(state, job, addWaitingMessage and not waitingPresented,
            restoreHistory = restoreHistory or waitingPresented)
          waitingPresented = true
          redraw(kxi)

      of "reconciliation_required", "outcome_unknown":
        finishReconciliationRequired(
          state,
          job,
          restoreHistory or waitingPresented
        )
        redraw(kxi)
        return

      of "pending", "processing", "approving":
        discard

      else:
        addRunEvent(
          state,
          "status",
          "Phoenix returned a job state this frontend does not yet render."
        )

        showToast(
          state,
          "Job state changed. Refresh the chat to continue."
        )

        redraw(kxi)
        return

      await observer.waitForUpdate()

  except CatchableError:
    if not isCurrent():
      return

    addRunEvent(
      state,
      "connection",
      "Observation was interrupted before the durable job reached a terminal state."
    )

    showToast(
      state,
      "Connection interrupted. Reload or reopen this chat to resume."
    )

    state.run.observationMode = "interrupted"

    redraw(kxi)

  finally:
    observer.closeObservation()
    if isCurrent() and state.run.observationMode != "interrupted":
      state.run.observationMode = ""


proc resumeBackendJob*(
  state: AppState
) {.async.} =

  if not state.run.active or
     state.run.jobId.len == 0:
    return

  if state.run.status notin restorableJobStates:
    return

  # Saved history locates the job; its current GET is the authority for
  # approval controls and execution outcome, including after a reload.
  # Reading durable state is safe after an interrupted approve/reject response:
  # it never resubmits the mutation decision.
  state.run.decisionError = ""
  state.run.status = "restoring"
  redraw(kxi)

  addRunEvent(
    state,
    "resume",
    "Resuming observation of the durable backend job."
  )

  await pollBackendJob(
    state,
    state.run.jobId,
    false,
    restoreHistory = true
  )


proc submitBackendJob*(
  state: AppState,
  message: string
) {.async.} =

  if not state.auth.authenticated:
    showToast(
      state,
      "Sign in before submitting a request."
    )
    return

  if state.currentChatId.len == 0:
    showToast(
      state,
      "Create or select a chat before submitting a request."
    )
    return

  addUserMessage(
    state,
    message
  )

  state.run =
    RunState(
      active: true,
      request: message,
      jobId: "",
      status: "submitting",
      agent: "",
      tool: "",
      presentations: @[]
    )

  state.runEvents.setLen(0)
  state.inspectorTab = tabRun
  inc state.jobObservationEpoch
  let submissionEpoch = state.jobObservationEpoch
  let submissionSession = state.auth.sessionId
  let submissionChat = state.currentChatId

  proc submissionIsCurrent(): bool =
    state.auth.authenticated and state.auth.sessionId == submissionSession and
      state.currentChatId == submissionChat and state.jobObservationEpoch == submissionEpoch

  addRunEvent(
    state,
    "request",
    "Submitting request to the durable Phoenix job API."
  )

  showToast(
    state,
    "Submitting request…"
  )

  redraw(kxi)

  try:
    let response =
      await createJob(
        chatId = submissionChat,
        message = message,
        csrfToken = state.auth.csrfToken
      )

    if not submissionIsCurrent():
      return

    state.run.jobId = response.jobId
    state.run.status = response.status

    addRunEvent(
      state,
      "backend",
      "Phoenix accepted the durable job."
    )

    showToast(
      state,
      "Queued."
    )

    redraw(kxi)

    await pollBackendJob(
      state,
      response.jobId,
      true
    )

  except CatchableError:
    if not submissionIsCurrent():
      return
    if state.run.jobId.len == 0:
      state.run.status = "failed"

    addRunEvent(
      state,
      "connection",
      "The request could not be submitted to the backend."
    )

    addAssistantMessage(
      state,
      "The request could not be submitted. Check the backend connection and try again."
    )

    showToast(
      state,
      "Could not submit the request."
    )

    redraw(kxi)


proc decidePendingJob(state: AppState, decision: JobDecision) {.async.} =
  if not canDecideJob(state):
    showToast(state, "A saved action with reviewable details must be waiting for your decision.")
    redraw(kxi)
    return

  let context = captureDecisionContext(state)
  # An in-flight observation must not restore waiting_approval over a decision
  # being submitted. Only its response or a new authorized GET may resolve it.
  inc state.jobObservationEpoch
  state.run.observationMode = ""
  state.run.progressStage = ""
  let eventKind = if decision == jdApprove: "approval" else: "rejection"
  state.run.status = decisionStatus(decision)
  state.run.decisionError = ""
  addRunEvent(state, eventKind, "Submitting your explicit action decision to Phoenix.")
  redraw(kxi)

  try:
    let job = await decideJob(context.jobId, state.auth.csrfToken, decision, context.approvalId)
    if not matchesDecisionContext(state, context):
      return
    if job.jobId != context.jobId:
      raise newException(ValueError, "Decision response belongs to another job.")

    applyJobState(state, job)
    case job.status
    of "completed": finishCompletedJob(state, job, restoreHistory = true)
    of "denied": finishDeniedJob(state, job, restoreHistory = true)
    of "failed": finishFailedJob(state, job, restoreHistory = true)
    of "waiting_approval":
      await pollBackendJob(state, context.jobId, false, restoreHistory = true)
    of "reconciliation_required", "outcome_unknown": finishReconciliationRequired(state, job, restoreHistory = true)
    of "pending", "processing", "approving":
      addRunEvent(state, eventKind, "The backend accepted the decision; observing its durable result.")
      redraw(kxi)
      await pollBackendJob(state, context.jobId, false, restoreHistory = true)
    else:
      showToast(state, "The saved decision state changed. Reload this chat to check its result.")
  except CatchableError:
    if not matchesDecisionContext(state, context):
      return
    # No local cancellation or retry: an interrupted response cannot reveal
    # whether either decision reached the server. A later GET is authoritative.
    state.run.status = decisionStatus(decision)
    state.run.decisionError = "The decision response was interrupted. Reload this chat to check the saved outcome before trying again."
    addRunEvent(state, "connection", state.run.decisionError)
    showToast(state, state.run.decisionError)
  redraw(kxi)


proc approvePendingJob*(state: AppState) {.async.} =
  await decidePendingJob(state, jdApprove)


proc rejectPendingJob*(state: AppState) {.async.} =
  await decidePendingJob(state, jdReject)




proc refreshIntegrationStatus(
  state: AppState
) {.async.} =
  let session = state.auth.sessionId
  try:
    let integrations =
      await getIntegrationStatus()

    if not state.auth.authenticated or state.auth.sessionId != session: return

    state.system.integrationsError =
      ""

    state.plugins.setLen(0)
    for item in integrations.items:
      state.plugins.add(PluginItem(id: item["id"].getStr,
        name: (if item.hasKey("name"): item["name"].getStr else: item["id"].getStr),
        connected: item.hasKey("configured") and item["configured"].getBool))

  except CatchableError as exc:
    if state.auth.authenticated and state.auth.sessionId == session:
      state.system.integrationsError = exc.msg

proc refreshSystemStatusBase(
  state: AppState
) {.async.} =

  if state.system.checking:
    return

  state.system.checking = true
  state.system.error = ""

  redraw(kxi)

  try:
    let health =
      await getSystemHealth()

    state.system.checked = true
    state.system.backendConnected = health.backendConnected
    state.system.aiReachable = health.aiReachable
    state.system.aiHealthy = health.aiHealthy
    state.system.aiReady = health.aiReady

  except CatchableError:
    state.system.checked = true
    state.system.backendConnected = false
    state.system.aiReachable = false
    state.system.aiHealthy = false
    state.system.aiReady = false
    state.system.error = "System status is currently unavailable."

  finally:
    state.system.checking = false

  redraw(kxi)


proc refreshSystemStatus*(
  state: AppState
) {.async.} =
  await refreshSystemStatusBase(
    state
  )

  await refreshIntegrationStatus(
    state
  )

  await refreshExtensions(state)

  redraw(
    kxi
  )
