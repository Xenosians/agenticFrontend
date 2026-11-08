## One-time hand-over of an approved request's temporary password.
##
## A new account's own mailbox does not exist yet, so its first password is
## shown once, here, to the person who asked for it, after they confirm their
## own Janus password. The backend decides whether it may be revealed; this
## module only builds the request and reads the answer.

import std/[json, uri]

type
  RevealedCredential* = object
    password*, subject*: string

proc revealPath*(jobId, credentialId: string): string =
  if jobId.len == 0 or credentialId.len == 0:
    raise newException(ValueError, "A saved task and credential are required.")
  "/api/v2/jobs/" & encodeUrl(jobId, usePlus = false) & "/credentials/" &
    encodeUrl(credentialId, usePlus = false) & "/reveal"

proc revealPayload*(password: string): JsonNode =
  if password.len == 0:
    raise newException(ValueError, "Enter your Janus password.")
  %*{"password": password}

proc succeededCredential(execution: JsonNode): string =
  if execution.isNil or execution.kind != JObject or
      execution{"execution_status"}.getStr() != "succeeded" or
      execution{"approval_status"}.getStr() != "approved":
    return ""
  let credential = execution{"result", "credential_id"}
  if credential.isNil or credential.kind != JString:
    return ""
  credential.getStr()

proc handoverCredential*(data: JsonNode): string =
  ## The credential a request's approved, succeeded action saved, or "".
  ## The onboarding workflow keeps its account step in approval_history, so
  ## the new account's password is still offered after the ticket step. The
  ## backend applies the same rule and decides.
  if data.isNil or data.kind != JObject or data{"result"}.isNil or data["result"].kind != JObject:
    return ""
  result = succeededCredential(data["result"]{"approval_execution"})
  let history = data["result"]{"approval_history"}
  if result.len == 0 and not history.isNil and history.kind == JArray:
    for step in history.items:
      if step.kind == JObject:
        result = succeededCredential(step{"execution"})
        if result.len > 0:
          return

proc parseRevealed*(data: JsonNode): RevealedCredential =
  if data.isNil or data.kind != JObject or data{"temporary_password"}.isNil or
      data{"temporary_password"}.kind != JString or data{"temporary_password"}.getStr().len == 0:
    raise newException(ValueError, "The server did not return a temporary password.")
  let subject = data{"subject"}
  let name =
    if subject.isNil or subject.kind != JObject: ""
    elif subject{"user_id"}.kind == JString: subject{"user_id"}.getStr()
    else: subject{"email"}.getStr()
  RevealedCredential(password: data["temporary_password"].getStr(), subject: name)
