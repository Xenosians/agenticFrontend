include karax/prelude

import std/asyncjs

import ../api/client

import types
import state


const
  DevelopmentUserId =
    "xenos"

  PollIntervalMs =
    1_000

  MaxPollAttempts =
    300


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

  #
  # The browser now starts with the real
  # backend path instead of the local mock.
  #

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
      tool: ""
    )


  state.runEvents.setLen(0)

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

    #
    # Create durable Phoenix job.
    #

    let response =
      await createJob(
        userId =
          DevelopmentUserId,

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


    #
    # Poll Phoenix.
    #
    # Phoenix remains the source of truth.
    #

    var pollCount =
      0


    while pollCount <
          MaxPollAttempts:

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


      inc pollCount


      await sleepMs(
        PollIntervalMs
      )


    #
    # Poll timeout.
    #

    addRunEvent(
      state,
      "timeout",
      "Stopped polling after five minutes."
    )


    showToast(
      state,
      "Job is still running. Polling timed out."
    )


  except CatchableError as exc:

    addRunEvent(
      state,
      "backend_error",
      exc.msg
    )


    #
    # If Phoenix never gave us a job ID,
    # creation itself failed.
    #

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