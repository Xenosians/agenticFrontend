import std/[json, uri]
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

proc cancelPath*(jobId: string): string =
  if jobId.len == 0:
    raise newException(ValueError, "A saved job is required.")
  "/api/v2/jobs/" & encodeUrl(jobId, usePlus = false) & "/cancel"

proc canCancelJob*(state: AppState): bool =
  ## Only a queued or running request can be stopped; one waiting for
  ## approval is decided by approve or reject instead.
  state.auth.authenticated and state.auth.csrfToken.len > 0 and
    state.run.active and state.run.jobId.len > 0 and
    state.run.status in ["pending", "processing"]

proc decisionPayload*(approvalId: string, confirmName = ""): JsonNode =
  if approvalId.len == 0:
    raise newException(ValueError, "The displayed saved proposal is required.")
  result = %*{"approval_id": approvalId}
  # Only a destructive approval carries the typed name; the server checks it.
  if confirmName.len > 0:
    result["confirm_name"] = %confirmName

proc canDecideJob*(state: AppState): bool =
  state.auth.authenticated and state.auth.sessionId.len > 0 and
    state.auth.csrfToken.len > 0 and state.currentChatId.len > 0 and
    state.run.active and state.run.jobId.len > 0 and
    state.run.status == "waiting_approval" and reviewableProposal(state.run.proposal)

proc canApproveJob*(state: AppState, typed: string): bool =
  ## A destructive action is approved only once its exact name is typed (rejecting needs nothing).
  canDecideJob(state) and typed == state.run.proposal.confirmationText

proc captureDecisionContext*(state: AppState): JobDecisionContext =
  JobDecisionContext(sessionId: state.auth.sessionId, chatId: state.currentChatId,
    jobId: state.run.jobId, approvalId: state.run.proposal.approvalId)

proc matchesDecisionContext*(state: AppState, context: JobDecisionContext): bool =
  state.auth.authenticated and state.run.active and
    context.sessionId.len > 0 and context.chatId.len > 0 and
    context.jobId.len > 0 and context.approvalId.len > 0 and
    state.auth.sessionId == context.sessionId and state.currentChatId == context.chatId and
    state.run.jobId == context.jobId and state.run.proposal.approvalId == context.approvalId
