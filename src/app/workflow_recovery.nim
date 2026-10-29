## One owner-scoped unconfirmed run per browser tab. Recovery never dispatches;
## only an explicit retry sends the original immutable request again.
import std/json
import workflows
import request_recovery

proc record(owner, backend: string, pending: WorkflowPendingRun): JsonNode =
  %*{"schema": "pending-workflow-run.v1", "backend": backend,
    "owner": owner, "workflow": workflowSnapshot(pending.draft), "request": pending.payload}

proc call(owner, backend, action: string, payload = ""): JsonNode =
  if owner.len == 0: raise newException(ValueError, "A signed-in owner is required for workflow recovery.")
  recoveryStorage("janus.pending-workflow-run.v1", owner, backend, action, payload,
    "Workflow recovery storage could not be confirmed. Keep this run unchanged and restore browser storage before retrying.")

proc parsePendingWorkflow*(data: JsonNode, backend, owner: string): WorkflowPendingRun =
  if data == nil or data.kind != JObject or data.len != 5 or
      data{"schema"}.getStr("") != "pending-workflow-run.v1" or
      data{"backend"}.getStr("") != backend or data{"owner"}.getStr("") != owner or
      not data.hasKey("workflow") or not data.hasKey("request"):
    raise newException(ValueError, "Stored workflow recovery does not match this account and server. Reconcile it before another run.")
  result.draft = parseWorkflow(data["workflow"])
  let request = data["request"]
  if request.kind != JObject or request.len != 3 or not request.hasKey("submission_id") or
      not request.hasKey("message") or request["submission_id"].kind != JString or
      request["submission_id"].getStr.len == 0 or request["message"].kind != JString:
    raise newException(ValueError, "Stored workflow recovery is incomplete. Reconcile it before another run.")
  if request != runPayload(result.draft, request["submission_id"].getStr, request["message"].getStr):
    raise newException(ValueError, "Stored workflow recovery changed its original request. Reconcile it before another run.")
  result.payload = request.copy

proc readPendingWorkflow*(owner, backend: string): WorkflowPendingRun =
  let raw = call(owner, backend, "load")
  if raw.kind != JNull:
    result = parsePendingWorkflow(parseJson(raw.getStr), backend, owner)

proc rememberPendingWorkflow*(owner, backend: string, pending: WorkflowPendingRun) =
  discard call(owner, backend, "save", $record(owner, backend, pending))

proc acknowledgePendingWorkflow*(owner, backend: string, pending: WorkflowPendingRun) =
  discard call(owner, backend, "clear", $record(owner, backend, pending))
