import std/[json, strutils, unittest]
import ../src/app/engineering

let topologyId = "a".repeat(32)
let digest = "1".repeat(64)

proc savedJson(version = 1): JsonNode =
  %*{"topology": {"topology_id": topologyId, "name": "Lab stack", "version": version,
     "design_sha256": digest, "state_kind": "desired",
     "design": {"nodes": [
       {"id": "container:itsm-surrealdb", "kind": "container", "label": "Database",
        "properties": {"state": "running"}},
       {"id": "endpoint:phoenix", "kind": "service_endpoint", "label": "Backend", "properties": {"up": true}}],
      "edges": [{"from": "endpoint:phoenix", "to": "container:itsm-surrealdb", "relation": "depends_on"}]},
     "layout": {"container:itsm-surrealdb": {"x": 40, "y": 40}, "endpoint:phoenix": {"x": 300, "y": 40}}}}

proc driftJson(version = 1): JsonNode =
  %*{"schema": "topology-drift.v1", "state_kind": "simulated", "topology_id": topologyId,
     "topology_version": version, "observed_at": "2026-10-29T01:00:00+00:00",
     "observation_sha256": "b".repeat(64),
     "sources": [{"id": "containers", "state": "observed", "error_code": nil},
                 {"id": "router", "state": "unavailable", "error_code": "provider_timeout"}],
     "nodes": [{"id": "container:itsm-surrealdb", "status": "drifted", "differences": [
                 {"property": "state", "expected": "running", "observed": "exited", "observed_present": true}]},
               {"id": "endpoint:phoenix", "status": "unknown", "reason": "source_unavailable", "differences": []}],
     "counts": {"matches": 0, "drifted": 1, "missing": 0, "unknown": 1},
     "potentially_affected": ["endpoint:phoenix"], "not_in_design": ["container:itsm-git-lab"],
     "execution_enabled": false, "apply_to_live": false, "notes": ["Only declared properties are compared."]}

