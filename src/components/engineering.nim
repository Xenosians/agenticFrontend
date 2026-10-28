## The Engineering surface (FR-093) inside the existing PCB / Infrastructure
## Simulator view. Infrastructure: draw the desired topology, save versions and
## compare a saved version with what the read adapters observe. PCB: inspect a
## KiCad netlist. Observed, desired and simulated state stay labelled, and
## nothing here can change a device.
include karax/prelude
import std/[asyncjs, json, strutils]
import karax/[kdom, vstyles]
import ../app/types
import ../app/engineering
import ../app/engineering_bridge

const nodeWidth = 200
const nodeHeight = 80

proc netlistFileOutcome(): Future[cstring] {.importjs: """
(async () => {
  try {
    const f=document.getElementById('netlistFile').files[0];
    if(!f || f.size>2000000) throw new Error('Choose a KiCad netlist (.net) under 2 MB.');
    return JSON.stringify({value: await f.text(), name: f.name});
  } catch(error) {
    return JSON.stringify({error: error && typeof error.message==='string' ? error.message : 'The netlist file could not be read.'});
  }
})()
""".}

proc readNetlistFile(state: AppState) {.async.} =
  let outcome = parseJson($(await netlistFileOutcome()))
  if outcome.hasKey("error"):
    state.engineeringError = outcome["error"].getStr
  else:
    state.engineeringNetlistText = outcome["value"].getStr
    state.engineeringNetlistName = outcome["name"].getStr
    state.engineeringError = ""
    state.engineeringHasNetlist = false
  redraw(kxi)

proc nodeAt(state: AppState, id: string): TopologyNode =
  for node in state.engineeringDraft.nodes:
    if node.id == id: return node

proc driftOf(state: AppState, id: string): DriftNode =
  if state.engineeringHasDrift:
    for row in state.engineeringDrift.nodes:
      if row.id == id: return row

proc renderEdges(state: AppState): VNode =
  var width = 0
  var height = 0
  for node in state.engineeringDraft.nodes:
    width = max(width, node.x + nodeWidth + 40)
    height = max(height, node.y + nodeHeight + 40)
  result = buildHtml(svg(class = "workflow-edges", `aria-hidden` = "true",
      width = cstring($width), height = cstring($height))):
    for edge in state.engineeringDraft.edges:
      let source = nodeAt(state, edge.source)
      let target = nodeAt(state, edge.target)
      line(class = (if edge.relation == "associated_with": cstring"workflow-edge topology-edge-weak"
                    else: cstring"workflow-edge"),
        x1 = cstring($(source.x + nodeWidth div 2)), y1 = cstring($(source.y + nodeHeight div 2)),
        x2 = cstring($(target.x + nodeWidth div 2)), y2 = cstring($(target.y + nodeHeight div 2)))

proc renderNode(state: AppState, node: TopologyNode): VNode =
  let selected = node.id == state.engineeringSelectedNode
  let drift = driftOf(state, node.id)
  let status = if drift.id.len > 0: driftStatusLabel(drift.status) else: "Desired"
  result = buildHtml(button(class = (if selected: cstring"workflow-step topology-node selected"
                                     else: cstring"workflow-step topology-node"),
      `data-node` = cstring(node.id), `data-status` = cstring(if drift.id.len > 0: drift.status else: "desired"),
      `aria-pressed` = (if selected: cstring"true" else: cstring"false"),
      style = style((StyleAttr.left, cstring($node.x & "px")), (StyleAttr.top, cstring($node.y & "px"))),
      title = cstring("Select " & node.id & ". Arrow keys move it."))):
    span(class = "workflow-step-id"): text node.id
    strong: text (if node.label.len > 0: node.label else: node.id)
    small: text status
    proc onclick(event: Event, n: VNode) =
      state.engineeringSelectedNode = node.id
    proc onkeydown(event: Event, n: VNode) =
      var dx = 0
      var dy = 0
      case $KeyboardEvent(event).key
      of "ArrowLeft": dx = -topologyGrid
      of "ArrowRight": dx = topologyGrid
      of "ArrowUp": dy = -topologyGrid
      of "ArrowDown": dy = topologyGrid
      else: return
      event.preventDefault()
      let id = node.id
      editTopology(state, proc(draft: TopologyDraft): TopologyDraft = moveTopologyNode(draft, id, dx, dy))

