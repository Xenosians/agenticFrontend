## Exercise the production submission coordinator without a browser or provider.
## Node supplies storage/fetch and suppresses painting; application state and
## local preparation/acknowledgement paths remain the production code.
import std/[asyncjs, json]
import karax/karax
import ../src/app/[types, state, backend_bridge, workflow_request]

var app: AppState

proc initializeSubmissionFlowForTest(draft, operations: cstring) {.exportc.} =
  kxi = KaraxInstance()
  app = initAppState()
  app.auth.authenticated = true
  app.auth.userId = "owner-a"
  app.auth.sessionId = "session-a"
  app.auth.csrfToken = "fixture-csrf"
  app.currentChatId = "chat-a"
  app.composerDraft = $draft
  for step in parseJson($operations):
    app.workflowSteps.add(WorkflowStep(id: step["id"].getStr,
      capability: step["capability"].getStr,
      groundedArguments: step["grounded_arguments"],
      afterSuccessOf: (if step["after_success_of"].kind == JNull: ""
                      else: step["after_success_of"].getStr)))

proc setSubmissionDraftForTest(draft: cstring) {.exportc.} =
  setComposerDraft(app, $draft)

proc submissionFlowSnapshotForTest(): cstring {.exportc.} =
  cstring($(%*{"draft": app.composerDraft, "status": app.run.status,
    "toast": app.toastMessage, "job_id": app.run.jobId}))

proc submitFlowForTest(message: cstring, recovering: bool): Future[void] {.async, exportc.} =
  await submitBackendJob(app, $message, recovering)
