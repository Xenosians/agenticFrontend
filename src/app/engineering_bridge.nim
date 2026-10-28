## Loads, edits, saves and checks the owner's topologies, and inspects netlists.
## Every server answer is bound to the request that asked for it; a stale
## answer is dropped. Nothing here can change a device.
include karax/prelude
import std/[asyncjs, json]
import ../api/engineering as engineeringApi
import engineering
import types
import state
import request_context

proc engineeringBusy*(state: AppState): bool =
  state.engineeringBusy or state.engineeringSaving or state.engineeringChecking

proc clearEngineeringReports(state: AppState) =
  state.engineeringDrift = DriftReport()
  state.engineeringHasDrift = false

proc newTopologyDraft*(state: AppState) =
  if engineeringBusy(state): return
  inc state.engineeringEpoch
  state.engineeringDraft = TopologyDraft(name: "New topology")
  state.engineeringSelectedNode = ""
  state.engineeringEdgeTarget = ""
  state.engineeringDirty = false
  state.engineeringError = ""
  state.engineeringNotice = ""
  clearEngineeringReports(state)

proc editTopology*(state: AppState, change: proc(draft: TopologyDraft): TopologyDraft) =
  ## Applies one local edit; a refused edit leaves the canvas unchanged.
  if engineeringBusy(state): return
  try:
    state.engineeringDraft = change(state.engineeringDraft)
    state.engineeringDirty = true
    state.engineeringError = ""
    state.engineeringNotice = ""
    # A report describes a saved version; an edited canvas no longer matches it.
    clearEngineeringReports(state)
  except ValueError as exc:
    state.engineeringError = exc.msg

proc refreshTopologies*(state: AppState) {.async.} =
  if not state.auth.authenticated or engineeringBusy(state): return
  let request = beginEngineeringRequest(state)
  state.engineeringBusy = true
  state.engineeringError = ""
  redraw(kxi)
  try:
    let rows = parseTopologyList(await engineeringApi.listTopologies())
    if not matchesEngineeringRequest(state, request): return
    state.engineeringTopologies = rows
    state.engineeringLoaded = true
  except CatchableError as exc:
    if matchesEngineeringRequest(state, request): state.engineeringError = exc.msg
  finally:
    if matchesEngineeringRequest(state, request): state.engineeringBusy = false
    redraw(kxi)

proc openTopology*(state: AppState, id: string) {.async.} =
  if not state.auth.authenticated or engineeringBusy(state): return
  let request = beginEngineeringRequest(state)
  state.engineeringBusy = true
  state.engineeringError = ""
  state.engineeringNotice = ""
  redraw(kxi)
  try:
    let draft = parseTopology(await engineeringApi.getTopology(id))
    if not matchesEngineeringRequest(state, request): return
    if draft.id != id: raise newException(ValueError, "The opened topology does not match the requested identity.")
    state.engineeringDraft = draft
    state.engineeringSelectedNode = ""
    state.engineeringEdgeTarget = ""
    state.engineeringDirty = false
    clearEngineeringReports(state)
  except CatchableError as exc:
    if matchesEngineeringRequest(state, request): state.engineeringError = exc.msg
  finally:
    if matchesEngineeringRequest(state, request): state.engineeringBusy = false
    redraw(kxi)

proc saveTopologyDraft*(state: AppState) {.async.} =
  if not state.auth.authenticated or engineeringBusy(state): return
  let draft = state.engineeringDraft
  var payload: JsonNode
  try:
    payload = topologySavePayload(draft)
  except ValueError as exc:
    state.engineeringError = exc.msg
    redraw(kxi)
    return
  let request = beginEngineeringRequest(state)
  state.engineeringSaving = true
  state.engineeringError = ""
  state.engineeringNotice = ""
  redraw(kxi)
  try:
    let response = await engineeringApi.saveTopology(draft.id, payload, state.auth.csrfToken)
    if not matchesEngineeringRequest(state, request): return
    let saved = parseTopologySave(response, draft, payload)
    state.engineeringDraft = saved
    state.engineeringDirty = false
    state.engineeringNotice = "Saved version " & $saved.version & "."
    redraw(kxi)
    let rows = parseTopologyList(await engineeringApi.listTopologies())
    if matchesEngineeringRequest(state, request): state.engineeringTopologies = rows
  except CatchableError as exc:
    if matchesEngineeringRequest(state, request): state.engineeringError = exc.msg
  finally:
    if matchesEngineeringRequest(state, request): state.engineeringSaving = false
    redraw(kxi)

