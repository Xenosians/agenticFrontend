include karax/prelude

import karax/kdom

import std/strutils

import app/commands
import app/types
import app/state
import app/auth_bridge
import app/backend_bridge
import app/operations_bridge
import app/review_bridge
import app/knowledge_bridge
import app/learning_bridge
import app/workflow_bridge
import app/engineering_bridge
import app/request_context

import components/connections
import components/capabilities
import app/extension_bridge
import components/auth
import components/account
import components/sidebar
import components/chat
import components/composer
import components/brand
import components/inspector
import components/result_card
import components/required_operations
import components/statusbar
import components/chat_search
import components/operations
import components/review
import components/knowledge
import components/learning
import components/workflows
import components/engineering
import components/workspace_menu
import config/runtime_config


var appState =
  initAppState()


proc runWorkspaceCommand(action: string)


type WorkspaceFocus = object
  target, userId, sessionId: string
  view: AppView
  paletteOpen: bool

var pendingWorkspaceFocus, paletteOrigin: WorkspaceFocus
var openWorkspaceMenu, workspaceMenuOwner, workspaceMenuSession: string
var workspaceHelpPreviousView = viewChat
var pendingMenuFocus: string

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
  if pendingMenuFocus.len > 0 and appState.auth.authenticated:
    focusElement(cstring(pendingMenuFocus))
  pendingMenuFocus = ""

