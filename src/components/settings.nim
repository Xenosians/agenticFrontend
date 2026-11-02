## Settings: appearance, notifications, signed-in devices, service status and profile.
##
## One place for everything the owner can change about their own workspace.
## Every saved choice comes from the server; nothing is kept in the browser.
include karax/prelude
import ../app/[types, auth_bridge, account_bridge, backend_bridge]

proc settingsSection(title, summary: string, body: VNode, action: VNode = nil): VNode =
  ## Every section: a title, one line saying what it is for, an optional
  ## action on the right, then its controls.
  result = buildHtml(section(class = "settings-section", `aria-label` = cstring(title))):
    tdiv(class = "settings-section-heading"):
      tdiv:
        h3: text title
        p: text summary
      if action != nil: action
    body

proc renderChoice[T](name: string, value, selected: T, disabled: bool,
                     label: proc(value: T): string, swatch: bool, choose: proc(value: T)): VNode =
  ## One option per call, so its handler keeps its own value (a loop
  ## variable captured by several handlers would be shared in JavaScript).
  result = buildHtml(label(class = (if value == selected: cstring"settings-choice selected" else: cstring"settings-choice"))):
    input(`type` = "radio", name = cstring(name), checked = value == selected, disabled = disabled):
      proc onchange(event: Event, node: VNode) = choose(value)
    if swatch:
      span(class = cstring("settings-swatch accent-" & accentValue(Accent(ord(value)))),
           `aria-hidden` = "true")
    span: text label(value)

proc renderChoiceGroup[T](name: string, options: openArray[T], selected: T, disabled: bool,
                          label: proc(value: T): string, swatch: bool,
                          choose: proc(value: T)): VNode =
  ## A radio group: arrow keys move between options, as for native radios.
  result = buildHtml(tdiv(class = (if swatch: cstring"settings-choices swatches" else: cstring"settings-choices"),
                          role = "radiogroup", `aria-label` = cstring(name))):
    for option in options:
      renderChoice(name, option, selected, disabled, label, swatch, choose)

proc renderAppearance(state: AppState): VNode =
  let disabled = not state.preferencesLoaded or state.preferencesBusy or state.preferencesSaving
  var themes: seq[ThemeMode]
  for mode in ThemeMode: themes.add mode
  var accents: seq[Accent]
  for accent in Accent: accents.add accent
  let body = buildHtml(tdiv(class = "settings-body")):
    tdiv(class = "settings-field"):
      span(class = "settings-field-label"): text "Theme"
      renderChoiceGroup("Theme", themes, state.themeMode, disabled, themeLabel, false,
        proc(mode: ThemeMode) = discard saveThemeMode(state, mode))
    tdiv(class = "settings-field"):
      span(class = "settings-field-label"): text "Accent"
      renderChoiceGroup("Accent", accents, state.accent, disabled, accentLabel, true,
        proc(accent: Accent) = discard saveAccent(state, accent))
  settingsSection("Appearance", "Saved to your account, so it follows you to any browser.", body)

proc renderNotifications(state: AppState): VNode =
  let body = buildHtml(tdiv(class = "settings-body")):
    if state.preferencesLoaded:
      label(class = "settings-toggle"):
        input(`type` = "checkbox", checked = state.completionMailDraft,
          disabled = state.preferencesBusy or state.preferencesSaving):
          proc onchange(event: Event, node: VNode) =
            discard saveCompletionMail(state, not state.completionMailDraft)
        span:
          strong: text "Task completion emails"
          small: text "For tasks that finish from now on."
  settingsSection("Notifications", "Sign-in and approval emails are always sent.", body)

proc localDate(value: cstring): cstring {.
  importjs: "((v) => { const d = new Date(v); return Number.isNaN(d.getTime()) ? v : d.toLocaleDateString(undefined, {year: 'numeric', month: 'short', day: 'numeric'}); })(#)".}

proc renderSession(state: AppState, item: AuthSessionItem): VNode =
  result = buildHtml(tdiv(class = "settings-row account-session-row")):
    tdiv(class = "settings-row-copy"):
      strong: text item.userAgent
      span: text "Signed in until " & $localDate(cstring(item.expiresAt))
    if item.revokedAt.len > 0:
      span(class = "settings-badge"): text "Revoked"
    elif item.current:
      span(class = "settings-badge active"): text "This browser"
    else:
      button(class = "secondary-action", `aria-label` = cstring("Sign out " & item.userAgent),
        disabled = state.sessionsBusy or state.sessionActionBusy or state.sessionsNeedRefresh):
        text "Sign out"
        proc onclick(event: Event, node: VNode) = discard revokeAuthSession(state, item.sessionId)

