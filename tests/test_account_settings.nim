import std/[json, unittest]
import ../src/app/[account_settings, types, state, request_context]

suite "authoritative account settings receipts":
  test "notification choices are explicit server booleans":
    check parseNotificationPreferences(%*{"preferences": {"task_completed": true}}).taskCompleted
    check not parseNotificationPreferences(%*{"preferences": {"task_completed": false}}).taskCompleted
  test "missing or malformed choices never become a default":
    for node in [%*{}, %*{"preferences": {}}, %*{"preferences": {"task_completed": "false"}},
                 %*{"preferences": {"task_completed": nil}}]:
      expect ValueError: discard parseNotificationPreferences(node)
  test "bulk revoke needs a nonnegative confirmed count":
    check parseOtherSessionRevocation(%*{"status": "revoked", "revoked_count": 3}) == 3
    for node in [%*{}, %*{"status": "accepted", "revoked_count": 3},
                 %*{"status": "revoked", "revoked_count": -1},
                 %*{"status": "revoked", "revoked_count": "3"}]:
      expect ValueError: discard parseOtherSessionRevocation(node)
  test "one session receipt must identify the requested session":
    validateSessionRevocation(%*{"status": "revoked", "session_id": "owned-session"}, "owned-session")
    expect ValueError:
      validateSessionRevocation(%*{"status": "revoked", "session_id": "other-session"}, "owned-session")
  test "settings and sessions have independent exact-session request scopes":
    let app = initAppState()
    app.auth.authenticated = true
    app.auth.userId = "owner"
    app.auth.sessionId = "session"
    let settings = beginPreferencesRequest(app)
    let sessions = beginSessionsRequest(app)
    check matchesPreferencesRequest(app, settings)
    check matchesSessionsRequest(app, sessions)
    discard beginPreferencesRequest(app)
    check not matchesPreferencesRequest(app, settings)
    check matchesSessionsRequest(app, sessions)
    app.auth.sessionId = "replacement"
    check not matchesSessionsRequest(app, sessions)
  test "sign-out clears settings and invalidates both pending responses":
    let app = initAppState()
    app.auth.authenticated = true
    app.auth.userId = "owner"
    app.auth.sessionId = "session"
    let settings = beginPreferencesRequest(app)
    let sessions = beginSessionsRequest(app)
    app.preferencesLoaded = true
    app.completionMailDraft = true
    app.sessionActionBusy = true
    app.sessionsError = "old owner"
    clearOperations(app)
    check not matchesPreferencesRequest(app, settings)
    check not matchesSessionsRequest(app, sessions)
    check not app.preferencesLoaded
    check not app.completionMailDraft
    check not app.sessionActionBusy
    check app.sessionsError == ""
