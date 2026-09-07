include karax/prelude

import karax/kdom

import std/strutils

import ../app/types
import ../app/state


type
  SubmitHandler* =
    proc(message: string) {.closure.}


proc submitDraft(
  state: AppState,
  onSubmit: SubmitHandler,
  textareaNode: VNode = nil
) =
  let message =
    state.composerDraft.strip()

  if message.len == 0:
    return

  onSubmit(message)

  setComposerDraft(
    state,
    ""
  )

  if textareaNode != nil:
    textareaNode.value = cstring""


proc renderComposer*(
  state: AppState,
  onSubmit: SubmitHandler
): VNode =

  let
    sendDisabled =
      state.composerDraft.strip().len == 0

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
        placeholder = "Ask Agentic...",
        rows = "1",
        value = cstring(state.composerDraft)
      ):

        proc oninput(
          event: Event,
          node: VNode
        ) =
          setComposerDraft(
            state,
            $node.value
          )


        proc onkeydown(
          event: Event,
          node: VNode
        ) =
          let keyboardEvent =
            cast[KeyboardEvent](event)

          setComposerDraft(
            state,
            $node.value
          )

          if keyboardEvent.key == "Enter" and
             not keyboardEvent.shiftKey:

            event.preventDefault()

            submitDraft(
              state,
              onSubmit,
              node
            )


      tdiv(class = "composer-footer"):

        tdiv(class = "composer-tools"):

          button(
            class = "composer-tool-button"
          ):
            text "+"

          button(
            class = "composer-tool-button"
          ):
            text "Tools"


        button(
          class = sendClass,
          disabled = sendDisabled
        ):

          text "↑"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            submitDraft(
              state,
              onSubmit
            )


    span(class = "composer-hint"):
      text "Enter to send · Shift+Enter for a new line"