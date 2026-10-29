## The Automation surface (FR-084): a node canvas whose steps compile to
## registered capabilities. Saving stores a version; a run is one durable job
## in its own chat, where approvals and results appear as in any other chat.
include karax/prelude
import std/[json, strutils]
import karax/[kdom, vstyles]
import ../app/types
import ../app/workflow_request
import ../app/workflows
import ../app/workflow_bridge

const nodeWidth = 200
const nodeHeight = 96

proc capabilityLabel(catalog: JsonNode, capability: string): string =
  let row = capabilityRow(catalog, capability)
  result = capability.replace("_", " ")
  if row != nil and row.hasKey("effect") and row["effect"].kind == JString and row["effect"].getStr == "mutation":
    result &= " · needs approval"

proc nodeAt(state: AppState, id: string): WorkflowNode =
  for node in state.automationDraft.nodes:
    if node.step.id == id: return node

proc renderEdges(state: AppState): VNode =
  ## Dependencies are drawn as lines from a source's right edge to its successor.
  var width = 0
  var height = 0
  for node in state.automationDraft.nodes:
    width = max(width, node.x + nodeWidth + 40)
    height = max(height, node.y + nodeHeight + 40)
  result = buildHtml(svg(class = "workflow-edges", `aria-hidden` = "true",
      width = cstring($width), height = cstring($height))):
    for node in state.automationDraft.nodes:
      if node.step.afterSuccessOf.len > 0:
        let source = nodeAt(state, node.step.afterSuccessOf)
        line(class = "workflow-edge",
          x1 = cstring($(source.x + nodeWidth)), y1 = cstring($(source.y + nodeHeight div 2)),
          x2 = cstring($node.x), y2 = cstring($(node.y + nodeHeight div 2)))

proc renderNode(state: AppState, node: WorkflowNode): VNode =
  let catalog = state.extensionCatalog
  let selected = node.step.id == state.automationSelectedNode
  let label = capabilityLabel(catalog, node.step.capability)
  let dependency = if node.step.afterSuccessOf.len > 0: "after " & node.step.afterSuccessOf else: "starts the run"
  result = buildHtml(button(class = (if selected: cstring"workflow-step selected" else: cstring"workflow-step"),
      `data-step` = cstring(node.step.id), `aria-pressed` = (if selected: cstring"true" else: cstring"false"),
      style = style((StyleAttr.left, cstring($node.x & "px")), (StyleAttr.top, cstring($node.y & "px"))),
      title = cstring("Select " & node.step.id & ". Arrow keys move it."))):
    span(class = "workflow-step-id"): text node.step.id
    strong: text label
    small: text dependency
    proc onclick(event: Event, n: VNode) =
      state.automationSelectedNode = node.step.id
    proc onkeydown(event: Event, n: VNode) =
      let key = $KeyboardEvent(event).key
      var dx = 0
      var dy = 0
      case key
      of "ArrowLeft": dx = -workflowGrid
      of "ArrowRight": dx = workflowGrid
      of "ArrowUp": dy = -workflowGrid
      of "ArrowDown": dy = workflowGrid
      else: return
      event.preventDefault()
      let id = node.step.id
      editWorkflow(state, proc(draft: WorkflowDraft): WorkflowDraft = moveNode(draft, id, dx, dy))

proc targetText(step: WorkflowStep, field: string): string =
  ## Saved targets shown one exact value per line.
  if step.groundedArguments == nil or not step.groundedArguments.hasKey(field): return ""
  var values: seq[string]
  for value in step.groundedArguments[field]: values.add value.getStr
  values.join("\n")

proc capabilityDescription(catalog: JsonNode, capability: string): string =
  let row = capabilityRow(catalog, capability)
  if row != nil and row.hasKey("description") and row["description"].kind == JString:
    return row["description"].getStr

proc targetField(state: AppState, id, field, current: string): VNode =
  let fieldId = "workflowTarget_" & field
  result = buildHtml(tdiv(class = "learning-field")):
    label(class = "review-label", `for` = cstring(fieldId)): text field.replace("_", " ")
    textarea(id = cstring(fieldId), class = "workflow-target", rows = "2", value = cstring(current),
        placeholder = "One exact value per line (optional)", disabled = workflowEditingBlocked(state)):
      proc onchange(event: Event, n: VNode) =
        let value = $n.value
        editWorkflow(state, proc(draft: WorkflowDraft): WorkflowDraft =
          setTargets(state.extensionCatalog, draft, id, field, value))

