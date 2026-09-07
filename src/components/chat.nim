include karax/prelude

import ../app/types


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