proc renderAddNode(state: AppState): VNode =
  result = buildHtml(form(class = "topology-add", `aria-label` = "Add a node")):
    proc onsubmit(event: Event, n: VNode) =
      event.preventDefault()
      let kind = if state.engineeringNewKind.len > 0: state.engineeringNewKind else: "container"
      let name = state.engineeringNewName.strip()
      editTopology(state, proc(draft: TopologyDraft): TopologyDraft = addTopologyNode(draft, kind, name))
      if state.engineeringError.len == 0:
        state.engineeringSelectedNode = state.engineeringDraft.nodes[^1].id
        state.engineeringNewName = ""
    strong(class = "topology-section-title"): text "Add a node"
    label(class = "review-label", `for` = "topologyNodeKind"): text "Type"
    select(id = "topologyNodeKind", class = "learning-select", disabled = engineeringBusy(state)):
      for kind in ["container", "endpoint", "router", "interface", "host", "service", "switch", "storage"]:
        option(value = cstring(kind), selected = kind == state.engineeringNewKind): text kind
      proc onchange(event: Event, n: VNode) = state.engineeringNewKind = $n.value
    label(class = "review-label", `for` = "topologyNodeName"): text "Name"
    input(id = "topologyNodeName", class = "workflow-name", `type` = "text", value = cstring(state.engineeringNewName),
        placeholder = "e.g. itsm-surrealdb", disabled = engineeringBusy(state)):
      proc oninput(event: Event, n: VNode) = state.engineeringNewName = $n.value
    button(`type` = "submit", class = "secondary-action", disabled = engineeringBusy(state)): text "Add node"
    p(class = "operation-note"):
      text "Use the names the read adapters observe: container names, health endpoint names, router interfaces."

proc renderInspector(state: AppState): VNode =
  let id = state.engineeringSelectedNode
  let node = nodeAt(state, id)
  let drift = driftOf(state, id)
  result = buildHtml(section(class = "topology-inspector", `aria-label` = "Selected node")):
    if node.id.len == 0:
      p(class = "operation-note"): text "Select a node to edit its desired properties and connections."
    else:
      strong(class = "topology-section-title"): text "Selected node · " & node.id
      label(class = "review-label", `for` = "topologyNodeLabel"): text "Label"
      input(id = "topologyNodeLabel", class = "workflow-name", `type` = "text", value = cstring(node.label),
          disabled = engineeringBusy(state)):
        proc onchange(event: Event, n: VNode) =
          let value = $n.value
          editTopology(state, proc(draft: TopologyDraft): TopologyDraft = setNodeLabel(draft, id, value))
      label(class = "review-label", `for` = "topologyNodeProperties"): text "Desired properties"
      textarea(id = "topologyNodeProperties", class = "workflow-target", rows = "4", value = cstring(node.properties),
          placeholder = "One name=value per line, e.g. state=running", disabled = engineeringBusy(state)):
        proc onchange(event: Event, n: VNode) =
          let value = $n.value
          editTopology(state, proc(draft: TopologyDraft): TopologyDraft = setNodeProperties(draft, id, value))
      p(class = "operation-note"): text "Only properties written here are compared with observations."
      if drift.id.len > 0:
        strong(class = "topology-section-title", role = "status"):
          text driftStatusLabel(drift.status) & (if drift.reason.len > 0: " · " & driftReasonLabel(drift.reason) else: "")
        for difference in drift.differences:
          p(class = "operation-note topology-difference"): text difference
      label(class = "review-label", `for` = "topologyEdgeRelation"): text "Connect to"
      tdiv(class = "workflow-actions"):
        select(id = "topologyEdgeRelation", class = "learning-select", disabled = engineeringBusy(state)):
          for relation in topologyRelations:
            option(value = cstring(relation), selected = relation == state.engineeringEdgeRelation):
              text relation.replace("_", " ")
          proc onchange(event: Event, n: VNode) = state.engineeringEdgeRelation = $n.value
        select(id = "topologyEdgeTarget", class = "learning-select", `aria-label` = "Connection target",
            disabled = engineeringBusy(state)):
          option(value = "", selected = state.engineeringEdgeTarget.len == 0): text "Choose a node"
          for other in state.engineeringDraft.nodes:
            if other.id != id:
              option(value = cstring(other.id), selected = other.id == state.engineeringEdgeTarget): text other.id
          proc onchange(event: Event, n: VNode) = state.engineeringEdgeTarget = $n.value
      button(class = "secondary-action", disabled = engineeringBusy(state)):
        text "Add connection"
        proc onclick(event: Event, n: VNode) =
          let target = state.engineeringEdgeTarget
          let relation = if state.engineeringEdgeRelation.len > 0: state.engineeringEdgeRelation else: "depends_on"
          editTopology(state, proc(draft: TopologyDraft): TopologyDraft =
            addTopologyEdge(draft, id, target, relation))
      ul(class = "workflow-run-list"):
        for index, edge in state.engineeringDraft.edges:
          if edge.source == id or edge.target == id:
            li(class = "workflow-run"):
              span: text edge.source & " " & edge.relation.replace("_", " ") & " " & edge.target
              let position = index
              button(class = "secondary-action", disabled = engineeringBusy(state)):
                text "Remove"
                proc onclick(event: Event, n: VNode) =
                  editTopology(state, proc(draft: TopologyDraft): TopologyDraft = removeTopologyEdge(draft, position))
      button(class = "secondary-action", disabled = engineeringBusy(state)):
        text "Remove node"
        proc onclick(event: Event, n: VNode) =
          editTopology(state, proc(draft: TopologyDraft): TopologyDraft = removeTopologyNode(draft, id))
          if state.engineeringError.len == 0: state.engineeringSelectedNode = ""