proc renderSessions(state: AppState): VNode =
  var others = 0
  for item in state.sessions:
    if not item.current and item.revokedAt.len == 0: inc others
  let action = buildHtml(button(class = "secondary-action", disabled = state.sessionsBusy or state.sessionActionBusy)):
    text (if state.sessionsBusy: "Loading…" else: "Refresh")
    proc onclick(event: Event, node: VNode) = discard refreshAccountSessions(state)
  let body = buildHtml(tdiv(class = "settings-body settings-list account-session-panel")):
    if state.sessionsError.len > 0:
      p(class = "settings-error", role = "alert"): text state.sessionsError
    if state.sessionsNotice.len > 0:
      p(class = "settings-notice", role = "status"): text state.sessionsNotice
    if not state.sessionsLoaded:
      p(class = "settings-help"):
        text (if state.sessionsBusy: "Loading signed-in devices…" else: "Signed-in devices could not be listed yet.")
    else:
      for item in state.sessions: renderSession(state, item)
      # Offered only when the loaded list shows another active device.
      if others > 0 or state.sessionActionBusy or state.sessionsNeedRefresh:
        tdiv(class = "settings-actions settings-list-footer"):
          button(class = "secondary-action",
            disabled = state.sessionsBusy or state.sessionActionBusy or state.sessionsNeedRefresh):
            text (if state.sessionActionBusy: "Signing out…" else: "Sign out other devices")
            proc onclick(event: Event, node: VNode) = discard revokeOtherAuthSessions(state)
  settingsSection("Signed-in devices", "Sign out anywhere you no longer use. This browser stays signed in.",
    body, action)

proc serviceRow(name, purpose, label: string, healthy, known: bool): VNode =
  result = buildHtml(tdiv(class = "settings-row system-row")):
    tdiv(class = "settings-row-copy"):
      strong: text name
      span: text purpose
    span(class = (if healthy: cstring"settings-badge active"
                  elif known: cstring"settings-badge attention"
                  else: cstring"settings-badge")):
      text label

proc renderServices(state: AppState): VNode =
  let system = state.system
  let backendLabel =
    if system.checking: "Checking" elif not system.checked: "Not checked"
    elif system.backendConnected: "Connected" else: "Unavailable"
  let aiLabel =
    if system.checking: "Checking" elif not system.checked: "Not checked"
    elif system.aiReady: "Ready" elif system.aiReachable: "Starting" else: "Unavailable"
  let action = buildHtml(button(class = "secondary-action", disabled = system.checking)):
    text (if system.checking: "Checking…" else: "Check again")
    proc onclick(event: Event, node: VNode) = discard refreshSystemStatus(state)
  let body = buildHtml(tdiv(class = "settings-body settings-list system-list")):
    serviceRow("Backend", "Sign-in, chats, tasks and approvals", backendLabel,
      system.backendConnected, system.checked)
    serviceRow("AI runtime", "Answers and approved actions", aiLabel, system.aiReady, system.checked)
    if system.error.len > 0:
      p(class = "settings-error", role = "alert"): text system.error
  settingsSection("Services", "Whether Janus can reach its backend and AI runtime.", body, action)

proc renderProfile(state: AppState): VNode =
  let body = buildHtml(tdiv(class = "settings-body")):
    dl(class = "settings-profile"):
      tdiv:
        dt: text "Name"
        dd: text (if state.auth.displayName.len > 0: state.auth.displayName else: "Not set")
      tdiv:
        dt: text "Email"
        dd: text state.auth.email
      tdiv:
        dt: text "Role"
        dd: text state.auth.role
  let action = buildHtml(button(class = "secondary-action", disabled = state.auth.loading)):
    text (if state.auth.loading: "Signing out…" else: "Sign out")
    proc onclick(event: Event, node: VNode) = discard logoutApplication(state)
  settingsSection("Profile", "Your account as Janus knows it.", body, action)

proc renderSettingsView*(state: AppState): VNode =
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "settings-view account-view"):
      if state.auth.error.len > 0:
        p(class = "settings-error", role = "alert"): text state.auth.error
      if state.preferencesError.len > 0:
        tdiv(class = "settings-banner", role = "alert"):
          p(class = "settings-error"): text state.preferencesError
          button(class = "secondary-action", disabled = state.preferencesBusy or state.preferencesSaving):
            text (if state.preferencesBusy: "Loading settings…" else: "Reload settings")
            proc onclick(event: Event, node: VNode) = discard loadAccountPreferences(state)
      elif not state.preferencesLoaded:
        p(class = "settings-help"):
          text (if state.preferencesBusy: "Loading your settings…" else: "Your settings are not loaded yet.")
      if state.preferencesNotice.len > 0:
        p(class = "settings-notice", role = "status"): text state.preferencesNotice
      renderAppearance(state)
      renderNotifications(state)
      renderSessions(state)
      renderServices(state)
      renderProfile(state)
