import std/[strutils, unicode]
include karax/prelude
import karax/kdom
import ../app/[types, state, extension_bridge, auth_bridge, chat_bridge, account_bridge,
  operations_bridge, review_bridge, request_context, engineering_bridge, backend_bridge,
  knowledge_bridge, learning_bridge, workflow_bridge]
import icons
import gladiators
import settings

proc currentCalendarDay(): cstring {.importjs: "(() => {const d = new Date(); return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');})()".}
proc eventKey(event: Event): cstring {.importjs: "#.key".}
proc composingOrRepeated(event: Event): bool {.importjs: "((event) => Boolean(event.isComposing || event.repeat || event.keyCode === 229))(#)".}
proc focusRename() {.importjs: "requestAnimationFrame(() => document.querySelector('.chat-rename-input')?.focus())".}

proc focusById(id: cstring) {.importjs: "document.getElementById(#)?.focus()".}

proc placeDashboardMenu() {.importjs: """(() => {
  const button = document.getElementById('dashboardAdd');
  const menu = document.getElementById('dashboardMenu');
  const side = button && button.closest('.sidebar');
  if (!button || !menu || !side) return;
  // Just past the sidebar, top-aligned with the "+" row, moved up only as far as needed to stay on
  // screen, and left only as far as needed on a narrow window.
  const box = button.getBoundingClientRect();
  const margin = 8;
  const left = Math.min(side.getBoundingClientRect().right + margin, innerWidth - menu.offsetWidth - margin);
  menu.style.left = Math.max(margin, left) + 'px';
  menu.style.top = Math.max(margin, Math.min(box.top, innerHeight - menu.offsetHeight - margin)) + 'px';
})()""".}

var pendingDashboardFocus = ""

proc afterSidebarRender*(state: AppState) =
  ## Run after Karax commits the DOM, so the elements exist.
  if state.dashboardsOpen: placeDashboardMenu()
  if pendingDashboardFocus.len > 0:
    focusById(cstring(pendingDashboardFocus))
    pendingDashboardFocus = ""
proc installDashboardDismiss(close: proc(focusPlus: bool)) {.importjs: """((close) => {
  document.addEventListener('pointerdown', e => {
    if (!e.target.closest('.dashboard-menu, .dashboard-add')) close(false);
  });
})(#)""".}

proc renderViewButton(state: AppState, iconName, label: string, target: AppView): VNode =
  ## A named place: its icon and its name side by side (ChatGPT, Hermes); collapsed, the icon alone,
  ## named on hover and for assistive technology.
  result = buildHtml(button(
      class = (if state.activeView == target: cstring"nav-item active" else: cstring"nav-item"),
      title = cstring(label),
      `aria-label` = cstring(label),
      `aria-current` = (if state.activeView == target: cstring"page" else: cstring"false"))):
    span(class = "nav-icon", `aria-hidden` = "true"): icon(iconName, 18)
    span(class = "nav-label"): text label
    proc onclick(event: Event, node: VNode) =
      state.dashboardsOpen = false
      setActiveView(state, target)
      if target in [viewPlugin, viewStore]:
        discard refreshExtensions(state)
      elif target == viewReview: discard refreshReview(state)
      elif target == viewSettings:
        openSettingsSection(state, state.settingsSection)

proc dashboardView(dashboard: Dashboard): AppView =
  case dashboard
  of dashAutomation: viewNodeBuilder
  of dashTopology: viewSimulator
  of dashKnowledge: viewKnowledge
  of dashOperations: viewJobs
  of dashLearning: viewLearning

proc openDashboard*(state: AppState, dashboard: Dashboard) =
  ## Opens a dashboard with the reads it needs, whether it is pinned or not.
  state.dashboardsOpen = false
  case dashboard
  of dashAutomation: openWorkflows(state)
  of dashTopology: openEngineering(state)
  of dashKnowledge: openKnowledge(state)
  of dashOperations: openOperations(state)
  of dashLearning: openLearning(state)

proc dashboardActive(state: AppState, dashboard: Dashboard): bool =
  let view = dashboardView(dashboard)
  state.activeView == view or (view == viewJobs and state.activeView in [viewRuns, viewLogs])

