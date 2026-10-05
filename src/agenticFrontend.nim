include karax/prelude

import std/strutils

import app/types
import app/state
import app/auth_bridge
import app/backend_bridge

import components/auth
import components/sidebar
import components/chat
import components/composer
import components/inspector
import components/result_card


var appState =
  initAppState()


proc activeViewTitle(): string =
  case appState.activeView
  of viewChat:
    "Chat"
  of viewSearch:
    "Search"
  of viewJobs, viewRuns, viewLogs:
    "Activity"
  of viewSystem:
    "System"
  of viewPlugin, viewTool:
    "Plugins"
  of viewNodeBuilder:
    "AI Node Builder"
  of viewSimulator:
    "PCB / Infrastructure Simulator"
  of viewAccount:
    "Account"


proc activeViewSubtitle(): string =
  case appState.activeView
  of viewChat:
    "Durable governed assistant workspace"
  of viewSearch:
    "Search the loaded chat"
  of viewJobs, viewRuns, viewLogs:
    "Current durable job and execution timeline"
  of viewSystem:
    "Safe service health and application state"
  of viewPlugin, viewTool:
    "Server-managed integrations"
  of viewNodeBuilder:
    "Design preview — execution is not enabled"
  of viewSimulator:
    "Design preview — simulation is not connected"
  of viewAccount:
    "Profile and authenticated sessions"


