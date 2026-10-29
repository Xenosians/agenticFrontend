import std/unittest
import ../src/app/[types, state, request_context]
import ../src/app/workflows
import std/json

proc signedIn(): AppState =
  result = initAppState()
  result.auth.authenticated = true
  result.auth.userId = "account-a"
  result.auth.sessionId = "session-a"

suite "asynchronous account and chat boundaries":
  test "old account and session responses cannot populate a replacement account":
    let app = signedIn()
    let request = accountContext(app)
    check matchesAccount(app, request)
    app.auth.authenticated = false
    check not matchesAccount(app, request)
    app.auth.authenticated = true
    app.auth.userId = "account-b"
    check not matchesAccount(app, request)
    app.auth.userId = "account-a"
    app.auth.sessionId = "new-session-for-same-account"
    check not matchesAccount(app, request)
  test "latest navigation wins when history responses finish in reverse order":
    let app = signedIn()
    let firstChat = beginNavigation(app)
    let secondChat = beginNavigation(app)
    check matchesNavigation(app, secondChat)
    app.currentChatId = "second-chat"
    check not matchesNavigation(app, firstChat)
    check app.currentChatId == "second-chat"
    discard beginNavigation(app) # Creating/selecting another chat cancels both.
    check not matchesNavigation(app, secondChat)
  test "new navigation cancels an older list's automatic initial chat selection":
    let app = signedIn()
    let list = navigationContext(app)
    check matchesNavigation(app, list)
    let createdChat = beginNavigation(app)
    check not matchesNavigation(app, list)
    check matchesNavigation(app, createdChat)
    app.auth.sessionId = "other-session"
    check not matchesNavigation(app, createdChat)
  test "sign out invalidates unfinished login or bootstrap responses before they apply":
    let app = signedIn()
    let login = beginAuthRequest(app)
    check matchesAuthRequest(app, login)
    let signOut = beginAuthRequest(app)
    app.auth.authenticated = false
    check not matchesAuthRequest(app, login)
    check matchesAuthRequest(app, signOut)
    let newLogin = beginAuthRequest(app)
    check not matchesAuthRequest(app, signOut)
    check matchesAuthRequest(app, newLogin)

  test "owner reset clears workflow canvas and pending recovery state and invalidates requests":
    let app = signedIn()
    let request = beginWorkflowRequest(app)
    app.automationPendingRun = WorkflowPendingRun(payload: %*{"submission_id": "old-owner-request"})
    app.automationRecoveryError = "old recovery"
    app.automationSaving = true
    clearOperations(app)
    check app.automationPendingRun.payload == nil
    check app.automationRecoveryError.len == 0
    check not app.automationSaving
    check not matchesWorkflowRequest(app, request)

  test "learning reads cannot invalidate starts and owner reset clears frozen state":
    let app = signedIn()
    let mutation = beginLearningMutationRequest(app)
    discard beginLearningRunsRequest(app)
    discard beginLearningRunsRequest(app)
    check matchesLearningMutationRequest(app, mutation)
    app.learningPendingRequest = %*{"submission_id": "old"}
    app.learningRecoveryChecked = true
    app.learningRecoveryError = "old error"
    app.learningStarting = true
    clearOperations(app)
    check not matchesLearningMutationRequest(app, mutation)
    check app.learningPendingRequest == nil
    check not app.learningRecoveryChecked
    check not app.learningStarting
    check app.learningRecoveryError == ""
