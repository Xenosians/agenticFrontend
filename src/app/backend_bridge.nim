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

  state.run.active =
    true

  state.run.jobId =
    job.jobId

  state.run.status =
    job.status

  state.run.agent =
    job.selectedAgent

  state.run.tool =
    job.proposedTool


proc submitBackendJob*(
  state: AppState,
  message: string
) {.async.} =

  addUserMessage(
    state,
    message
  )


  state.run =
    RunState(
      active:
        true,

      request:
        message,

      jobId:
        "",

      status:
        "submitting",

      agent:
        "",

      tool:
        ""
    )


  state.runEvents.setLen(
    0
  )


  state.inspectorTab =
    tabRun


  addRunEvent(
    state,
    "request",
    "Submitting request to Phoenix."
  )


  showToast(
    state,
    "Creating durable backend job..."
  )


  redraw(
    kxi
  )


  try:

    let response =
      await createJob(
        userId =
          frontendConfig
          .userId,

        conversationId =
          "",

        message =
          message
      )


    state.run.jobId =
      response.jobId

    state.run.status =
      response.status


    addRunEvent(
      state,
      "backend",
      "Phoenix created durable job " &
      response.jobId &
      "."
    )


    showToast(
      state,
      "Backend job created: " &
      response.jobId
    )


    redraw(
      kxi
    )


    # --------------------------------------------------------
    # Durable job polling
    #
    # Phoenix owns durable job state.
    #
    # There is intentionally no frontend-owned maximum runtime.
    # Long-running AI execution is kept alive through the
    # AI -> Phoenix heartbeat/lease protocol.
    # --------------------------------------------------------

    while true:

      let previousStatus =
        state.run.status


      let job =
        await getJob(
          response.jobId
        )


      applyJobState(
        state,
        job
      )


      if job.status !=
         previousStatus:

        addRunEvent(
          state,
          "status",
          "Phoenix job state changed: " &
          previousStatus &
          " -> " &
          job.status
        )


      redraw(
        kxi
      )


      case job.status

      of "completed":

        let answer =
          if job.answer.len > 0:

            job.answer

          else:

            "Job completed without an assistant message."


        addAssistantMessage(
          state,
          answer
        )


        addRunEvent(
          state,
          "completion",
          "Phoenix reported job completed."
        )


        showToast(
          state,
          "Job completed."
        )


        redraw(
          kxi
        )

        return


      of "failed":

        let failureMessage =
          if job.error.len > 0:

            "Job failed: " &
            job.error

          else:

            "The backend job failed."


        addAssistantMessage(
          state,
          failureMessage
        )


        addRunEvent(
          state,
          "failure",
          failureMessage
        )


        showToast(
          state,
          "Backend job failed."
        )


        redraw(
          kxi
        )

        return


      of "waiting_approval":

        let approvalMessage =
          if job.answer.len > 0:

            job.answer

          else:

            "This job requires approval before it can continue."


        addAssistantMessage(
          state,
          approvalMessage
        )


        addRunEvent(
          state,
          "approval",
          "Phoenix reported that approval is required."
        )


        showToast(
          state,
          "Job is waiting for approval."
        )


        redraw(
          kxi
        )

        return


      else:

        discard


      await sleepMs(
        frontendConfig
        .pollIntervalMs
      )


  except CatchableError as exc:

    addRunEvent(
      state,
      "backend_error",
      exc.msg
    )


    if state.run.jobId.len == 0:

      state.run.status =
        "failed"


      addAssistantMessage(
        state,
        "Backend request failed: " &
        exc.msg
      )


    showToast(
      state,
      "Backend request failed: " &
      exc.msg
    )


  redraw(
    kxi
  )


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


  if state.run.status !=
     "waiting_approval":

    showToast(
      state,
      "The current job is not waiting for approval."
    )

    return


  let jobId =
    state.run.jobId


  state.run.status =
    "approving"


  addRunEvent(
    state,
    "approval",
    "Submitting explicit approval to Phoenix."
  )


  showToast(
    state,
    "Approving governed action..."
  )


  redraw(
    kxi
  )


  try:

    let job =
      await approveJob(
        jobId
      )


    applyJobState(
      state,
      job
    )


    case job.status

    of "completed":

      let answer =
        if job.answer.len > 0:

          job.answer

        else:

          "Approved action completed successfully."


      addAssistantMessage(
        state,
        answer
      )


      addRunEvent(
        state,
        "approval_executed",
        "Phoenix executed the approved action and completed the job."
      )


      showToast(
        state,
        "Approved action completed."
      )


    of "failed":

      let failureMessage =
        if job.error.len > 0:

          "Approved action failed: " &
          job.error

        else:

          "The approved action failed."


      addAssistantMessage(
        state,
        failureMessage
      )


      addRunEvent(
        state,
        "approval_failure",
        failureMessage
      )


      showToast(
        state,
        "Approved action failed."
      )


    else:

      addRunEvent(
        state,
        "approval_unexpected",
        "Phoenix returned unexpected job status: " &
        job.status
      )


      showToast(
        state,
        "Approval returned unexpected job state: " &
        job.status
      )


  except CatchableError as exc:

    state.run.status =
      "waiting_approval"


    addRunEvent(
      state,
      "approval_error",
      exc.msg
    )


    showToast(
      state,
      "Approval request failed: " &
      exc.msg
    )


  redraw(
    kxi
  )


proc refreshSystemStatus*(
  state: AppState
) {.async.} =

  if state.system.checking:
    return


  state.system.checking =
    true

  state.system.error =
    ""


  redraw(
    kxi
  )


  try:

    let health =
      await getSystemHealth()


    state.system.checked =
      true

    state.system.backendConnected =
      health.backendConnected

    state.system.aiReachable =
      health.aiReachable

    state.system.aiHealthy =
      health.aiHealthy

    state.system.aiReady =
      health.aiReady


  except CatchableError as exc:

    state.system.checked =
      true

    state.system.backendConnected =
      false

    state.system.aiReachable =
      false

    state.system.aiHealthy =
      false

    state.system.aiReady =
      false

    state.system.error =
      exc.msg


  finally:

    state.system.checking =
      false


  redraw(
    kxi
  )