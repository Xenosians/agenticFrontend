include karax/prelude

import karax/kdom

import std/strutils

import ../app/types
import ../app/state
import ../app/backend_bridge


proc backendJobBusy(
  state: AppState
): bool =

  return state.run.active and (
    state.run.status == "submitting" or
    state.run.status == "pending" or
    state.run.status == "processing" or
    state.run.status == "waiting_approval" or
    state.run.status == "approving"
  )


proc composerStatusText(
  state: AppState
): string =

  case state.run.status

  of "submitting":
    "Submitting request…"

  of "pending":
    "Queued — waiting for backend dispatch…"

  of "processing":
    "Agentic is processing your request…"

  of "waiting_approval":
    "Waiting for your approval."

  of "reconciliation_required":
    "Execution outcome unresolved — trusted reconciliation required."

  of "approving":
    "Executing the approved action…"

  of "completed":
    "Completed."

  of "failed":
    "Request could not be completed."

  else:
    if state.toastMessage.len > 0:
      state.toastMessage
    elif state.currentChatId.len == 0:
      "Create or select a chat to begin."
    else:
      "Ready · Enter to send · Shift+Enter for a new line"


proc submitDraft(
  state: AppState,
  textareaNode: VNode = nil
) =

  let message =
    state.composerDraft.strip()

  if message.len == 0:
    return

  if state.currentChatId.len == 0:
    showToast(
      state,
      "Create or select a chat before sending a message."
    )
    return

  if backendJobBusy(
    state
  ):
    showToast(
      state,
      "Finish the current job before starting another."
    )
    return

  clearToast(
    state
  )

  discard submitBackendJob(
    state,
    message
  )

  setComposerDraft(
    state,
    ""
  )

  if textareaNode != nil:
    textareaNode.value = cstring""


proc renderComposer*(
  state: AppState
): VNode =

  let
    jobBusy =
      backendJobBusy(
        state
      )

    sendDisabled =
      state.composerDraft.strip().len == 0 or
      state.currentChatId.len == 0 or
      jobBusy

    sendClass =
      if sendDisabled:
        cstring"send-button"
      else:
        cstring"send-button active"

  result = buildHtml(
    section(class = "composer-container")
  ):

    tdiv(class = "composer"):
      textarea(
        id = "messageInput",
        class = "composer-input",
        placeholder = "Message Agentic...",
        rows = "1",
        value = cstring(state.composerDraft),
        disabled = jobBusy
      ):
        proc oninput(
          event: Event,
          node: VNode
        ) =
          clearToast(
            state
          )

          setComposerDraft(
            state,
            $node.value
          )

        proc onkeydown(
          event: Event,
          node: VNode
        ) =
          let keyboardEvent =
            cast[KeyboardEvent](
              event
            )

          setComposerDraft(
            state,
            $node.value
          )

          if keyboardEvent.key == "Enter" and
             not keyboardEvent.shiftKey:
            event.preventDefault()
            submitDraft(
              state,
              node
            )

      tdiv(class = "composer-footer"):
        span(class = "composer-context"):
          if jobBusy:
            text "One foreground job at a time"
          else:
            text "Phoenix-backed durable chat"

        button(
          class = sendClass,
          disabled = sendDisabled,
          title = "Send message"
        ):
          text "↑"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            submitDraft(
              state
            )

    span(class = "composer-hint"):
      text composerStatusText(
        state
      )
