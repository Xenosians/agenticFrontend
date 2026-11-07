include karax/prelude
import std/asyncjs
import ../api/operations
import ../api/client
import proxmox_snapshot
import types
import state
import request_context

proc refreshOperations*(state: AppState) {.async.} =
  if not state.auth.authenticated or state.operationsBusy: return
  let request = beginOperationsRequest(state)
  state.operationsBusy = true
  state.operationsError = ""
  redraw(kxi)
  try:
    let snapshot = await fetchOperations()
    if not matchesOperationsRequest(state, request): return
    state.operations = snapshot
    state.operationsLoaded = true
    state.operationsExpandedJob = ""
  except CatchableError as exc:
    if matchesOperationsRequest(state, request):
      state.operationsError = exc.msg
      state.operationsLoaded = false
  finally:
    if matchesOperationsRequest(state, request): state.operationsBusy = false
    redraw(kxi)

proc refreshProxmoxOverview*(state: AppState) {.async.} =
  if not state.auth.authenticated or state.proxmoxBusy: return
  let request = beginProxmoxRequest(state)
  state.proxmoxBusy = true
  state.proxmoxError = ""
  redraw(kxi)
  try:
    let snapshot = parseProxmoxSnapshot(await getProxmoxOverview())
    if not matchesProxmoxRequest(state, request): return
    state.proxmox = snapshot
    state.proxmoxLoaded = true
  except CatchableError as exc:
    if matchesProxmoxRequest(state, request):
      state.proxmoxError = exc.msg
      state.proxmoxLoaded = false
  finally:
    if matchesProxmoxRequest(state, request): state.proxmoxBusy = false
    redraw(kxi)

proc openOperations*(state: AppState) =
  setActiveView(state, viewJobs)
  discard refreshOperations(state)
  discard refreshProxmoxOverview(state)
