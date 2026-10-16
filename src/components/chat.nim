include karax/prelude

import std/json

import ../app/types
import ../app/backend_bridge
import ../api/tool_proposal
import ../app/job_decision

import result_card


proc renderMessage(
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
        text "A"

      tdiv(class = "message-column assistant"):

        span(class = "message-author"):
          text "Agentic"

        if message.content.len > 0:

          tdiv(class = "message-bubble assistant"):
            text message.content


        if message.cards.len > 0:

          tdiv(class = "message-result-cards"):

            for card in message.cards:

              renderResultCard(
                card
              )


proc renderApprovalAction(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "message-row assistant")
  ):

    tdiv(class = "assistant-avatar"):
      text "A"

    tdiv(class = "message-column assistant"):

      span(class = "message-author"):
        if state.run.status == "waiting_approval":
          text "Approval required"
        else:
          text "Saving your decision"

      tdiv(class = "message-bubble assistant"):

        if reviewableProposal(state.run.proposal):
          p:
            text "Review these saved action details. Approve to execute them, or reject to stop this proposal."
          strong:
            text "Action details"
          p:
            text state.run.proposal.tool
          pre(class = "approval-arguments"):
            text pretty(state.run.proposal.arguments)
          if state.run.decisionError.len > 0:
            p(class = "approval-decision-error"):
              text state.run.decisionError
          tdiv(class = "approval-actions"):
            button(
              class = "approval-action-button",
              title = "Approve and execute this governed action",
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
            text "The saved action details are unavailable. Reload this chat to check its job before approving."


proc renderChat*(
  state: AppState
): VNode =

  result = buildHtml(
    section(class = "conversation")
  ):

    if state.messages.len == 0:

      tdiv(class = "welcome"):

        tdiv(class = "welcome-icon"):
          text "A"

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
          message
        )


    if state.run.active and state.run.status in ["waiting_approval", "approving", "rejecting"]:
      renderApprovalAction(state)