proc renderSearchView(): VNode =
  let query =
    appState.searchDraft
      .strip()
      .toLowerAscii()

  var resultCount =
    0

  if query.len > 0:
    for message in appState.messages:
      if query in message.content.toLowerAscii():
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
            text "Search messages in the current durable chat."

      tdiv(class = "search-box"):
        span:
          text "⌕"

        input(
          class = "search-input",
          `type` = "search",
          placeholder = "Search this chat...",
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
            redraw(kxi)

        if appState.searchDraft.len > 0:
          button(title = "Clear search"):
            text "×"

            proc onclick(
              event: Event,
              node: VNode
            ) =
              setSearchDraft(
                appState,
                ""
              )
              redraw(kxi)

      if query.len == 0:
        tdiv(class = "empty-card"):
          text "Start typing to search the messages already loaded for this chat."
      elif resultCount == 0:
        tdiv(class = "empty-card"):
          text "No messages matched your search."
      else:
        tdiv(class = "search-results"):
          for message in appState.messages:
            if query in message.content.toLowerAscii():
              tdiv(class = "search-result"):
                span:
                  case message.role
                  of mrUser:
                    text "You"
                  of mrAssistant:
                    text "Agentic"

                p:
                  text message.content


proc renderActivityView(): VNode =
  result = buildHtml(
    section(class = "conversation")
  ):
    tdiv(class = "developer-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "Activity"
          p:
            text "Current durable job state and frontend-visible lifecycle events."

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

      if not appState.run.active:
        tdiv(class = "empty-card"):
          text "No durable job is active in this browser session."
      else:
        tdiv(class = "activity-summary"):
          tdiv(class = "developer-card"):
            span(class = "run-label"):
              text "Status"
            strong:
              text appState.run.status

          tdiv(class = "developer-card"):
            span(class = "run-label"):
              text "Job ID"
            strong(class = "mono"):
              text (
                if appState.run.jobId.len > 0:
                  appState.run.jobId
                else:
                  "Waiting for backend"
              )

          tdiv(class = "developer-card wide"):
            span(class = "run-label"):
              text "Request"
            p:
              text (
                if appState.run.request.len > 0:
                  appState.run.request
                else:
                  "This job was recovered from durable chat history."
              )

        if appState.runEvents.len > 0:
          tdiv(class = "activity-section"):
            tdiv(class = "section-heading-row"):
              h3:
                text "Timeline"
              span:
                text $appState.runEvents.len & " event(s)"

            tdiv(class = "activity-timeline"):
              for runEvent in appState.runEvents:
                tdiv(class = "activity-event"):
                  span(class = "activity-dot"):
                    text ""
                  tdiv:
                    strong:
                      text runEvent.kind.replace("_", " ")
                    p:
                      text runEvent.message

        if appState.run.presentations.len > 0:
          tdiv(class = "activity-section"):
            tdiv(class = "section-heading-row"):
              h3:
                text "Result"

            tdiv(class = "run-result-cards"):
              for card in appState.run.presentations:
                renderResultCard(
                  card
                )


proc renderSystemView(): VNode =
  let
    backendLabel =
      if appState.system.checking:
        "Checking"
      elif not appState.system.checked:
        "Not checked"
      elif appState.system.backendConnected:
        "Connected"
      else:
        "Unavailable"

    aiLabel =
      if appState.system.checking:
        "Checking"
      elif not appState.system.checked:
        "Not checked"
      elif appState.system.aiReady:
        "Ready"
      elif appState.system.aiReachable:
        "Starting"
      else:
        "Unavailable"

  result = buildHtml(
    section(class = "conversation")
  ):
    tdiv(class = "developer-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "System"
          p:
            text "Public service health only. Model, credential, and provider internals stay server-side."

        button(
          class = "secondary-action",
          disabled = appState.system.checking
        ):
          if appState.system.checking:
            text "Checking…"
          else:
            text "Refresh"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            discard refreshSystemStatus(
              appState
            )

      tdiv(class = "system-list"):
        tdiv(class = "system-row"):
          tdiv:
            strong:
              text "Frontend"
            span:
              text "Karax browser application"
          span(class = "capability-badge enabled"):
            text "Running"

        tdiv(class = "system-row"):
          tdiv:
            strong:
              text "Phoenix backend"
            span:
              text "Authentication, chats, durable jobs, approvals"
          span(
            class =
              if appState.system.backendConnected:
                cstring"capability-badge enabled"
              elif not appState.system.checked:
                cstring"capability-badge preview"
              else:
                cstring"capability-badge disabled"
          ):
            text backendLabel

        tdiv(class = "system-row"):
          tdiv:
            strong:
              text "AI runtime"
            span:
              text "Governed execution service behind Phoenix"
          span(
            class =
              if appState.system.aiReady:
                cstring"capability-badge enabled"
              elif appState.system.aiReachable:
                cstring"capability-badge preview"
              else:
                cstring"capability-badge disabled"
          ):
            text aiLabel

        tdiv(class = "system-row"):
          tdiv:
            strong:
              text "Authentication"
            span:
              text "Backend-owned application session"
          span(class = "capability-badge enabled"):
            text "Active"

      if appState.system.error.len > 0:
        tdiv(class = "empty-card system-warning"):
          text appState.system.error


proc pluginDescription(
  pluginId: string
): string =
  case pluginId
  of "jira":
    "Jira and Atlassian operations are executed by trusted server-side providers and governed capabilities."
  of "github":
    "Repository integration is server managed. Browser code never receives repository credentials."
  of "directory":
    "Account and access operations remain behind the backend and governed identity providers."
  of "knowledge":
    "Knowledge and runbook retrieval can be exposed through trusted read-only capabilities."
  else:
    "Server-managed integration surface."


proc renderPluginView(): VNode =
  result = buildHtml(
    section(class = "conversation")
  ):
    tdiv(class = "developer-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "Plugins"
          p:
            text "Integration catalog. Provider credentials and authorization remain server-side."

      tdiv(class = "plugin-grid"):
        for plugin in appState.plugins:
          let currentPlugin = plugin

          tdiv(class = "plugin-card integration-card"):
            tdiv(class = "plugin-card-header"):
              tdiv(class = "plugin-icon"):
                text currentPlugin.name[0 .. 0]

              span(class = "capability-badge preview"):
                text "Server managed"

            strong:
              text currentPlugin.name

            p:
              text pluginDescription(
                currentPlugin.id
              )

      tdiv(class = "empty-card integration-note"):
        strong:
          text "Connection controls are intentionally not simulated."
        p:
          text "When a public plugin registry/status contract exists, this page can render real availability without moving secrets or authority into the browser."


proc renderNodeBuilderView(): VNode =
  result = buildHtml(
    section(class = "conversation")
  ):
    tdiv(class = "developer-view build-preview-page"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "AI Node Builder"
          p:
            text "Visual workflow design surface for a future no-code capability graph."

        span(class = "capability-badge preview"):
          text "Design preview"

      tdiv(class = "preview-banner"):
        strong:
          text "Execution is disabled."
        p:
          text "This draft only establishes the frontend information architecture. Future workflows must compile to the same typed capability, risk, policy, and approval model used by chat."

      tdiv(class = "node-builder-shell"):
        tdiv(class = "node-palette"):
          span(class = "section-label"):
            text "Planned nodes"

          tdiv(class = "palette-item"):
            strong:
              text "Input"
            span:
              text "User or event data"

          tdiv(class = "palette-item"):
            strong:
              text "AI step"
            span:
              text "Semantic proposal"

          tdiv(class = "palette-item"):
            strong:
              text "Capability"
            span:
              text "Governed operation"

          tdiv(class = "palette-item"):
            strong:
              text "Approval"
            span:
              text "Human checkpoint"

        tdiv(class = "node-canvas-preview"):
          tdiv(class = "workflow-node preview-node"):
            span:
              text "1"
            strong:
              text "Request"
            small:
              text "typed input"

          tdiv(class = "workflow-arrow"):
            text "→"

          tdiv(class = "workflow-node preview-node"):
            span:
              text "2"
            strong:
              text "AI proposal"
            small:
              text "no authority"

          tdiv(class = "workflow-arrow"):
            text "→"

          tdiv(class = "workflow-node preview-node"):
            span:
              text "3"
            strong:
              text "Approval / policy"
            small:
              text "trusted boundary"

          tdiv(class = "canvas-watermark"):
            text "Preview only — no graph execution engine is connected"

      tdiv(class = "preview-actions"):
        button(
          class = "secondary-action",
          disabled = true
        ):
          text "Run workflow — not enabled"


proc renderSimulatorView(): VNode =
  result = buildHtml(
    section(class = "conversation")
  ):
    tdiv(class = "developer-view build-preview-page"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "PCB / Infrastructure Simulator"
          p:
            text "Future simulation-first engineering and infrastructure workspace."

        span(class = "capability-badge preview"):
          text "Design preview"

      tdiv(class = "preview-banner"):
        strong:
          text "No simulator or physical device bridge is connected."
        p:
          text "Observed, desired, and simulated state will remain separate. Physical actions will require dedicated governed capabilities and explicit approval."

      tdiv(class = "simulation-layout"):
        tdiv(class = "simulation-toolbar"):
          button(class = "simulation-tab active", disabled = true):
            text "Infrastructure"
          button(class = "simulation-tab", disabled = true):
            text "PCB"
          button(class = "simulation-tab", disabled = true):
            text "Devices"

        tdiv(class = "simulation-canvas"):
          tdiv(class = "infra-node infra-node-a"):
            strong:
              text "Service"
            span:
              text "planned graph node"

          tdiv(class = "infra-node infra-node-b"):
            strong:
              text "Host"
            span:
              text "planned graph node"

          tdiv(class = "infra-node infra-node-c"):
            strong:
              text "Provider"
            span:
              text "planned graph node"

          tdiv(class = "canvas-watermark"):
            text "Simulation workspace placeholder"

      tdiv(class = "simulation-cards"):
        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "Infrastructure graph"
          strong:
            text "Planned"
          p:
            text "Model services, hosts, repositories, deployments, tickets, and dependencies."

        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "PCB / EDA"
          strong:
            text "Planned"
          p:
            text "Simulation and design review before any hardware or manufacturing integration."

        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "Physical bridge"
          strong:
            text "Not enabled"
          p:
            text "No flashing, printing, or machine actuation is available from this draft page."


proc renderAccountView(): VNode =
  result = buildHtml(
    section(class = "conversation")
  ):
    tdiv(class = "developer-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "Account"
          p:
            text "Application identity and server-side sessions."

        button(class = "secondary-action"):
          text "Sign out"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            discard logoutApplication(
              appState
            )

      tdiv(class = "account-profile-grid"):
        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "Display name"
          strong:
            text (
              if appState.auth.displayName.len > 0:
                appState.auth.displayName
              else:
                "Not set"
            )

        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "Email"
          strong:
            text appState.auth.email

        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "Role"
          strong:
            text appState.auth.role

      tdiv(class = "developer-card wide account-session-panel"):
        tdiv(class = "developer-view-header compact"):
          tdiv:
            h3:
              text "Authenticated sessions"
            p:
              text "Sessions are owned and enforced by the backend."

          button(class = "secondary-action"):
            text "Refresh"

            proc onclick(
              event: Event,
              node: VNode
            ) =
              discard loadAuthSessions(
                appState
              )

        if not appState.sessionsLoaded:
          p:
            text "Refresh to load your active sessions."
        elif appState.sessions.len == 0:
          p:
            text "No sessions found."
        else:
          for authSession in appState.sessions:
            let currentSession = authSession

            tdiv(class = "system-row account-session-row"):
              tdiv:
                strong:
                  text (
                    if currentSession.current:
                      "Current session"
                    else:
                      "Session"
                  )

                span:
                  text (
                    currentSession.userAgent &
                    " · expires " &
                    currentSession.expiresAt
                  )

              if currentSession.revokedAt.len > 0:
                span(class = "capability-badge disabled"):
                  text "Revoked"
              elif currentSession.current:
                span(class = "capability-badge enabled"):
                  text "Current"
              else:
                button(class = "secondary-action"):
                  text "Revoke"

                  proc onclick(
                    event: Event,
                    node: VNode
                  ) =
                    discard revokeAuthSession(
                      appState,
                      currentSession.sessionId
                    )


proc renderWorkspaceBody(): VNode =
  case appState.activeView
  of viewChat:
    renderChat(
      appState
    )
  of viewSearch:
    renderSearchView()
  of viewJobs, viewRuns, viewLogs:
    renderActivityView()
  of viewSystem:
    renderSystemView()
  of viewPlugin, viewTool:
    renderPluginView()
  of viewNodeBuilder:
    renderNodeBuilderView()
  of viewSimulator:
    renderSimulatorView()
  of viewAccount:
    renderAccountView()


proc renderHeaderMenu(): VNode =
  result = buildHtml(
    tdiv(class = "header-menu")
  ):
    button:
      text "New chat"
      proc onclick(
        event: Event,
        node: VNode
      ) =
        appState.headerMenuOpen = false
        discard createNewChat(
          appState
        )

    button:
      text "Account"
      proc onclick(
        event: Event,
        node: VNode
      ) =
        appState.headerMenuOpen = false
        setActiveView(
          appState,
          viewAccount
        )
        discard loadAuthSessions(
          appState
        )

    button:
      text "Refresh system status"
      proc onclick(
        event: Event,
        node: VNode
      ) =
        appState.headerMenuOpen = false
        setActiveView(
          appState,
          viewSystem
        )
        discard refreshSystemStatus(
          appState
        )

    button:
      if appState.inspectorOpen:
        text "Hide developer diagnostics"
      else:
        text "Developer diagnostics"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        toggleInspector(
          appState
        )

    button:
      text "Sign out"
      proc onclick(
        event: Event,
        node: VNode
      ) =
        appState.headerMenuOpen = false
        discard logoutApplication(
          appState
        )


proc renderWorkspace(): VNode =
  result = buildHtml(
    main(class = "workspace")
  ):
    header(class = "workspace-header"):
      tdiv(class = "workspace-title"):
        h1:
          text activeViewTitle()
        span:
          text activeViewSubtitle()

      tdiv(class = "header-controls"):
        if appState.activeView == viewSystem:
          button(
            class = "header-action",
            title = "Refresh system status"
          ):
            text "↻"

            proc onclick(
              event: Event,
              node: VNode
            ) =
              discard refreshSystemStatus(
                appState
              )

        button(
          class = "header-action",
          title = "More"
        ):
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
        appState
      )


proc renderApp(): VNode =
  if not appState.auth.checked or
     not appState.auth.authenticated:
    return renderAuthScreen(
      appState
    )

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


discard bootstrapApplication(
  appState
)


discard refreshSystemStatus(
  appState
)