proc renderInspector(state: AppState): VNode =
  let catalog = state.extensionCatalog
  let id = state.automationSelectedNode
  let node = nodeAt(state, id)
  let description = capabilityDescription(catalog, node.step.capability)
  result = buildHtml(section(class = "workflow-inspector", `aria-label` = "Selected step")):
    if node.step.id.len == 0:
      p(class = "operation-note"): text "Select a step to edit its exact targets."
    else:
      strong: text node.step.id & " · " & node.step.capability.replace("_", " ")
      if description.len > 0:
        p(class = "operation-note"): text description
      for field in groundedFields(catalog, node.step.capability):
        targetField(state, id, field, targetText(node.step, field))
      tdiv(class = "workflow-actions"):
        button(class = "secondary-action", disabled = workflowEditingBlocked(state)):
          text "Remove step"
          proc onclick(event: Event, n: VNode) =
            editWorkflow(state, proc(draft: WorkflowDraft): WorkflowDraft = removeNode(draft, id))
            if state.automationError.len == 0: state.automationSelectedNode = ""

proc addOptions(state: AppState): seq[string] =
  let catalog = state.extensionCatalog
  for row in capabilityRows(catalog):
    if row.kind != JObject or not row.hasKey("id") or row["id"].kind != JString: continue
    let capability = row["id"].getStr
    if state.automationAddAfter.len > 0:
      var source = ""
      for node in state.automationDraft.nodes:
        if node.step.id == state.automationAddAfter: source = node.step.capability
      if source.len == 0 or not supportsSuccessDependency(catalog, source, capability): continue
    if workflowCapabilityAvailable(catalog, state.automationDraft.steps, capability) or
        (state.automationAddAfter.len > 0 and state.automationDraft.nodes.len == 1):
      result.add capability

proc renderPalette(state: AppState): VNode =
  let options = addOptions(state)
  if state.automationAddCapability notin options:
    state.automationAddCapability = if options.len > 0: options[0] else: ""
  result = buildHtml(form(class = "workflow-palette", `aria-label` = "Add a step")):
    proc onsubmit(event: Event, n: VNode) =
      event.preventDefault()
      let capability = state.automationAddCapability
      let after = state.automationAddAfter
      editWorkflow(state, proc(draft: WorkflowDraft): WorkflowDraft =
        addNode(state.extensionCatalog, draft, capability, after))
      if state.automationError.len == 0:
        state.automationSelectedNode = state.automationDraft.nodes[^1].step.id
        state.automationAddAfter = ""
    label(class = "review-label", `for` = "automationAddAfter"): text "Runs"
    select(id = "automationAddAfter", class = "learning-select", disabled = workflowEditingBlocked(state)):
      option(value = "", selected = state.automationAddAfter.len == 0): text "Independently"
      for node in state.automationDraft.nodes:
        option(value = cstring(node.step.id), selected = state.automationAddAfter == node.step.id):
          text "After " & node.step.id & " succeeds"
      proc onchange(event: Event, n: VNode) =
        if not workflowEditingBlocked(state): state.automationAddAfter = $n.value
    label(class = "review-label", `for` = "automationAddCapability"): text "Capability"
    select(id = "automationAddCapability", class = "learning-select",
        disabled = workflowEditingBlocked(state) or options.len == 0):
      for capability in options:
        option(value = cstring(capability), selected = capability == state.automationAddCapability):
          text capabilityLabel(state.extensionCatalog, capability)
      proc onchange(event: Event, n: VNode) =
        if not workflowEditingBlocked(state): state.automationAddCapability = $n.value
    button(`type` = "submit", class = "secondary-action", disabled = workflowEditingBlocked(state) or options.len == 0):
      text "Add step"
    if options.len == 0:
      p(class = "operation-note"): text "No registered capability can be added here."

proc renderRuns(state: AppState): VNode =
  result = buildHtml(section(class = "workflow-runs", `aria-label` = "Run history")):
    strong: text "Runs"
    if state.automationRuns.len == 0:
      p(class = "operation-note"): text "No runs yet."
    else:
      ul(class = "workflow-run-list"):
        for run in state.automationRuns:
          li(class = "workflow-run", `data-job` = cstring(run.jobId)):
            span: text "v" & $run.version & " · " & runStatusLabel(run.status)
            let chatId = run.chatId
            button(class = "secondary-action", disabled = workflowBusy(state)):
              text "Open chat"
              proc onclick(event: Event, n: VNode) = openRunChat(state, chatId)

