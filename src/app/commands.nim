type WorkspaceCommand* = object
  id*, label*: string
  keys*: seq[string]  ## Shortcut as keys, e.g. @["Mod", "Alt", "N"]; "Mod" is Ctrl or ⌘.
  reviewerOnly*: bool  ## Shown only to reviewers; the backend still enforces it.

const
  paletteKeys* = ["Mod", "K"]
  workspaceCommands* = [
    WorkspaceCommand(id: "new_chat", label: "New chat", keys: @["Mod", "Alt", "N"]),
    WorkspaceCommand(id: "chats", label: "Browse saved chats", keys: @["Mod", "Alt", "C"]),
    WorkspaceCommand(id: "search", label: "Search chats", keys: @["Mod", "Shift", "F"]),
    WorkspaceCommand(id: "connections", label: "Model store: models, harnesses and datasets", keys: @["Mod", ","]),
    WorkspaceCommand(id: "tools", label: "MCP tool store: registered capabilities"),
    WorkspaceCommand(id: "plugins", label: "Lua plugin store: runtime adapters"),
    WorkspaceCommand(id: "settings", label: "Settings: theme, notifications and devices"),
    WorkspaceCommand(id: "skills", label: "Skill Store"),
    WorkspaceCommand(id: "knowledge", label: "Knowledge and cited search"),
    WorkspaceCommand(id: "learning", label: "Learning readiness"),
    WorkspaceCommand(id: "automation", label: "Automation workflows"),
    WorkspaceCommand(id: "engineering", label: "Infrastructure topology and drift"),
    WorkspaceCommand(id: "pcb", label: "PCB netlist inspection"),
    WorkspaceCommand(id: "operations", label: "Operations and recorded timings"),
    WorkspaceCommand(id: "review", label: "Review feedback", reviewerOnly: true),
    WorkspaceCommand(id: "inspector", label: "Toggle run inspector", keys: @["Mod", "Alt", "I"]),
    WorkspaceCommand(id: "refresh", label: "Check service status"),
    WorkspaceCommand(id: "compose", label: "Focus message composer")]

proc shortcutLabel*(keys: openArray[string], apple: bool): string =
  ## How the platform writes a shortcut: "Ctrl+Alt+N" on Windows and Linux,
  ## "⌥⌘N" on Apple keyboards (modifiers in Apple's order, then the key).
  if keys.len == 0: return ""
  if not apple:
    for i, key in keys:
      if i > 0: result.add "+"
      result.add(if key == "Mod": "Ctrl" else: key)
    return
  for (name, symbol) in [("Alt", "⌥"), ("Shift", "⇧"), ("Mod", "⌘")]:
    if name in keys: result.add symbol
  result.add keys[^1]

when defined(js):
  proc isApplePlatform(): bool {.importjs:
    "(() => /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent || ''))()".}

  proc shortcutText*(keys: openArray[string]): string =
    ## The label for the keyboard of the browser in use.
    shortcutLabel(keys, isApplePlatform())

proc shortcutAction*(key: string, modifier, shift, composing, repeated: bool, alt = false): string =
  if composing or repeated: return ""
  if key == "Escape": return "dismiss"
  if not modifier: return ""
  if alt:
    if key in ["c", "C"]: return "chats"
    if key in ["n", "N"]: return "new_chat"
    if key in ["i", "I"]: return "inspector"
    return ""
  if key in ["k", "K"] and not shift: return "palette"
  if key == "," and not shift: return "connections"
  if shift:
    case key
    of "f", "F": return "search"
    else: discard