proc archiveTopologyDraft*(state: AppState) {.async.} =
  if not state.auth.authenticated or engineeringBusy(state) or state.engineeringDraft.id.len == 0: return
  let identity = state.engineeringDraft.id
  let request = beginEngineeringRequest(state)
  state.engineeringSaving = true
  state.engineeringError = ""
  redraw(kxi)
  try:
    parseTopologyArchive(await engineeringApi.archiveTopology(identity, state.auth.csrfToken), identity)
    if not matchesEngineeringRequest(state, request): return
    state.engineeringDraft = TopologyDraft(name: "New topology")
    state.engineeringSelectedNode = ""
    state.engineeringDirty = false
    clearEngineeringReports(state)
    state.engineeringNotice = "Topology archived."
    redraw(kxi)
    let rows = parseTopologyList(await engineeringApi.listTopologies())
    if matchesEngineeringRequest(state, request): state.engineeringTopologies = rows
  except CatchableError as exc:
    if matchesEngineeringRequest(state, request): state.engineeringError = exc.msg
  finally:
    if matchesEngineeringRequest(state, request): state.engineeringSaving = false
    redraw(kxi)

proc checkTopologyDrift*(state: AppState) {.async.} =
  ## Observes the configured sources and compares them with the saved version.
  if not state.auth.authenticated or engineeringBusy(state): return
  if state.engineeringDirty:
    state.engineeringError = "Save your changes first; a check compares the saved version."
    redraw(kxi)
    return
  let draft = state.engineeringDraft
  var payload: JsonNode
  try:
    payload = topologyDriftPayload(draft)
  except ValueError as exc:
    state.engineeringError = exc.msg
    redraw(kxi)
    return
  let request = beginEngineeringRequest(state)
  state.engineeringChecking = true
  state.engineeringError = ""
  state.engineeringNotice = ""
  clearEngineeringReports(state)
  redraw(kxi)
  try:
    let report = parseDrift(await engineeringApi.checkTopologyDrift(draft.id, payload, state.auth.csrfToken), draft)
    if not matchesEngineeringRequest(state, request): return
    state.engineeringDrift = report
    state.engineeringHasDrift = true
  except CatchableError as exc:
    if matchesEngineeringRequest(state, request): state.engineeringError = exc.msg
  finally:
    if matchesEngineeringRequest(state, request): state.engineeringChecking = false
    redraw(kxi)

proc inspectNetlistText*(state: AppState) {.async.} =
  if not state.auth.authenticated or engineeringBusy(state): return
  let text = state.engineeringNetlistText
  if text.len == 0:
    state.engineeringError = "Choose a KiCad netlist file (.net) first."
    redraw(kxi)
    return
  let request = beginEngineeringRequest(state)
  state.engineeringChecking = true
  state.engineeringError = ""
  state.engineeringHasNetlist = false
  redraw(kxi)
  try:
    let report = parseNetlist(await engineeringApi.inspectNetlist(text, state.auth.csrfToken))
    if not matchesEngineeringRequest(state, request): return
    state.engineeringNetlist = report
    state.engineeringHasNetlist = true
  except CatchableError as exc:
    if matchesEngineeringRequest(state, request): state.engineeringError = exc.msg
  finally:
    if matchesEngineeringRequest(state, request): state.engineeringChecking = false
    redraw(kxi)

proc openEngineering*(state: AppState, tab = "infrastructure") =
  setActiveView(state, viewSimulator)
  state.engineeringTab = tab
  if not state.engineeringLoaded: discard refreshTopologies(state)
