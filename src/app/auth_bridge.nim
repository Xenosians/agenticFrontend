include karax/prelude

import std/[
  asyncjs,
  strutils
]

import ../api/auth_client
import ../api/job_submission

import types
import state
import backend_bridge
import extension_bridge
import connection_draft
import request_context
import account_bridge
import chat_bridge
import answer_references


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


proc monotonicMs(): float {.importjs: "performance.now()".}


proc everySecond(callback: proc()) : int {.importjs: "setInterval(#, 1000)".}


proc stopTimer(id: int) {.importjs: "clearInterval(#)".}


var verificationTimer = 0


proc updateVerificationCountdown(state: AppState) =
  let left = int((state.auth.verificationResendAt - monotonicMs() + 999.0) / 1000.0)
  state.auth.verificationSecondsLeft = max(left, 0)
  if state.auth.verificationSecondsLeft == 0 and verificationTimer != 0:
    stopTimer(verificationTimer)
    verificationTimer = 0


proc leaveVerification(state: AppState) =
  ## Ends the verification step in this page. The server's cookie is the step;
  ## nothing about it was kept in the browser.
  inc state.auth.verificationEpoch
  if verificationTimer != 0:
    stopTimer(verificationTimer)
    verificationTimer = 0
  state.auth.verificationEmailHint = ""
  state.auth.verificationResendAt = 0
  state.auth.verificationSecondsLeft = 0
  state.auth.mode = amLogin


proc enterVerification(state: AppState, step: VerificationStep) =
  ## Shows the timed step with the server's wait. The countdown only mirrors
  ## that wait; the server refuses an early resend whatever the page shows.
  inc state.auth.verificationEpoch
  state.auth.mode = amVerifyEmail
  if step.emailHint.len > 0: state.auth.verificationEmailHint = step.emailHint
  state.auth.verificationResendAt = monotonicMs() + float(step.resendAfterSeconds) * 1000.0
  updateVerificationCountdown(state)
  if state.auth.verificationSecondsLeft > 0 and verificationTimer == 0:
    verificationTimer = everySecond(proc() =
      updateVerificationCountdown(state)
      redraw(kxi))


