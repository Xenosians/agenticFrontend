## Saved-chat metadata is backend-owned. Legacy rows may omit pinned, but an
## invalid explicit value or receipt must never be presented as a saved choice.
import std/[json, strutils, times, algorithm]

type
  ChatItem* = object
    chatId*, title*, createdAt*, updatedAt*: string
    pinned*: bool
    ## A request in this chat is still queued, running or awaiting approval.
    working*: bool
  ChatGroup* = object
    title*: string
    chats*: seq[ChatItem]
  ## One page of the sidebar's chat history; an empty `nextCursor` means the list is complete.
  ChatPage* = object
    chats*: seq[ChatItem]
    nextCursor*: string

proc textField(node: JsonNode, key: string, required = false): string =
  if not node.hasKey(key):
    if required: raise newException(ValueError, "Backend chat response is invalid.")
    return ""
  if node[key].kind != JString:
    raise newException(ValueError, "Backend chat response is invalid.")
  result = node[key].getStr()
  if required and result.strip().len == 0:
    raise newException(ValueError, "Backend chat response is invalid.")

proc parseChat*(node: JsonNode): ChatItem =
  if node.kind != JObject:
    raise newException(ValueError, "Backend chat response is invalid.")
  result = ChatItem(chatId: textField(node, "chat_id", true),
    title: textField(node, "title", true), createdAt: textField(node, "created_at"),
    updatedAt: textField(node, "updated_at"))
  if node.hasKey("pinned"):
    if node["pinned"].kind != JBool:
      raise newException(ValueError, "Backend chat response is invalid.")
    result.pinned = node["pinned"].getBool()
  if node.hasKey("working"):
    if node["working"].kind != JBool:
      raise newException(ValueError, "Backend chat response is invalid.")
    result.working = node["working"].getBool()

proc parseChatList*(data: JsonNode): seq[ChatItem] =
  if data.kind != JObject or not data.hasKey("chats") or data["chats"].kind != JArray:
    raise newException(ValueError, "Backend chat list is invalid.")
  var ids: seq[string] = @[]
  for node in data["chats"]:
    let chat = parseChat(node)
    if chat.chatId in ids:
      raise newException(ValueError, "Backend chat list contains a duplicate identity.")
    ids.add(chat.chatId)
    result.add(chat)

proc parseChatPage*(data: JsonNode): ChatPage =
  ## A page must say where the next one starts (a cursor) or that there is none (null). A missing or
  ## malformed cursor is refused, so a broken answer is never read as the end of the history.
  if data.kind != JObject or not data.hasKey("next_cursor"):
    raise newException(ValueError, "Backend chat page is invalid.")
  let cursor = data["next_cursor"]
  if cursor.kind == JNull:
    result.nextCursor = ""
  elif cursor.kind == JString and cursor.getStr().len > 0:
    result.nextCursor = cursor.getStr()
  else:
    raise newException(ValueError, "Backend chat page is invalid.")
  result.chats = parseChatList(data)

proc appendChatPage*(loaded, page: seq[ChatItem]): seq[ChatItem] =
  ## A later page adds only chats not listed yet: a chat that moved between two reads keeps its first place.
  result = loaded
  for chat in page:
    var known = false
    for existing in result:
      if existing.chatId == chat.chatId:
        known = true
        break
    if not known: result.add(chat)

proc validateChatUpdate*(data: JsonNode, chatId: string, patch: JsonNode): ChatItem =
  if data.kind != JObject or not data.hasKey("chat") or data["chat"].kind != JObject or
      not data["chat"].hasKey("pinned"):
    raise newException(ValueError, "The saved chat change is not confirmed. Refresh chats before trying again.")
  result = parseChat(data["chat"])
  if result.chatId != chatId or
      (patch.hasKey("title") and result.title != patch["title"].getStr()) or
      (patch.hasKey("pinned") and result.pinned != patch["pinned"].getBool()):
    raise newException(ValueError, "The saved chat change is not confirmed. Refresh chats before trying again.")

when defined(js):
  proc localCalendarDate(timestamp: cstring): cstring {.importjs: "((value) => {const d = new Date(value); if(!Number.isFinite(d.getTime())) return ''; return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');})(#)".}

proc dateBucket*(timestamp, today: string): string =
  if timestamp.len < 10: return "Recent"
  try:
    var calendarDate = timestamp[0 .. 9]
    when defined(js):
      if timestamp.len > 10: calendarDate = $localCalendarDate(cstring(timestamp))
    let date = parse(calendarDate, "yyyy-MM-dd", utc())
    let current = parse(today, "yyyy-MM-dd", utc())
    let age = (current.toTime - date.toTime).inDays
    if age <= 0: "Today"
    elif age == 1: "Yesterday"
    elif age < 7: "Previous 7 days"
    elif age < 30: "Previous 30 days"
    else: date.format("MMMM yyyy")
  except CatchableError:
    "Recent"

proc groupChats*(chats: seq[ChatItem], today: string, query = ""): seq[ChatGroup] =
  var sorted = chats
  sorted.sort(proc(a, b: ChatItem): int =
    if a.pinned != b.pinned: cmp(b.pinned, a.pinned)
    else: cmp(b.updatedAt, a.updatedAt))
  for chat in sorted:
    if query.strip().toLowerAscii() notin chat.title.toLowerAscii(): continue
    let caption = if chat.pinned: "Pinned" else: dateBucket(chat.updatedAt, today)
    var found = false
    for group in result.mitems:
      if group.title == caption:
        group.chats.add(chat)
        found = true
        break
    if not found: result.add(ChatGroup(title: caption, chats: @[chat]))