suite "topology design":
  test "a saved topology round-trips through the editor model":
    let draft = parseTopology(savedJson())
    check draft.id == topologyId and draft.version == 1 and draft.digest == digest
    check draft.nodes.len == 2 and draft.edges.len == 1
    check draft.nodes[1].x == 300
    check draft.nodes[0].properties == "state=running"
    let payload = topologySavePayload(draft)
    check payload["design"] == savedJson()["topology"]["design"]
    check payload["layout"] == savedJson()["topology"]["layout"]
    check payload["base_version"].getInt == 1

  test "properties are typed from their text form":
    var draft = TopologyDraft(name: "Typed")
    draft = addTopologyNode(draft, "router", "edge")
    draft = setNodeProperties(draft, "router:edge", "up=true\nports=4\nratio=1.5\nmodel=AX-1\nnote=\nmissing=null")
    let node = topologySavePayload(draft)["design"]["nodes"][0]
    check node["properties"] == %*{"up": true, "ports": 4, "ratio": 1.5, "model": "AX-1", "note": "", "missing": nil}
    check node["kind"].getStr == "router" and node["label"].getStr == "edge"

  test "quoted values stay text":
    var draft = addTopologyNode(TopologyDraft(name: "Text"), "service", "api")
    draft = setNodeProperties(draft, "service:api", "version=\"4\"\nflag=\"true\"")
    check topologySavePayload(draft)["design"]["nodes"][0]["properties"] == %*{"version": "4", "flag": "true"}

  test "invalid property lines are refused and the node is unchanged":
    var draft = addTopologyNode(TopologyDraft(name: "Bad"), "service", "api")
    for text in ["no equals sign", "Bad Key=x", "=x", "a=1\na=2", "admin_password=x", "api_key=x"]:
      expect ValueError: discard setNodeProperties(draft, "service:api", text)
    check draft.nodes[0].properties == ""

  test "node identities are unique type:name values":
    var draft = addTopologyNode(TopologyDraft(name: "Ids"), "container", "itsm-surrealdb")
    check draft.nodes[0].id == "container:itsm-surrealdb"
    expect ValueError: discard addTopologyNode(draft, "container", "itsm-surrealdb")
    expect ValueError: discard addTopologyNode(draft, "Container", "x")
    expect ValueError: discard addTopologyNode(draft, "host", "bad name")
    expect ValueError: discard addTopologyNode(draft, "host", "")

  test "new nodes are placed on the grid without overlapping":
    var draft = TopologyDraft(name: "Grid")
    for name in ["a", "b", "c", "d"]:
      draft = addTopologyNode(draft, "host", name)
    var seen: seq[(int, int)]
    for node in draft.nodes:
      check node.x mod topologyGrid == 0 and node.y mod topologyGrid == 0
      check (node.x, node.y) notin seen
      seen.add (node.x, node.y)

  test "edges join two existing nodes once with a known relation":
    var draft = addTopologyNode(TopologyDraft(name: "Edges"), "service", "api")
    draft = addTopologyNode(draft, "container", "db")
    draft = addTopologyEdge(draft, "service:api", "container:db", "depends_on")
    check draft.edges.len == 1
    expect ValueError: discard addTopologyEdge(draft, "service:api", "container:db", "depends_on")
    expect ValueError: discard addTopologyEdge(draft, "service:api", "service:api", "depends_on")
    expect ValueError: discard addTopologyEdge(draft, "service:api", "ghost:node", "depends_on")
    expect ValueError: discard addTopologyEdge(draft, "service:api", "container:db", "executes")
    draft = removeTopologyEdge(draft, 0)
    check draft.edges.len == 0

  test "removing a node removes its edges":
    var draft = addTopologyNode(TopologyDraft(name: "Remove"), "service", "api")
    draft = addTopologyNode(draft, "container", "db")
    draft = addTopologyEdge(draft, "service:api", "container:db", "hosted_on")
    draft = removeTopologyNode(draft, "container:db")
    check draft.nodes.len == 1 and draft.edges.len == 0

  test "moving snaps to the grid and stays on the canvas":
    var draft = addTopologyNode(TopologyDraft(name: "Move"), "host", "a")
    draft = moveTopologyNode(draft, "host:a", 13, -500)
    check draft.nodes[0].x mod topologyGrid == 0 and draft.nodes[0].y == 0

  test "an empty or unnamed topology is not saved":
    expect ValueError: discard topologySavePayload(TopologyDraft(name: "Empty"))
    let draft = addTopologyNode(TopologyDraft(name: "  "), "host", "a")
    expect ValueError: discard topologySavePayload(draft)

  test "malformed saved topologies are refused":
    for mutate in [
        proc(row: JsonNode) = row["state_kind"] = %"observed",
        proc(row: JsonNode) = row["topology_id"] = %"short",
        proc(row: JsonNode) = row["design"]["nodes"][0]["id"] = %"bad id",
        proc(row: JsonNode) = row["layout"].delete("endpoint:phoenix"),
        proc(row: JsonNode) = row["design"]["edges"][0]["to"] = %"ghost:node",
        proc(row: JsonNode) = row["design"]["nodes"][0]["properties"] = %*{"nested": {"a": 1}}]:
      let data = savedJson()
      mutate(data["topology"])
      expect ValueError: discard parseTopology(data)

  test "a save receipt must echo exactly the saved request":
    let draft = parseTopology(savedJson())
    let payload = topologySavePayload(draft)
    check parseTopologySave(savedJson(2), draft, payload).version == 2
    expect ValueError: discard parseTopologySave(savedJson(3), draft, payload)
    let changed = savedJson(2)
    changed["topology"]["design"]["nodes"][0]["properties"]["state"] = %"exited"
    expect ValueError: discard parseTopologySave(changed, draft, payload)

  test "the topology list is read strictly":
    let rows = parseTopologyList(%*{"topologies": [{"topology_id": topologyId, "name": "Lab", "version": 2,
      "design_sha256": digest, "updated_at": "2026-10-29T01:00:00Z"}]})
    check rows.len == 1 and rows[0].version == 2
    expect ValueError: discard parseTopologyList(%*{"topologies": [{"topology_id": "x", "name": "Lab", "version": 2,
      "design_sha256": digest}]})

  test "an archive answer must confirm this topology":
    parseTopologyArchive(%*{"topology_id": topologyId, "archived": true}, topologyId)
    for answer in [%*{"topology_id": topologyId, "archived": false}, %*{"topology_id": topologyId},
                   %*{"topology_id": topologyId, "archived": "true"},
                   %*{"topology_id": "b".repeat(32), "archived": true}]:
      expect ValueError: parseTopologyArchive(answer, topologyId)

