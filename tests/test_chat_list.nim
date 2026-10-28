import std/[json, unittest]
import ../src/app/chat_list

suite "saved chat metadata":
  test "legacy pin omission is false, explicit malformed metadata is rejected":
    check not parseChat(%*{"chat_id": "a", "title": "First"}).pinned
    for node in [%*{"chat_id": "a", "title": "First", "pinned": "false"},
                 %*{"chat_id": "", "title": "First"}, %*{"chat_id": "a", "title": 3}]:
      expect ValueError: discard parseChat(node)
  test "malformed lists and duplicate identities do not become an empty list":
    for node in [%*{}, %*{"chats": nil},
                 %*{"chats": [{"chat_id": "a", "title": "First"}, {"chat_id": "a", "title": "Second"}]}]:
      expect ValueError: discard parseChatList(node)
    check parseChatList(%*{"chats": []}).len == 0
  test "update acknowledgement confirms the exact target and requested values":
    let saved = %*{"chat": {"chat_id": "a", "title": "Renamed", "pinned": true}}
    check validateChatUpdate(saved, "a", %*{"title": "Renamed"}).title == "Renamed"
    expect ValueError: discard validateChatUpdate(saved, "b", %*{"pinned": true})
    expect ValueError: discard validateChatUpdate(saved, "a", %*{"pinned": false})
    expect ValueError: discard validateChatUpdate(saved, "a", %*{"title": "Other"})
    expect ValueError:
      discard validateChatUpdate(%*{"chat": {"chat_id": "a", "title": "First"}}, "a", %*{"pinned": false})
  test "calendar buckets distinguish dates and retain unknown dates":
    check dateBucket("2026-10-28", "2026-10-28") == "Today"
    check dateBucket("2026-10-27", "2026-10-28") == "Yesterday"
    check dateBucket("2026-10-23", "2026-10-28") == "Previous 7 days"
    check dateBucket("2026-10-01", "2026-10-28") == "Previous 30 days"
    check dateBucket("2026-06-02", "2026-10-28") == "June 2026"
    check dateBucket("unreadable", "2026-10-28") == "Recent"
  test "pinning and date sorting preserve identities and filtering":
    let chats = @[ChatItem(chatId: "older", title: "Old task", updatedAt: "2026-10-27"),
      ChatItem(chatId: "newer", title: "New task", updatedAt: "2026-10-28"),
      ChatItem(chatId: "pinned", title: "Pinned task", updatedAt: "2026-06-01", pinned: true)]
    let groups = groupChats(chats, "2026-10-28")
    check groups[0].title == "Pinned"
    check groups[0].chats[0].chatId == "pinned"
    check groups[1].chats[0].chatId == "newer"
    check groups[2].chats[0].chatId == "older"
    check groupChats(chats, "2026-10-28", " OLD ")[0].chats[0].chatId == "older"
    check chats[0].chatId == "older" # grouping does not mutate the caller
