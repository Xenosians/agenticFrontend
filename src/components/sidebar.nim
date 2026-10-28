import std/[strutils, unicode]
include karax/prelude
import karax/kdom
import ../app/[types, state, extension_bridge, auth_bridge, chat_bridge,
  operations_bridge, review_bridge, request_context]
import brand

proc currentCalendarDay(): cstring {.importjs: "(() => {const d = new Date(); return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');})()".}
proc eventKey(event: Event): cstring {.importjs: "#.key".}
proc composingOrRepeated(event: Event): bool {.importjs: "((event) => Boolean(event.isComposing || event.repeat || event.keyCode === 229))(#)".}
proc focusRename() {.importjs: "requestAnimationFrame(() => document.querySelector('.chat-rename-input')?.focus())".}

proc renderViewButton(state: AppState, icon, label: string, target: AppView,
    preview = false): VNode =
  result = buildHtml(button(
      class = (if state.activeView == target: cstring"nav-item active" else: cstring"nav-item"),
      title = cstring(label & (if preview: " · Design preview" else: "")),
      `aria-label` = cstring(label),
      `aria-current` = (if state.activeView == target: cstring"page" else: cstring"false"))):
    span(class = "nav-icon", `aria-hidden` = "true"): text icon
    span(class = "rail-label"): text label
    proc onclick(event: Event, node: VNode) =
      setActiveView(state, target)
      if target in [viewPlugin, viewTool, viewCapabilities, viewKnowledge]:
        discard refreshExtensions(state)
      elif target == viewJobs: discard refreshOperations(state)
      elif target == viewReview: discard refreshReview(state)

proc renderSavedChat(state: AppState, chat: ChatItem): VNode =
  # Each invocation captures one immutable identity, including all row actions.
  let disabled = state.chatActionId.len > 0 or state.chatsRefreshing or state.chatsNeedRefresh
  result = buildHtml(tdiv(class = "chat-nav-row")):
    let isOpen = chat.chatId == state.currentChatId
    button(class = (if isOpen and state.activeView == viewChat: cstring"chat-nav-main active"
      elif isOpen: cstring"chat-nav-main active background" else: cstring"chat-nav-main"),
      title = cstring(chat.title),
      `aria-current` = (if isOpen and state.activeView == viewChat: cstring"page"
        elif isOpen: cstring"true" else: cstring"false")):
      span(class = "chat-nav-title"): text chat.title
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
          text (if chat.pinned: "◆" else: "◇")
          proc onclick(event: Event, node: VNode) = discard pinChatApplication(state, chat)
        button(class = "chat-rename-open", title = "Rename chat", `aria-label` = cstring("Rename chat " & chat.title),
          disabled = disabled):
          text "✎"
          proc onclick(event: Event, node: VNode) =
            state.chatRenameId = chat.chatId
            state.chatRenameDraft = chat.title
            state.pendingDeleteChatId = ""
            redraw(kxi)
            focusRename()
        button(class = "chat-delete", title = "Delete chat", `aria-label` = cstring("Delete chat " & chat.title)):
          text "×"
          proc onclick(event: Event, node: VNode) =
            state.pendingDeleteChatId = chat.chatId
            state.chatRenameId = ""
            redraw(kxi)

proc renderSidebar*(state: AppState): VNode =
  result = buildHtml(aside(class = "sidebar", `aria-label` = "Workspace navigation")):
    tdiv(class = "workspace-rail"):
      tdiv(class = "rail-brand"):
        img(class = "brand-logo", src = productMark, alt = productName)
      nav(class = "rail-navigation", `aria-label` = "Workspace"):
        renderViewButton(state, "◈", "Chat", viewChat)
        renderViewButton(state, "⌕", "Search", viewSearch)
        renderViewButton(state, "◇", "Connections", viewPlugin)
        renderViewButton(state, "▤", "Capabilities", viewCapabilities)
        renderViewButton(state, "❏", "Knowledge", viewKnowledge)
        renderViewButton(state, "◌", "Operations", viewJobs)
        if isReviewer(state): renderViewButton(state, "✓", "Review", viewReview)
        renderViewButton(state, "⚙", "System", viewSystem)
        span(class = "rail-divider", `aria-hidden` = "true")
        renderViewButton(state, "⌘", "AI Node Builder", viewNodeBuilder, true)
        renderViewButton(state, "▦", "PCB / Infra Simulator", viewSimulator, true)
      let ownerName = if state.auth.displayName.len > 0: state.auth.displayName else: state.auth.email
      button(class = "sidebar-footer", title = cstring("Account · " & ownerName), `aria-label` = "Account settings"):
        tdiv(class = "avatar"):
          text (if state.auth.displayName.len > 0: $state.auth.displayName.runeAt(0).toUpper() else: "U")
        span(class = "rail-label"): text ownerName
        proc onclick(event: Event, node: VNode) =
          setActiveView(state, viewAccount)
          discard loadAuthSessions(state)
    tdiv(class = "chats-sidebar"):
      tdiv(class = "chats-sidebar-heading"):
        strong: text productName
        button(class = "chat-refresh", title = "Refresh chats", `aria-label` = "Refresh chats",
          disabled = state.chatsRefreshing or state.chatActionId.len > 0):
          text (if state.chatsRefreshing: "…" else: "↻")
          proc onclick(event: Event, node: VNode) = discard refreshChatMetadata(state)
      button(class = "new-session"):
        span(`aria-hidden` = "true"): text "+"
        text "New chat"
        proc onclick(event: Event, node: VNode) =
          state.commandPaletteOpen = false
          discard createNewChat(state)
      tdiv(class = "chat-filter"):
        input(`type` = "search", `aria-label` = "Filter recent chats", placeholder = "Find a chat…",
          value = state.chatFilter):
          proc oninput(event: Event, node: VNode) =
            state.chatFilter = $node.getInputText
            redraw(kxi)
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
      tdiv(class = "chat-sidebar-footnote"):
        text "Your conversations"
