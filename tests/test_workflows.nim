import std/[json, strutils, unittest]
import ../src/app/workflow_request
import ../src/app/workflows
import ../src/app/workflow_recovery

let workflowId = "e".repeat(32)
let digest = "1".repeat(64)

proc catalog(): JsonNode =
  %*{"capabilities": [
    {"id": "account_create", "agent_names": ["account-specialist"],
     "grounded_arguments": ["given_name", "family_name"], "success_continuations": ["ticket_create"]},
    {"id": "account_get", "agent_names": ["account-specialist"], "grounded_arguments": ["login"],
     "success_continuations": []},
    {"id": "ticket_create", "agent_names": ["ticket-specialist", "jira-specialist"],
     "grounded_arguments": ["project_key"], "success_continuations": []},
    {"id": "unowned", "agent_names": [], "grounded_arguments": []}]}

proc savedJson(version = 1): JsonNode =
  %*{"workflow": {"workflow_id": workflowId, "name": "Onboard", "version": version,
     "definition_sha256": digest, "execution": "durable_job",
     "definition": {"version": 1, "steps": [
       {"id": "step_1", "capability": "account_create", "grounded_arguments": {"given_name": ["Dana"]},
        "after_success_of": nil},
       {"id": "step_2", "capability": "ticket_create", "grounded_arguments": {"project_key": ["SUP"]},
        "after_success_of": "step_1"}]},
     "layout": {"step_1": {"x": 40, "y": 40}, "step_2": {"x": 300, "y": 40}}}}

suite "workflow canvas":
  test "a dependent node is placed beside its source and compiles to the chat contract":
    var draft = WorkflowDraft(name: "Onboard")
    draft = addNode(catalog(), draft, "account_create")
    draft = addNode(catalog(), draft, "ticket_create", "step_1")
    check draft.nodes.len == 2
    check draft.nodes[1].x == draft.nodes[0].x + workflowNodeSpacing
    check draft.nodes[1].y == draft.nodes[0].y
    let payload = savePayload(draft)
    check payload["name"].getStr == "Onboard"
    check payload["definition"] == workflowContract(draft.steps)
    check payload["definition"]["steps"][1]["after_success_of"].getStr == "step_1"
    check payload["layout"]["step_2"]["x"].getInt == draft.nodes[1].x
    check not payload.hasKey("base_version")

  test "the shared rules refuse unowned, repeated and unsupported steps":
    var draft = addNode(catalog(), WorkflowDraft(name: "x"), "account_create")
    expect ValueError: discard addNode(catalog(), draft, "unowned")
    expect ValueError: discard addNode(catalog(), draft, "account_create")
    # Another capability of the same specialist cannot join the same workflow.
    expect ValueError: discard addNode(catalog(), draft, "account_get")
    # A dependency the capability catalog does not declare is refused.
    let ticketFirst = addNode(catalog(), WorkflowDraft(name: "x"), "ticket_create")
    expect ValueError: discard addNode(catalog(), ticketFirst, "account_create", "step_1")

  test "targets keep one exact value per line and only registered fields":
    var draft = addNode(catalog(), WorkflowDraft(name: "x"), "account_create")
    draft = addNode(catalog(), draft, "ticket_create", "step_1")
    draft = setTargets(catalog(), draft, "step_1", "given_name", "Dana\nAlex")
    check draft.nodes[0].step.groundedArguments["given_name"] == %["Dana", "Alex"]
    draft = setTargets(catalog(), draft, "step_2", "project_key", "SUP")
    check draft.nodes[1].step.groundedArguments["project_key"] == %["SUP"]
    # The dependency survives a target edit.
    check draft.nodes[1].step.afterSuccessOf == "step_1"
    expect ValueError: discard setTargets(catalog(), draft, "step_1", "password", "x")
    expect ValueError: discard setTargets(catalog(), draft, "step_1", "given_name", "Dana\n   ")
    draft = setTargets(catalog(), draft, "step_1", "given_name", "")
    check not draft.nodes[0].step.groundedArguments.hasKey("given_name")

  test "a source step cannot be removed while another step depends on it":
    var draft = addNode(catalog(), WorkflowDraft(name: "x"), "account_create")
    draft = addNode(catalog(), draft, "ticket_create", "step_1")
    expect ValueError: discard removeNode(draft, "step_1")
    draft = removeNode(draft, "step_2")
    draft = removeNode(draft, "step_1")
    check draft.nodes.len == 0
    expect ValueError: discard savePayload(draft)

  test "moving a node snaps it to the grid and keeps it on the canvas":
    var draft = addNode(catalog(), WorkflowDraft(name: "x"), "account_create")
    draft = moveNode(draft, "step_1", 13, -500)
    check draft.nodes[0].x mod workflowGrid == 0
    check draft.nodes[0].y == 0
    check snap(workflowCanvasLimit + 999) == workflowCanvasLimit

  test "a blank or overlong name is refused before saving":
    let draft = addNode(catalog(), WorkflowDraft(name: "   "), "account_create")
    expect ValueError: discard savePayload(draft)
    var long = draft
    long.name = "n".repeat(workflowNameLimit + 1)
    expect ValueError: discard savePayload(long)

