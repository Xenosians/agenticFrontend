type WorkspaceCommand* = object
  id*, label*, shortcut*: string
  reviewerOnly*: bool  ## Shown only to reviewers; the backend still enforces it.

const workspaceCommands* = [
  WorkspaceCommand(id: "new_chat", label: "New chat", shortcut: "Ctrl/Meta+Alt+N"),
  WorkspaceCommand(id: "chats", label: "Browse saved chats", shortcut: "Ctrl/Meta+Alt+C"),
  WorkspaceCommand(id: "search", label: "Search chats", shortcut: "Ctrl/Meta+Shift+F"),
  WorkspaceCommand(id: "connections", label: "Models, harnesses and datasets", shortcut: "Ctrl/Meta+,"),
  WorkspaceCommand(id: "capabilities", label: "Capabilities", shortcut: ""),
  WorkspaceCommand(id: "operations", label: "Operations and recorded timings", shortcut: ""),
  WorkspaceCommand(id: "review", label: "Review feedback", shortcut: "", reviewerOnly: true),
  WorkspaceCommand(id: "inspector", label: "Toggle run inspector", shortcut: "Ctrl/Meta+Alt+I"),
  WorkspaceCommand(id: "refresh", label: "Refresh system and connections", shortcut: ""),
  WorkspaceCommand(id: "compose", label: "Focus message composer", shortcut: "")]

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