proc backToSignIn*(state: AppState) =
  state.auth.error = ""
  state.auth.notice = ""
  leaveVerification(state)


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
  clearChatMetadata(state)
  inc state.chatNavigationEpoch
  inc state.jobObservationEpoch
  clearOperations(state)
  state.auth.authenticated = false
  clearWorkflowDraft(state)
  state.extensionCatalog = nil
  state.extensionBusy = false
  state.extensionError = ""
  state.plugins.setLen(0)
  state.connectionKey = ""
  state.clearExtensionDrafts()
  state.datasetText = ""
  state.datasetApiKey = ""
  state.tools.setLen(0)
  state.commandPaletteOpen = false
  state.auth.userId = ""
  state.auth.email = ""
  state.auth.displayName = ""
  state.auth.role = ""
  state.auth.csrfToken = ""
  state.auth.sessionId = ""
  state.auth.expiresAt = ""
  state.auth.passwordDraft = ""
  state.auth.newPasswordDraft = ""
  state.auth.resetToken = ""
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
  if state.currentChatId != chatId:
    clearWorkflowDraft(state)
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
        jobId: item.jobId,
        role: role,
        content: item.content,
        cards: @[],
        references: parseAnswerReferences(item.references)
      )
    )

    inc state.nextMessageId

  let outstanding = historyJobForRestore(history)
  if outstanding.jobId.len > 0:
    state.run = RunState(
      active: true,
      request: "",
      jobId: outstanding.jobId,
      status: outstanding.status,
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

  let context = beginNavigation(state)

  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  try:
    let history = await getChatHistory(chatId)
    if not matchesNavigation(state, context):
      return
    applyHistory(state, chatId, history)

    # Read-only recovery: opening/reloading a chat must never POST its task.
    let pending = await readServerSubmission(state.auth.userId, chatId)
    if not matchesNavigation(state, context): return
    if pending.identity.len > 0:
      state.run = RunState(active: true, request: pending.message, status: "submission_unknown",
        workflowContract: pending.workflowContract)
      showToast(state, "An earlier request is unconfirmed. Check the saved submission before sending another.")
      return

    if (
      state.run.active and
      state.run.jobId.len > 0 and
      state.run.status in restorableJobStates
    ):
      discard resumeBackendJob(
        state
      )

  except CatchableError:
    if matchesNavigation(state, context):
      state.auth.error = "Could not load this chat right now."
  finally:
    if matchesNavigation(state, context):
      state.auth.loading = false

  redraw(kxi)


proc loadChats*(
  state: AppState
) {.async.} =
  if not state.auth.authenticated:
    return

  let context = navigationContext(state)
  let remoteChats = await listChats()
  if not matchesNavigation(state, context):
    return

  state.chats.setLen(0)

  for remote in remoteChats:
    state.chats.add(
      ChatItem(
        chatId: remote.chatId,
        title: remote.title,
        updatedAt: remote.updatedAt,
        createdAt: remote.createdAt, pinned: remote.pinned
      )
    )

  if state.currentChatId.len == 0:
    if state.chats.len > 0:
      await loadChatHistory(state, state.chats[0].chatId)
    else:
      let created = await createChat(state.auth.csrfToken)
      if not matchesNavigation(state, context):
        return

      state.chats.add(
        ChatItem(
          chatId: created.chatId,
          title: created.title,
          updatedAt: created.updatedAt,
          createdAt: created.createdAt, pinned: created.pinned
        )
      )

      applyHistory(state, created.chatId, @[])


proc resumeVerification(state: AppState, requestEpoch: int) {.async.} =
  ## After a reload, the server says whether this browser has a pending
  ## verification step and how long its wait still is.
  try:
    let step = await verificationStatus()
    if not matchesAuthRequest(state, requestEpoch): return
    if step.pending:
      enterVerification(state, step)
    elif step.verified:
      state.auth.notice = "Email verified. You can sign in now."
  except CatchableError:
    discard # The sign-in form stays usable; a later sign-in resumes the step.


proc bootstrapApplication*(
  state: AppState
) {.async.} =
  let requestEpoch = beginAuthRequest(state)
  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  let verifyToken = ($browserQueryParam(cstring"verify_token")).strip()
  let resetToken = ($browserQueryParam(cstring"reset_token")).strip()

  if verifyToken.len > 0:
    try:
      await verifyEmail(verifyToken)
      if not matchesAuthRequest(state, requestEpoch): return
      state.auth.notice = "Email verified. You can sign in now."
      clearBrowserQuery()
    except CatchableError as exc:
      if matchesAuthRequest(state, requestEpoch): state.auth.error = exc.msg

  if resetToken.len > 0:
    state.auth.mode = amResetPassword
    state.auth.resetToken = resetToken

  try:
    let auth = await me()
    if not matchesAuthRequest(state, requestEpoch): return
    applyAuth(state, auth)
    # The header shows the active model and dataset from the owner's catalog.
    discard refreshExtensions(state)
    await loadChats(state)
  except CatchableError as exc:
    if matchesAuthRequest(state, requestEpoch):
      clearAuthenticatedState(state)
      if exc.msg.startsWith("HTTP 401"):
        if verifyToken.len == 0 and resetToken.len == 0:
          await resumeVerification(state, requestEpoch)
      else:
        state.auth.error = "Your session could not be checked right now. Check the connection and reload."

  if not matchesAuthRequest(state, requestEpoch): return
  state.auth.checked = true
  state.auth.loading = false
  redraw(kxi)


proc loginApplication*(
  state: AppState
) {.async.} =
  if state.auth.loading: return
  let email = state.auth.emailDraft.strip()
  let password = state.auth.passwordDraft

  if email.len == 0 or password.len == 0:
    state.auth.error = "Email and password are required."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  let requestEpoch = beginAuthRequest(state)
  redraw(kxi)

  try:
    let auth = await login(email, password)
    if not matchesAuthRequest(state, requestEpoch): return
    applyAuth(state, auth)
    state.auth.passwordDraft = ""
    state.auth.notice = ""
    discard refreshExtensions(state)
    await loadChats(state)
  except EmailNotVerified as exc:
    if matchesAuthRequest(state, requestEpoch):
      state.auth.passwordDraft = ""
      state.auth.notice = exc.msg
      enterVerification(state, exc.step)
  except CatchableError as exc:
    if matchesAuthRequest(state, requestEpoch): state.auth.error = exc.msg
  finally:
    if matchesAuthRequest(state, requestEpoch): state.auth.loading = false

  redraw(kxi)


proc registerApplication*(
  state: AppState
) {.async.} =
  if state.auth.loading: return
  let displayName = state.auth.displayNameDraft.strip()
  let email = state.auth.emailDraft.strip()
  let password = state.auth.passwordDraft

  if displayName.len == 0 or email.len == 0 or password.len == 0:
    state.auth.error = "Display name, email and password are required."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  let requestEpoch = beginAuthRequest(state)
  redraw(kxi)

  try:
    let step = await register(displayName, email, password)
    if not matchesAuthRequest(state, requestEpoch): return
    state.auth.passwordDraft = ""
    state.auth.notice =
      if step.mailFailed: "Account created, but the verification email could not be sent. Send a new one when the wait ends."
      else: "Account created. Check your email for the verification link."
    enterVerification(state, step)
  except CatchableError as exc:
    if matchesAuthRequest(state, requestEpoch): state.auth.error = exc.msg
  finally:
    if matchesAuthRequest(state, requestEpoch): state.auth.loading = false

  redraw(kxi)


proc resendVerificationApplication*(
  state: AppState
) {.async.} =
  ## Asks the server for another email. The server decides whether the wait
  ## has passed; its answer (sent, or the time left) restarts the countdown.
  if state.auth.loading or state.auth.mode != amVerifyEmail: return

  state.auth.loading = true
  state.auth.error = ""
  state.auth.notice = ""
  let requestEpoch = beginAuthRequest(state)
  redraw(kxi)

  try:
    let step = await resendVerification()
    if not matchesAuthRequest(state, requestEpoch): return
    if step.tooSoon:
      state.auth.notice = "Please wait before sending another email."
    elif step.mailFailed:
      state.auth.error = "The verification email could not be sent. Try again when the wait ends."
    else:
      state.auth.notice = "A new verification email was sent. Earlier links still work until they expire."
    enterVerification(state, step)
  except CatchableError as exc:
    if matchesAuthRequest(state, requestEpoch):
      if exc.msg.startsWith("HTTP 404"):
        leaveVerification(state)
        state.auth.notice = "No account is waiting for verification in this browser. Sign in to continue."
      else:
        state.auth.error = exc.msg
  finally:
    if matchesAuthRequest(state, requestEpoch): state.auth.loading = false

  redraw(kxi)


proc forgotPasswordApplication*(
  state: AppState
) {.async.} =
  if state.auth.loading: return
  let email = state.auth.emailDraft.strip()

  if email.len == 0:
    state.auth.error = "Enter your email first."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  let requestEpoch = beginAuthRequest(state)
  redraw(kxi)

  try:
    await forgotPassword(email)
    if not matchesAuthRequest(state, requestEpoch): return
    state.auth.notice = "If the account exists, a password reset email was sent."
    state.auth.mode = amLogin
  except CatchableError as exc:
    if matchesAuthRequest(state, requestEpoch): state.auth.error = exc.msg
  finally:
    if matchesAuthRequest(state, requestEpoch): state.auth.loading = false

  redraw(kxi)


proc resetPasswordApplication*(
  state: AppState
) {.async.} =
  if state.auth.loading: return
  if state.auth.resetToken.len == 0 or state.auth.newPasswordDraft.len == 0:
    state.auth.error = "A reset token and new password are required."
    redraw(kxi)
    return

  state.auth.loading = true
  state.auth.error = ""
  let requestEpoch = beginAuthRequest(state)
  redraw(kxi)

  try:
    await resetPassword(state.auth.resetToken, state.auth.newPasswordDraft)
    if not matchesAuthRequest(state, requestEpoch): return
    state.auth.notice = "Password reset complete. Sign in with your new password."
    state.auth.resetToken = ""
    state.auth.newPasswordDraft = ""
    state.auth.mode = amLogin
    clearBrowserQuery()
  except CatchableError as exc:
    if matchesAuthRequest(state, requestEpoch): state.auth.error = exc.msg
  finally:
    if matchesAuthRequest(state, requestEpoch): state.auth.loading = false

  redraw(kxi)


proc logoutApplication*(
  state: AppState
) {.async.} =
  ## The workspace is cleared only after the server confirms the session
  ## ended. Otherwise the user stays signed in and can retry: clearing the
  ## screen would hide a session that may still be valid.
  if state.auth.loading: return
  if not state.auth.authenticated:
    clearAuthenticatedState(state)
    state.auth.checked = true
    state.auth.mode = amLogin
    redraw(kxi)
    return

  let requestEpoch = beginAuthRequest(state)
  let csrfToken = state.auth.csrfToken
  let ownerId = state.auth.userId
  state.auth.loading = true
  state.auth.error = ""
  redraw(kxi)

  var outcome = loUnconfirmed
  try:
    outcome = await logout(csrfToken)
  except CatchableError:
    outcome = loUnconfirmed

  if not matchesAuthRequest(state, requestEpoch): return
  state.auth.loading = false

  if outcome == loUnconfirmed:
    state.auth.error = "Sign-out was not confirmed by the server, so this session may still be active. Check the connection and sign out again."
    showToast(state, state.auth.error)
    redraw(kxi)
    return

  try:
    clearOwnerSubmissions(ownerId)
  except CatchableError:
    discard # Clearing the in-memory workspace must still proceed.
  clearAuthenticatedState(state)
  state.auth.checked = true
  state.auth.mode = amLogin
  state.auth.error = ""
  state.auth.notice = "Signed out."
  redraw(kxi)


proc createNewChat*(
  state: AppState
) {.async.} =
  if not state.auth.authenticated:
    return

  # Do not generate endless empty "New chat" rows.
  if (
    state.currentChatId.len > 0 and
    state.messages.len == 0 and
    not state.run.active
  ):
    discard beginNavigation(state)
    state.auth.loading = false
    state.activeView =
      viewChat

    redraw(kxi)
    return

  # A single foreground durable job is still the current
  # frontend contract. Don't detach its UI from its chat.
  if (
    state.run.active and
    state.run.status in [
      "submitting",
      "restoring",
      "pending",
      "processing",
      "waiting_approval",
      "approving",
      "rejecting"
    ]
  ):
    showToast(
      state,
      "Finish the current job before creating another chat."
    )

    redraw(kxi)
    return

  if state.chatActionId.len > 0:
    showToast(state, "Wait for the current chat change to finish.")
    redraw(kxi)
    return
  cancelChatMetadataRead(state)
  let context = beginNavigation(state)
  state.auth.loading = true
  try:
    let created =
      await createChat(
        state.auth.csrfToken
      )
    if not matchesNavigation(state, context): return
    cancelChatMetadataRead(state)

    state.chats.insert(
      ChatItem(
        chatId:
          created.chatId,

        title:
          created.title,

        updatedAt:
          created.updatedAt,
        createdAt: created.createdAt,
        pinned: created.pinned
      ),
      0
    )

    applyHistory(
      state,
      created.chatId,
      @[]
    )

    state.activeView =
      viewChat

    showToast(
      state,
      "New chat created."
    )

  except CatchableError:
    if matchesNavigation(state, context):
      showToast(state, "Could not create a new chat right now.")
  finally:
    if matchesNavigation(state, context): state.auth.loading = false

  redraw(kxi)



proc deleteChatApplication*(
  state: AppState,
  chatId: string
) {.async.} =
  if (
    not state.auth.authenticated or
    chatId.len == 0
  ):
    return

  if (
    chatId == state.currentChatId and
    state.run.active and
    state.run.status in [
      "submitting",
      "restoring",
      "pending",
      "processing",
      "waiting_approval",
      "approving",
      "rejecting"
    ]
  ):
    showToast(
      state,
      "Finish the current job before deleting this chat."
    )

    redraw(kxi)
    return

  if state.chatActionId.len > 0:
    showToast(state, "Wait for the current chat change to finish.")
    redraw(kxi)
    return
  cancelChatMetadataRead(state)
  let context = accountContext(state)
  try:
    await deleteChat(
      chatId,
      state.auth.csrfToken
    )
    if not matchesAccount(state, context): return
    cancelChatMetadataRead(state)

    let wasCurrent =
      chatId ==
      state.currentChatId

    var remaining:
      seq[ChatItem] =
        @[]

    for chat in state.chats:
      if chat.chatId != chatId:
        remaining.add(
          chat
        )

    state.chats =
      remaining

    if wasCurrent:
      if state.chats.len > 0:
        await loadChatHistory(
          state,
          state.chats[0].chatId
        )

      else:
        let navigation = beginNavigation(state)
        let created =
          await createChat(
            state.auth.csrfToken
          )
        if not matchesNavigation(state, navigation): return

        state.chats.add(
          ChatItem(
            chatId:
              created.chatId,

            title:
              created.title,

            updatedAt:
              created.updatedAt,
            createdAt: created.createdAt,
            pinned: created.pinned
          )
        )

        applyHistory(
          state,
          created.chatId,
          @[]
        )
        state.auth.loading = false

    showToast(
      state,
      "Chat deleted."
    )

  except CatchableError:
    if matchesAccount(state, context):
      showToast(state, "Could not delete this chat right now.")

  redraw(kxi)


proc selectChat*(
  state: AppState,
  chatId: string
) {.async.} =
  if not state.auth.authenticated: return
  if chatId == state.currentChatId:
    discard beginNavigation(state)
    state.auth.loading = false
    state.activeView = viewChat
    redraw(kxi)
    return

  if (
    state.run.active and
    state.run.status in [
      "submitting",
      "restoring",
      "pending",
      "processing",
      "waiting_approval",
      "approving",
      "rejecting"
    ]
  ):
    showToast(
      state,
      "Finish the current job before switching chats."
    )
    redraw(kxi)
    return

  let context = accountContext(state)
  await loadChatHistory(state, chatId)
  if not matchesAccount(state, context) or state.currentChatId != chatId: return
  state.activeView = viewChat
  redraw(kxi)


proc loadAuthSessions*(
  state: AppState
) {.async.} =
  discard loadAccountPreferences(state)
  await refreshAccountSessions(state)


proc revokeAuthSession*(
  state: AppState,
  sessionId: string
) {.async.} =
  if not state.auth.authenticated or sessionId.len == 0 or
      state.sessionsBusy or state.sessionActionBusy or state.sessionsNeedRefresh:
    return

  let context = beginSessionsRequest(state)
  state.sessionActionBusy = true
  state.sessionsError = ""
  state.sessionsNotice = ""
  redraw(kxi)
  var confirmed = false
  try:
    await revokeSession(state.auth.csrfToken, sessionId)
    if not matchesSessionsRequest(state, context): return

    if sessionId == state.auth.sessionId:
      clearAuthenticatedState(state)
      state.auth.checked = true
      state.auth.mode = amLogin
      state.auth.notice = "Current session revoked."
    else:
      state.sessionsNotice = "Session revoked."
      confirmed = true
  except CatchableError:
    if matchesSessionsRequest(state, context):
      state.sessionsError = "Session revocation was not confirmed. Refresh sessions to check their saved state."
      state.sessionsNeedRefresh = true
  finally:
    if matchesSessionsRequest(state, context): state.sessionActionBusy = false
  if confirmed and matchesSessionsRequest(state, context): await refreshAccountSessions(state)

  redraw(kxi)
