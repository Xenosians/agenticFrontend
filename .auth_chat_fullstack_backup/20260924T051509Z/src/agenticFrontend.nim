include karax/prelude

import std/strutils

import app/types
import app/state
import app/mock_agent

import components/sidebar
import components/chat
import components/composer
import components/inspector


var appState =
  initAppState()


proc applySelectedTool(
  result: var LocalAgentResult
) =
  case appState.composerSelectedToolId

  of "account":
    result.agent =
      "Account Specialist"

    result.tool =
      "account_status"


  of "access":
    result.agent =
      "Access Specialist"

    result.tool =
      "check_access"


  of "shell":
    result.agent =
      "Developer Specialist"

    result.tool =
      "shell"


  of "files":
    result.agent =
      "Developer Specialist"

    result.tool =
      "files"


  of "git":
    result.agent =
      "Developer Specialist"

    result.tool =
      "git"


  else:
    discard


proc submitMessage(
  message: string
) =
  let cleanMessage =
    message.strip()

  if cleanMessage.len == 0:
    return


  addUserMessage(
    appState,
    cleanMessage
  )


  startLocalRun(
    appState,
    cleanMessage
  )


  var localResult =
    routeLocalRequest(
      cleanMessage
    )


  if appState.composerSelectedToolId.len > 0:

    applySelectedTool(
      localResult
    )

    localResult.response =
      "Using the manually selected tool in frontend preview mode. " &
      localResult.response


  completeLocalRun(
    appState,
    localResult.agent,
    localResult.tool
  )


  addAssistantMessage(
    appState,
    localResult.response
  )


proc renderPlaceholder(
  icon: string,
  title: string,
  description: string
): VNode =

  result = buildHtml(
    section(class = "conversation")
  ):

    tdiv(class = "welcome"):

      tdiv(class = "welcome-icon"):
        text icon

      h2:
        text title

      p:
        text description


proc renderSearchView(): VNode =

  let
    query =
      appState.searchDraft
        .strip()
        .toLowerAscii()

  var resultCount =
    0

  if query.len > 0:

    for message in appState.messages:

      if query in
         message.content.toLowerAscii():

        inc resultCount


  result = buildHtml(
    section(class = "conversation")
  ):

    tdiv(class = "developer-view"):

      tdiv(class = "developer-view-header"):

        tdiv:

          h2:
            text "Search"

          p:
            text "Search the current local conversation."


      tdiv(class = "search-box"):

        span:
          text "⌕"

        input(
          class = "search-input",
          `type` = "search",
          placeholder = "Search messages...",
          value = cstring(appState.searchDraft)
        ):

          proc oninput(
            event: Event,
            node: VNode
          ) =
            setSearchDraft(
              appState,
              $node.value
            )


        if appState.searchDraft.len > 0:

          button:
            text "×"

            proc onclick(
              event: Event,
              node: VNode
            ) =
              setSearchDraft(
                appState,
                ""
              )


      if query.len == 0:

        tdiv(class = "empty-card"):
          text "Start typing to search this session."


      elif resultCount == 0:

        tdiv(class = "empty-card"):
          text "No messages matched your search."


      else:

        tdiv(class = "search-results"):

          for message in appState.messages:

            if query in
               message.content.toLowerAscii():

              tdiv(class = "search-result"):

                span:
                  case message.role

                  of mrUser:
                    text "You"

                  of mrAssistant:
                    text "Agentic"

                p:
                  text message.content


proc renderJobsView(): VNode =

  result = buildHtml(
    section(class = "conversation")
  ):

    if not appState.run.active:

      tdiv(class = "welcome"):

        tdiv(class = "welcome-icon"):
          text "▣"

        h2:
          text "Jobs"

        p:
          text "No jobs have been created yet."


    else:

      tdiv(class = "developer-view"):

        tdiv(class = "developer-view-header"):

          tdiv:

            h2:
              text "Latest Job"

            p:
              text "Frontend representation of the durable job contract."

          span(
            class =
              cstring(
                "view-status " &
                appState.run.status
              )
          ):
            text appState.run.status


        tdiv(class = "developer-grid"):

          tdiv(class = "developer-card"):

            span(class = "run-label"):
              text "Job ID"

            strong(class = "mono"):
              text appState.run.jobId


          tdiv(class = "developer-card"):

            span(class = "run-label"):
              text "Status"

            strong:
              text appState.run.status


          tdiv(class = "developer-card wide"):

            span(class = "run-label"):
              text "Request"

            p:
              text appState.run.request


