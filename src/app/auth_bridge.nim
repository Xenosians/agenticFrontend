include karax/prelude

import std/[
  asyncjs,
  strutils
]

import ../api/auth_client

import types
import state


proc browserQueryParam(
  name: cstring
): cstring {.
  importjs:
    "((new URLSearchParams(window.location.search)).get(#) || '')"
.}


proc clearBrowserQuery() {.
  importjs:
    "window.history.replaceState({}, document.title, window.location.pathname)"
.}


proc emptyRun(): RunState =
  RunState(
    active: false,
    request: "",
    jobId: "",
    status: "",
    agent: "",
    tool: "",
    presentations: @[]
  )


proc applyAuth(
  state: AppState,
  auth: AuthResponse
) =
  state.auth.authenticated = true
  state.auth.userId = auth.user.userId
  state.auth.email = auth.user.email
  state.auth.displayName = auth.user.displayName
  state.auth.role = auth.user.role
  state.auth.csrfToken = auth.csrfToken
  state.auth.sessionId = auth.sessionId
  state.auth.expiresAt = auth.expiresAt
  state.auth.error = ""


proc clearAuthenticatedState(
  state: AppState
) =
  state.auth.authenticated = false
  state.auth.userId = ""
  state.auth.email = ""
  state.auth.displayName = ""
  state.auth.role = ""
  state.auth.csrfToken = ""
  state.auth.sessionId = ""
  state.auth.expiresAt = ""
  state.chats.setLen(0)
  state.sessions.setLen(0)
  state.sessionsLoaded = false
  state.currentChatId = ""
  state.messages.setLen(0)
  state.run = emptyRun()
  state.runEvents.setLen(0)


proc applyHistory(
  state: AppState,
  chatId: string,
  history: seq[ChatHistoryMessage]
) =
  state.currentChatId = chatId
  state.messages.setLen(0)
  state.run = emptyRun()
  state.runEvents.setLen(0)
  state.nextMessageId = 1

  for item in history:
    if item.content.len == 0:
      continue

    let role =
      if item.role == "user":
        mrUser
      else:
        mrAssistant

    state.messages.add(
      ChatMessage(
        id: state.nextMessageId,
        role: role,
        content: item.content,
        cards: @[]
      )
    )

    inc state.nextMessageId

  if history.len > 0:
    let latest = history[^1]

    if latest.status == "waiting_approval" and latest.jobId.len > 0:
      state.run = RunState(
        active: true,
        request: "",
        jobId: latest.jobId,
        status: latest.status,
        agent: "",
        tool: "",
        presentations: @[]
      )


proc loadChatHistory*(
  state: AppState,
  chatId: string
) {.async.} =
  if not state.auth.authenticated or chatId.len == 0:
    return

  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  try:
    let history = await getChatHistory(chatId)
    applyHistory(state, chatId, history)
  except CatchableError as exc:
    state.auth.error = exc.msg
  finally:
    state.auth.loading = false

  redraw(kxi)


proc loadChats*(
  state: AppState
) {.async.} =
  if not state.auth.authenticated:
    return

  let remoteChats = await listChats()

  state.chats.setLen(0)

  for remote in remoteChats:
    state.chats.add(
      ChatItem(
        chatId: remote.chatId,
        title: remote.title,
        updatedAt: remote.updatedAt
      )
    )

  if state.currentChatId.len == 0:
    if state.chats.len > 0:
      await loadChatHistory(state, state.chats[0].chatId)
    else:
      let created = await createChat(state.auth.csrfToken)

      state.chats.add(
        ChatItem(
          chatId: created.chatId,
          title: created.title,
          updatedAt: created.updatedAt
        )
      )

      applyHistory(state, created.chatId, @[])


proc bootstrapApplication*(
  state: AppState
) {.async.} =
  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  let verifyToken = ($browserQueryParam(cstring"verify_token")).strip()
  let resetToken = ($browserQueryParam(cstring"reset_token")).strip()

  if verifyToken.len > 0:
    try:
      await verifyEmail(verifyToken)
      state.auth.notice = "Email verified. You can sign in now."
      clearBrowserQuery()
    except CatchableError as exc:
      state.auth.error = exc.msg

  if resetToken.len > 0:
    state.auth.mode = amResetPassword
    state.auth.resetToken = resetToken

  try:
    let auth = await me()
    applyAuth(state, auth)
    await loadChats(state)
  except CatchableError:
    clearAuthenticatedState(state)

  state.auth.checked = true
  state.auth.loading = false
  redraw(kxi)


proc loginApplication*(
  state: AppState
) {.async.} =
  let email = state.auth.emailDraft.strip()
  let password = state.auth.passwordDraft

  if email.len == 0 or password.len == 0:
    state.auth.error = "Email and password are required."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  try:
    let auth = await login(email, password)
    applyAuth(state, auth)
    state.auth.passwordDraft = ""
    state.auth.notice = ""
    await loadChats(state)
  except CatchableError as exc:
    state.auth.error = exc.msg
  finally:
    state.auth.loading = false

  redraw(kxi)


