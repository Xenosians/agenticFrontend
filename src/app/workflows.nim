## Saved workflows (FR-084): a node graph the owner draws, stored as the same
## requested-workflow contract chat uses. Steps compile to registered
## capabilities; the servers still check ownership, targets, dependencies and
## approvals, and a run is one ordinary durable job.
import std/[json, strutils]
from std/unicode import runeLen
import workflow_request

type
  WorkflowSummary* = object
    id*, name*, digest*, updatedAt*: string
    version*: int

  WorkflowNode* = object
    step*: WorkflowStep
    x*, y*: int

  WorkflowDraft* = object
    id*, name*, digest*: string
    version*: int        ## 0 until the first save.
    nodes*: seq[WorkflowNode]

  WorkflowPendingRun* = object
    draft*: WorkflowDraft
    payload*: JsonNode

const
  workflowNameLimit* = 120
  workflowRunMessageLimit* = 4000
  workflowCanvasLimit* = 100_000
  workflowGrid* = 20
  workflowNodeSpacing* = 260

proc text(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString: node[key].getStr else: ""

proc requireText(node: JsonNode, key: string): string =
  result = text(node, key)
  if result.len == 0: raise newException(ValueError, "The workflow response is missing " & key & ".")

proc requireInt(node: JsonNode, key: string): int =
  if node == nil or node.kind != JObject or not node.hasKey(key) or node[key].kind != JInt or node[key].getInt < 1:
    raise newException(ValueError, "The workflow response is missing " & key & ".")
  node[key].getInt

proc hexadecimal(value: string, length: int): bool =
  value.len == length and value.allCharsInSet({'0'..'9', 'a'..'f'})

proc requireHex(node: JsonNode, key: string, length: int): string =
  result = requireText(node, key)
  if not hexadecimal(result, length):
    raise newException(ValueError, "The workflow response has an invalid " & key & ".")

proc requireKeys(node: JsonNode, keys: openArray[string]) =
  if node == nil or node.kind != JObject or node.len != keys.len:
    raise newException(ValueError, "The workflow response has unsupported fields.")
  for key in keys:
    if not node.hasKey(key): raise newException(ValueError, "The workflow response is incomplete.")

proc checkedName(node: JsonNode): string =
  result = requireText(node, "name")
  if result != result.strip() or result.runeLen > workflowNameLimit:
    raise newException(ValueError, "The workflow response has an invalid name.")

proc knownRunStatus(status: string): bool =
  status in ["pending", "processing", "waiting_approval", "completed", "failed", "denied", "outcome_unknown"]

proc requireRunStatus(node: JsonNode): string =
  result = requireText(node, "status")
  if not knownRunStatus(result): raise newException(ValueError, "The run response has an unsupported status.")

proc parseWorkflowList*(data: JsonNode): seq[WorkflowSummary] =
  if data == nil or data.kind != JObject or not data.hasKey("workflows") or data["workflows"].kind != JArray:
    raise newException(ValueError, "The workflow list response is invalid.")
  var identities: seq[string]
  for row in data["workflows"]:
    let identity = requireHex(row, "workflow_id", 32)
    if identity in identities: raise newException(ValueError, "The workflow list repeats an identity.")
    identities.add identity
    result.add WorkflowSummary(id: identity, name: checkedName(row),
      version: requireInt(row, "version"), digest: requireHex(row, "definition_sha256", 64),
      updatedAt: text(row, "updated_at"))

proc snap*(value: int): int =
  ## Positions snap to one grid so a saved canvas reloads exactly.
  let clamped = max(0, min(workflowCanvasLimit, value))
  ((clamped + workflowGrid div 2) div workflowGrid) * workflowGrid

proc parseWorkflow*(data: JsonNode): WorkflowDraft =
  ## Reads one saved workflow and rejects anything the editor could not round-trip.
  if data == nil or data.kind != JObject or not data.hasKey("workflow") or data["workflow"].kind != JObject:
    raise newException(ValueError, "The workflow response is invalid.")
  let row = data["workflow"]
  if text(row, "execution") != "durable_job":
    raise newException(ValueError, "The workflow response does not describe a durable run.")
  result = WorkflowDraft(id: requireHex(row, "workflow_id", 32), name: checkedName(row),
    version: requireInt(row, "version"), digest: requireHex(row, "definition_sha256", 64))
  let definition = if row.hasKey("definition"): row["definition"] else: newJNull()
  let layout = if row.hasKey("layout"): row["layout"] else: newJNull()
  requireKeys(definition, ["version", "steps"])
  if definition["version"].kind != JInt or definition["version"].getInt != 1 or
      definition["steps"].kind != JArray or definition["steps"].len notin 1..maxWorkflowSteps or
      layout.kind != JObject or layout.len != definition["steps"].len:
    raise newException(ValueError, "The saved workflow definition is invalid.")
  var identities, capabilities: seq[string]
  for step in definition["steps"]:
    requireKeys(step, ["id", "capability", "grounded_arguments", "after_success_of"])
    let id = requireText(step, "id")
    let capability = requireText(step, "capability")
    if id.len > 80 or id[0] notin {'A'..'Z', 'a'..'z'} or
        not id.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}) or id in identities or
        capability.len > 150 or not capability.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-'}) or
        capability in capabilities:
      raise newException(ValueError, "The saved workflow step has an invalid identity.")
    let position = if layout.hasKey(id): layout[id] else: newJNull()
    if position.kind != JObject or not position.hasKey("x") or not position.hasKey("y") or
        position.len != 2 or position["x"].kind != JInt or position["y"].kind != JInt or
        position["x"].getInt notin -workflowCanvasLimit..workflowCanvasLimit or
        position["y"].getInt notin -workflowCanvasLimit..workflowCanvasLimit:
      raise newException(ValueError, "The saved workflow canvas is incomplete.")
    if step["grounded_arguments"].kind != JObject or step["grounded_arguments"].len > 32:
      raise newException(ValueError, "The saved workflow step is invalid.")
    for field, values in step["grounded_arguments"]:
      if field.len notin 1..150 or field[0] notin {'A'..'Z', 'a'..'z', '_'} or
          not field.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_'}) or values.kind != JArray or values.len notin 1..16:
        raise newException(ValueError, "The saved workflow targets are invalid.")
      for value in values:
        if value.kind != JString or value.getStr.len == 0 or value.getStr.runeLen > 1024:
          raise newException(ValueError, "The saved workflow target is invalid.")
    var dependency = ""
    if step["after_success_of"].kind != JNull:
      dependency = requireText(step, "after_success_of")
      if dependency notin identities: raise newException(ValueError, "The saved workflow dependency is invalid.")
    identities.add id
    capabilities.add capability
    result.nodes.add WorkflowNode(step: WorkflowStep(id: id, capability: capability,
      groundedArguments: step["grounded_arguments"].copy, afterSuccessOf: dependency),
      x: position["x"].getInt, y: position["y"].getInt)

