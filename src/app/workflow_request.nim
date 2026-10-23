## Explicit, user-reviewed operation obligations. This is request input, never
## execution authority: the servers still validate targets, policy and approvals.
import std/[json, strutils]

type WorkflowStep* = object
  id*, capability*, afterSuccessOf*: string
  groundedArguments*: JsonNode

const maxWorkflowSteps* = 8

proc characterCount(value: cstring): int {.importjs: "Array.from(#).length".}
proc hasTargetText(value: cstring): bool {.importjs: "(#).trim().length > 0".}

proc capabilityRows*(catalog: JsonNode): JsonNode =
  if catalog != nil and catalog.kind == JObject and catalog.hasKey("capabilities") and
      catalog["capabilities"].kind == JArray:
    return catalog["capabilities"]
  newJArray()

proc capabilityRow*(catalog: JsonNode, capability: string): JsonNode =
  for row in capabilityRows(catalog):
    if row.kind == JObject and row.hasKey("id") and row["id"].kind == JString and
        row["id"].getStr == capability:
      return row

proc groundedFields*(catalog: JsonNode, capability: string): seq[string] =
  let row = capabilityRow(catalog, capability)
  if row == nil or not row.hasKey("grounded_arguments") or
      row["grounded_arguments"].kind != JArray:
    return
  for field in row["grounded_arguments"]:
    if field.kind == JString and field.getStr.len > 0:
      result.add(field.getStr)

proc capabilityOwners*(catalog: JsonNode, capability: string): seq[string] =
  ## Every specialist registered for the capability. A provider-specific and a
  ## provider-neutral specialist can share one; the server picks the carrier.
  let row = capabilityRow(catalog, capability)
  if row == nil or not row.hasKey("agent_names") or row["agent_names"].kind != JArray:
    return
  for owner in row["agent_names"]:
    if owner.kind == JString and owner.getStr.len > 0:
      result.add(owner.getStr)

proc workflowCapabilityAvailable*(catalog: JsonNode, steps: seq[WorkflowStep], capability: string): bool =
  let owners = capabilityOwners(catalog, capability)
  if owners.len == 0: return false
  for step in steps:
    if step.afterSuccessOf.len > 0: return false
    if step.capability == capability: return false
    # Steps may not share a possible specialist: a dependency names the
    # specialist that carried its source step.
    for owner in capabilityOwners(catalog, step.capability):
      if owner in owners: return false
  true

proc supportsSuccessDependency*(catalog: JsonNode, previous, following: string): bool =
  let row = capabilityRow(catalog, previous)
  if row == nil or not row.hasKey("success_continuations") or
      row["success_continuations"].kind != JArray:
    return false
  for target in row["success_continuations"]:
    if target.kind == JString and target.getStr == following:
      return true

proc addWorkflowStep*(catalog: JsonNode, steps: seq[WorkflowStep], capability: string,
    argumentDrafts: JsonNode, afterSuccessOf: string): seq[WorkflowStep] =
  if steps.len >= maxWorkflowSteps:
    raise newException(ValueError, "A request can include at most eight required operations.")
  if not workflowCapabilityAvailable(catalog, steps, capability):
    raise newException(ValueError, "Choose a registered capability whose specialists are not already used by another step.")
  if afterSuccessOf.len > 0:
    if steps.len != 1:
      raise newException(ValueError, "Success-dependent requests currently support exactly two operations.")
    var permitted = false
    for step in steps:
      if step.id == afterSuccessOf:
        permitted = supportsSuccessDependency(catalog, step.capability, capability)
    if not permitted:
      raise newException(ValueError, "This success dependency is not supported by the capability catalog.")
  let arguments = newJObject()
  let fields = groundedFields(catalog, capability)
  if argumentDrafts != nil:
    if argumentDrafts.kind != JObject:
      raise newException(ValueError, "Grounded targets must be named text fields.")
    for field, _ in argumentDrafts:
      if field notin fields:
        raise newException(ValueError, "This target field is not part of the registered capability.")
  for field in fields:
    if argumentDrafts == nil or argumentDrafts.kind != JObject or
        not argumentDrafts.hasKey(field):
      continue
    if argumentDrafts[field].kind != JString:
      raise newException(ValueError, "Grounded targets must be text.")
    let draft = argumentDrafts[field].getStr
    if draft.len == 0: continue
    let values = draft.splitLines()
    if values.len > 16:
      raise newException(ValueError, "Use at most sixteen exact values per target field.")
    for value in values:
      if not hasTargetText(cstring(value)) or characterCount(cstring(value)) > 1024:
        raise newException(ValueError, "Each target needs a nonempty value of at most 1,024 characters.")
    arguments[field] = %values
  var index = steps.len + 1
  while true:
    var used = false
    for step in steps:
      if step.id == "step_" & $index: used = true
    if not used: break
    inc index
  result = steps
  result.add(WorkflowStep(id: "step_" & $index, capability: capability,
    groundedArguments: arguments, afterSuccessOf: afterSuccessOf))

proc removeWorkflowStep*(steps: seq[WorkflowStep], id: string): seq[WorkflowStep] =
  for step in steps:
    if step.afterSuccessOf == id:
      raise newException(ValueError, "Remove the dependent operation first.")
  for step in steps:
    if step.id != id: result.add(step)

proc workflowContract*(steps: seq[WorkflowStep]): JsonNode =
  if steps.len == 0: return nil
  let rows = newJArray()
  for step in steps:
    rows.add(%*{"id": step.id, "capability": step.capability,
      "grounded_arguments": step.groundedArguments,
      "after_success_of": (if step.afterSuccessOf.len == 0: newJNull() else: %step.afterSuccessOf)})
  result = %*{"version": 1, "steps": rows}
