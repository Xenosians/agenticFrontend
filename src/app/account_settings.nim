import std/json
import appearance

type NotificationPreferences* = object
  ## Every setting the server keeps for the owner, as saved.
  taskCompleted*: bool
  theme*: ThemeMode
  accent*: Accent

proc parseNotificationPreferences*(node: JsonNode): NotificationPreferences =
  if node.kind != JObject or not node.hasKey("preferences") or node["preferences"].kind != JObject:
    raise newException(ValueError, "The settings response was invalid.")
  let saved = node["preferences"]
  if not saved.hasKey("task_completed") or saved["task_completed"].kind != JBool or
      not saved.hasKey("theme") or saved["theme"].kind != JString or
      not saved.hasKey("accent") or saved["accent"].kind != JString:
    raise newException(ValueError, "The settings response was invalid.")
  let theme = parseThemeMode(saved["theme"].getStr())
  let accent = parseAccent(saved["accent"].getStr())
  if theme.isNone or accent.isNone:
    raise newException(ValueError, "The settings response was invalid.")
  NotificationPreferences(taskCompleted: saved["task_completed"].getBool(),
    theme: theme.get, accent: accent.get)

proc parseOtherSessionRevocation*(node: JsonNode): int =
  if node.kind != JObject or not node.hasKey("status") or
      node["status"].kind != JString or node["status"].getStr() != "revoked" or
      not node.hasKey("revoked_count") or node["revoked_count"].kind != JInt or
      node["revoked_count"].getInt() < 0:
    raise newException(ValueError, "Session revocation was not confirmed. Refresh sessions to check their saved state.")
  node["revoked_count"].getInt()

proc validateSessionRevocation*(node: JsonNode, sessionId: string) =
  if node.kind != JObject or not node.hasKey("status") or
      node["status"].kind != JString or node["status"].getStr() != "revoked" or
      not node.hasKey("session_id") or node["session_id"].kind != JString or
      node["session_id"].getStr() != sessionId:
    raise newException(ValueError, "Session revocation was not confirmed. Refresh sessions to check their saved state.")