proc renderRunsView(): VNode =

  result = buildHtml(
    section(class = "conversation")
  ):

    if not appState.run.active:

      tdiv(class = "welcome"):

        tdiv(class = "welcome-icon"):
          text "◌"

        h2:
          text "Runs"

        p:
          text "No execution run is active."


    else:

      tdiv(class = "developer-view"):

        tdiv(class = "developer-view-header"):

          tdiv:

            h2:
              text "Latest Run"

            p:
              text "Routing and capability selection."


        tdiv(class = "developer-grid"):

          tdiv(class = "developer-card"):

            span(class = "run-label"):
              text "Agent"

            strong:
              text (
                if appState.run.agent.len > 0:
                  appState.run.agent
                else:
                  "Not selected"
              )


          tdiv(class = "developer-card"):

            span(class = "run-label"):
              text "Tool"

            strong:
              text (
                if appState.run.tool.len > 0:
                  appState.run.tool
                else:
                  "Not selected"
              )


          tdiv(class = "developer-card"):

            span(class = "run-label"):
              text "Status"

            strong:
              text appState.run.status


          tdiv(class = "developer-card"):

            span(class = "run-label"):
              text "Events"

            strong:
              text $appState.runEvents.len


proc renderLogsView(): VNode =

  result = buildHtml(
    section(class = "conversation")
  ):

    tdiv(class = "developer-view"):

      tdiv(class = "developer-view-header"):

        tdiv:

          h2:
            text "Logs"

          p:
            text "Local execution timeline."


      if appState.runEvents.len == 0:

        tdiv(class = "empty-card"):
          text "No runtime events yet."


      else:

        tdiv(class = "log-console"):

          for runEvent in appState.runEvents:

            tdiv(class = "log-line"):

              span:
                text "[" & runEvent.kind & "]"

              text runEvent.message


proc renderSystemView(): VNode =

  result = buildHtml(
    section(class = "conversation")
  ):

    tdiv(class = "developer-view"):

      tdiv(class = "developer-view-header"):

        tdiv:

          h2:
            text "System"

          p:
            text "Current frontend runtime and integration state."


      tdiv(class = "system-list"):

        tdiv(class = "system-row"):

          tdiv:

            strong:
              text "Frontend"

            span:
              text "Karax virtual DOM"

          span(class = "capability-badge enabled"):
            text "Running"


        tdiv(class = "system-row"):

          tdiv:

            strong:
              text "Phoenix Backend"

            span:
              text "Public application boundary"

          span(class = "capability-badge disabled"):
            text "Not connected"


        tdiv(class = "system-row"):

          tdiv:

            strong:
              text "AI Service"

            span:
              text "Python execution service"

          span(class = "capability-badge disabled"):
            text "Not connected"


        tdiv(class = "system-row"):

          tdiv:

            strong:
              text "Plugins"

            span:
              text (
                $appState.plugins.len &
                " registered"
              )

          span(class = "capability-badge preview"):
            text "Local"


        tdiv(class = "system-row"):

          tdiv:

            strong:
              text "Runtime mode"

            span:
              text "Frontend-only simulation"

          span(class = "capability-badge preview"):
            text "Preview"


proc renderToolView(): VNode =

  var
    found = false
    selected = ToolItem()

  for tool in appState.tools:

    if tool.id ==
       appState.selectedToolId:

      selected = tool
      found = true
      break


  if not found:

    return renderPlaceholder(
      ">_",
      "Tool not found",
      "Select a tool from the sidebar."
    )


  result = buildHtml(
    section(class = "conversation")
  ):

    tdiv(class = "developer-view"):

      tdiv(class = "detail-hero"):

        tdiv(class = "detail-icon"):
          text (
            if selected.id == "shell":
              ">_"
            else:
              "◇"
          )

        tdiv:

          span(class = "eyebrow"):
            text "Tool capability"

          h2:
            text selected.name

          p:
            text (
              "Capability ID: " &
              selected.id
            )


        if selected.enabled:

          span(class = "capability-badge enabled"):
            text "Available"

        else:

          span(class = "capability-badge preview"):
            text "Preview only"


      tdiv(class = "detail-card"):

        h3:
          text "Capability boundary"

        p:

          case selected.id

          of "shell":
            text """
Governed command execution. The final gateway will
validate executable, working directory, arguments,
risk and approval requirements.
"""

          of "account":
            text """
Account identity and status operations such as
account lookup, lock state and account-status checks.
"""

          of "access":
            text """
Access and authorization inspection such as roles,
groups and permission checks.
"""

          of "files":
            text """
Controlled file inspection and eventually approved
filesystem mutations.
"""

          of "git":
            text """
Repository state, diff, history and governed
Git operations.
"""

          else:
            text "Frontend capability preview."


      tdiv(class = "detail-actions"):

        button(class = "primary-action"):

          text "Use in composer"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            selectComposerTool(
              appState,
              selected.id
            )

            setActiveView(
              appState,
              viewChat
            )


        button(class = "secondary-action"):

          text "Back to chat"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            setActiveView(
              appState,
              viewChat
            )


