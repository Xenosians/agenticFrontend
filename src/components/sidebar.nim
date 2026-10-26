import std/strutils

include karax/prelude

import ../app/types
import ../app/state
import ../app/extension_bridge
import ../app/auth_bridge
import ../app/operations_bridge
import brand


proc viewNavClass(
  state: AppState,
  target: AppView
): cstring =

  if state.activeView == target:
    cstring"nav-item active"
  else:
    cstring"nav-item"


proc renderViewButton(
  state: AppState,
  icon: string,
  label: string,
  target: AppView,
  tail: string = ""
): VNode =

  result = buildHtml(
    button(
      class = viewNavClass(
        state,
        target
      ),
      `aria-current` = (if state.activeView == target: cstring"page" else: cstring"false")
    )
  ):

    span(class = "nav-icon", `aria-hidden` = "true"):
      text icon

    span:
      text label

    if tail.len > 0:
      span(class = "nav-preview"):
        text tail

    proc onclick(
      event: Event,
      node: VNode
    ) =
      setActiveView(
        state,
        target
      )
      if target in [viewPlugin, viewTool, viewCapabilities]:
        discard refreshExtensions(state)
      elif target == viewJobs:
        discard refreshOperations(state)


proc renderSavedChat(state: AppState, chat: ChatItem): VNode =
  # Each call owns the target captured by its open/delete handlers. A local
  # declared inside a rendering loop shares one closure in Nim's JS backend.
  result = buildHtml(tdiv(class = "chat-nav-row")):
    # The open chat is the page in view only in the chat view; elsewhere it
    # stays marked as the current chat without competing with the page.
    let isOpen = chat.chatId == state.currentChatId
    button(
      class =
        if isOpen and state.activeView == viewChat:
          cstring"chat-nav-main active"
        elif isOpen:
          cstring"chat-nav-main active background"
        else:
          cstring"chat-nav-main",
      `aria-current` =
        if isOpen and state.activeView == viewChat: cstring"page"
        elif isOpen: cstring"true"
        else: cstring"false"
    ):
      span(class = "nav-icon", `aria-hidden` = "true"):
        text "◇"
      span(class = "chat-nav-title"):
        text chat.title
      proc onclick(event: Event, node: VNode) =
        state.commandPaletteOpen = false
        discard selectChat(state, chat.chatId)

    if state.pendingDeleteChatId == chat.chatId:
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
      button(class = "chat-delete", title = "Delete chat",
             `aria-label` = cstring("Delete chat " & chat.title)):
        text "×"
        proc onclick(event: Event, node: VNode) =
          state.pendingDeleteChatId = chat.chatId
          redraw(kxi)


proc renderSidebar*(
  state: AppState
): VNode =

  result = buildHtml(
    aside(class = "sidebar")
  ):

    tdiv(class = "brand"):
      img(
        class = "brand-logo",
        src = productMark,
        alt = productName
      )

      tdiv(class = "brand-copy"):
        strong:
          text productName
        span:
          text productTagline


    button(class = "new-session"):
      span:
        text "+"
      text "New chat"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        state.commandPaletteOpen = false
        discard createNewChat(
          state
        )


    nav(class = "nav-section chat-nav-section"):
      span(class = "section-label"):
        text "Chats"

      if state.chats.len == 0:
        span(class = "sidebar-empty"):
          text "No chats"
      else:
        for chat in state.chats:
          renderSavedChat(state, chat)


    nav(class = "nav-section"):
      span(class = "section-label"):
        text "Workspace"

      renderViewButton(
        state,
        "◈",
        "Chat",
        viewChat
      )

      renderViewButton(
        state,
        "⌕",
        "Search",
        viewSearch
      )

      renderViewButton(
        state,
        "◇",
        "Connections",
        viewPlugin
      )

      renderViewButton(
        state,
        "▤",
        "Capabilities",
        viewCapabilities
      )

      renderViewButton(
        state,
        "◌",
        "Operations",
        viewJobs
      )

      renderViewButton(
        state,
        "⚙",
        "System",
        viewSystem
      )


    nav(class = "nav-section"):
      span(class = "section-label"):
        text "Labs"

      renderViewButton(
        state,
        "⌘",
        "AI Node Builder",
        viewNodeBuilder,
        "Preview"
      )

      renderViewButton(
        state,
        "▦",
        "PCB / Infra Simulator",
        viewSimulator,
        "Preview"
      )


    button(class = "sidebar-footer"):
      tdiv(class = "avatar"):
        text (
          if state.auth.displayName.len > 0:
            state.auth.displayName[0 .. 0].toUpperAscii()
          elif state.auth.email.len > 0:
            state.auth.email[0 .. 0].toUpperAscii()
          else:
            "U"
        )

      tdiv(class = "user-info"):
        strong:
          text (
            if state.auth.displayName.len > 0:
              state.auth.displayName
            else:
              state.auth.email
          )

        span:
          text (
            if state.auth.role.len > 0:
              state.auth.role
            else:
              "authenticated"
          )

      span(class = "nav-tail", `aria-hidden` = "true"):
        text "›"

      proc onclick(
        event: Event,
        node: VNode
      ) =
        setActiveView(
          state,
          viewAccount
        )

        discard loadAuthSessions(
          state
        )
