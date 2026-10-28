include karax/prelude
import std/[asyncjs, json, unicode]
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

proc cancelChatMetadataRead*(state: AppState) =
  ## A list fetched before create/delete may not overwrite its new identity set.
  if state.chatsRefreshing:
    inc state.chatMetadataEpoch
    state.chatsRefreshing = false

proc refreshChatMetadata*(state: AppState) {.async.} =
  if not state.auth.authenticated or state.chatsRefreshing or state.chatActionId.len > 0: return
  let context = accountContext(state)
  inc state.chatMetadataEpoch
  let epoch = state.chatMetadataEpoch
  state.chatsRefreshing = true
  redraw(kxi)
  try:
    let chats = await listChats()
    if not matchesAccount(state, context) or state.chatMetadataEpoch != epoch: return
    state.chats = chats
    state.chatsNeedRefresh = false
    state.chatActionError = ""
  except CatchableError:
    if matchesAccount(state, context) and state.chatMetadataEpoch == epoch:
      state.chatActionError = "Could not refresh chats. Your saved choices have not been confirmed."
  finally:
    if matchesAccount(state, context) and state.chatMetadataEpoch == epoch:
      state.chatsRefreshing = false
  redraw(kxi)

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