proc renderWorkflowPanel*(state: AppState): VNode =
  let draft = state.automationDraft
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view workflow-panel"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2: text "Automation"
          p: text "Draw a workflow from registered capabilities, save it, then run it as a governed job."
      p(class = "operation-note"):
        text "Saving never runs anything. A run uses the saved version and asks for approval before any change. Retries keep the same run identity."
      if workflowUnconfirmed(state):
        p(class = "operation-note", role = "status"):
          text (if state.automationRunConfirmed: "Confirmed run is still being cleared. " else: "Unconfirmed run. ") &
            "Saved version " & $draft.version & " and its exact request stay locked. Refresh does not send it again."
      if state.automationRecoveryError.len > 0:
        p(class = "operation-error", role = "alert"): text state.automationRecoveryError
      if state.automationError.len > 0 and state.automationError != state.automationRecoveryError:
        p(class = "operation-error", role = "alert"): text state.automationError
      if state.automationNotice.len > 0:
        p(class = "operation-note", role = "status"): text state.automationNotice
      tdiv(class = "workflow-toolbar"):
        label(class = "review-label", `for` = "workflowOpen"): text "Workflow"
        select(id = "workflowOpen", class = "learning-select", disabled = workflowEditingBlocked(state)):
          option(value = "", selected = draft.id.len == 0): text "New workflow"
          for row in state.automationWorkflows:
            option(value = cstring(row.id), selected = row.id == draft.id):
              text row.name & " · v" & $row.version
          proc onchange(event: Event, n: VNode) =
            let id = $n.value
            if id.len == 0: newWorkflowDraft(state)
            else: discard openWorkflow(state, id)
        label(class = "review-label", `for` = "workflowName"): text "Name"
        input(id = "workflowName", class = "workflow-name", value = cstring(draft.name),
            maxlength = $workflowNameLimit, disabled = workflowEditingBlocked(state)):
          proc oninput(event: Event, n: VNode) =
            let value = $n.value
            editWorkflow(state, proc(current: WorkflowDraft): WorkflowDraft =
              result = current
              result.name = value)
        button(class = "secondary-action", disabled = workflowEditingBlocked(state) or draft.nodes.len == 0):
          text (if state.automationSaving: "Saving…" elif draft.version == 0: "Save" else: "Save version")
          proc onclick(event: Event, n: VNode) = discard saveWorkflowDraft(state)
        if draft.id.len > 0:
          button(class = "secondary-action", disabled = workflowEditingBlocked(state)):
            text "Archive"
            proc onclick(event: Event, n: VNode) = discard archiveWorkflowDraft(state)
        button(class = "secondary-action", disabled = workflowBusy(state)):
          text "Refresh workflows"
          proc onclick(event: Event, n: VNode) = discard refreshWorkflows(state)
      if state.automationBusy and not state.automationLoaded:
        p(class = "operation-note", role = "status"): text "Loading your workflows…"
      elif state.extensionCatalog == nil:
        p(class = "operation-note"): text "Capabilities are still loading."
      else:
        tdiv(class = "workflow-editor"):
          renderPalette(state)
          tdiv(class = "workflow-canvas", role = "group", `aria-label` = "Workflow canvas"):
            renderEdges(state)
            for node in draft.nodes:
              renderNode(state, node)
            if draft.nodes.len == 0:
              p(class = "workflow-empty"): text "Add a step to start."
          renderInspector(state)
        tdiv(class = "workflow-run-form"):
          label(class = "review-label", `for` = "automationRunMessage"): text "Run request"
          textarea(id = "automationRunMessage", class = "workflow-target", rows = "2",
              value = cstring(state.automationRunMessage), maxlength = $workflowRunMessageLimit,
              placeholder = "Describe this run, for example who to onboard",
              disabled = workflowEditingBlocked(state) or draft.version == 0):
            proc oninput(event: Event, n: VNode) =
              setWorkflowRunMessage(state, $n.value)
          button(class = "secondary-action",
              disabled = workflowBusy(state) or state.automationRecoveryError.len > 0 or
                draft.version == 0 or (state.automationDirty and not workflowUnconfirmed(state))):
            text (if state.automationRunning: "Starting…" elif workflowUnconfirmed(state): "Retry same run" else: "Run saved version")
            proc onclick(event: Event, n: VNode) = discard runWorkflowDraft(state)
          if draft.version == 0:
            p(class = "operation-note"): text "Save the workflow to run it."
          elif state.automationDirty:
            p(class = "operation-note"): text "Unsaved changes. Save a new version to run them."
        if draft.id.len > 0:
          renderRuns(state)