suite "saved workflows":
  test "a saved workflow reloads to the same contract, canvas and version":
    let draft = parseWorkflow(savedJson(3))
    check draft.id == workflowId
    check draft.version == 3
    check draft.nodes.len == 2
    check draft.nodes[1].x == 300
    check workflowContract(draft.steps) == savedJson()["workflow"]["definition"]
    let payload = savePayload(draft)
    check payload["base_version"].getInt == 3
    check payload["layout"] == savedJson()["workflow"]["layout"]

  test "a saved workflow missing a position, a contract or the durable run marker is refused":
    var missing = savedJson()
    missing["workflow"]["layout"].delete("step_2")
    expect ValueError: discard parseWorkflow(missing)
    var noRun = savedJson()
    noRun["workflow"]["execution"] = %"browser"
    expect ValueError: discard parseWorkflow(noRun)
    var badContract = savedJson()
    badContract["workflow"]["definition"]["version"] = %2
    expect ValueError: discard parseWorkflow(badContract)
    expect ValueError: discard parseWorkflow(%*{"workflows": []})

  test "the list keeps every summary field and rejects a malformed row":
    let rows = parseWorkflowList(%*{"workflows": [
      {"workflow_id": workflowId, "name": "Onboard", "version": 2, "definition_sha256": digest,
       "updated_at": "2026-10-28T10:00:00Z"}]})
    check rows.len == 1
    check rows[0].version == 2
    expect ValueError: discard parseWorkflowList(%*{"workflows": [{"workflow_id": workflowId}]})
    expect ValueError: discard parseWorkflowList(%*{"rows": []})

suite "workflow runs":
  test "a run needs a saved version and a request":
    let unsaved = addNode(catalog(), WorkflowDraft(name: "x"), "account_create")
    expect ValueError: discard runPayload(unsaved, "sub", "Go")
    let draft = parseWorkflow(savedJson(2))
    expect ValueError: discard runPayload(draft, "sub", "   ")
    expect ValueError: discard runPayload(draft, "sub", "x".repeat(workflowRunMessageLimit + 1))
    check runPayload(draft, "sub", " Onboard Dana ") ==
      %*{"version": 2, "submission_id": "sub", "message": "Onboard Dana"}

  test "a run is accepted only when it echoes this exact version and contract":
    let draft = parseWorkflow(savedJson(2))
    let response = %*{"job_id": "f".repeat(32), "status": "pending", "submission_id": "sub",
      "chat_id": "c".repeat(32), "workflow_id": workflowId, "workflow_version": 2,
      "workflow_contract": workflowContract(draft.steps), "workflow_contract_hash": digest}
    let run = parseWorkflowRun(response, draft, "sub")
    check run.jobId == "f".repeat(32)
    check run.chatId == "c".repeat(32)
    var otherVersion = response.copy
    otherVersion["workflow_version"] = %3
    expect ValueError: discard parseWorkflowRun(otherVersion, draft, "sub")
    var otherContract = response.copy
    otherContract["workflow_contract"]["steps"][0]["grounded_arguments"] = %*{"given_name": ["Eve"]}
    expect ValueError: discard parseWorkflowRun(otherContract, draft, "sub")
    expect ValueError: discard parseWorkflowRun(response, draft, "another-submission")
    var noChat = response.copy
    noChat.delete("chat_id")
    expect ValueError: discard parseWorkflowRun(noChat, draft, "sub")

  test "run receipts require exact saved digest, known status and real identifier shapes":
    let draft = parseWorkflow(savedJson(2))
    let response = %*{"job_id": "f".repeat(32), "status": "pending", "submission_id": "sub",
      "chat_id": "c".repeat(32), "workflow_id": workflowId, "workflow_version": 2,
      "workflow_contract": workflowContract(draft.steps), "workflow_contract_hash": digest}
    for patch in [%*{"workflow_contract_hash": "2".repeat(64)}, %*{"status": "accepted"},
                  %*{"job_id": "ok"}, %*{"chat_id": "wrong"}]:
      var malformed = response.copy
      for field, value in patch: malformed[field] = value
      expect ValueError: discard parseWorkflowRun(malformed, draft, "sub")
    for status in ["pending", "processing", "waiting_approval", "completed", "failed", "denied", "outcome_unknown"]:
      var supported = response.copy
      supported["status"] = %status
      check parseWorkflowRun(supported, draft, "sub").status == status

  test "run history pins each immutable version and rejects mixed workflow identities":
    let history = %*{"runs": [{"job_id": "f".repeat(32), "chat_id": "c".repeat(32),
      "workflow_id": workflowId, "workflow_version": 2, "definition_sha256": digest, "status": "outcome_unknown"}]}
    check parseWorkflowRuns(history, workflowId)[0].digest == digest
    var other = history.copy
    other["runs"][0]["workflow_id"] = %"a".repeat(32)
    expect ValueError: discard parseWorkflowRuns(other, workflowId)
    var missing = history.copy
    missing["runs"][0].delete("definition_sha256")
    expect ValueError: discard parseWorkflowRuns(missing, workflowId)

