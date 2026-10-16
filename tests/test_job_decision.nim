import std/[json, unittest]
import ../src/app/[types, state, job_decision]

proc awaitingDecision(): AppState =
  result = initAppState()
  result.auth.authenticated = true
  result.auth.sessionId = "session"
  result.auth.csrfToken = "csrf"
  result.currentChatId = "chat"
  result.run = RunState(active: true, jobId: "job", status: "waiting_approval",
    proposal: ToolProposal(tool: "workspace_mkdir", arguments: %*{"relative_path": "reviewed"}, approvalId: "approval"))

suite "governed action decisions":
  test "both decisions use the versioned job endpoint and escaped identity":
    check decisionPath("job", jdApprove) == "/api/v2/jobs/job/approve"
    check decisionPath("job", jdReject) == "/api/v2/jobs/job/reject"
    check decisionPath("job/other", jdReject) == "/api/v2/jobs/job%2Fother/reject"
    expect ValueError:
      discard decisionPath("", jdReject)
  test "only an authenticated reviewable waiting action permits either decision":
    let app = awaitingDecision()
    check canDecideJob(app)
    for decision in [jdApprove, jdReject]:
      app.run.status = decisionStatus(decision)
      check not canDecideJob(app)
    for status in ["completed", "denied", "failed", "outcome_unknown", "restoring"]:
      app.run.status = status
      check not canDecideJob(app)
    app.run.status = "waiting_approval"
    app.auth.csrfToken = ""
    check not canDecideJob(app)
    app.auth.csrfToken = "csrf"
    app.run.proposal.arguments = nil
    check not canDecideJob(app)
  test "late decision responses cannot cross account chat job or proposal boundaries":
    let app = awaitingDecision()
    let context = captureDecisionContext(app)
    check matchesDecisionContext(app, context)
    app.auth.authenticated = false
    check not matchesDecisionContext(app, context)
    app.auth.authenticated = true
    app.auth.sessionId = "other-session"
    check not matchesDecisionContext(app, context)
    app.auth.sessionId = context.sessionId
    app.currentChatId = "other-chat"
    check not matchesDecisionContext(app, context)
    app.currentChatId = context.chatId
    app.run.jobId = "other-job"
    check not matchesDecisionContext(app, context)
    app.run.jobId = context.jobId
    app.run.proposal.approvalId = "other-approval"
    check not matchesDecisionContext(app, context)