proc steps*(draft: WorkflowDraft): seq[WorkflowStep] =
  for node in draft.nodes: result.add node.step

proc argumentDrafts(step: WorkflowStep): JsonNode =
  ## The editor's text form of saved targets: one exact value per line.
  result = newJObject()
  if step.groundedArguments == nil: return
  for field, values in step.groundedArguments:
    var lines: seq[string]
    for value in values: lines.add value.getStr
    result[field] = %lines.join("\n")

proc addNode*(catalog: JsonNode, draft: WorkflowDraft, capability: string, afterSuccessOf = ""): WorkflowDraft =
  ## Adds one step with the same rules chat uses; a dependent step sits to the
  ## right of its source, an independent one below the last node.
  let steps = addWorkflowStep(catalog, draft.steps, capability, newJObject(), afterSuccessOf)
  result = draft
  var x = 40
  var y = 40
  for node in draft.nodes:
    if afterSuccessOf.len > 0 and node.step.id == afterSuccessOf:
      x = node.x + workflowNodeSpacing
      y = node.y
    elif afterSuccessOf.len == 0:
      y = max(y, node.y + workflowNodeSpacing div 2)
  result.nodes.add WorkflowNode(step: steps[^1], x: snap(x), y: snap(y))

proc removeNode*(draft: WorkflowDraft, id: string): WorkflowDraft =
  let remaining = removeWorkflowStep(draft.steps, id)
  result = draft
  result.nodes = @[]
  for node in draft.nodes:
    for step in remaining:
      if step.id == node.step.id: result.nodes.add node

proc moveNode*(draft: WorkflowDraft, id: string, dx, dy: int): WorkflowDraft =
  result = draft
  for node in result.nodes.mitems:
    if node.step.id == id:
      node.x = snap(node.x + dx)
      node.y = snap(node.y + dy)

proc setTargets*(catalog: JsonNode, draft: WorkflowDraft, id, field, value: string): WorkflowDraft =
  ## Rebuilds the step through the shared validator so targets stay exactly
  ## the registered grounded fields, with one value per line. An empty value
  ## clears the field.
  var target: WorkflowStep
  var found = false
  for node in draft.nodes:
    if node.step.id == id:
      target = node.step
      found = true
  if not found: raise newException(ValueError, "This step is no longer on the canvas.")
  # A dependent step is checked against its source, exactly as when it was added.
  var source: seq[WorkflowStep]
  for node in draft.nodes:
    if node.step.id == target.afterSuccessOf: source.add node.step
  let drafts = argumentDrafts(target)
  drafts[field] = %value
  let checked = addWorkflowStep(catalog, source, target.capability, drafts, target.afterSuccessOf)
  result = draft
  for node in result.nodes.mitems:
    if node.step.id == id:
      node.step.groundedArguments = checked[^1].groundedArguments

