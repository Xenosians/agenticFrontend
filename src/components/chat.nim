import std/strutils

import ../app/types


proc escapeHtml(value: string): string =
  result = value
    .replace("&", "&amp;")
    .replace("<", "&lt;")
    .replace(">", "&gt;")
    .replace("\"", "&quot;")
    .replace("'", "&#39;")


proc renderMessage(message: ChatMessage): string =
  let content = escapeHtml(message.content)

  case message.role
  of mrUser:
    result = """
      <div class="message-row user">
        <div class="message-bubble user">
    """ &
    content &
    """
        </div>
      </div>
    """

  of mrAssistant:
    result = """
      <div class="message-row assistant">
        <div class="assistant-avatar">A</div>

        <div class="message-bubble assistant">
    """ &
    content &
    """
        </div>
      </div>
    """


proc renderChat*(state: AppState): string =
  if state.messages.len == 0:
    return """
      <div class="welcome">

        <div class="welcome-icon">
          A
        </div>

        <h2>What do you want to work on?</h2>

        <p>
          Ask Agentic to inspect systems, understand commands,
          check accounts and access, analyze code, or work with
          connected developer tools.
        </p>

      </div>
    """

  var html = ""

  for message in state.messages:
    html.add(renderMessage(message))

  result = html