proc renderPinnedButton(state: AppState, dashboard: Dashboard): VNode =
  ## A pinned dashboard on the rail; its own proc so the click keeps its dashboard.
  let active = dashboardActive(state, dashboard)
  result = buildHtml(button(class = (if active: cstring"nav-item active" else: cstring"nav-item"),
      title = cstring(dashboardLabel(dashboard)), `aria-label` = cstring(dashboardLabel(dashboard)),
      `aria-current` = (if active: cstring"page" else: cstring"false"))):
    span(class = "nav-icon", `aria-hidden` = "true"): icon(dashboardIcon(dashboard), 18)
    span(class = "nav-label"): text dashboardLabel(dashboard)
    proc onclick(event: Event, node: VNode) = openDashboard(state, dashboard)

proc renderDashboardRow(state: AppState, dashboard: Dashboard): VNode =
  ## One dashboard in the "+" list: open it, or pin it to the rail.
  let pinned = dashboard in state.pinnedViews
  let label = dashboardLabel(dashboard)
  result = buildHtml(li(class = "dashboard-row")):
    button(id = cstring("dashboardOpen" & dashboardValue(dashboard)), class = "dashboard-open"):
      span(class = "nav-icon", `aria-hidden` = "true"): icon(dashboardIcon(dashboard), 18)
      span(class = "dashboard-name"): text label
      proc onclick(event: Event, node: VNode) = openDashboard(state, dashboard)
    button(class = (if pinned: cstring"dashboard-pin pinned" else: cstring"dashboard-pin"),
           `aria-label` = cstring((if pinned: "Unpin " else: "Pin ") & label),
           `aria-pressed` = (if pinned: cstring"true" else: cstring"false"),
           title = cstring(if pinned: "Unpin from the sidebar" else: "Pin to the sidebar"),
           disabled = not canChangePins(state)):
      icon(if pinned: "unpin" else: "pin", 14)
      proc onclick(event: Event, node: VNode) = discard togglePinnedDashboard(state, dashboard)

proc renderDashboardMenu(state: AppState): VNode =
  result = buildHtml(tdiv(class = "dashboard-menu", role = "dialog", `aria-label` = "Dashboards",
                          id = "dashboardMenu")):
    strong(class = "dashboard-menu-title"): text "Dashboards"
    p(class = "dashboard-menu-note"): text "Open one, or pin it to keep it in the sidebar."
    if not state.pinsKnown and state.preferencesLoaded:
      p(class = "dashboard-menu-error", role = "alert"):
        text "Your pinned dashboards could not be loaded. Open any dashboard from here."
    elif state.pinError.len > 0:
      p(class = "dashboard-menu-error", role = "alert"): text state.pinError
    ul(class = "dashboard-list"):
      for dashboard in Dashboard:
        renderDashboardRow(state, dashboard)
    proc onkeydown(event: Event, node: VNode) =
      if eventKey(event) == "Escape":
        event.preventDefault()
        state.dashboardsOpen = false
        pendingDashboardFocus = "dashboardAdd"

proc renderDashboardAdd(state: AppState): VNode =
  ## "+" on the Dashboards heading (Hermes, ChatGPT "Projects"); collapsed, the last icon of the rail.
  result = buildHtml(button(id = "dashboardAdd", class = (if state.dashboardsOpen: cstring"nav-item dashboard-add active"
                                                          else: cstring"nav-item dashboard-add"),
      title = "Add a dashboard", `aria-label` = "Add a dashboard", `aria-haspopup` = "dialog",
      `aria-controls` = "dashboardMenu", `aria-expanded` = (if state.dashboardsOpen: cstring"true" else: cstring"false"))):
    span(class = "nav-icon", `aria-hidden` = "true"): icon("plus", 16)
    proc onclick(event: Event, node: VNode) =
      state.dashboardsOpen = not state.dashboardsOpen
      if state.dashboardsOpen:
        state.pinError = ""
        pendingDashboardFocus = "dashboardOpen" & dashboardValue(low(Dashboard))

var dashboardDismissInstalled = false

proc installDashboardMenu*(state: AppState) =
  ## A click outside the dashboard list closes it, once per page.
  if dashboardDismissInstalled: return
  dashboardDismissInstalled = true
  installDashboardDismiss(proc(focusPlus: bool) =
    if state.dashboardsOpen:
      state.dashboardsOpen = false
      redraw(kxi))

