include karax/prelude

import karax/kdom

import std/strutils

import app/commands
import app/types
import app/state
import app/auth_bridge
import app/backend_bridge

import components/connections
import components/capabilities
import app/extension_bridge
import components/auth
import components/sidebar
import components/chat
import components/composer
import components/brand
import components/inspector
import components/result_card
import components/required_operations


var appState =
  initAppState()


proc runWorkspaceCommand(action: string)


type WorkspaceFocus = object
  target, userId, sessionId: string
  view: AppView
  paletteOpen: bool

var pendingWorkspaceFocus, paletteOrigin: WorkspaceFocus

proc activeElementId(): cstring {.importjs: "(() => document.activeElement?.id || '')()".}
proc focusElement(id: cstring) {.importjs: "document.getElementById(#)?.focus()".}
proc activateSearchCommand(event: Event): bool {.
  importjs: "((e) => e.key === 'Enter' && !e.isComposing && !e.repeat)(#)".}

proc focusTargetForView(): string =
  case appState.activeView
  of viewChat: "messageInput"
  of viewSearch: "chatSearch"
  else: "commandPaletteButton"

proc workspaceFocus(target: string): WorkspaceFocus =
  WorkspaceFocus(target: target, userId: appState.auth.userId,
    sessionId: appState.auth.sessionId, view: appState.activeView,
    paletteOpen: appState.commandPaletteOpen)

proc focusContextMatches(request: WorkspaceFocus): bool =
  appState.auth.authenticated and request.userId.len > 0 and request.sessionId.len > 0 and
    request.userId == appState.auth.userId and request.sessionId == appState.auth.sessionId and
    request.view == appState.activeView and request.paletteOpen == appState.commandPaletteOpen

proc queueWorkspaceFocus(target: string) =
  pendingWorkspaceFocus = workspaceFocus(target)

proc focusWorkspaceAfterRender() =
  # Consume once, after Karax commits DOM; another navigation/owner cancels it.
  let request = pendingWorkspaceFocus
  pendingWorkspaceFocus = WorkspaceFocus()
  if request.target.len > 0 and focusContextMatches(request):
    focusElement(cstring(request.target))

proc activateFirstSearchResult() =
  let query = appState.commandQuery.toLowerAscii()
  for command in workspaceCommands:
    if query in command.label.toLowerAscii():
      runWorkspaceCommand(command.id)
      return
  let chatQuery = appState.commandQuery.strip().toLowerAscii()
  for chat in appState.chats:
    if chatQuery in chat.title.toLowerAscii():
      appState.commandPaletteOpen = false
      discard selectChat(appState, chat.chatId)
      return


proc activeViewTitle(): string =
  if appState.commandPaletteOpen:
    return "Commands"

  case appState.activeView
  of viewChat:
    "Chat"
  of viewChats:
    "Chats"
  of viewSearch:
    "Search"
  of viewJobs, viewRuns, viewLogs:
    "Activity"
  of viewSystem:
    "System"
  of viewPlugin, viewTool:
    "Connections"
  of viewNodeBuilder:
    "AI Node Builder"
  of viewSimulator:
    "PCB / Infrastructure Simulator"
  of viewAccount:
    "Account"
  of viewCapabilities:
    "Capabilities"


proc currentChatTitle(): string =
  for chat in appState.chats:
    if chat.chatId == appState.currentChatId:
      return chat.title


proc activeViewSubtitle(): string =
  if appState.commandPaletteOpen:
    return "Quick workspace actions and navigation"

  case appState.activeView
  of viewChat:
    "Durable governed assistant workspace"
  of viewChats:
    "Your saved conversations"
  of viewSearch:
    "Search the loaded chat"
  of viewJobs, viewRuns, viewLogs:
    "Current durable job and execution timeline"
  of viewSystem:
    "Safe service health and application state"
  of viewPlugin, viewTool:
    "Models, harnesses, datasets and governed integrations"
  of viewNodeBuilder:
    "Design preview — execution is not enabled"
  of viewSimulator:
    "Design preview — simulation is not connected"
  of viewAccount:
    "Profile and authenticated sessions"
  of viewCapabilities:
    "Governed operations by specialist"


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
          id = "chatSearch",
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
          button(title = "Clear search", `aria-label` = "Clear search"):
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
                    text productName

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

        if appState.run.workflowContract != nil:
          tdiv(class = "activity-section"):
            h3: text "Required operations"
            renderWorkflowReview(appState.run.workflowContract)

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


