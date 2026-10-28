## Engineering (FR-093): the owner's desired infrastructure topology, advisory
## drift against what the read adapters observed, and PCB netlist reports.
## Everything here is design or comparison; nothing can change a device.
import std/[json, strutils]
from std/unicode import runeLen

type
  TopologySummary* = object
    id*, name*, digest*, updatedAt*: string
    version*: int

  TopologyNode* = object
    id*, kind*, label*: string
    properties*: string  ## The editor's text form: one name=value per line.
    x*, y*: int

  TopologyEdge* = object
    source*, target*, relation*: string

  TopologyDraft* = object
    id*, name*, digest*: string
    version*: int        ## 0 until the first save.
    nodes*: seq[TopologyNode]
    edges*: seq[TopologyEdge]

  DriftNode* = object
    id*, status*, reason*: string
    differences*: seq[string]

  DriftReport* = object
    topologyId*, observedAt*: string
    version*: int
    sources*: seq[tuple[id, state, errorCode: string]]
    nodes*: seq[DriftNode]
    counts*: tuple[matches, drifted, missing, unknown: int]
    affected*, notInDesign*, notes*: seq[string]

  NetlistReport* = object
    tool*, digest*: string
    components*, nets*, connections*, errors*, warnings*: int
    findings*: seq[tuple[severity, subject, message: string]]
    truncated*: bool

const
  topologyNameLimit* = 120
  topologyCanvasLimit* = 100_000
  topologyGrid* = 20
  topologyNodeSpacing* = 260
  topologyRelations* = ["depends_on", "hosted_on", "connected_to", "associated_with"]
  maxTopologyNodes = 300
  maxTopologyProperties = 40
  safeInteger = 9_007_199_254_740_992'i64
  privateNames = ["pass", "secret", "token", "credential", "api_key", "apikey", "private_key", "privatekey",
                  "cookie", "authorization"]

proc fail(message: string) {.noreturn.} = raise newException(ValueError, message)

