include karax/prelude

import karax/kdom

import std/strutils

import ../app/types
import ../app/state
import ../app/backend_bridge
import brand
import required_operations
import ../config/runtime_config


proc resizeComposerInput() {.
  importjs: "requestAnimationFrame(() => { const el = document.getElementById('messageInput'); if (!el) return; el.style.height = 'auto'; el.style.height = Math.min(el.scrollHeight, 180) + 'px'; })"
.}

proc isComposing(event: Event): bool {.importjs: "Boolean(#.isComposing)".}

proc showComposerDraft(state: AppState) =
  ## Karax refreshes a textarea's live value only when its rendered value
  ## attribute changes. A draft typed and sent before the next frame leaves
  ## that attribute unchanged, so apply the submission's outcome directly.
  let input = getVNodeById("messageInput")
  if input != nil and input.getInputText != cstring(state.composerDraft):
    input.setInputText(cstring(state.composerDraft))

proc backendJobBusy(
  state: AppState
): bool =

  return state.run.active and (
    state.run.status == "submitting" or
    state.run.status == "submission_unknown" or
    state.run.status == "restoring" or
    state.run.status == "pending" or
    state.run.status == "processing" or
    state.run.status == "waiting_approval" or
    state.run.status == "approving" or
    state.run.status == "rejecting"
  )


proc composerStatusText(
  state: AppState
): string =

  if state.auth.loading:
    return "Checking your workspace…"

  case state.run.status

  of "submitting":
    "Submitting request…"

  of "restoring":
    "Checking the saved job…"

  of "submission_unknown":
    "Submission not confirmed. Check the saved request before sending another."

  of "pending":
    "Queued — waiting for backend dispatch…"

  of "processing":
    productName & " is processing your request…"

  of "waiting_approval":
    "Waiting for your approval."

  of "reconciliation_required", "outcome_unknown":
    "Execution outcome unresolved — trusted reconciliation required."

  of "approving":
    "Submitting approval and checking the saved outcome…"

  of "rejecting":
    "Submitting your rejection…"

  of "completed":
    "Completed."

  of "denied":
    "The action did not proceed."

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
  state: AppState
) =

  if state.auth.loading:
    showToast(state, "Wait for your workspace to finish loading before sending.")
    return

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

  showComposerDraft(state)
  resizeComposerInput()


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
      state.auth.loading or
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

    if frontendConfig.requiredOperations:
      renderRequiredOperations(state, state.auth.loading or jobBusy)

    tdiv(class = "composer"):
      textarea(
        id = "messageInput",
        class = "composer-input",
        placeholder = cstring("Message " & productName & "..."),
        `aria-label` = cstring("Message " & productName),
        rows = "1",
        value = cstring(state.composerDraft)
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

          resizeComposerInput()

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
             not keyboardEvent.shiftKey and not isComposing(event):
            event.preventDefault()
            submitDraft(state)

      tdiv(class = "composer-footer"):
        span(class = "composer-context"):
          if state.auth.loading:
            text "Checking your workspace · your draft is kept"
          elif jobBusy:
            text "Task in progress · you can draft your next message"
          else:
            text (if state.workflowSteps.len > 0: "Required operations included · review before sending"
                  else: "Tools selected automatically")

        button(
          class = sendClass,
          disabled = sendDisabled,
          `aria-label` = "Send message",
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

    if state.run.status == "submission_unknown":
      button(class = "secondary-action"):
        text "Check saved submission"
        proc onclick(event: Event, node: VNode) =
          discard recoverPendingSubmission(state)