proc renderSavedChat(state: AppState, chat: ChatItem): VNode =
  # Each invocation captures one immutable identity, including all row actions.
  let disabled = state.chatActionId.len > 0 or state.chatsRefreshing or state.chatsNeedRefresh
  # A chat with a request still running in it shows a small marker, so the
  # user can open other chats while it works.
  result = buildHtml(tdiv(class = (if chat.working: cstring"chat-nav-row working" else: cstring"chat-nav-row"))):
    let isOpen = chat.chatId == state.currentChatId
    button(class = (if isOpen and state.activeView == viewChat: cstring"chat-nav-main active"
      elif isOpen: cstring"chat-nav-main active background" else: cstring"chat-nav-main"),
      title = cstring(chat.title & (if chat.working: " · Working" else: "")),
      `aria-current` = (if isOpen and state.activeView == viewChat: cstring"page"
        elif isOpen: cstring"true" else: cstring"false")):
      span(class = "chat-nav-title"): text chat.title
      if chat.working:
        span(class = "chat-working-dot", `aria-label` = "Working", role = "img")
      proc onclick(event: Event, node: VNode) =
        state.commandPaletteOpen = false
        discard selectChat(state, chat.chatId)
    if state.chatRenameId == chat.chatId:
      tdiv(class = "chat-rename"):
        input(class = "chat-rename-input", `aria-label` = "Chat title", value = state.chatRenameDraft,
          disabled = disabled):
          proc oninput(event: Event, node: VNode) = state.chatRenameDraft = $node.getInputText
          proc onkeydown(event: Event, node: VNode) =
            if eventKey(event) == "Escape":
              event.preventDefault()
              state.chatRenameId = ""
              redraw(kxi)
            elif eventKey(event) == "Enter" and not composingOrRepeated(event):
              event.preventDefault()
              discard renameChatApplication(state, chat.chatId)
        button(class = "chat-rename-save", disabled = disabled):
          text "Save"
          proc onclick(event: Event, node: VNode) = discard renameChatApplication(state, chat.chatId)
        button(disabled = state.chatActionId.len > 0):
          text "Cancel"
          proc onclick(event: Event, node: VNode) =
            state.chatRenameId = ""
            redraw(kxi)
    elif state.pendingDeleteChatId == chat.chatId:
      tdiv(class = "chat-delete-confirm"):
        button(class = "chat-delete-confirm-yes", title = "Delete chat"):
          text "Delete"
          proc onclick(event: Event, node: VNode) =
            state.pendingDeleteChatId = ""
            discard deleteChatApplication(state, chat.chatId)
        button(class = "chat-delete-confirm-no", title = "Cancel"):
          text "Cancel"
          proc onclick(event: Event, node: VNode) =
            state.pendingDeleteChatId = ""
            redraw(kxi)
    else:
      tdiv(class = "chat-row-actions"):
        button(class = "chat-pin", title = (if chat.pinned: cstring"Unpin chat" else: cstring"Pin chat"),
          `aria-label` = cstring((if chat.pinned: "Unpin chat " else: "Pin chat ") & chat.title),
          disabled = disabled):
          icon(if chat.pinned: "unpin" else: "pin", 14)
          proc onclick(event: Event, node: VNode) = discard pinChatApplication(state, chat)
        button(class = "chat-rename-open", title = "Rename chat", `aria-label` = cstring("Rename chat " & chat.title),
          disabled = disabled):
          icon("rename", 14)
          proc onclick(event: Event, node: VNode) =
            state.chatRenameId = chat.chatId
            state.chatRenameDraft = chat.title
            state.pendingDeleteChatId = ""
            redraw(kxi)
            focusRename()
        button(class = "chat-delete", title = "Delete chat", `aria-label` = cstring("Delete chat " & chat.title)):
          icon("close", 14)
          proc onclick(event: Event, node: VNode) =
            state.pendingDeleteChatId = chat.chatId
            state.chatRenameId = ""
            redraw(kxi)

