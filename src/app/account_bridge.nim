include karax/prelude
import std/asyncjs
import ../api/[account_settings, auth_client]
import types
import request_context

proc refreshAccountSessions*(state: AppState) {.async.} =
  if not state.auth.authenticated or state.sessionsBusy or state.sessionActionBusy: return
  let request = beginSessionsRequest(state)
  state.sessionsBusy = true
  state.sessionsError = ""
  redraw(kxi)
  try:
    let remote = await listSessions()
    if not matchesSessionsRequest(state, request): return
    state.sessions = @[]
    for item in remote:
      state.sessions.add(AuthSessionItem(sessionId: item.sessionId, createdAt: item.createdAt,
        lastSeenAt: item.lastSeenAt, expiresAt: item.expiresAt, revokedAt: item.revokedAt,
        userAgent: item.userAgent, current: item.current))
    state.sessionsLoaded = true
    state.sessionsNeedRefresh = false
  except CatchableError:
    if matchesSessionsRequest(state, request):
      state.sessionsError = "Session history could not be loaded. Refresh to check again."
      state.sessionsLoaded = false
  finally:
    if matchesSessionsRequest(state, request): state.sessionsBusy = false
    redraw(kxi)

proc loadAccountPreferences*(state: AppState) {.async.} =
  if not state.auth.authenticated or state.preferencesBusy or state.preferencesSaving: return
  let request = beginPreferencesRequest(state)
  state.preferencesBusy = true
  state.preferencesError = ""
  state.preferencesNotice = ""
  redraw(kxi)
  try:
    let preferences = await readNotificationPreferences()
    if not matchesPreferencesRequest(state, request): return
    state.completionMail = preferences.taskCompleted
    state.completionMailDraft = preferences.taskCompleted
    state.preferencesLoaded = true
  except CatchableError:
    if matchesPreferencesRequest(state, request):
      state.preferencesLoaded = false
      state.preferencesError = "Notification settings could not be loaded. Reload settings to check again."
  finally:
    if matchesPreferencesRequest(state, request): state.preferencesBusy = false
    redraw(kxi)

proc saveAccountPreferences*(state: AppState) {.async.} =
  if not state.auth.authenticated or not state.preferencesLoaded or
      state.preferencesBusy or state.preferencesSaving: return
  let request = beginPreferencesRequest(state)
  let choice = state.completionMailDraft
  state.preferencesSaving = true
  state.preferencesError = ""
  state.preferencesNotice = ""
  redraw(kxi)
  try:
    let preferences = await writeNotificationPreferences(state.auth.csrfToken, choice)
    if not matchesPreferencesRequest(state, request): return
    state.completionMail = preferences.taskCompleted
    state.completionMailDraft = preferences.taskCompleted
    state.preferencesNotice = "Notification setting saved."
  except CatchableError as exc:
    if matchesPreferencesRequest(state, request):
      state.preferencesLoaded = false
      state.preferencesError = exc.msg
  finally:
    if matchesPreferencesRequest(state, request): state.preferencesSaving = false
    redraw(kxi)

proc revokeOtherAuthSessions*(state: AppState) {.async.} =
  if not state.auth.authenticated or state.sessionsBusy or state.sessionActionBusy or state.sessionsNeedRefresh: return
  let request = beginSessionsRequest(state)
  state.sessionActionBusy = true
  state.sessionsError = ""
  state.sessionsNotice = ""
  redraw(kxi)
  var confirmed = false
  try:
    let count = await revokeOtherSessions(state.auth.csrfToken)
    if not matchesSessionsRequest(state, request): return
    state.sessionsNotice = $count & " other session(s) revoked. This session stays signed in."
    confirmed = true
  except CatchableError as exc:
    if matchesSessionsRequest(state, request):
      state.sessionsError = exc.msg
      state.sessionsNeedRefresh = true
  finally:
    if matchesSessionsRequest(state, request): state.sessionActionBusy = false
    redraw(kxi)
  if confirmed and matchesSessionsRequest(state, request): await refreshAccountSessions(state)
