include karax/prelude

import std/asyncjs

import ../api/client
import ../config/runtime_config

import types
import state


proc sleepMs(
  milliseconds: int
): Future[void] {.
  importjs:
    "new Promise((resolve) => setTimeout(resolve, #))"
.}


proc applyJobState(
  state: AppState,
  job: JobResponse
) =

  state.run.active = true
  state.run.jobId = job.jobId
  state.run.status = job.status
  state.run.agent = job.selectedAgent
  state.run.tool = job.proposedTool
  state.run.presentations = job.presentations


proc jobFailureMessage(
  job: JobResponse
): string =

  if job.error.len > 0:
    return job.error

  return "The backend job could not be completed."


proc finishCompletedJob(
  state: AppState,
  job: JobResponse
) =

  let answer =
    if job.answer.len > 0:
      job.answer
    else:
      "Job completed successfully."

  addAssistantMessage(
    state,
    answer,
    job.presentations
  )

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
  job: JobResponse
) =

  let failureMessage =
    jobFailureMessage(
      job
    )

  addAssistantMessage(
    state,
    failureMessage
  )

  addRunEvent(
    state,
    "failure",
    "Phoenix reported the durable job failed."
  )

  showToast(
    state,
    "Request could not be completed."
  )


proc finishWaitingApproval(
  state: AppState,
  job: JobResponse,
  addMessage: bool
) =

  if addMessage:
    let approvalMessage =
      if job.answer.len > 0:
        job.answer
      else:
        "This action requires your approval before it can continue."

    addAssistantMessage(
      state,
      approvalMessage,
      job.presentations
    )

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
  addWaitingMessage: bool = true
) {.async.} =

  if jobId.len == 0:
    return

  try:
    while true:
      let previousStatus =
        state.run.status

      let job =
        await getJob(
          jobId
        )

      applyJobState(
        state,
        job
      )

      if job.status != previousStatus:
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
          job
        )
        redraw(kxi)
        return

      of "failed":
        finishFailedJob(
          state,
          job
        )
        redraw(kxi)
        return

      of "waiting_approval":
        finishWaitingApproval(
          state,
          job,
          addWaitingMessage
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

      await sleepMs(
        frontendConfig.pollIntervalMs
      )

  except CatchableError:
    addRunEvent(
      state,
      "connection",
      "Polling was interrupted before the durable job reached a terminal state."
    )

    showToast(
      state,
      "Connection interrupted. Reload or reopen this chat to resume."
    )

    redraw(kxi)


proc resumeBackendJob*(
  state: AppState
) {.async.} =

  if not state.run.active or
     state.run.jobId.len == 0:
    return

  if state.run.status notin [
    "pending",
    "processing",
    "approving"
  ]:
    return

  addRunEvent(
    state,
    "resume",
    "Resuming observation of the durable backend job."
  )

  await pollBackendJob(
    state,
    state.run.jobId,
    false
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
        chatId = state.currentChatId,
        message = message,
        csrfToken = state.auth.csrfToken
      )

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


proc approvePendingJob*(
  state: AppState
) {.async.} =

  if not state.run.active or
     state.run.jobId.len == 0:
    showToast(
      state,
      "There is no backend job to approve."
    )
    return

  if state.run.status != "waiting_approval":
    showToast(
      state,
      "The current job is not waiting for approval."
    )
    return

  let jobId =
    state.run.jobId

  state.run.status = "approving"

  addRunEvent(
    state,
    "approval",
    "Submitting explicit approval to Phoenix."
  )

  showToast(
    state,
    "Approving…"
  )

  redraw(kxi)

  try:
    let job =
      await approveJob(
        jobId,
        state.auth.csrfToken
      )

    applyJobState(
      state,
      job
    )

    case job.status

    of "completed":
      finishCompletedJob(
        state,
        job
      )

    of "failed":
      finishFailedJob(
        state,
        job
      )

    of "waiting_approval":
      finishWaitingApproval(
        state,
        job,
        false
      )

    of "pending", "processing", "approving":
      addRunEvent(
        state,
        "approval",
        "Approval was accepted; waiting for durable execution to finish."
      )

      redraw(kxi)

      await pollBackendJob(
        state,
        jobId,
        false
      )

    else:
      addRunEvent(
        state,
        "approval",
        "Approval returned a job state this frontend does not yet render."
      )

      showToast(
        state,
        "Approval state changed. Refresh the chat to continue."
      )

  except CatchableError:
    state.run.status = "waiting_approval"

    addRunEvent(
      state,
      "connection",
      "The approval request could not be delivered."
    )

    showToast(
      state,
      "Approval request failed. Try again."
    )

  redraw(kxi)




proc refreshIntegrationStatus(
  state: AppState
) {.async.} =

  try:
    let integrations =
      await getIntegrationStatus()

    state.system.paloAltoConfigured =
      integrations.paloAltoConfigured

    state.system.paloAltoHost =
      integrations.paloAltoHost

    state.system.paloAltoMode =
      integrations.paloAltoMode

    state.system.integrationsError =
      ""

    for i in 0 ..< state.plugins.len:
      if state.plugins[i].id == "palo-alto":
        state.plugins[i].connected =
          integrations.paloAltoConfigured
        break

  except CatchableError as exc:
    state.system.integrationsError =
      exc.msg

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


# SRS18_PALO_ALTO_REFRESH_WRAPPER_V1
proc refreshSystemStatus*(
  state: AppState
) {.async.} =
  await refreshSystemStatusBase(
    state
  )

  await refreshIntegrationStatus(
    state
  )

  redraw(
    kxi
  )