suite "exact workflow mutation receipts":
  test "save binds identity, next version, normalized name, definition and layout":
    let previous = parseWorkflow(savedJson(2))
    let payload = savePayload(previous)
    check parseWorkflowSave(savedJson(3), previous, payload).version == 3
    for patch in [%*{"workflow_id": "a".repeat(32)}, %*{"version": 2}, %*{"name": "Another name"},
                  %*{"definition_sha256": "bad"}]:
      var malformed = savedJson(3)
      for key, value in patch: malformed["workflow"][key] = value
      expect ValueError: discard parseWorkflowSave(malformed, previous, payload)
    var changedLayout = savedJson(3)
    changedLayout["workflow"]["layout"]["step_1"]["x"] = %80
    expect ValueError: discard parseWorkflowSave(changedLayout, previous, payload)
    var changedDefinition = savedJson(3)
    changedDefinition["workflow"]["definition"]["steps"][0]["grounded_arguments"]["given_name"] = %["Eve"]
    expect ValueError: discard parseWorkflowSave(changedDefinition, previous, payload)
    var fresh = previous
    fresh.id = ""
    fresh.version = 0
    check parseWorkflowSave(savedJson(1), fresh, savePayload(fresh)).version == 1
    expect ValueError: discard parseWorkflowSave(savedJson(2), fresh, savePayload(fresh))

  test "archive needs this exact identity and a true confirmation":
    parseWorkflowArchive(%*{"workflow_id": workflowId, "archived": true}, workflowId)
    for receipt in [%*{"archived": true}, %*{"workflow_id": "a".repeat(32), "archived": true},
                    %*{"workflow_id": workflowId, "archived": false}, %*{"workflow_id": workflowId, "archived": "true"}]:
      expect ValueError: parseWorkflowArchive(receipt, workflowId)

  test "invalid saved geometry and target fields cannot masquerade as a round-trip canvas":
    for position in [%*{"x": 40, "y": 40, "extra": true}, %*{"x": 100001, "y": 40}, %*{"x": "40", "y": 40}]:
      var malformed = savedJson()
      malformed["workflow"]["layout"]["step_1"] = position
      expect ValueError: discard parseWorkflow(malformed)
    var wrongDependency = savedJson()
    wrongDependency["workflow"]["definition"]["steps"][1]["after_success_of"] = %"missing"
    expect ValueError: discard parseWorkflow(wrongDependency)
    var wrongTargets = savedJson()
    wrongTargets["workflow"]["definition"]["steps"][0]["grounded_arguments"]["given_name"] = %"Dana"
    expect ValueError: discard parseWorkflow(wrongTargets)

suite "unconfirmed workflow recovery":
  test "recovery binds account, server, exact saved version and exact request":
    let draft = parseWorkflow(savedJson(2))
    let payload = runPayload(draft, "sub", "Onboard Dana")
    let journal = %*{"schema": "pending-workflow-run.v1", "backend": "https://fixture.test", "owner": "alice",
      "workflow": workflowSnapshot(draft), "request": payload}
    let recovered = parsePendingWorkflow(journal, "https://fixture.test", "alice")
    check recovered.draft.digest == draft.digest
    check recovered.payload == payload
    expect ValueError: discard parsePendingWorkflow(journal, "https://fixture.test", "bob")
    expect ValueError: discard parsePendingWorkflow(journal, "https://other.test", "alice")
    var changed = journal.copy
    changed["request"]["version"] = %3
    expect ValueError: discard parsePendingWorkflow(changed, "https://fixture.test", "alice")
    var extra = journal.copy
    extra["request"]["new_submission"] = %true
    expect ValueError: discard parsePendingWorkflow(extra, "https://fixture.test", "alice")
    var malformed = journal.copy
    malformed["request"].delete("message")
    expect ValueError: discard parsePendingWorkflow(malformed, "https://fixture.test", "alice")
