## Feedback on a task's result (FR-089).
##
## The user's critique, with an optional correct result, is saved by the
## backend for review and linked to the task. It never changes the task.

import std/[json, strutils, uri]

proc randomUuid(): cstring {.importjs: "globalThis.crypto.randomUUID()".}

proc newFeedbackIdentity*(): string =
  ## One identity per note: resending the same note cannot save it twice.
  $randomUuid()

proc feedbackPath*(jobId: string): string =
  if jobId.len == 0:
    raise newException(ValueError, "A saved task is required.")
  "/api/v1/jobs/" & encodeUrl(jobId, usePlus = false) & "/feedback"

proc feedbackPayload*(identity, note, correction: string): JsonNode =
  let note = note.strip()
  let correction = correction.strip()
  if identity.len == 0:
    raise newException(ValueError, "A feedback identity is required.")
  if note.len == 0:
    raise newException(ValueError, "Describe what was wrong.")
  result = %*{"submission_id": identity, "note": note}
  if correction.len > 0:
    result["correction"] = %correction
