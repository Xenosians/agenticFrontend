import std/unittest
import ../src/app/commands
suite "workspace shortcuts":
  test "ordinary typing, IME and held keys do not dispatch commands":
    check shortcutAction("n", false, false, false, false) == ""
    check shortcutAction("K", true, false, true, false) == ""
    check shortcutAction("K", true, false, false, true) == ""
  test "shortcut dispatch matches command palette actions":
    check shortcutAction("K", true, false, false, false) == "palette"
    check shortcutAction("N", true, false, false, false, true) == "new_chat"
    check shortcutAction("I", true, false, false, false, true) == "inspector"
    check shortcutAction("C", true, false, false, false, true) == "chats"
    check shortcutAction("N", true, true, false, false) == ""
    check shortcutAction(",", true, false, false, false) == "connections"