proc text(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString: node[key].getStr else: ""

proc requireText(node: JsonNode, key: string): string =
  result = text(node, key)
  if result.len == 0: fail("The engineering response is missing " & key & ".")

proc requireInt(node: JsonNode, key: string, minimum = 1): int =
  if node == nil or node.kind != JObject or not node.hasKey(key) or node[key].kind != JInt or
      node[key].getInt < minimum:
    fail("The engineering response is missing " & key & ".")
  node[key].getInt

proc requireHex(node: JsonNode, key: string, length: int): string =
  result = requireText(node, key)
  if result.len != length or not result.allCharsInSet({'0'..'9', 'a'..'f'}):
    fail("The engineering response has an invalid " & key & ".")

proc requireArray(node: JsonNode, key: string): JsonNode =
  if node == nil or node.kind != JObject or not node.hasKey(key) or node[key].kind != JArray:
    fail("The engineering response is missing " & key & ".")
  node[key]

proc identifier(value: string, prefixLimit, nameLimit: int, nameChars: set[char]): bool =
  let parts = value.split(':', 1)
  parts.len == 2 and parts[0].len in 1..prefixLimit and parts[0][0] in {'a'..'z'} and
    parts[0].allCharsInSet({'a'..'z', '0'..'9', '_'}) and parts[1].len in 1..nameLimit and
    parts[1][0] in {'A'..'Z', 'a'..'z', '0'..'9'} and parts[1].allCharsInSet(nameChars)

proc validNodeId*(value: string): bool =
  identifier(value, 32, 96, {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', ':', '-'})

proc validKind(value: string): bool =
  value.len in 1..32 and value[0] in {'a'..'z'} and value.allCharsInSet({'a'..'z', '0'..'9', '_'})

proc validProperty(value: string): bool =
  value.len in 1..64 and value[0] in {'a'..'z'} and value.allCharsInSet({'a'..'z', '0'..'9', '_'})

proc privateName(value: string): bool =
  for word in privateNames:
    if word in value: return true

proc singleLine(value: string, limit: int): bool =
  value.runeLen <= limit and not value.contains({'\r', '\n', '\t', '\0'})

proc propertyText(value: JsonNode): string =
  ## A saved value in the editor's text form; text that would read back as
  ## another type is quoted so it round-trips exactly.
  case value.kind
  of JNull: "null"
  of JBool, JInt, JFloat: $value
  of JString:
    let raw = value.getStr
    var reads = raw in ["true", "false", "null"]
    if not reads:
      try:
        discard parseFloat(raw)
        reads = raw.len > 0
      except ValueError: discard
    if reads or (raw.len >= 2 and raw[0] == '"' and raw[^1] == '"'): "\"" & raw & "\"" else: raw
  else: fail("The saved topology has an unsupported property value.")

proc propertyValue(raw: string): JsonNode =
  if raw.len >= 2 and raw[0] == '"' and raw[^1] == '"': return %raw[1 ..^ 2]
  case raw
  of "true": return %true
  of "false": return %false
  of "null": return newJNull()
  else: discard
  if raw.len > 0 and raw.allCharsInSet({'0'..'9', '-'}) and raw.count('-') <= 1 and (raw[0] == '-' or raw[0] in Digits):
    try:
      let number = parseBiggestInt(raw)
      if abs(number) > safeInteger: fail("A number is outside the exact integer range.")
      return %number
    except ValueError: discard
  if raw.len > 0 and raw.allCharsInSet({'0'..'9', '-', '.', 'e', 'E', '+'}) and raw.count('.') <= 1:
    try:
      return %parseFloat(raw)
    except ValueError: discard
  %raw

proc parseProperties*(source: string): JsonNode =
  ## One name=value per line. Values read as true/false/null/numbers unless quoted.
  result = newJObject()
  for line in source.splitLines:
    let row = line.strip()
    if row.len == 0: continue
    let at = row.find('=')
    if at <= 0: fail("Write each property as name=value on its own line.")
    let name = row[0 ..< at].strip()
    let raw = row[at + 1 .. ^1].strip()
    if not validProperty(name): fail("Property names use lowercase letters, digits and underscores.")
    if privateName(name): fail("Topologies cannot hold credentials.")
    if result.hasKey(name): fail("Each property appears once.")
    if not singleLine(raw, 200): fail("Property values are single-line text of at most 200 characters.")
    result[name] = propertyValue(raw)
  if result.len > maxTopologyProperties: fail("A node has at most 40 properties.")

proc snap*(value: int): int =
  let clamped = max(0, min(topologyCanvasLimit, value))
  ((clamped + topologyGrid div 2) div topologyGrid) * topologyGrid

proc hasNode(draft: TopologyDraft, id: string): bool =
  for node in draft.nodes:
    if node.id == id: return true

proc addTopologyNode*(draft: TopologyDraft, kind, name: string): TopologyDraft =
  let id = kind & ":" & name
  if not validKind(kind) or not validNodeId(id):
    fail("Name the node as a lowercase type and a name without spaces, for example container:itsm-db.")
  if draft.hasNode(id): fail("This node is already on the canvas.")
  if draft.nodes.len >= maxTopologyNodes: fail("A topology has at most 300 nodes.")
  result = draft
  let index = draft.nodes.len
  result.nodes.add TopologyNode(id: id, kind: kind, label: name,
    x: snap(40 + (index mod 4) * topologyNodeSpacing), y: snap(40 + (index div 4) * (topologyNodeSpacing div 2)))

proc removeTopologyNode*(draft: TopologyDraft, id: string): TopologyDraft =
  result = draft
  result.nodes = @[]
  result.edges = @[]
  for node in draft.nodes:
    if node.id != id: result.nodes.add node
  for edge in draft.edges:
    if edge.source != id and edge.target != id: result.edges.add edge

proc moveTopologyNode*(draft: TopologyDraft, id: string, dx, dy: int): TopologyDraft =
  result = draft
  for node in result.nodes.mitems:
    if node.id == id:
      node.x = snap(node.x + dx)
      node.y = snap(node.y + dy)

proc setNodeProperties*(draft: TopologyDraft, id, source: string): TopologyDraft =
  discard parseProperties(source)
  if not draft.hasNode(id): fail("This node is no longer on the canvas.")
  result = draft
  for node in result.nodes.mitems:
    if node.id == id: node.properties = source.strip()

proc setNodeLabel*(draft: TopologyDraft, id, label: string): TopologyDraft =
  if not singleLine(label, 120): fail("Labels are single-line text of at most 120 characters.")
  result = draft
  for node in result.nodes.mitems:
    if node.id == id: node.label = label

proc addTopologyEdge*(draft: TopologyDraft, source, target, relation: string): TopologyDraft =
  if not draft.hasNode(source) or not draft.hasNode(target) or source == target:
    fail("Connect two different nodes on the canvas.")
  if relation notin topologyRelations: fail("Choose a known relation.")
  for edge in draft.edges:
    if edge.source == source and edge.target == target and edge.relation == relation:
      fail("This connection already exists.")
  result = draft
  result.edges.add TopologyEdge(source: source, target: target, relation: relation)

proc removeTopologyEdge*(draft: TopologyDraft, index: int): TopologyDraft =
  result = draft
  if index in 0 ..< result.edges.len: result.edges.delete(index)

proc designJson*(draft: TopologyDraft): JsonNode =
  var nodes = newJArray()
  for node in draft.nodes:
    nodes.add %*{"id": node.id, "kind": node.kind, "label": node.label,
                 "properties": parseProperties(node.properties)}
  var edges = newJArray()
  for edge in draft.edges:
    edges.add %*{"from": edge.source, "to": edge.target, "relation": edge.relation}
  %*{"nodes": nodes, "edges": edges}

proc layoutJson*(draft: TopologyDraft): JsonNode =
  result = newJObject()
  for node in draft.nodes: result[node.id] = %*{"x": node.x, "y": node.y}

proc topologySavePayload*(draft: TopologyDraft): JsonNode =
  if draft.nodes.len == 0: fail("Add at least one node before saving.")
  let name = draft.name.strip()
  if name.len == 0 or name.runeLen > topologyNameLimit: fail("Name the topology (at most 120 characters).")
  result = %*{"name": name, "design": designJson(draft), "layout": layoutJson(draft)}
  if draft.version > 0: result["base_version"] = %draft.version

proc checkedName(row: JsonNode): string =
  result = requireText(row, "name")
  if result != result.strip() or result.runeLen > topologyNameLimit: fail("The topology has an invalid name.")

proc parseTopologyList*(data: JsonNode): seq[TopologySummary] =
  var identities: seq[string]
  for row in requireArray(data, "topologies"):
    let id = requireHex(row, "topology_id", 32)
    if id in identities: fail("The topology list repeats an identity.")
    identities.add id
    result.add TopologySummary(id: id, name: checkedName(row), version: requireInt(row, "version"),
      digest: requireHex(row, "design_sha256", 64), updatedAt: text(row, "updated_at"))

proc parseTopology*(data: JsonNode): TopologyDraft =
  ## Reads one saved topology and rejects anything the editor could not round-trip.
  if data == nil or data.kind != JObject or not data.hasKey("topology") or data["topology"].kind != JObject:
    fail("The topology response is invalid.")
  let row = data["topology"]
  if text(row, "state_kind") != "desired": fail("The topology response is not desired state.")
  result = TopologyDraft(id: requireHex(row, "topology_id", 32), name: checkedName(row),
    version: requireInt(row, "version"), digest: requireHex(row, "design_sha256", 64))
  let design = if row.hasKey("design"): row["design"] else: newJNull()
  let layout = if row.hasKey("layout"): row["layout"] else: newJNull()
  if design.kind != JObject or design.len != 2 or layout.kind != JObject:
    fail("The saved topology is invalid.")
  let nodes = requireArray(design, "nodes")
  if layout.len != nodes.len: fail("The saved topology canvas is incomplete.")
  for node in nodes:
    if node.kind != JObject or node.len != 4 or not node.hasKey("properties") or node["properties"].kind != JObject:
      fail("The saved topology node is invalid.")
    let id = requireText(node, "id")
    let kind = requireText(node, "kind")
    if not validNodeId(id) or not validKind(kind) or result.hasNode(id) or not node.hasKey("label") or
        node["label"].kind != JString:
      fail("The saved topology node is invalid.")
    let position = if layout.hasKey(id): layout[id] else: newJNull()
    if position.kind != JObject or position.len != 2 or not position.hasKey("x") or not position.hasKey("y") or
        position["x"].kind != JInt or position["y"].kind != JInt or
        abs(position["x"].getInt) > topologyCanvasLimit or abs(position["y"].getInt) > topologyCanvasLimit:
      fail("The saved topology canvas is incomplete.")
    var lines: seq[string]
    for name, value in node["properties"]:
      lines.add name & "=" & propertyText(value)
    result.nodes.add TopologyNode(id: id, kind: kind, label: node["label"].getStr, properties: lines.join("\n"),
      x: position["x"].getInt, y: position["y"].getInt)
  for edge in requireArray(design, "edges"):
    if edge.kind != JObject or edge.len != 3: fail("The saved topology connection is invalid.")
    let source = requireText(edge, "from")
    let target = requireText(edge, "to")
    let relation = requireText(edge, "relation")
    if not result.hasNode(source) or not result.hasNode(target) or source == target or relation notin topologyRelations:
      fail("The saved topology connection is invalid.")
    result.edges.add TopologyEdge(source: source, target: target, relation: relation)

proc parseTopologySave*(data: JsonNode, previous: TopologyDraft, payload: JsonNode): TopologyDraft =
  result = parseTopology(data)
  if (previous.id.len > 0 and result.id != previous.id) or result.version != previous.version + 1 or
      result.name != payload["name"].getStr or designJson(result) != payload["design"] or
      layoutJson(result) != payload["layout"]:
    fail("The saved topology differs from this exact save request. Reload before another change.")

proc parseTopologyArchive*(data: JsonNode, identity: string) =
  if data == nil or data.kind != JObject or text(data, "topology_id") != identity or
      not data.hasKey("archived") or data["archived"].kind != JBool or not data["archived"].getBool:
    fail("The archive response did not confirm this topology. Refresh before trying again.")

proc topologyDriftPayload*(draft: TopologyDraft): JsonNode =
  if draft.id.len == 0 or draft.version == 0: fail("Save the topology before checking it.")
  %*{"version": draft.version}

proc shown(value: JsonNode): string =
  if value == nil or value.kind == JNull: "null" else: $value

proc parseDrift*(data: JsonNode, draft: TopologyDraft): DriftReport =
  ## A report is shown only when it is simulated state for the exact open version.
  if data == nil or data.kind != JObject or text(data, "schema") != "topology-drift.v1" or
      text(data, "state_kind") != "simulated" or
      not data.hasKey("execution_enabled") or data["execution_enabled"] != %false or
      not data.hasKey("apply_to_live") or data["apply_to_live"] != %false:
    fail("The drift report is not an advisory comparison.")
  result = DriftReport(topologyId: requireHex(data, "topology_id", 32),
    version: requireInt(data, "topology_version"), observedAt: requireText(data, "observed_at"))
  if result.topologyId != draft.id or result.version != draft.version:
    fail("The drift report describes another topology version. Check again.")
  for row in requireArray(data, "sources"):
    result.sources.add (id: requireText(row, "id"), state: requireText(row, "state"), errorCode: text(row, "error_code"))
  for row in requireArray(data, "nodes"):
    let status = requireText(row, "status")
    if status notin ["matches", "drifted", "missing", "unknown"]: fail("The drift report has an unknown status.")
    var node = DriftNode(id: requireText(row, "id"), status: status, reason: text(row, "reason"))
    for difference in requireArray(row, "differences"):
      let observed = if difference.hasKey("observed_present") and difference["observed_present"] == %false:
          "not reported" else: shown(difference{"observed"})
      node.differences.add requireText(difference, "property") & ": expected " & shown(difference{"expected"}) &
        ", observed " & observed
    result.nodes.add node
  let counts = data{"counts"}
  result.counts = (matches: requireInt(counts, "matches", 0), drifted: requireInt(counts, "drifted", 0),
                   missing: requireInt(counts, "missing", 0), unknown: requireInt(counts, "unknown", 0))
  for value in requireArray(data, "potentially_affected"): result.affected.add value.getStr
  for value in requireArray(data, "not_in_design"): result.notInDesign.add value.getStr
  for value in requireArray(data, "notes"): result.notes.add value.getStr

proc driftStatusLabel*(status: string): string =
  case status
  of "matches": "Matches"
  of "drifted": "Drifted"
  of "missing": "Missing"
  else: "Unknown"

proc driftReasonLabel*(reason: string): string =
  case reason
  of "source_unavailable": "source could not be read"
  of "source_not_configured": "source not configured"
  of "not_read": "router refused this interface"
  of "not_in_source_scope": "not in the observed scope"
  of "no_source": "no observation source for this kind"
  else: reason.replace("_", " ")

proc parseNetlist*(data: JsonNode): NetlistReport =
  if data == nil or data.kind != JObject or text(data, "schema") != "pcb-netlist-inspection.v1" or
      text(data, "state_kind") != "desired" or text(data, "actuation") != "none":
    fail("The netlist report is not a design inspection.")
  let summary = data{"summary"}
  result = NetlistReport(tool: text(data, "tool"), digest: requireHex(data, "sha256", 64),
    components: requireInt(summary, "components", 0), nets: requireInt(summary, "nets", 0),
    connections: requireInt(summary, "connections", 0), errors: requireInt(summary, "errors", 0),
    warnings: requireInt(summary, "warnings", 0),
    truncated: data.hasKey("findings_truncated") and data["findings_truncated"] == %true)
  for row in requireArray(data, "findings"):
    result.findings.add (severity: requireText(row, "severity"), subject: requireText(row, "subject"),
                         message: requireText(row, "message"))
