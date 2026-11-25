include karax/prelude
import std/[asyncjs, json, strutils, unicode]
import karax/kdom
import ../api/auth_client
import types, state, request_context

proc clearChatMetadata*(state: AppState) =
  inc state.chatMetadataEpoch
  state.chatFilter = ""
  state.chatRenameId = ""
  state.chatRenameDraft = ""
  state.chatActionId = ""
  state.chatActionError = ""
  state.chatsRefreshing = false
  state.chatsNeedRefresh = false
  state.chatsNextCursor = ""
  state.chatsPageQuery = ""
  state.chatsPageLoading = false
  state.chatsPageFailed = false

proc cancelChatMetadataRead*(state: AppState) =
  ## A list fetched before create/delete may not overwrite its new identity set.
  if state.chatsRefreshing or state.chatsPageLoading:
    inc state.chatMetadataEpoch
    state.chatsRefreshing = false
    state.chatsPageLoading = false

proc keepOpenChat(state: AppState, previous: seq[ChatItem]) =
  ## The open chat stays listed even when it lies beyond the loaded pages, so its row and title remain.
  if state.currentChatId.len == 0: return
  for chat in state.chats:
    if chat.chatId == state.currentChatId: return
  for chat in previous:
    if chat.chatId == state.currentChatId:
      state.chats.add(chat)
      return

proc refreshChatMetadata*(state: AppState) {.async.} =
  ## Reads the first page again (pinned, then newest) under the current filter; later pages load on scroll.
  if not state.auth.authenticated or state.chatsRefreshing or state.chatActionId.len > 0: return
  let context = accountContext(state)
  inc state.chatMetadataEpoch
  let epoch = state.chatMetadataEpoch
  let query = state.chatFilter.strip()
  state.chatsRefreshing = true
  state.chatsPageLoading = false
  redraw(kxi)
  try:
    let page = await listChatPage(query = query)
    if not matchesAccount(state, context) or state.chatMetadataEpoch != epoch: return
    let previous = state.chats
    state.chats = page.chats
    state.chatsNextCursor = page.nextCursor
    state.chatsPageQuery = query
    state.chatsPageFailed = false
    keepOpenChat(state, previous)
    state.chatsNeedRefresh = false
    state.chatActionError = ""
  except CatchableError:
    if matchesAccount(state, context) and state.chatMetadataEpoch == epoch:
      state.chatActionError = "Could not refresh chats. Your saved choices have not been confirmed."
  finally:
    if matchesAccount(state, context) and state.chatMetadataEpoch == epoch:
      state.chatsRefreshing = false
  redraw(kxi)

proc loadMoreChats*(state: AppState) {.async.} =
  ## The next page of history, when the list is scrolled near its end. One page at a time; a failed page
  ## says so and is tried again only when asked, never in a loop. While a new filter is pending, the old
  ## list's pages are not read: the filter's own first page replaces the list.
  if not state.auth.authenticated or state.chatsNextCursor.len == 0 or state.chatsPageLoading or
      state.chatsRefreshing or state.chatActionId.len > 0 or state.chatsPageFailed or
      state.chatFilter.strip() != state.chatsPageQuery: return
  let context = accountContext(state)
  let epoch = state.chatMetadataEpoch
  let cursor = state.chatsNextCursor
  let query = state.chatsPageQuery
  state.chatsPageLoading = true
  redraw(kxi)
  try:
    let page = await listChatPage(cursor = cursor, query = query)
    if not matchesAccount(state, context) or state.chatMetadataEpoch != epoch or
        state.chatsNextCursor != cursor: return
    state.chats = appendChatPage(state.chats, page.chats)
    state.chatsNextCursor = page.nextCursor
  except CatchableError:
    if matchesAccount(state, context) and state.chatMetadataEpoch == epoch:
      state.chatsPageFailed = true
  finally:
    if matchesAccount(state, context) and state.chatMetadataEpoch == epoch:
      state.chatsPageLoading = false
  redraw(kxi)

proc retryChatPage*(state: AppState) {.async.} =
  state.chatsPageFailed = false
  await loadMoreChats(state)

var filterTimer: TimeOut

proc scheduleChatFilter*(state: AppState) =
  ## "Find a chat" searches every chat on the server: the settled filter reads its first page again.
  if filterTimer != nil:
    clearTimeout(filterTimer)
    filterTimer = nil
  filterTimer = setTimeout(proc() =
    filterTimer = nil
    if state.chatFilter.strip() != state.chatsPageQuery:
      if state.chatsRefreshing: cancelChatMetadataRead(state)
      discard refreshChatMetadata(state), 250)

proc changeChatMetadata(state: AppState, chatId: string, patch: JsonNode) {.async.} =
  if not state.auth.authenticated or chatId.len == 0 or state.chatActionId.len > 0 or
      state.chatsRefreshing or state.chatsNeedRefresh: return
  var owned = false
  for chat in state.chats:
    if chat.chatId == chatId: owned = true
  if not owned: return
  let context = accountContext(state)
  inc state.chatMetadataEpoch
  let epoch = state.chatMetadataEpoch
  state.chatActionId = chatId
  state.chatActionError = ""
  redraw(kxi)
  try:
    let saved = await updateChat(chatId, patch, state.auth.csrfToken)
    if not matchesAccount(state, context) or state.chatMetadataEpoch != epoch: return
    for chat in state.chats.mitems:
      if chat.chatId == saved.chatId: chat = saved
    if state.chatRenameId == chatId:
      state.chatRenameId = ""
      state.chatRenameDraft = ""
    showToast(state, "Chat updated.")
  except CatchableError:
    if matchesAccount(state, context) and state.chatMetadataEpoch == epoch:
      # A missing/malformed acknowledgement cannot establish whether PATCH was
      # applied. Require an authoritative read before any second metadata write.
      state.chatsNeedRefresh = true
      state.chatActionError = "The chat change is not confirmed. Refresh chats to check the saved state before trying again."
  finally:
    if matchesAccount(state, context) and state.chatMetadataEpoch == epoch:
      state.chatActionId = ""
  redraw(kxi)

proc renameChatApplication*(state: AppState, chatId: string) {.async.} =
  let title = state.chatRenameDraft.strip()
  if title.len == 0 or title.runeLen > 160:
    state.chatActionError = "Use a chat title of 1 to 160 characters."
    redraw(kxi)
    return
  await changeChatMetadata(state, chatId, %*{"title": title})

proc pinChatApplication*(state: AppState, chat: ChatItem) {.async.} =
  await changeChatMetadata(state, chat.chatId, %*{"pinned": not chat.pinned})