proc renderAccountSession(currentSession: AuthSessionItem): VNode =
  result = buildHtml(tdiv(class = "system-row account-session-row")):
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

        button(class = "secondary-action", disabled = appState.auth.loading):
          text (if appState.auth.loading: "Signing out…" else: "Sign out")

          proc onclick(
            event: Event,
            node: VNode
          ) =
            discard logoutApplication(
              appState
            )

      if appState.auth.error.len > 0:
        p(class = "account-error", role = "alert"):
          text appState.auth.error

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
            renderAccountSession(authSession)


proc renderSavedChat(savedChat: ChatItem): VNode =
  result = buildHtml(button(class =
      if savedChat.chatId == appState.currentChatId:
        cstring"command-center-row saved-chat-row active"
      else:
        cstring"command-center-row saved-chat-row")):
    span(class = "command-center-icon", `aria-hidden` = "true"):
      text "◇"
    tdiv(class = "command-center-copy"):
      strong:
        text savedChat.title
      span:
        if savedChat.chatId == appState.currentChatId:
          text "Current chat"
        else:
          text "Open conversation"
    proc onclick(event: Event, node: VNode) =
      appState.commandPaletteOpen = false
      discard selectChat(appState, savedChat.chatId)


proc renderChatList(query: string = ""): VNode =
  let search = query.strip().toLowerAscii()
  result = buildHtml(tdiv(class = "command-center-list")):
    if appState.chats.len == 0:
      p:
        text "No saved chats yet."
    else:
      for chat in appState.chats:
        if search in chat.title.toLowerAscii():
          renderSavedChat(chat)


proc renderChatsView(): VNode =
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "command-center"):
      tdiv(class = "command-center-header"):
        tdiv:
          h2:
            text "Saved chats"
          p:
            text "Open a conversation to restore its messages and saved job."
        button(class = "command-back-button"):
          text "New chat"
          proc onclick(event: Event, node: VNode) =
            discard createNewChat(appState)
      renderChatList()


proc renderWorkspaceCommand(command: WorkspaceCommand): VNode =
  result = buildHtml(button(class = "command-center-row")):
    span(class = "command-center-icon", `aria-hidden` = "true"):
      case command.id
      of "new_chat":
        text "+"
      of "chats":
        text "◇"
      of "search":
        text "⌕"
      of "connections":
        text "◇"
      of "capabilities":
        text "▤"
      of "inspector":
        text "I"
      of "refresh":
        text "↻"
      of "compose":
        text "✎"
      else:
        text "·"

    tdiv(class = "command-center-copy"):
      strong:
        text command.label

      span:
        case command.id
        of "new_chat":
          text "Create a new durable conversation"
        of "chats":
          text "Browse your saved conversations"
        of "search":
          text "Search the current chat"
        of "connections":
          text "Open models, harnesses, datasets and integrations"
        of "capabilities":
          text "Browse governed operations by specialist"
        of "inspector":
          text "Toggle developer diagnostics"
        of "refresh":
          text "Refresh service and connection state"
        of "compose":
          text "Return to the chat composer"
        else:
          text "Workspace action"

    if command.shortcut.len > 0:
      kbd:
        text command.shortcut
    else:
      span(class = "command-enter", `aria-hidden` = "true"):
        text "↵"

    proc onclick(
      event: Event,
      node: VNode
    ) =
      runWorkspaceCommand(
        command.id
      )