proc renderDrift(state: AppState): VNode =
  let report = state.engineeringDrift
  result = buildHtml(section(class = "workflow-runs topology-drift", `aria-label` = "Drift check")):
    strong: text "Simulated comparison · version " & $report.version
    p(class = "operation-note"):
      text "Observed " & report.observedAt & ". " & $report.counts.matches & " match, " & $report.counts.drifted &
        " drifted, " & $report.counts.missing & " missing, " & $report.counts.unknown & " unknown."
    ul(class = "workflow-run-list"):
      for source in report.sources:
        li(class = "workflow-run", `data-source` = cstring(source.id)):
          span: text source.id
          span: text source.state.replace("_", " ") & (if source.errorCode.len > 0: " · " & source.errorCode else: "")
    if report.affected.len > 0:
      p(class = "operation-note"): text "Potentially affected (graph reach, not an outage): " & report.affected.join(", ")
    if report.notInDesign.len > 0:
      p(class = "operation-note"): text "Observed but not in this design: " & report.notInDesign.join(", ")
    for note in report.notes:
      p(class = "operation-note"): text note

proc renderInfrastructure(state: AppState): VNode =
  let draft = state.engineeringDraft
  result = buildHtml(tdiv(class = "topology-workspace")):
    tdiv(class = "workflow-toolbar"):
      label(class = "review-label", `for` = "topologyOpen"): text "Topology"
      select(id = "topologyOpen", class = "learning-select", disabled = engineeringBusy(state)):
        option(value = "", selected = draft.id.len == 0): text "New topology"
        for row in state.engineeringTopologies:
          option(value = cstring(row.id), selected = row.id == draft.id): text row.name & " · v" & $row.version
        proc onchange(event: Event, n: VNode) =
          let id = $n.value
          if id.len == 0: newTopologyDraft(state)
          else: discard openTopology(state, id)
      label(class = "review-label", `for` = "topologyName"): text "Name"
      input(id = "topologyName", class = "workflow-name", value = cstring(draft.name), maxlength = $topologyNameLimit,
          disabled = engineeringBusy(state)):
        proc oninput(event: Event, n: VNode) =
          let value = $n.value
          editTopology(state, proc(current: TopologyDraft): TopologyDraft =
            result = current
            result.name = value)
      button(class = "secondary-action", disabled = engineeringBusy(state) or draft.nodes.len == 0):
        text (if state.engineeringSaving: "Saving…" elif draft.version == 0: "Save" else: "Save version")
        proc onclick(event: Event, n: VNode) = discard saveTopologyDraft(state)
      button(class = "secondary-action",
          disabled = engineeringBusy(state) or draft.version == 0 or state.engineeringDirty):
        text (if state.engineeringChecking: "Checking…" else: "Check drift")
        proc onclick(event: Event, n: VNode) = discard checkTopologyDrift(state)
      if draft.id.len > 0:
        button(class = "secondary-action", disabled = engineeringBusy(state)):
          text "Archive"
          proc onclick(event: Event, n: VNode) = discard archiveTopologyDraft(state)
    if state.engineeringDirty and draft.version > 0:
      p(class = "operation-note"): text "Unsaved changes. Save a new version to check it."
    tdiv(class = "topology-editor"):
      tdiv(class = "workflow-canvas topology-canvas", role = "group", `aria-label` = "Topology canvas"):
        renderEdges(state)
        for node in draft.nodes: renderNode(state, node)
        if draft.nodes.len == 0:
          p(class = "workflow-empty"): text "Add a node to start your desired topology."
      tdiv(class = "topology-panels"):
        renderAddNode(state)
        renderInspector(state)
    if state.engineeringHasDrift: renderDrift(state)

