## Search across saved chats (FR-078), Hermes-style.
##
## The backend searches every saved conversation this account owns; this
## component debounces the query, keeps only the newest answer, and lists the
## matches. Opening a match restores that chat through the normal history path,
## so its outstanding job and decision state come back with it.

import std/[asyncjs, strutils]

include karax/prelude
import karax/kdom

import ../api/auth_client
import ../app/types

type
  ChatSearchState = object
    query: string          # the settled query the results belong to
    results: seq[ChatSearchResult]
    pending, failed: bool
    epoch: int             # a newer keystroke makes older answers stale
    timer: TimeOut

# One debounce window, as Hermes uses for its server session search.
const searchDebounceMs = 200

var chatSearch: ChatSearchState


proc runSearch(query: string, epoch: int) {.async.} =
  try:
    let results = await searchChats(query)
    if epoch != chatSearch.epoch: return
    chatSearch.results = results
    chatSearch.failed = false
  except CatchableError:
    if epoch != chatSearch.epoch: return
    chatSearch.results.setLen(0)
    chatSearch.failed = true
  chatSearch.pending = false
  chatSearch.query = query
  redraw(kxi)


proc scheduleChatSearch*(rawQuery: string) =
  ## Called on every edit of the search box; only the settled query is sent.
  inc chatSearch.epoch
  let epoch = chatSearch.epoch
  if chatSearch.timer != nil:
    clearTimeout(chatSearch.timer)
    chatSearch.timer = nil
  let query = rawQuery.strip()
  if query.len == 0:
    chatSearch = ChatSearchState(epoch: epoch)
    return
  chatSearch.pending = true
  chatSearch.timer = setTimeout(proc() =
    chatSearch.timer = nil
    discard runSearch(query, epoch), searchDebounceMs)


proc renderChatSearchResults*(state: AppState, openChat: proc(chatId: string)): VNode =
  result = buildHtml(tdiv(class = "chat-search")):
    if chatSearch.query.len > 0 or chatSearch.pending:
      h3(class = "chat-search-heading"):
        text "Saved chats"
      if chatSearch.failed and not chatSearch.pending:
        p(class = "chat-search-status", role = "status"):
          text "Saved chats could not be searched. Try again."
      elif chatSearch.results.len == 0 and not chatSearch.pending:
        p(class = "chat-search-status", role = "status"):
          text "No saved chats match this search."
      else:
        for item in chatSearch.results:
          let chatId = item.chatId
          button(class = (if chatId == state.currentChatId: cstring"chat-search-result current"
                          else: cstring"chat-search-result")):
            strong:
              text (if item.title.len > 0: item.title else: "Untitled chat")
            span:
              text (if item.matched == "message" and item.excerpt.len > 0: item.excerpt
                    else: "Title matches")
            proc onclick(event: Event, node: VNode) =
              openChat(chatId)
