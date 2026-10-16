import std/uri
import types
import ../api/tool_proposal

type
  JobDecision* = enum
    jdApprove, jdReject
  JobDecisionContext* = object
    sessionId*, chatId*, jobId*, approvalId*: string

proc decisionPath*(jobId: string, decision: JobDecision): string =
  if jobId.len == 0:
    raise newException(ValueError, "A saved job is required.")
  "/api/v2/jobs/" & encodeUrl(jobId, usePlus = false) &
    (if decision == jdApprove: "/approve" else: "/reject")

proc decisionStatus*(decision: JobDecision): string =
  if decision == jdApprove: "approving" else: "rejecting"

proc canDecideJob*(state: AppState): bool =
  state.auth.authenticated and state.auth.sessionId.len > 0 and
    state.auth.csrfToken.len > 0 and state.currentChatId.len > 0 and
    state.run.active and state.run.jobId.len > 0 and
    state.run.status == "waiting_approval" and reviewableProposal(state.run.proposal)

proc captureDecisionContext*(state: AppState): JobDecisionContext =
  JobDecisionContext(sessionId: state.auth.sessionId, chatId: state.currentChatId,
    jobId: state.run.jobId, approvalId: state.run.proposal.approvalId)

proc matchesDecisionContext*(state: AppState, context: JobDecisionContext): bool =
  state.auth.authenticated and state.run.active and
    context.sessionId.len > 0 and context.chatId.len > 0 and
    context.jobId.len > 0 and context.approvalId.len > 0 and
    state.auth.sessionId == context.sessionId and state.currentChatId == context.chatId and
    state.run.jobId == context.jobId and state.run.proposal.approvalId == context.approvalId
