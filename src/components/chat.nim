include karax/prelude

import std/json

import ../app/types
import ../app/backend_bridge
import ../api/tool_proposal
import ../app/job_decision

import result_card
import answer_references
import ../app/skills
import message_body
import message_feedback
import answer_actions
import brand
import statusbar


proc progressLabel(state: AppState): string =
  case state.run.progressStage
  of "routing": "Choosing the right tools"
  of "planning": "Preparing the next action"
  of "executing": "Running the requested tools"
  of "synthesizing": "Preparing the result"
  of "waiting_provider": "Waiting for the model provider"
  else:
    case state.run.status
    of "submitting": "Submitting your request"
    of "restoring": "Checking the saved task"
    of "pending": "Your task is queued"
    else: "Working on your request"


proc renderJobProgress(state: AppState): VNode =
  # While the answer is written it is shown here as plain text, marked as a
  # preview; the saved answer replaces it as a normal message (FR-080).
  let writing = state.run.answerPreview.len > 0
  result = buildHtml(tdiv(class = "job-progress", role = "status", `aria-live` = "polite")):
    span(class = "job-progress-dot"):
      text ""
    tdiv(class = "job-progress-copy"):
      strong:
        text(if writing: "Writing the answer" else: progressLabel(state))
      span:
        text(if writing: "Preview. The saved answer replaces it." else: observationLabel(state.run.observationMode))
      if writing:
        p(class = "answer-preview"):
          text state.run.answerPreview
    if state.run.observationMode == "interrupted":
      button(class = "approval-recovery-button"):
        text "Check saved task"
        proc onclick(event: Event, node: VNode) =
          discard resumeBackendJob(state)
    elif canCancelJob(state):
      button(class = "approval-recovery-button", `aria-label` = "Stop this request"):
        text "Stop"
        proc onclick(event: Event, node: VNode) =
          discard cancelRunningJob(state)


proc renderMessage(
  state: AppState,
  message: ChatMessage
): VNode =

  case message.role

  of mrUser:

    result = buildHtml(
      tdiv(class = "message-row user")
    ):

      tdiv(class = "message-column user"):

        span(class = "message-author"):
          text "You"

        tdiv(class = "message-bubble user"):
          text message.content


  of mrAssistant:

    result = buildHtml(
      tdiv(class = "message-row assistant")
    ):

      tdiv(class = "assistant-avatar"):
        text productName[0 .. 0]

      tdiv(class = "message-column assistant"):

        span(class = "message-author"):
          text productName

        if message.content.len > 0:

          tdiv(class = "message-bubble assistant"):
            renderMessageBody(message.content)

          tdiv(class = "message-actions"):
            renderCopyAnswer(message)


        if message.cards.len > 0:

          tdiv(class = "message-result-cards"):

            for card in message.cards:

              renderResultCard(
                card
              )

        if message.references.len > 0:
          renderAnswerReferences(state, message.references)

        if message.skills.len > 0:
          renderAnswerSkills(message.skills)

        # Only answers from a saved task can be linked for review.
        if message.jobId.len > 0 and message.content.len > 0:
          renderMessageFeedback(state, message.jobId)


proc renderApprovalAction(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "message-row assistant")
  ):

    tdiv(class = "assistant-avatar"):
      text productName[0 .. 0]

    tdiv(class = "message-column assistant"):

      span(class = "message-author"):
        if state.run.status == "waiting_approval":
          text "Approval required"
        elif state.run.status == "restoring":
          text "Checking saved outcome"
        else:
          text "Saving your decision"

      tdiv(class = "message-bubble assistant"):

        if reviewableProposal(state.run.proposal):
          p:
            text "Check the details, then approve to run this action or reject to stop it."
          strong:
            text "Action details"
          p:
            text state.run.proposal.tool
          pre(class = "approval-arguments"):
            text pretty(state.run.proposal.arguments)
          if state.run.decisionError.len > 0:
            p(class = "approval-decision-error"):
              text state.run.decisionError
            button(
              class = "approval-recovery-button",
              title = "Check this task again without sending the decision twice"
            ):
              text "Check saved outcome"
              proc onclick(event: Event, node: VNode) =
                discard resumeBackendJob(state)

          tdiv(class = "approval-actions"):
            button(
              class = "approval-action-button",
              title = "Approve and run this action",
              disabled = not canDecideJob(state)
            ):
              if state.run.status == "approving":
                text "Approving…"
              else:
                text "Approve action"
              proc onclick(event: Event, node: VNode) =
                discard approvePendingJob(state)
            button(
              class = "approval-action-button rejection-action-button",
              title = "Reject this saved proposal without executing it",
              disabled = not canDecideJob(state)
            ):
              if state.run.status == "rejecting":
                text "Rejecting…"
              else:
                text "Reject action"
              proc onclick(event: Event, node: VNode) =
                discard rejectPendingJob(state)
        else:
          p:
            text "The action details could not be loaded. Reload this chat before approving."


proc renderChat*(
  state: AppState
): VNode =

  result = buildHtml(
    section(class = "conversation")
  ):

    if state.messages.len == 0:

      tdiv(class = "welcome"):

        img(
          class = "welcome-icon",
          src = productMark,
          alt = ""
        )

        h2:
          text "What do you want to work on?"

        p:
          text """
Inspect systems, check accounts and access,
analyze developer operations, or work with
connected tools and plugins.
"""

        tdiv(class = "welcome-hints"):

          span:
            text "Account status"

          span:
            text "Access checks"

          span:
            text "Developer operations"

          span:
            text "Git workflows"


    else:

      for message in state.messages:

        renderMessage(
          state,
          message
        )


    if state.run.active and state.run.status in ["waiting_approval", "approving", "rejecting"]:
      renderApprovalAction(state)

    if state.run.active and state.run.status in ["submitting", "restoring", "pending", "processing"]:
      renderJobProgress(state)
