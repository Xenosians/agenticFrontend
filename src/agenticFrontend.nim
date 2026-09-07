import dom
import strutils

import app/state
import app/types

import components/sidebar
import components/chat
import components/inspector
import components/composer


proc renderChatView(state: AppState) =
  let conversation =
    document.getElementById("conversationRoot")

  if conversation == nil:
    return

  conversation.innerHTML =
    renderChat(state)

  conversation.scrollTop =
    conversation.scrollHeight


proc renderInspectorView(state: AppState) =
  let inspector =
    document.getElementById("inspectorContent")

  if inspector == nil:
    return

  inspector.innerHTML =
    renderInspector(state)


proc renderAppState(state: AppState) =
  renderChatView(state)
  renderInspectorView(state)


proc submitMessage(state: AppState) =
  let message =
    getComposerValue()

  if message.len == 0:
    return

  addUserMessage(
    state,
    message
  )

  startLocalRun(
    state,
    message
  )

  renderAppState(state)

  resetComposer()


proc setupEvents(state: AppState) =
  let
    sendButton =
      document.getElementById("sendButton")

    input =
      document.getElementById("messageInput")

    newSessionButton =
      document.getElementById("newSessionButton")


  if sendButton != nil:
    sendButton.addEventListener(
      "click",
      proc(event: Event) =
        submitMessage(state)
    )


  if input != nil:
    input.addEventListener(
      "keydown",
      proc(event: Event) =

        let keyboardEvent =
          KeyboardEvent(event)

        if keyboardEvent.key == "Enter" and
           not keyboardEvent.shiftKey:

          event.preventDefault()

          submitMessage(state)
    )


  if newSessionButton != nil:
    newSessionButton.addEventListener(
      "click",
      proc(event: Event) =

        resetConversation(state)

        renderAppState(state)

        if input != nil:
          input.focus()
    )


proc main() =
  let appState =
    initAppState()

  let root =
    document.getElementById("app")

  if root == nil:
    return


  root.innerHTML = """
    <div class="app-shell">


      <!-- SIDEBAR -->

      <aside
        id="sidebarRoot"
        class="sidebar"
      ></aside>


      <!-- WORKSPACE -->

      <main class="workspace">


        <header class="workspace-header">

          <div>

            <h1>
              Workspace
            </h1>

            <span>
              Agentic Developer Hub
            </span>

          </div>

          <button class="header-action">
            ⋯
          </button>

        </header>


        <!-- CHAT -->

        <section
          id="conversationRoot"
          class="conversation"
        ></section>


        <!-- COMPOSER -->

        <section class="composer-container">

          <div class="composer">

            <textarea
              id="messageInput"
              placeholder="Ask Agentic..."
              rows="1"
            ></textarea>


            <div class="composer-footer">

              <div class="composer-tools">

                <button
                  type="button"
                  aria-label="Attach"
                >
                  +
                </button>

                <button
                  type="button"
                >
                  Tools
                </button>

              </div>


              <button
                id="sendButton"
                class="send-button"
                type="button"
                aria-label="Send message"
              >
                ↑
              </button>

            </div>

          </div>


          <span class="composer-hint">
            Review commands and mutations before approval.
          </span>

        </section>

      </main>


      <!-- RUN INSPECTOR -->

      <aside class="inspector">

        <header class="inspector-header">

          <span>
            Run Inspector
          </span>

          <button
            type="button"
            aria-label="Close inspector"
          >
            ×
          </button>

        </header>


        <div class="inspector-tabs">

          <button class="active">
            Run
          </button>

          <button>
            Tools
          </button>

          <button>
            Events
          </button>

          <button>
            Raw
          </button>

        </div>


        <section
          id="inspectorContent"
          class="inspector-content"
        ></section>

      </aside>

    </div>
  """


  let sidebarRoot =
    document.getElementById("sidebarRoot")

  if sidebarRoot != nil:
    sidebarRoot.innerHTML =
      renderSidebar(appState)


  renderAppState(appState)

  setupEvents(appState)


main()