proc counted(count: int, noun: string): string =
  $count & " " & noun & (if count == 1: "" else: "s")

proc renderPcb(state: AppState): VNode =
  result = buildHtml(tdiv(class = "topology-workspace")):
    p(class = "operation-note"):
      text "Inspect a KiCad netlist export (File → Export → Netlist). The design is read as text; nothing is fabricated or flashed."
    tdiv(class = "netlist-picker"):
      # The visible label is the picker; the native input stays reachable but hidden.
      label(class = "secondary-action netlist-choose", `for` = "netlistFile"): text "Choose netlist file"
      input(id = "netlistFile", class = "netlist-file", `type` = "file", accept = ".net,.xml,text/plain",
          disabled = engineeringBusy(state)):
        proc onchange(event: Event, n: VNode) = discard readNetlistFile(state)
      span(class = "operation-note netlist-selected"):
        text (if state.engineeringNetlistName.len > 0: "Selected: " & state.engineeringNetlistName
              else: "No file selected")
      button(class = "secondary-action", disabled = engineeringBusy(state) or state.engineeringNetlistText.len == 0):
        text (if state.engineeringChecking: "Inspecting…" else: "Inspect netlist")
        proc onclick(event: Event, n: VNode) = discard inspectNetlistText(state)
    if state.engineeringHasNetlist:
      let report = state.engineeringNetlist
      section(class = "workflow-runs", `aria-label` = "Netlist inspection"):
        strong: text "Design inspection" & (if report.tool.len > 0: " · " & report.tool else: "")
        p(class = "operation-note"):
          text counted(report.components, "component") & ", " & counted(report.nets, "net") & ", " &
            counted(report.connections, "connection") & ". " & counted(report.errors, "error") & ", " &
            counted(report.warnings, "warning") & "."
        if report.findings.len == 0:
          p(class = "operation-note"): text "No connectivity findings."
        ul(class = "workflow-run-list"):
          for finding in report.findings:
            li(class = "netlist-finding", `data-severity` = cstring(finding.severity)):
              span(class = "netlist-finding-subject"): text finding.severity & " · " & finding.subject
              span: text finding.message
        if report.truncated:
          p(class = "operation-note"): text "Only the first 500 findings are listed."

proc renderEngineeringPanel*(state: AppState): VNode =
  let tab = if state.engineeringTab == "pcb": "pcb" else: "infrastructure"
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view workflow-panel"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2: text "PCB / Infrastructure Simulator"
          p: text "Desired designs, observed state and simulated comparisons, kept separate."
      p(class = "operation-note"):
        text "Read-only: checks observe allow-listed sources and compare. Live changes stay with governed tools and approval."
      if state.engineeringError.len > 0:
        p(class = "operation-error", role = "alert"): text state.engineeringError
      if state.engineeringNotice.len > 0:
        p(class = "operation-note", role = "status"): text state.engineeringNotice
      tdiv(class = "simulation-toolbar", role = "tablist"):
        for (id, title) in [("infrastructure", "Infrastructure"), ("pcb", "PCB")]:
          button(class = (if tab == id: cstring"simulation-tab active" else: cstring"simulation-tab"),
              role = "tab", `aria-selected` = (if tab == id: cstring"true" else: cstring"false")):
            text title
            let target = id
            proc onclick(event: Event, n: VNode) = state.engineeringTab = target
      if tab == "pcb":
        renderPcb(state)
      elif state.engineeringBusy and not state.engineeringLoaded:
        p(class = "operation-note", role = "status"): text "Loading your topologies…"
      else:
        renderInfrastructure(state)
