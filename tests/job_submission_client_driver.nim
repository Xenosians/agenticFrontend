## Test driver for the production HTTP client; injected fetch stays inside Node.
import std/[asyncjs, json]
import ../src/api/client
import ../src/api/auth_client
import ../src/api/submission_intents

proc submitJobForTest(chat, message, csrf, identity: cstring, workflow: cstring = "null"): Future[cstring] {.async, exportc.} =
  try:
    let response = await createJob($chat, $message, $csrf, $identity, parseJson($workflow))
    return cstring($(%*{"kind": "acknowledged", "job_id": response.jobId,
      "status": response.status, "submission_id": response.submissionId}))
  except JobCreateRejectedError:
    return cstring("{\"kind\":\"rejected\"}")
  except CatchableError:
    return cstring("{\"kind\":\"unknown\"}")

proc intentJson(slot: SubmissionIntent): JsonNode =
  %*{"id": slot.id, "state": slot.state,
    "request": (if slot.request == nil: newJNull() else: slot.request),
    "context": (if slot.context == nil: newJNull() else: slot.context),
    "receipt": (if slot.receipt == nil: newJNull() else: slot.receipt)}

proc readIntentForTest(owner, kind, target: cstring): Future[cstring] {.async, exportc.} =
  try:
    let saved = await readIntent($owner, $kind, $target)
    return cstring($(%*{"ok": true, "intent": intentJson(saved)}))
  except CatchableError as exc:
    return cstring($(%*{"ok": false, "error": exc.msg}))

proc reserveIntentForTest(owner, kind, target, payload: cstring): Future[cstring] {.async, exportc.} =
  try:
    let saved = await reserveIntent($owner, $kind, $target, parseJson($payload), "fixture-csrf")
    return cstring($(%*{"ok": true, "intent": intentJson(saved)}))
  except CatchableError as exc:
    return cstring($(%*{"ok": false, "error": exc.msg}))

proc acknowledgeIntentForTest(owner, kind, target, identity: cstring): Future[cstring] {.async, exportc.} =
  try:
    let saved = await acknowledgeIntent($owner, $kind, $target, $identity, "fixture-csrf")
    return cstring($(%*{"ok": true, "intent": intentJson(saved)}))
  except CatchableError as exc:
    return cstring($(%*{"ok": false, "error": exc.msg}))

proc cachedIntentForTest(owner, kind, target: cstring): cstring {.exportc.} =
  try:
    return cstring($(%*{"ok": true, "intent": intentJson(cachedIntent($owner, $kind, $target))}))
  except CatchableError as exc:
    return cstring($(%*{"ok": false, "error": exc.msg}))

proc clearIntentForTest(owner: cstring) {.exportc.} = clearIntentCache($owner)

proc logoutForTest(csrf: cstring): Future[cstring] {.async, exportc.} =
  try:
    return cstring($(await logout($csrf)))
  except CatchableError:
    return cstring("raised")

proc readJobForTest(identity: cstring): Future[cstring] {.async, exportc.} =
  try:
    let response = await getJob($identity)
    return cstring($(%*{"kind": "read", "status": response.status}))
  except CatchableError:
    return cstring("{\"kind\":\"read_interrupted\"}")