proc renderCommandCenter(): VNode =
  result = buildHtml(
    section(class = "conversation")
  ):
    tdiv(class = "command-center"):
      tdiv(class = "command-center-header"):
        tdiv:
          span(class = "command-center-eyebrow"):
            text "Workspace"

          h2:
            text "Commands"

          p:
            text "Navigate and run workspace actions without opening an overlay."

        button(class = "command-back-button"):
          text "Back"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            runWorkspaceCommand(
              "dismiss"
            )

      tdiv(class = "command-center-search"):
        span:
          text "⌕"

        input(
          id = "commandSearch",
          `type` = "search",
          placeholder = "Search commands and chats",
          value = cstring(
            appState.commandQuery
          )
        ):
          proc oninput(
            event: Event,
            node: VNode
          ) =
            appState.commandQuery =
              $node.value

            redraw(kxi)
          proc onkeydown(event: Event, node: VNode) =
            if activateSearchCommand(event):
              event.preventDefault()
              activateFirstSearchResult()

      tdiv(class = "command-center-section"):
        tdiv(class = "command-section-heading"):
          strong:
            text "Quick actions"

          span:
            text "Ctrl/⌘ K"

        tdiv(class = "command-center-list"):
          for command in workspaceCommands:
            if appState.commandQuery.toLowerAscii() in command.label.toLowerAscii():
              renderWorkspaceCommand(command)

      tdiv(class = "command-center-section"):
        tdiv(class = "command-section-heading"):
          strong:
            text "Saved chats"
        renderChatList(appState.commandQuery)


proc renderWorkspaceBody(): VNode =
  if appState.commandPaletteOpen:
    return renderCommandCenter()

  case appState.activeView
  of viewChat:
    renderChat(
      appState
    )
  of viewChats:
    renderChatsView()
  of viewSearch:
    renderSearchView()
  of viewJobs, viewRuns, viewLogs:
    renderActivityView()
  of viewSystem:
    renderSystemView()
  of viewPlugin, viewTool:
    renderConnections(appState)
  of viewNodeBuilder:
    renderNodeBuilderView()
  of viewSimulator:
    renderSimulatorView()
  of viewAccount:
    renderAccountView()
  of viewCapabilities:
    renderCapabilitiesView(appState)


proc runStatusLabel(status: string): string =
  case status
  of "submitting": "Submitting"
  of "submission_unknown": "Submission not confirmed"
  of "restoring": "Checking saved state"
  of "pending": "Queued"
  of "processing": "Working"
  of "waiting_approval": "Approval needed"
  of "approving": "Approving"
  of "rejecting": "Rejecting"
  of "completed": "Completed"
  of "denied": "Stopped"
  of "outcome_unknown", "reconciliation_required": "Needs review"
  of "failed": "Failed"
  else:
    if status.len > 0: status.replace("_", " ")
    else: "Activity"

proc runStatusClass(status: string): cstring =
  case status
  of "submitting", "restoring", "pending", "processing", "approving", "rejecting":
    cstring"run-status-chip working"
  of "waiting_approval": cstring"run-status-chip attention"
  of "completed": cstring"run-status-chip success"
  of "outcome_unknown", "reconciliation_required", "submission_unknown": cstring"run-status-chip warning"
  of "failed": cstring"run-status-chip error"
  of "denied": cstring"run-status-chip neutral"
  else: cstring"run-status-chip"