proc renderPluginCatalog(): VNode =

  result = buildHtml(
    section(class = "conversation")
  ):

    tdiv(class = "developer-view"):

      tdiv(class = "developer-view-header"):

        tdiv:

          h2:
            text "Plugins"

          p:
            text "External providers and integrations."


        button(class = "primary-action"):

          text "+ Custom plugin"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            addPreviewPlugin(
              appState
            )


      tdiv(class = "plugin-grid"):

        for plugin in appState.plugins:

          let currentPlugin =
            plugin

          button(class = "plugin-card"):

            tdiv(class = "plugin-card-header"):

              tdiv(class = "plugin-icon"):
                text currentPlugin.name[0 .. 0]

              if currentPlugin.connected:

                span(class = "capability-badge enabled"):
                  text "Connected"

              else:

                span(class = "capability-badge disabled"):
                  text "Not connected"


            strong:
              text currentPlugin.name

            span:
              text currentPlugin.id

            proc onclick(
              event: Event,
              node: VNode
            ) =
              openPluginView(
                appState,
                currentPlugin.id
              )


proc renderPluginView(): VNode =

  if appState.selectedPluginId.len == 0:
    return renderPluginCatalog()


  var
    found = false
    selected = PluginItem()

  for plugin in appState.plugins:

    if plugin.id ==
       appState.selectedPluginId:

      selected = plugin
      found = true
      break


  if not found:
    return renderPluginCatalog()


  result = buildHtml(
    section(class = "conversation")
  ):

    tdiv(class = "developer-view"):

      tdiv(class = "detail-hero"):

        tdiv(class = "detail-icon"):
          text selected.name[0 .. 0]

        tdiv:

          span(class = "eyebrow"):
            text "Plugin integration"

          h2:
            text selected.name

          p:
            text (
              "Provider ID: " &
              selected.id
            )


        if selected.connected:

          span(class = "capability-badge enabled"):
            text "Connected"

        else:

          span(class = "capability-badge disabled"):
            text "Disconnected"


      tdiv(class = "detail-card"):

        h3:
          text "Integration"

        p:
          text """
This frontend control is intentionally local for now.
Backend plugin credentials, permissions and provider
capabilities will be connected after the Phoenix API.
"""


      tdiv(class = "detail-actions"):

        button(class = "primary-action"):

          if selected.connected:
            text "Disconnect"
          else:
            text "Connect preview"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            togglePluginConnection(
              appState,
              selected.id
            )


        button(class = "secondary-action"):

          text "All plugins"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            openPluginCatalog(
              appState
            )


proc renderWorkspaceBody(): VNode =

  case appState.activeView

  of viewChat:
    renderChat(
      appState
    )

  of viewSearch:
    renderSearchView()

  of viewJobs:
    renderJobsView()

  of viewRuns:
    renderRunsView()

  of viewLogs:
    renderLogsView()

  of viewSystem:
    renderSystemView()

  of viewTool:
    renderToolView()

  of viewPlugin:
    renderPluginView()


proc renderHeaderMenu(): VNode =

  result = buildHtml(
    tdiv(class = "header-menu")
  ):

    button:

      text "New session"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        resetConversation(
          appState
        )


    button:

      if appState.inspectorOpen:
        text "Hide inspector"
      else:
        text "Show inspector"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        toggleInspector(
          appState
        )


    button:

      text "Clear run state"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        clearRun(
          appState
        )


    button:

      text "About frontend preview"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        appState.headerMenuOpen =
          false

        showToast(
          appState,
          "Agentic Developer Hub · Karax frontend preview."
        )


proc renderWorkspace(): VNode =

  result = buildHtml(
    main(class = "workspace")
  ):

    header(class = "workspace-header"):

      tdiv(class = "workspace-title"):

        h1:
          text "Workspace"

        span:
          text "Agentic Developer Hub"


      tdiv(class = "header-controls"):

        button(class = "inspector-toggle"):

          if appState.inspectorOpen:
            text "Inspector"
          else:
            text "Open inspector"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            toggleInspector(
              appState
            )


        button(class = "header-action"):

          text "⋯"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            toggleHeaderMenu(
              appState
            )


        if appState.headerMenuOpen:
          renderHeaderMenu()


    renderWorkspaceBody()


    if appState.activeView == viewChat:

      renderComposer(
        appState,
        submitMessage
      )


    if appState.toastMessage.len > 0:

      tdiv(class = "toast"):

        span:
          text appState.toastMessage

        button:
          text "×"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            clearToast(
              appState
            )


proc renderApp(): VNode =

  let shellClass =
    if appState.inspectorOpen:
      cstring"app-shell"
    else:
      cstring"app-shell inspector-hidden"


  result = buildHtml(
    tdiv(class = shellClass)
  ):

    renderSidebar(
      appState
    )


    renderWorkspace()


    if appState.inspectorOpen:

      renderInspector(
        appState
      )


setRenderer(
  renderApp,
  "app"
)