proc registerApplication*(
  state: AppState
) {.async.} =
  let displayName = state.auth.displayNameDraft.strip()
  let email = state.auth.emailDraft.strip()
  let password = state.auth.passwordDraft

  if displayName.len == 0 or email.len == 0 or password.len == 0:
    state.auth.error = "Display name, email and password are required."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  try:
    await register(displayName, email, password)
    state.auth.notice = "Registration created. Check your email for the verification link."
    state.auth.passwordDraft = ""
    state.auth.mode = amLogin
  except CatchableError as exc:
    state.auth.error = exc.msg
  finally:
    state.auth.loading = false

  redraw(kxi)


proc resendVerificationApplication*(
  state: AppState
) {.async.} =
  let email = state.auth.emailDraft.strip()

  if email.len == 0:
    state.auth.error = "Enter your email first."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  try:
    await resendVerification(email)
    state.auth.notice = "If the account still needs verification, a new email was sent."
  except CatchableError as exc:
    state.auth.error = exc.msg
  finally:
    state.auth.loading = false

  redraw(kxi)


proc forgotPasswordApplication*(
  state: AppState
) {.async.} =
  let email = state.auth.emailDraft.strip()

  if email.len == 0:
    state.auth.error = "Enter your email first."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  try:
    await forgotPassword(email)
    state.auth.notice = "If the account exists, a password reset email was sent."
    state.auth.mode = amLogin
  except CatchableError as exc:
    state.auth.error = exc.msg
  finally:
    state.auth.loading = false

  redraw(kxi)


proc resetPasswordApplication*(
  state: AppState
) {.async.} =
  if state.auth.resetToken.len == 0 or state.auth.newPasswordDraft.len == 0:
    state.auth.error = "A reset token and new password are required."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  try:
    await resetPassword(state.auth.resetToken, state.auth.newPasswordDraft)
    state.auth.notice = "Password reset complete. Sign in with your new password."
    state.auth.resetToken = ""
    state.auth.newPasswordDraft = ""
    state.auth.mode = amLogin
    clearBrowserQuery()
  except CatchableError as exc:
    state.auth.error = exc.msg
  finally:
    state.auth.loading = false

  redraw(kxi)


proc logoutApplication*(
  state: AppState
) {.async.} =
  if not state.auth.authenticated:
    clearAuthenticatedState(state)
    state.auth.checked = true
    redraw(kxi)
    return

  state.auth.loading = true
  redraw(kxi)

  try:
    await logout(state.auth.csrfToken)
  except CatchableError:
    discard

  clearAuthenticatedState(state)
  state.auth.checked = true
  state.auth.loading = false
  state.auth.mode = amLogin
  state.auth.notice = "Signed out."
  redraw(kxi)


proc createNewChat*(
  state: AppState
) {.async.} =
  if not state.auth.authenticated:
    return

  try:
    let created = await createChat(state.auth.csrfToken)

    state.chats.insert(
      ChatItem(
        chatId: created.chatId,
        title: created.title,
        updatedAt: created.updatedAt
      ),
      0
    )

    applyHistory(state, created.chatId, @[])
    state.activeView = viewChat
    showToast(state, "New chat created.")
  except CatchableError as exc:
    showToast(state, "Could not create chat: " & exc.msg)

  redraw(kxi)


proc selectChat*(
  state: AppState,
  chatId: string
) {.async.} =
  if chatId == state.currentChatId:
    state.activeView = viewChat
    redraw(kxi)
    return

  await loadChatHistory(state, chatId)
  state.activeView = viewChat
  redraw(kxi)


proc loadAuthSessions*(
  state: AppState
) {.async.} =
  if not state.auth.authenticated:
    return

  try:
    let remoteSessions = await listSessions()
    state.sessions.setLen(0)

    for remote in remoteSessions:
      state.sessions.add(
        AuthSessionItem(
          sessionId: remote.sessionId,
          createdAt: remote.createdAt,
          lastSeenAt: remote.lastSeenAt,
          expiresAt: remote.expiresAt,
          revokedAt: remote.revokedAt,
          userAgent: remote.userAgent,
          current: remote.current
        )
      )

    state.sessionsLoaded = true
  except CatchableError as exc:
    showToast(state, "Session history failed: " & exc.msg)

  redraw(kxi)


proc revokeAuthSession*(
  state: AppState,
  sessionId: string
) {.async.} =
  if not state.auth.authenticated or sessionId.len == 0:
    return

  try:
    await revokeSession(state.auth.csrfToken, sessionId)

    if sessionId == state.auth.sessionId:
      clearAuthenticatedState(state)
      state.auth.checked = true
      state.auth.mode = amLogin
      state.auth.notice = "Current session revoked."
    else:
      await loadAuthSessions(state)
  except CatchableError as exc:
    showToast(state, "Could not revoke session: " & exc.msg)

  redraw(kxi)
