import std/[json, unittest]
import ../src/app/credential_handover
import ../src/app/state
import ../src/app/types

proc approvedAccount(credential: JsonNode): JsonNode =
  %*{"status": "completed",
    "proposed_tool": {"tool": "account_create", "arguments": {"given_name": "Jo", "family_name": "Doe"},
      "approval_id": "approval"},
    "result": {"approval_execution": {"approval_id": "approval", "execution_status": "succeeded",
      "approval_status": "approved",
      "result": {"ok": true, "user_id": "jdoe", "credential_id": credential}, "error": nil}}}

suite "temporary password hand-over":
  test "the request path names the escaped task and credential":
    check revealPath("job", "cred") == "/api/v2/jobs/job/credentials/cred/reveal"
    check revealPath("job/x", "c d") == "/api/v2/jobs/job%2Fx/credentials/c%20d/reveal"
    for (job, credential) in [("", "cred"), ("job", "")]:
      expect ValueError:
        discard revealPath(job, credential)

  test "only the user's own password is sent":
    check revealPayload("correct horse") == %*{"password": "correct horse"}
    expect ValueError:
      discard revealPayload("")

  test "an approved account names the credential its result saved":
    check handoverCredential(approvedAccount(%"cred-1")) == "cred-1"

  test "the onboarding account's password stays offered after its ticket step":
    for ticketStatus in ["succeeded", "failed"]:
      let workflow = approvedAccount(%"cred-1")
      let account = workflow["result"]["approval_execution"]
      workflow["status"] = %(if ticketStatus == "succeeded": "completed" else: "failed")
      workflow["result"]["approval_history"] = %*[{"proposal": {"tool": "account_create"}, "execution": account}]
      workflow["result"]["approval_execution"] = %*{"approval_id": "ticket", "execution_status": ticketStatus,
        "approval_status": (if ticketStatus == "succeeded": "approved" else: "failed"),
        "result": {"ok": ticketStatus == "succeeded", "ticket_key": "IT-1"}}
      check handoverCredential(workflow) == "cred-1"
    let failedAccount = approvedAccount(%"cred-1")
    failedAccount["result"]["approval_execution"]["execution_status"] = %"failed"
    failedAccount["result"]["approval_execution"]["approval_status"] = %"failed"
    failedAccount["result"]["approval_history"] = %*[{"execution": failedAccount["result"]["approval_execution"]}]
    check handoverCredential(failedAccount) == ""

  test "no credential, an unfinished outcome or a malformed one offers nothing":
    check handoverCredential(approvedAccount(newJNull())) == ""
    check handoverCredential(approvedAccount(%7)) == ""
    let rejected = approvedAccount(%"cred-1")
    rejected["status"] = %"denied"
    rejected["result"]["approval_execution"]["execution_status"] = %"rejected"
    rejected["result"]["approval_execution"]["approval_status"] = %"rejected"
    check handoverCredential(rejected) == ""
    check handoverCredential(%*{"status": "completed"}) == ""

  test "a revealed password is read only from the server's answer":
    let answer = %*{"credential_id": "cred-1", "temporary_password": "Temp-Secret!42",
      "subject": {"kind": "directory_account", "user_id": "jdoe"}, "must_change_at_first_sign_in": true}
    let revealed = parseRevealed(answer)
    check revealed.password == "Temp-Secret!42"
    check revealed.subject == "jdoe"
    for broken in [%*{"credential_id": "cred-1"}, %*{"temporary_password": 7}, newJNull()]:
      expect ValueError:
        discard parseRevealed(broken)

  test "a job read keeps the hand-over a reloaded history turn named":
    let state = AppState()
    state.addAssistantMessage("Saved answer", jobId = "job-1", handoverCredentialId = "cred-1")
    state.restoreAssistantJobMessage("job-1", "Fresh answer", @[])
    check state.messages[0].content == "Fresh answer"
    check state.messages[0].handoverCredentialId == "cred-1"
    state.restoreAssistantJobMessage("job-2", "New answer", @[], handoverCredentialId = "cred-2")
    check state.messages[1].handoverCredentialId == "cred-2"