proc activateFirstSearchResult() =
  let query = appState.commandQuery.toLowerAscii()
  for command in workspaceCommands:
    if command.reviewerOnly and not isReviewer(appState): continue
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
    "Operations"
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
  of viewReview:
    "Review"
  of viewKnowledge:
    "Knowledge"
  of viewLearning:
    "Learning"
  of viewHelp:
    "Help"


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
    "Saved chats and the open conversation"
  of viewJobs, viewRuns, viewLogs:
    "Your task queue and recorded inference timings"
  of viewSystem:
    "Safe service health and application state"
  of viewPlugin, viewTool:
    "Models, harnesses, datasets and governed integrations"
  of viewNodeBuilder:
    "Saved workflows that run as governed jobs"
  of viewSimulator:
    "Desired topologies, drift checks and PCB netlist inspection"
  of viewAccount:
    "Profile, notifications and authenticated sessions"
  of viewCapabilities:
    "Governed operations by specialist"
  of viewReview:
    "Critiques and corrections awaiting a decision"
  of viewKnowledge:
    "Reference sources and cited search"
  of viewLearning:
    "Training readiness for your models and datasets"
  of viewHelp:
    "Workspace actions and keyboard shortcuts"


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
            text "Search every saved chat, and the messages in the open one."

      tdiv(class = "search-box"):
        span:
          text "⌕"

        input(
          id = "chatSearch",
          class = "search-input",
          `type` = "search",
          placeholder = "Search chats...",
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
            scheduleChatSearch($node.value)
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
              scheduleChatSearch("")
              redraw(kxi)

      # Every saved chat, searched by the backend (FR-078). Opening a match
      # shows the chat at once; its history and saved job load into it.
      renderChatSearchResults(
        appState,
        proc(chatId: string) =
          setActiveView(appState, viewChat)
          discard selectChat(appState, chatId)
      )

      if query.len == 0:
        tdiv(class = "empty-card"):
          text "Start typing to search saved chats and this chat's messages."
      else:
        h3(class = "chat-search-heading"):
          let openTitle = currentChatTitle()
          text (if openTitle.len > 0: "In this chat · " & openTitle else: "In this chat")
        if resultCount == 0:
          tdiv(class = "empty-card"):
            text "No messages in this chat match your search."
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
                    renderMarkedText(message.content, query)


proc renderActivityView(): VNode =
  result = buildHtml(
    section(class = "conversation")
  ):
    renderOperationsPanel(appState)
    tdiv(class = "developer-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "Current task"
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
      of "knowledge":
        text "❏"
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
          text "Search every saved chat"
        of "connections":
          text "Open models, harnesses, datasets and integrations"
        of "capabilities":
          text "Browse governed operations by specialist"
        of "review":
          text "Decide on critiques and corrections"
        of "knowledge":
          text "Search your reference datasets with citations"
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
            if command.reviewerOnly and not isReviewer(appState): continue
            if appState.commandQuery.toLowerAscii() in command.label.toLowerAscii():
              renderWorkspaceCommand(command)

      tdiv(class = "command-center-section"):
        tdiv(class = "command-section-heading"):
          strong:
            text "Saved chats"
        renderChatList(appState.commandQuery)


proc renderWorkspaceHelp(): VNode =
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "workspace-help"):
      h2: text "Working with " & productName
      p: text "Choose a local model or an outbound connection in Connections. Add reference datasets there, then use Knowledge to inspect cited passages. Chat uses the available tools and asks for approval when an action needs it."
      h3: text "Keyboard shortcuts"
      dl:
        for command in workspaceCommands:
          if command.shortcut.len > 0 and (not command.reviewerOnly or isReviewer(appState)):
            dt: text command.label
            dd:
              kbd: text command.shortcut
        dt: text "Commands"
        dd:
          kbd: text "Ctrl/⌘ K"
        dt: text "Close menu or commands"
        dd:
          kbd: text "Escape"
      p: text "Menus support arrow keys, Enter and Escape. Sending a request or receiving a progress update does not confirm that an external task finished; check its saved result and any delivery status."
      button(class = "secondary-action"):
        text "Back to workspace"
        proc onclick(event: Event, node: VNode) =
          runWorkspaceCommand("dismiss")

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
    renderWorkflowPanel(appState)
  of viewSimulator:
    renderEngineeringPanel(appState)
  of viewAccount:
    renderAccountView(appState)
  of viewCapabilities:
    renderCapabilitiesView(appState)
  of viewReview:
    renderReviewPanel(appState)
  of viewKnowledge:
    renderKnowledgePanel(appState)
  of viewLearning:
    renderLearningPanel(appState)
  of viewHelp:
    renderWorkspaceHelp()


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
    main(class = "workspace", `data-chat-id` = cstring(appState.currentChatId))
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
              openOperations(appState)

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
  let wasWorkspaceMenu = openWorkspaceMenu
  let wasHelp = appState.activeView == viewHelp
  openWorkspaceMenu = ""
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
    elif wasWorkspaceMenu.len > 0:
      pendingMenuFocus = "menu" & wasWorkspaceMenu
    elif wasHelp:
      setActiveView(appState, workspaceHelpPreviousView)
      pendingMenuFocus = "menuHelp"
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
  of "account":
    setActiveView(appState, viewAccount)
    discard loadAuthSessions(appState)
  of "capabilities":
    setActiveView(appState, viewCapabilities)
    discard refreshExtensions(appState)
  of "operations": openOperations(appState)
  of "review": openReview(appState)
  of "knowledge": openKnowledge(appState)
  of "learning": openLearning(appState)
  of "automation": openWorkflows(appState)
  of "engineering": openEngineering(appState)
  of "pcb": openEngineering(appState, "pcb")
  of "help":
    if not wasHelp: workspaceHelpPreviousView = appState.activeView
    setActiveView(appState, viewHelp)
  of "system":
    setActiveView(appState, viewSystem)
    discard refreshSystemStatus(appState)
  of "inspector": appState.inspectorOpen = not appState.inspectorOpen
  of "refresh": discard refreshSystemStatus(appState)
  of "compose":
    setActiveView(appState, viewChat)
    queueWorkspaceFocus("messageInput")
  else: discard
  redraw(kxi)



proc installWorkspaceKeys(handler: proc(key: cstring, modifier, shift, composing, repeated, alt: bool): bool) {.importjs: "document.addEventListener('keydown', e => { if (!e.defaultPrevented && #(e.key, e.ctrlKey || e.metaKey, e.shiftKey, e.isComposing, e.repeat, e.altKey)) e.preventDefault(); })".}

proc renderApp(): VNode =
  if workspaceMenuOwner != appState.auth.userId or workspaceMenuSession != appState.auth.sessionId:
    openWorkspaceMenu = ""
    workspaceHelpPreviousView = viewChat
    pendingMenuFocus = ""
    workspaceMenuOwner = appState.auth.userId
    workspaceMenuSession = appState.auth.sessionId
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
    renderWorkspaceMenubar(openWorkspaceMenu,
      proc(menu: string) =
        openWorkspaceMenu = (if openWorkspaceMenu == menu: "" else: menu)
        appState.headerMenuOpen = false
        redraw(kxi),
      proc(action: string) = runWorkspaceCommand(action))

    renderSidebar(
      appState
    )

    renderWorkspace()

    if appState.inspectorOpen:
      renderInspector(
        appState
      )

    renderStatusbar(
      appState,
      proc(view: AppView) =
        if view == viewJobs: openOperations(appState)
        else: setActiveView(appState, view)
        redraw(kxi),
      proc() =
        runWorkspaceCommand("inspector")
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

# Re-read public service health on the configured cadence, so the status bar
# follows an outage or recovery without a reload. One read at a time.
# While a candidate run trains, its progress is re-read on the same cadence.
if frontendConfig.healthIntervalMs > 0:
  discard setInterval(
    proc() =
      if appState.auth.authenticated and not appState.system.checking:
        discard refreshServiceHealth(appState)
      if appState.auth.authenticated and appState.activeView == viewLearning and
          (learningRunActive(appState) or learningStartPending(appState)):
        discard refreshLearningRuns(appState),
    frontendConfig.healthIntervalMs
  )

installMenuInteractions(proc(focusId: cstring) =
  if openWorkspaceMenu.len > 0:
    openWorkspaceMenu = ""
    pendingMenuFocus = $focusId
    redraw(kxi)
)

installWorkspaceKeys(proc(key: cstring, modifier, shift, composing, repeated, alt: bool): bool =
  if not appState.auth.authenticated: return false
  let action = shortcutAction($key, modifier, shift, composing, repeated, alt)
  if action.len == 0: return false
  runWorkspaceCommand(action)
  return true
)
