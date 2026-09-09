include karax/prelude

import ../app/types
import ../app/backend_bridge


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

        tdiv(class = "message-bubble assistant"):
          text message.content


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
        text "Approval required"

      tdiv(class = "message-bubble assistant"):

        p:
          text (
            "This action is ready to execute. " &
            "Approve it to continue."
          )

        button(
          class = "inspector-toggle",
          title = "Approve and execute this governed action"
        ):

          text "Approve action"

          proc onclick(
            event: Event,
            node: VNode
          ) =

            discard approvePendingJob(
              state
            )


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
            text "Shell operations"

          span:
            text "Git workflows"


    else:

      for message in state.messages:

        renderMessage(
          message
        )


      if state.run.active and
         state.run.status ==
         "waiting_approval":

        renderApprovalAction(
          state
        )