include karax/prelude

import std/asyncjs

import ../api/client

import types
import state


const
  DevelopmentUserId =
    "xenos"


proc submitBackendJob*(
  state: AppState,
  message: string
) {.async.} =

  try:

    let response =
      await createJob(
        userId =
          DevelopmentUserId,

        conversationId =
          "",

        message =
          message
      )


    #
    # The local frontend preview has already
    # created its RunState.
    #
    # Replace its fake job identity with
    # the durable Phoenix job identity.
    #

    state.run.active =
      true

    state.run.request =
      message

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


  except CatchableError as exc:

    addRunEvent(
      state,
      "backend_error",
      exc.msg
    )


    showToast(
      state,
      "Backend request failed: " &
      exc.msg
    )


  #
  # The fetch completes outside the original
  # Karax DOM event, so request a VDOM redraw.
  #

  redraw(
    kxi
  )