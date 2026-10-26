include karax/prelude
import std/asyncjs
import ../api/operations
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

proc openOperations*(state: AppState) =
  setActiveView(state, viewJobs)
  discard refreshOperations(state)
