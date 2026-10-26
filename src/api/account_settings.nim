import std/[asyncjs, jsfetch, json]
from std/httpcore import HttpGet, HttpPut, HttpPost
import ../config/runtime_config
import ../app/account_settings
import http_call
from auth_client import jsonHeaders

proc readNotificationPreferences*(): Future[NotificationPreferences] {.async.} =
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/auth/preferences",
    newFetchOptions(metod = HttpGet, mode = fmCors, credentials = fcInclude))
  if not response.ok:
    raise newException(ValueError, "Notification settings could not be loaded (HTTP " & $response.status & ").")
  return parseNotificationPreferences(decodeJson(response.body))

proc writeNotificationPreferences*(csrfToken: string, taskCompleted: bool): Future[NotificationPreferences] {.async.} =
  var response: HttpReply
  try:
    response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/auth/preferences",
      newFetchOptions(metod = HttpPut, body = ($(%*{"task_completed": taskCompleted})).cstring,
        mode = fmCors, credentials = fcInclude, headers = jsonHeaders(csrfToken)))
  except CatchableError:
    raise newException(ValueError, "Settings could not be confirmed. Reload settings to check the saved choice.")
  if not response.ok:
    raise newException(ValueError, "Settings were not confirmed (HTTP " & $response.status & "). Reload settings to check the saved choice.")
  let preferences = parseNotificationPreferences(decodeJson(response.body))
  if preferences.taskCompleted != taskCompleted:
    raise newException(ValueError, "The saved setting did not match your choice. Reload settings to check it.")
  return preferences

proc revokeOtherSessions*(csrfToken: string): Future[int] {.async.} =
  var response: HttpReply
  try:
    response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/auth/sessions/revoke-others",
      newFetchOptions(metod = HttpPost, body = cstring"{}", mode = fmCors,
        credentials = fcInclude, headers = jsonHeaders(csrfToken)))
  except CatchableError:
    raise newException(ValueError, "Session revocation was not confirmed. Refresh sessions to check their saved state.")
  if not response.ok:
    raise newException(ValueError, "Session revocation was not confirmed (HTTP " & $response.status & "). Refresh sessions to check their saved state.")
  return parseOtherSessionRevocation(decodeJson(response.body))
