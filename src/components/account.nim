include karax/prelude
import ../app/[types, auth_bridge, account_bridge]

proc renderAccountSession(state: AppState, currentSession: AuthSessionItem): VNode =
  result = buildHtml(tdiv(class = "system-row account-session-row")):
    tdiv:
      strong:
        text (if currentSession.current: "Current session" else: "Session")
      span:
        text currentSession.userAgent & " · expires " & currentSession.expiresAt
    if currentSession.revokedAt.len > 0:
      span(class = "capability-badge disabled"):
        text "Revoked"
    elif currentSession.current:
      span(class = "capability-badge enabled"):
        text "Current"
    else:
      button(class = "secondary-action", disabled = state.sessionsBusy or state.sessionActionBusy or state.sessionsNeedRefresh):
        text "Revoke"
        proc onclick(event: Event, node: VNode) =
          discard revokeAuthSession(state, currentSession.sessionId)

proc renderAccountView*(state: AppState): VNode =
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view account-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "Account"
          p:
            text "Application identity, notifications and server-side sessions."
        button(class = "secondary-action", disabled = state.auth.loading):
          text (if state.auth.loading: "Signing out…" else: "Sign out")
          proc onclick(event: Event, node: VNode) =
            discard logoutApplication(state)
      if state.auth.error.len > 0:
        p(class = "account-error", role = "alert"):
          text state.auth.error
      tdiv(class = "account-profile-grid"):
        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "Display name"
          strong:
            text (if state.auth.displayName.len > 0: state.auth.displayName else: "Not set")
        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "Email"
          strong:
            text state.auth.email
        tdiv(class = "developer-card"):
          span(class = "run-label"):
            text "Role"
          strong:
            text state.auth.role
      tdiv(class = "developer-card wide account-notifications"):
        tdiv(class = "developer-view-header compact"):
          tdiv:
            h3:
              text "Email notifications"
            p:
              text "Choose whether to receive an email when a task completes."
          button(class = "secondary-action", disabled = state.preferencesBusy or state.preferencesSaving):
            text (if state.preferencesBusy: "Loading settings…" else: "Reload settings")
            proc onclick(event: Event, node: VNode) =
              discard loadAccountPreferences(state)
        if state.preferencesError.len > 0:
          p(class = "account-error", role = "alert"):
            text state.preferencesError
        elif not state.preferencesLoaded:
          p:
            text (if state.preferencesBusy: "Loading notification settings…" else: "Reload settings to see your saved choice.")
        if state.preferencesLoaded:
          label(class = "account-mail-choice"):
            input(`type` = "checkbox", checked = state.completionMailDraft,
              disabled = state.preferencesBusy or state.preferencesSaving):
              proc onchange(event: Event, node: VNode) =
                state.completionMailDraft = not state.completionMailDraft
                state.preferencesNotice = ""
            span:
              text "Task completion emails"
          button(class = "secondary-action", disabled = state.preferencesBusy or state.preferencesSaving or
              state.completionMailDraft == state.completionMail):
            text (if state.preferencesSaving: "Saving setting…" else: "Save notification setting")
            proc onclick(event: Event, node: VNode) =
              discard saveAccountPreferences(state)
        if state.preferencesNotice.len > 0:
          p(class = "account-notice", role = "status"):
            text state.preferencesNotice
        p(class = "account-setting-help"):
          text "Applies to future task completions. Already queued emails, authentication, approval, failure and reconciliation messages, and notifications you request are unchanged. Delivery also depends on the deployment's mail settings."
      tdiv(class = "developer-card wide account-session-panel"):
        tdiv(class = "developer-view-header compact"):
          tdiv:
            h3:
              text "Authenticated sessions"
            p:
              text "Revoke other sessions while keeping this one signed in."
          tdiv(class = "account-session-actions"):
            button(class = "secondary-action", disabled = state.sessionsBusy or state.sessionActionBusy):
              text (if state.sessionsBusy: "Loading sessions…" else: "Refresh")
              proc onclick(event: Event, node: VNode) =
                discard refreshAccountSessions(state)
            button(class = "secondary-action", disabled = state.sessionsBusy or state.sessionActionBusy or state.sessionsNeedRefresh):
              text (if state.sessionActionBusy: "Revoking…" else: "Revoke other sessions")
              proc onclick(event: Event, node: VNode) =
                discard revokeOtherAuthSessions(state)
        if state.sessionsError.len > 0:
          p(class = "account-error", role = "alert"):
            text state.sessionsError
        if state.sessionsNotice.len > 0:
          p(class = "account-notice", role = "status"):
            text state.sessionsNotice
        if not state.sessionsLoaded:
          p:
            text (if state.sessionsBusy: "Loading session history…" else: "Refresh to load your sessions.")
        elif state.sessions.len == 0:
          p:
            text "No sessions were returned."
        else:
          for session in state.sessions:
            renderAccountSession(state, session)
