import std/[sequtils, unittest]
import ../src/app/commands
suite "workspace shortcuts":
  test "labels name the keys of the platform in use":
    check shortcutLabel(@["Mod", "K"], apple = false) == "Ctrl+K"
    check shortcutLabel(@["Mod", "K"], apple = true) == "⌘K"
    check shortcutLabel(@["Mod", "Alt", "N"], apple = false) == "Ctrl+Alt+N"
    check shortcutLabel(@["Mod", "Alt", "N"], apple = true) == "⌥⌘N"
    check shortcutLabel(@["Mod", "Shift", "F"], apple = true) == "⇧⌘F"
    check shortcutLabel(@["Mod", ","], apple = false) == "Ctrl+,"
    check shortcutLabel(@[], apple = false) == ""
  test "every listed shortcut is one the keyboard handler dispatches":
    for command in workspaceCommands:
      if command.keys.len > 0:
        let key = command.keys[^1]
        check shortcutAction(key, "Mod" in command.keys, "Shift" in command.keys, false, false,
                             "Alt" in command.keys) == command.id
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

  test "the store sections and the dashboards each have one command":
    var ids: seq[string]
    for command in workspaceCommands: ids.add command.id
    for id in ["tools", "skills", "plugins", "automation", "engineering", "knowledge", "operations", "learning"]:
      check ids.count(id) == 1
