import std/json

type NotificationPreferences* = object
  taskCompleted*: bool

proc parseNotificationPreferences*(node: JsonNode): NotificationPreferences =
  if node.kind != JObject or not node.hasKey("preferences") or
      node["preferences"].kind != JObject or
      not node["preferences"].hasKey("task_completed") or
      node["preferences"]["task_completed"].kind != JBool:
    raise newException(ValueError, "The notification settings response was invalid.")
  NotificationPreferences(taskCompleted: node["preferences"]["task_completed"].getBool())

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