proc renderSidebar*(state: AppState, newChatKeys: string): VNode =
  ## One labelled sidebar (owner decision of 19 November, after Hermes and ChatGPT): the places with
  ## their names, the pinned dashboards with "+", the chats by day, the agents' room, and the account
  ## pinned at the bottom. The middle scrolls as one when the window is short; the chat list scrolls
  ## on its own when there is room. Collapsed (the owner's saved choice) or on a phone it narrows to
  ## the icons alone.
  let collapsed = state.sidebarCollapsed
  result = buildHtml(aside(class = (if collapsed: cstring"sidebar collapsed" else: cstring"sidebar"),
                           `aria-label` = "Workspace navigation")):
    tdiv(class = "sidebar-body"):
      nav(class = "sidebar-nav", `aria-label` = "Workspace"):
        button(class = "nav-item new-session", title = cstring("New chat (" & newChatKeys & ")"),
               `aria-label` = "New chat", `aria-keyshortcuts` = cstring(newChatKeys.replace("Ctrl", "Control"))):
          span(class = "nav-icon", `aria-hidden` = "true"): icon("new-chat", 18)
          span(class = "nav-label"): text "New chat"
          kbd(class = "nav-shortcut", `aria-hidden` = "true"): text newChatKeys
          proc onclick(event: Event, node: VNode) =
            state.commandPaletteOpen = false
            discard createNewChat(state)
        # The core places are always here; dashboards are pinned from "+".
        renderViewButton(state, "search", "Search", viewSearch)
        renderViewButton(state, "model-store", "Model Store", viewPlugin)
        renderViewButton(state, "store", "Store", viewStore)
        if isReviewer(state): renderViewButton(state, "review", "Review", viewReview)
        renderViewButton(state, "settings", "Settings", viewSettings)
      tdiv(class = "dashboard-nav", role = "group", `aria-labelledby` = "dashboardNavLabel"):
        tdiv(class = "dashboard-nav-header"):
          span(id = "dashboardNavLabel", class = "sidebar-section-label"): text "Dashboards"
          renderDashboardAdd(state)
        for dashboard in state.pinnedViews:
          renderPinnedButton(state, dashboard)
      if state.dashboardsOpen:
        renderDashboardMenu(state)
      tdiv(class = "sidebar-chats"):
        tdiv(class = "chat-filter"):
          input(`type` = "search", `aria-label` = "Filter recent chats", placeholder = "Find a chat…",
            value = state.chatFilter):
            proc oninput(event: Event, node: VNode) =
              state.chatFilter = $node.getInputText
              redraw(kxi)
          button(class = "chat-refresh", title = "Refresh chats", `aria-label` = "Refresh chats",
            disabled = state.chatsRefreshing or state.chatActionId.len > 0):
            icon("refresh", 16, (if state.chatsRefreshing: "spinning" else: ""))
            proc onclick(event: Event, node: VNode) = discard refreshChatMetadata(state)
        if state.chatActionError.len > 0:
          p(class = "chat-metadata-error", role = "alert"): text state.chatActionError
        nav(class = "nav-section chat-nav-section", `aria-label` = "Recent chats"):
          let groups = groupChats(state.chats, $currentCalendarDay(), state.chatFilter)
          if groups.len == 0:
            span(class = "sidebar-empty"):
              text (if state.chatFilter.len > 0: "No matching chats" else: "No chats yet")
          for group in groups:
            tdiv(class = "chat-date-group"):
              span(class = "section-label"): text group.title
              for chat in group.chats: renderSavedChat(state, chat)
        # The agents' room (owner decision, 18 November): who is doing what, below the chats.
        if state.gladiators:
          renderRoomPreview(state)
    let ownerName = if state.auth.displayName.len > 0: state.auth.displayName else: state.auth.email
    button(class = "sidebar-footer", title = cstring("Settings · " & ownerName), `aria-label` = "Account settings"):
      tdiv(class = "avatar", `aria-hidden` = "true"):
        text (if state.auth.displayName.len > 0: $state.auth.displayName.runeAt(0).toUpper() else: "U")
      span(class = "sidebar-account"):
        strong(class = "nav-label"): text ownerName
        if state.auth.displayName.len > 0 and state.auth.email.len > 0:
          span(class = "sidebar-account-email"): text state.auth.email
      proc onclick(event: Event, node: VNode) =
        # The account row opens the owner's profile (ChatGPT, Hermes).
        openSettingsSection(state, settingsProfile)