proc layoutJson*(draft: WorkflowDraft): JsonNode =
  result = newJObject()
  for node in draft.nodes:
    result[node.step.id] = %*{"x": node.x, "y": node.y}

proc validName(name: string): string =
  result = name.strip()
  if result.len == 0 or result.runeLen > workflowNameLimit:
    raise newException(ValueError, "Name the workflow (at most 120 characters).")

proc savePayload*(draft: WorkflowDraft): JsonNode =
  if draft.nodes.len == 0: raise newException(ValueError, "Add at least one step before saving.")
  result = %*{"name": validName(draft.name), "definition": workflowContract(draft.steps),
              "layout": layoutJson(draft)}
  if draft.version > 0: result["base_version"] = %draft.version

proc parseWorkflowSave*(data: JsonNode, previous: WorkflowDraft, payload: JsonNode): WorkflowDraft =
  result = parseWorkflow(data)
  if (previous.id.len > 0 and result.id != previous.id) or result.version != previous.version + 1 or
      result.name != payload["name"].getStr or workflowContract(result.steps) != payload["definition"] or
      layoutJson(result) != payload["layout"]:
    raise newException(ValueError, "The saved workflow differs from this exact save request. Reload before another change.")

proc parseWorkflowArchive*(data: JsonNode, identity: string) =
  if data == nil or data.kind != JObject or text(data, "workflow_id") != identity or
      not data.hasKey("archived") or data["archived"].kind != JBool or not data["archived"].getBool:
    raise newException(ValueError, "The archive response did not confirm this workflow. Refresh before trying again.")

proc workflowSnapshot*(draft: WorkflowDraft): JsonNode =
  %*{"workflow": {"workflow_id": draft.id, "name": draft.name, "version": draft.version,
    "definition_sha256": draft.digest, "execution": "durable_job",
    "definition": workflowContract(draft.steps), "layout": layoutJson(draft)}}

proc runPayload*(draft: WorkflowDraft, submissionId, message: string): JsonNode =
  if draft.version == 0 or draft.id.len == 0:
    raise newException(ValueError, "Save the workflow before running it.")
  let request = message.strip()
  if request.len == 0 or request.runeLen > workflowRunMessageLimit:
    raise newException(ValueError, "Describe what this run should do (at most 4,000 characters).")
  %*{"version": draft.version, "submission_id": submissionId, "message": request}

type WorkflowRun* = object
  jobId*, chatId*, status*, submissionId*: string
  version*: int

type WorkflowRunRow* = object
  jobId*, chatId*, status*, createdAt*, workflowId*, digest*: string
  version*: int

proc parseWorkflowRuns*(data: JsonNode, identity: string): seq[WorkflowRunRow] =
  if data == nil or data.kind != JObject or not data.hasKey("runs") or data["runs"].kind != JArray:
    raise newException(ValueError, "The run history response is invalid.")
  var jobs: seq[string]
  for row in data["runs"]:
    let jobId = requireHex(row, "job_id", 32)
    let workflowId = requireHex(row, "workflow_id", 32)
    if workflowId != identity or jobId in jobs:
      raise newException(ValueError, "The run history does not match this workflow.")
    jobs.add jobId
    result.add WorkflowRunRow(jobId: jobId, chatId: requireHex(row, "chat_id", 32),
      status: requireRunStatus(row), createdAt: text(row, "created_at"),
      version: requireInt(row, "workflow_version"), workflowId: workflowId,
      digest: requireHex(row, "definition_sha256", 64))

proc runStatusLabel*(status: string): string =
  case status
  of "pending": "Queued"
  of "processing": "Working"
  of "waiting_approval": "Approval needed"
  of "completed": "Completed"
  of "failed": "Failed"
  of "denied": "Denied"
  of "outcome_unknown": "Outcome unknown"
  else: "Status unknown"

proc parseWorkflowRun*(data: JsonNode, draft: WorkflowDraft, submissionId: string): WorkflowRun =
  ## A run is accepted only when the backend echoes the exact saved version
  ## and contract this editor holds; anything else is reported, never assumed.
  if data == nil or data.kind != JObject:
    raise newException(ValueError, "The run response is invalid.")
  result = WorkflowRun(jobId: requireHex(data, "job_id", 32), chatId: requireHex(data, "chat_id", 32),
    status: requireRunStatus(data), submissionId: requireText(data, "submission_id"),
    version: requireInt(data, "workflow_version"))
  if result.submissionId != submissionId or text(data, "workflow_id") != draft.id or
      result.version != draft.version or requireHex(data, "workflow_contract_hash", 64) != draft.digest or
      not data.hasKey("workflow_contract") or
      data["workflow_contract"] != workflowContract(draft.steps):
    raise newException(ValueError, "The run response does not match this workflow version.")
