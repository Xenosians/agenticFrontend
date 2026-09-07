import dom
import strutils


const
  ComposerMinHeight* = 24
  ComposerMaxHeight* = 180


proc messageInput*(): Element =
  document.getElementById("messageInput")


proc sendButton*(): Element =
  document.getElementById("sendButton")


proc getComposerValue*(): string =
  let input = messageInput()

  if input == nil:
    return ""

  result = ($input.value).strip()


proc updateSendButton*() =
  let
    input = messageInput()
    button = sendButton()

  if input == nil or button == nil:
    return

  let hasContent =
    ($input.value).strip().len > 0

  button.disabled = not hasContent

  if hasContent:
    button.classList.add("active")
  else:
    button.classList.remove("active")


proc resizeComposer*() =
  let input = messageInput()

  if input == nil:
    return

  # Reset first so shrinking works too.
  input.style.height = "auto"

  let wantedHeight =
    min(
      input.scrollHeight,
      ComposerMaxHeight
    )

  input.style.height =
    $wantedHeight & "px"

  if input.scrollHeight > ComposerMaxHeight:
    input.style.overflowY = "auto"
  else:
    input.style.overflowY = "hidden"


proc resetComposer*() =
  let input = messageInput()

  if input == nil:
    return

  input.value = ""
  input.style.height = "auto"
  input.style.overflowY = "hidden"

  updateSendButton()

  input.focus()