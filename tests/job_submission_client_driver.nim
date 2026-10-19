## Test driver for the production HTTP client; injected fetch stays inside Node.
import std/[asyncjs, json]
import ../src/api/client
import ../src/api/job_submission

proc submitJobForTest(chat, message, csrf, identity: cstring): Future[cstring] {.async, exportc.} =
  try:
    let response = await createJob($chat, $message, $csrf, $identity)
    return cstring($(%*{"kind": "acknowledged", "job_id": response.jobId,
      "status": response.status, "submission_id": response.submissionId}))
  except JobCreateRejectedError:
    return cstring("{\"kind\":\"rejected\"}")
  except CatchableError:
    return cstring("{\"kind\":\"unknown\"}")

proc prepareJobForTest(owner, chat, message: cstring): cstring {.exportc.} =
  try:
    let saved = prepareSubmission($owner, $chat, $message)
    return cstring($(%*{"kind": "prepared", "submission_id": saved.identity}))
  except CatchableError:
    return cstring("{\"kind\":\"storage_error\"}")

proc readJobForTest(identity: cstring): Future[cstring] {.async, exportc.} =
  try:
    let response = await getJob($identity)
    return cstring($(%*{"kind": "read", "status": response.status}))
  except CatchableError:
    return cstring("{\"kind\":\"read_interrupted\"}")