proc renderHeaderMenu(): VNode =
  result = buildHtml(
    tdiv(class = "header-menu")
  ):
    # Who is signed in: the sidebar footer shows this on wide screens only.
    tdiv(class = "header-menu-owner"):
      strong:
        text (if appState.auth.displayName.len > 0: appState.auth.displayName
              else: appState.auth.email)
      if appState.auth.displayName.len > 0 and appState.auth.email.len > 0:
        span:
          text appState.auth.email

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
        # Shown where the sidebar (and its chat list) is hidden. Search covers
        # only the open chat, so it names that chat as well.
        let chatTitle = currentChatTitle()
        if appState.activeView in {viewChat, viewSearch} and
           not appState.commandPaletteOpen and chatTitle.len > 0:
          span(class = "workspace-chat-title"):
            text chatTitle

      # Active model · dataset. A sibling of the controls so narrow layouts
      # can give it a full-width row instead of squeezing it between buttons.
      let context = activeContextNames(appState)
      if context.model.len > 0:
        let label =
          if context.dataset.len > 0: context.model & " · " & context.dataset
          else: context.model
        button(
          class = "workspace-context",
          title = cstring("Active model and dataset: " & label),
          `aria-label` = cstring("Active model and dataset: " & label)
        ):
          span(class = "workspace-context-model"):
            text context.model
          if context.dataset.len > 0:
            span(class = "workspace-context-separator"):
              text "·"
            span(class = "workspace-context-dataset"):
              text context.dataset
          proc onclick(event: Event, node: VNode) =
            openActiveContext(appState)
            runWorkspaceCommand("connections")

      tdiv(class = "header-controls"):
        if appState.run.active and appState.run.status.len > 0:
          button(
            class = runStatusClass(appState.run.status),
            `aria-label` = cstring(runStatusLabel(appState.run.status)),
            title = "Open durable job activity"
          ):
            span(class = "run-status-dot"):
              text ""
            span(class = "run-status-label"):
              text runStatusLabel(appState.run.status)
            proc onclick(event: Event, node: VNode) =
              setActiveView(appState, viewJobs)

        button(
          class = "header-action chats-header-action",
          title = "Saved chats (Ctrl/Cmd+Alt+C)"
        ):
          text "Chats"
          proc onclick(event: Event, node: VNode) =
            runWorkspaceCommand("chats")

        button(
          id = "commandPaletteButton",
          class = "header-action command-header-action",
          title = "Commands (Ctrl/Cmd+K)"
        ):
          text "⌘ K"

          proc onclick(
            event: Event,
            node: VNode
          ) =
            runWorkspaceCommand(
              "palette"
            )

        if appState.activeView == viewSystem and
           not appState.commandPaletteOpen:
          button(
            class = "header-action",
            title = "Refresh system status",
            `aria-label` = "Refresh system status"
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
          id = "workspaceMoreButton",
          title = "More",
          `aria-label` = "More",
          `aria-expanded` = cstring($appState.headerMenuOpen)
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

    if appState.activeView == viewChat and
       not appState.commandPaletteOpen:
      renderComposer(
        appState
      )




proc runWorkspaceCommand(action: string) =
  if not appState.auth.authenticated: return
  let wasPalette = appState.commandPaletteOpen
  let wasMenu = appState.headerMenuOpen
  if action == "palette" and not wasPalette:
    let current = $activeElementId()
    paletteOrigin = workspaceFocus(if current.len > 0: current else: focusTargetForView())
  appState.commandPaletteOpen = false
  case action
  of "palette":
    appState.headerMenuOpen = false
    appState.commandQuery = ""
    appState.commandPaletteOpen = true
    queueWorkspaceFocus("commandSearch")
  of "dismiss":
    appState.headerMenuOpen = false
    appState.composerPanel = cpNone
    if wasPalette and focusContextMatches(paletteOrigin):
      queueWorkspaceFocus(paletteOrigin.target)
    elif wasMenu:
      queueWorkspaceFocus("workspaceMoreButton")
    else:
      queueWorkspaceFocus(focusTargetForView())
  of "new_chat": discard createNewChat(appState)
  of "chats": setActiveView(appState, viewChats)
  of "search":
    setActiveView(appState, viewSearch)
    queueWorkspaceFocus("chatSearch")
  of "connections":
    setActiveView(appState, viewPlugin)
    discard refreshExtensions(appState)
  of "capabilities":
    setActiveView(appState, viewCapabilities)
    discard refreshExtensions(appState)
  of "inspector": appState.inspectorOpen = not appState.inspectorOpen
  of "refresh": discard refreshSystemStatus(appState)
  of "compose":
    setActiveView(appState, viewChat)
    queueWorkspaceFocus("messageInput")
  else: discard
  redraw(kxi)



proc installWorkspaceKeys(handler: proc(key: cstring, modifier, shift, composing, repeated, alt: bool): bool) {.importjs: "document.addEventListener('keydown', e => { if (#(e.key, e.ctrlKey || e.metaKey, e.shiftKey, e.isComposing, e.repeat, e.altKey)) e.preventDefault(); })".}

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
  "app",
  clientPostRenderCallback = focusWorkspaceAfterRender
)


discard bootstrapApplication(
  appState
)


discard refreshSystemStatus(
  appState
)

installWorkspaceKeys(proc(key: cstring, modifier, shift, composing, repeated, alt: bool): bool =
  if not appState.auth.authenticated: return false
  let action = shortcutAction($key, modifier, shift, composing, repeated, alt)
  if action.len == 0: return false
  runWorkspaceCommand(action)
  return true
)
