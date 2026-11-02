include karax/prelude
import std/[asyncjs, json]
import ../api/[account_settings, auth_client]
from account_settings as saved_settings import NotificationPreferences
import types
import request_context

proc systemPrefersLight(): bool {.importjs: "(() => !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches))()".}
proc setDocumentTheme(theme, accent: cstring) {.importjs: "((t, a) => { const root = document.documentElement; root.dataset.theme = t; root.dataset.accent = a; })(#, #)".}
proc onSystemThemeChange(callback: proc()) {.importjs: "(cb => window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', () => cb()))(#)".}

proc applyAppearance*(state: AppState) =
  ## Paints the owner's saved theme and accent. Attributes only: the
  ## stylesheet defines every theme, so no inline style is ever written.
  setDocumentTheme(cstring(resolvedTheme(state.themeMode, systemPrefersLight())),
                   cstring(accentValue(state.accent)))

proc followSystemTheme*(state: AppState) =
  ## "Match system" repaints when the operating system switches theme.
  onSystemThemeChange(proc() =
    if state.themeMode == themeSystem: applyAppearance(state))

proc applySavedPreferences(state: AppState, saved: NotificationPreferences) =
  state.completionMail = saved.taskCompleted
  state.completionMailDraft = saved.taskCompleted
  state.themeMode = saved.theme
  state.accent = saved.accent
  state.preferencesLoaded = true
  applyAppearance(state)

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
    applySavedPreferences(state, preferences)
  except CatchableError:
    if matchesPreferencesRequest(state, request):
      state.preferencesLoaded = false
      state.preferencesError = "Settings could not be loaded. Reload settings to check again."
  finally:
    if matchesPreferencesRequest(state, request): state.preferencesBusy = false
    redraw(kxi)

proc canSaveSettings*(state: AppState): bool =
  state.auth.authenticated and state.preferencesLoaded and
    not state.preferencesBusy and not state.preferencesSaving

proc saveSetting(state: AppState, changes: JsonNode, notice: string, revert: proc()) {.async.} =
  ## Saves one setting; the server keeps the rest. The caller has already
  ## previewed the choice; `revert` restores the saved value if the server
  ## does not confirm it, and a reload is required instead of guessing.
  let request = beginPreferencesRequest(state)
  state.preferencesSaving = true
  state.preferencesError = ""
  state.preferencesNotice = ""
  redraw(kxi)
  try:
    let preferences = await writePreferences(state.auth.csrfToken, changes)
    if not matchesPreferencesRequest(state, request): return
    applySavedPreferences(state, preferences)
    state.preferencesNotice = notice
  except CatchableError as exc:
    if matchesPreferencesRequest(state, request):
      revert()
      state.preferencesLoaded = false
      state.preferencesError = exc.msg
      applyAppearance(state)
  finally:
    if matchesPreferencesRequest(state, request): state.preferencesSaving = false
    redraw(kxi)

proc saveThemeMode*(state: AppState, mode: ThemeMode) {.async.} =
  if mode == state.themeMode or not canSaveSettings(state): return
  let saved = state.themeMode
  state.themeMode = mode  # Preview at once; the server's receipt confirms it.
  applyAppearance(state)
  await saveSetting(state, %*{"theme": themeValue(mode)}, "Theme saved.",
    proc() = state.themeMode = saved)

proc saveAccent*(state: AppState, accent: Accent) {.async.} =
  if accent == state.accent or not canSaveSettings(state): return
  let saved = state.accent
  state.accent = accent
  applyAppearance(state)
  await saveSetting(state, %*{"accent": accentValue(accent)}, "Accent saved.",
    proc() = state.accent = saved)

proc saveCompletionMail*(state: AppState, enabled: bool) {.async.} =
  if enabled == state.completionMail or not canSaveSettings(state): return
  let saved = state.completionMail
  state.completionMailDraft = enabled
  await saveSetting(state, %*{"task_completed": enabled}, "Notification setting saved.",
    proc() = state.completionMailDraft = saved)

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