suite "drift report":
  test "a report for the open version is accepted with labelled states":
    let draft = parseTopology(savedJson())
    let report = parseDrift(driftJson(), draft)
    check report.counts == (matches: 0, drifted: 1, missing: 0, unknown: 1)
    check report.nodes[0].status == "drifted"
    check report.nodes[0].differences[0] == "state: expected \"running\", observed \"exited\""
    check report.nodes[1].reason == "source_unavailable"
    check report.affected == @["endpoint:phoenix"]
    check report.notInDesign == @["container:itsm-git-lab"]
    check report.sources[1] == (id: "router", state: "unavailable", errorCode: "provider_timeout")

  test "a report for another version or that enables execution is refused":
    let draft = parseTopology(savedJson())
    expect ValueError: discard parseDrift(driftJson(2), draft)
    for key in ["execution_enabled", "apply_to_live"]:
      let data = driftJson()
      data[key] = %true
      expect ValueError: discard parseDrift(data, draft)
    let observed = driftJson()
    observed["state_kind"] = %"observed"
    expect ValueError: discard parseDrift(observed, draft)

  test "status and reason labels are plain words":
    check driftStatusLabel("matches") == "Matches"
    check driftStatusLabel("drifted") == "Drifted"
    check driftStatusLabel("missing") == "Missing"
    check driftStatusLabel("unknown") == "Unknown"
    check driftReasonLabel("source_unavailable") == "source could not be read"
    check driftReasonLabel("source_not_configured") == "source not configured"
    check driftReasonLabel("not_read") == "router refused this interface"
    check driftReasonLabel("not_in_source_scope") == "not in the observed scope"
    check driftReasonLabel("no_source") == "no observation source for this kind"

suite "netlist report":
  test "a netlist report is summarised and findings keep their order":
    let report = parseNetlist(%*{"schema": "pcb-netlist-inspection.v1", "state_kind": "desired",
      "actuation": "none", "format": "kicad", "tool": "Eeschema 7.0.10", "sha256": "c".repeat(64),
      "summary": {"components": 3, "nets": 2, "connections": 5, "errors": 1, "warnings": 0},
      "components": [{"ref": "R1", "value": "10k", "footprint": nil, "part": "Device:R", "pins": 2}],
      "nets": [{"code": "1", "name": "GND", "connections": 2, "nodes": ["C1.2", "U1.8"]}],
      "findings": [{"severity": "error", "code": "missing_footprint", "subject": "R1",
                    "message": "This component has no footprint."}],
      "findings_truncated": false})
    check report.components == 3 and report.nets == 2 and report.errors == 1
    check report.findings[0] == (severity: "error", subject: "R1", message: "This component has no footprint.")
    check report.tool == "Eeschema 7.0.10"

  test "a netlist report that claims actuation is refused":
    expect ValueError: discard parseNetlist(%*{"schema": "pcb-netlist-inspection.v1", "state_kind": "desired",
      "actuation": "flash", "format": "kicad", "tool": nil, "sha256": "c".repeat(64),
      "summary": {"components": 0, "nets": 0, "connections": 0, "errors": 0, "warnings": 0},
      "components": [], "nets": [], "findings": [], "findings_truncated": false})
