import std/[json, strutils, unittest]
import ../src/app/workflow_request

let catalog = %*{"capabilities": [
  {"id": "identity_create", "agent_names": ["identity"], "grounded_arguments": ["login"],
   "success_continuations": ["issue_create"]},
  {"id": "identity_read", "agent_names": ["identity"], "grounded_arguments": ["login"]},
  {"id": "issue_create", "agent_names": ["issues", "provider-issues"], "grounded_arguments": ["project"]},
  {"id": "issue_read", "agent_names": ["provider-issues"], "grounded_arguments": ["issue"]},
  {"id": "read_files", "agent_names": ["files"], "grounded_arguments": ["paths"]},
  {"id": "not_owned", "agent_names": [], "grounded_arguments": []}
]}

suite "explicit required operations":
  test "empty selection does not change normal chat requests":
    check workflowContract(@[]) == nil
    check capabilityRows(nil).len == 0
    check not workflowCapabilityAvailable(catalog, @[], "not_owned")
    check not workflowCapabilityAvailable(catalog, @[], "missing")

  test "selection pins exact target strings, supported dependency and only grounded fields":
    let first = addWorkflowStep(catalog, @[], "identity_create", %*{"login": " Exact Value "}, "")
    let steps = addWorkflowStep(catalog, first, "issue_create", %*{"project": "ALPHA"}, first[0].id)
    let contract = workflowContract(steps)
    check contract["version"].getInt == 1
    check contract["steps"][0]["grounded_arguments"] == %*{"login": [" Exact Value "]}
    check contract["steps"][0]["after_success_of"].kind == JNull
    check contract["steps"][1]["after_success_of"].getStr == first[0].id
    check not workflowCapabilityAvailable(catalog, first, "identity_read")
    check not workflowCapabilityAvailable(catalog, first, "identity_create")

  test "optional targets remain absent and multiline values retain individual identity":
    let steps = addWorkflowStep(catalog, @[], "read_files", %*{"paths": "one path\nsecond path"}, "")
    check workflowContract(steps)["steps"][0]["grounded_arguments"] == %*{"paths": ["one path", "second path"]}
    let empty = addWorkflowStep(catalog, @[], "issue_create", %*{"project": ""}, "")
    check workflowContract(empty)["steps"][0]["grounded_arguments"] == newJObject()

  test "unknown specialist, duplicate owner and unsupported dependencies fail before send":
    expect ValueError: discard addWorkflowStep(catalog, @[], "not_owned", nil, "")
    expect ValueError: discard addWorkflowStep(catalog, @[], "missing", nil, "")
    let first = addWorkflowStep(catalog, @[], "identity_create", nil, "")
    expect ValueError: discard addWorkflowStep(catalog, first, "identity_read", nil, "")
    expect ValueError: discard addWorkflowStep(catalog, first, "read_files", nil, first[0].id)
    expect ValueError: discard addWorkflowStep(catalog, first, "issue_create", nil, "missing")
    let independent = addWorkflowStep(catalog, first, "read_files", nil, "")
    expect ValueError: discard addWorkflowStep(catalog, independent, "issue_create", nil, first[0].id)

  test "dependent operations cannot be silently detached when removing a predecessor":
    let first = addWorkflowStep(catalog, @[], "identity_create", nil, "")
    let steps = addWorkflowStep(catalog, first, "issue_create", nil, first[0].id)
    check not workflowCapabilityAvailable(catalog, steps, "read_files")
    expect ValueError: discard addWorkflowStep(catalog, steps, "read_files", nil, "")
    expect ValueError: discard removeWorkflowStep(steps, first[0].id)
    check removeWorkflowStep(steps, steps[1].id).len == 1
    check removeWorkflowStep(first, first[0].id).len == 0

  test "a capability shared by several specialists stays selectable without a shared owner":
    check capabilityOwners(catalog, "issue_create") == @["issues", "provider-issues"]
    check workflowCapabilityAvailable(catalog, @[], "issue_create")
    let first = addWorkflowStep(catalog, @[], "issue_create", nil, "")
    check not workflowCapabilityAvailable(catalog, first, "issue_read")
    expect ValueError: discard addWorkflowStep(catalog, first, "issue_read", nil, "")
    check workflowCapabilityAvailable(catalog, first, "read_files")

  test "a catalog row without an owner list offers no workflow choice":
    let legacy = %*{"capabilities": [{"id": "legacy", "agent_name": "identity", "grounded_arguments": []}]}
    check capabilityOwners(legacy, "legacy").len == 0
    check not workflowCapabilityAvailable(legacy, @[], "legacy")

  test "empty or excessive target bindings are rejected instead of rewritten":
    expect ValueError: discard addWorkflowStep(catalog, @[], "read_files", %*{"paths": "one\n\ntwo"}, "")
    expect ValueError: discard addWorkflowStep(catalog, @[], "read_files", %*{"paths": 12}, "")
    expect ValueError: discard addWorkflowStep(catalog, @[], "read_files", %*{"paths": "  "}, "")
    expect ValueError: discard addWorkflowStep(catalog, @[], "read_files", %*{"password": "never admitted"}, "")

  test "target length counts Unicode characters while preserving the original value":
    let exact = "😀".repeat(1024)
    let steps = addWorkflowStep(catalog, @[], "identity_create", %*{"login": exact}, "")
    check steps[0].groundedArguments["login"][0].getStr == exact
    expect ValueError:
      discard addWorkflowStep(catalog, @[], "identity_create", %*{"login": exact & "😀"}, "")
