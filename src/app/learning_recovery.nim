## One frozen unconfirmed candidate start per owner/server/browser tab.
## Loading or clearing it never submits a training job.
import std/json
import learning
import request_recovery

const namespace = "janus.pending-learning-run.v1"
const storageError = "Learning recovery storage could not be confirmed. Restore browser storage and reconcile the previous start before another run."

proc record(owner, backend: string, request: JsonNode): JsonNode =
  validateLearningRunRequest(request)
  %*{"schema": "pending-learning-run.v1", "owner": owner, "backend": backend, "request": request}

proc parsePendingLearningRun*(data: JsonNode, owner, backend: string): JsonNode =
  if data.kind != JObject or data.len != 4 or data{"schema"}.getStr("") != "pending-learning-run.v1" or
      data{"owner"}.getStr("") != owner or data{"backend"}.getStr("") != backend or not data.hasKey("request"):
    raise newException(ValueError, "Stored learning recovery does not match this account and server. Reconcile it before another run.")
  validateLearningRunRequest(data["request"])
  data["request"].copy

proc readPendingLearningRun*(owner, backend: string): JsonNode =
  let raw = recoveryStorage(namespace, owner, backend, "load", errorMessage=storageError)
  if raw.kind != JNull: result = parsePendingLearningRun(parseJson(raw.getStr), owner, backend)

proc rememberPendingLearningRun*(owner, backend: string, request: JsonNode) =
  discard recoveryStorage(namespace, owner, backend, "save", $record(owner, backend, request), storageError)

proc acknowledgePendingLearningRun*(owner, backend: string, request: JsonNode) =
  discard recoveryStorage(namespace, owner, backend, "clear", $record(owner, backend, request), storageError)
