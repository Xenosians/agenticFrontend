include karax/prelude
import std/asyncjs
import ../api/operations
import ../api/client
import ../api/proxmox_requests
import proxmox_snapshot
import proxmox_actions
import tailnet_snapshot
import types
import state
import request_context

const proxmoxRefreshMs = 10_000
  ## The live dashboard re-reads Proxmox this often while it is on screen.
const tailnetRefreshMs = 30_000
  ## Device health changes slowly; the Tailscale API is rate limited per tailnet.

proc everyInterval(callback: proc(), milliseconds: int): int {.importjs: "setInterval(#, #)".}
proc stopInterval(id: int) {.importjs: "clearInterval(#)".}
proc pageVisible(): bool {.importjs: "(document.visibilityState !== 'hidden')".}
proc onVisibilityChange(callback: proc()) {.importjs: "document.addEventListener('visibilitychange', #)".}
proc randomUuid(): cstring {.importjs: "globalThis.crypto.randomUUID()".}

var
  proxmoxTimer = 0
  tailnetTimer = 0
  visibilityWatched = false
  pendingProxmoxFocus = ""

proc consumeProxmoxFocus*(): string =
  ## The element to focus after the next render (a confirmation, the composer).
  result = pendingProxmoxFocus
  pendingProxmoxFocus = ""

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
  state.proxmoxErrorReason = ""
  state.proxmoxErrorMessage = ""
  redraw(kxi)
  try:
    let snapshot = parseProxmoxSnapshot(await getProxmoxOverview())
    if not matchesProxmoxRequest(state, request): return
    state.proxmox = snapshot
    state.proxmoxLoaded = true
  except ProxmoxReadFailed as failure:
    if matchesProxmoxRequest(state, request):
      state.proxmoxError = failure.msg
      state.proxmoxErrorReason = failure.reason
      state.proxmoxErrorMessage = failure.detail
      state.proxmoxLoaded = false
  except CatchableError as exc:
    if matchesProxmoxRequest(state, request):
      state.proxmoxError = exc.msg
      state.proxmoxLoaded = false
  finally:
    if matchesProxmoxRequest(state, request): state.proxmoxBusy = false
    redraw(kxi)

proc refreshProxmoxActions*(state: AppState) {.async.} =
  ## The owner's recent actions. A list read never replaces a decision in flight.
  if not state.auth.authenticated or state.proxmoxActionBusy: return
  let account = proxmoxActionsAccount(state)
  try:
    let actions = await fetchProxmoxActions()
    if not matchesProxmoxActionRequest(state, account) or state.proxmoxActionBusy: return
    state.proxmoxActions = actions
    state.proxmoxActionsError = ""
  except CatchableError as exc:
    if matchesProxmoxActionRequest(state, account):
      state.proxmoxActionsError = exc.msg
  finally:
    redraw(kxi)

proc refreshTailnetOverview*(state: AppState) {.async.} =
  if not state.auth.authenticated or state.tailnetBusy: return
  let request = beginTailnetRequest(state)
  state.tailnetBusy = true
  redraw(kxi)
  try:
    let snapshot = parseTailnetSnapshot(await getTailnetOverview())
    if not matchesTailnetRequest(state, request): return
    state.tailnet = snapshot
    state.tailnetLoaded = true
    state.tailnetError = ""
    state.tailnetErrorReason = ""
    state.tailnetErrorMessage = ""
  except TailnetReadFailed as failure:
    if matchesTailnetRequest(state, request):
      state.tailnetError = failure.msg
      state.tailnetErrorReason = failure.reason
      state.tailnetErrorMessage = failure.detail
      state.tailnetLoaded = false
  except CatchableError as exc:
    if matchesTailnetRequest(state, request):
      state.tailnetError = exc.msg
      state.tailnetErrorReason = ""
      state.tailnetErrorMessage = ""
      state.tailnetLoaded = false
  finally:
    if matchesTailnetRequest(state, request): state.tailnetBusy = false
    redraw(kxi)

proc proxmoxDashboardOnScreen(state: AppState): bool =
  state.auth.authenticated and state.activeView in [viewJobs, viewRuns, viewLogs] and pageVisible()

proc stopProxmoxRefresh*() =
  if proxmoxTimer != 0:
    stopInterval(proxmoxTimer)
    proxmoxTimer = 0
  if tailnetTimer != 0:
    stopInterval(tailnetTimer)
    tailnetTimer = 0

proc startProxmoxRefresh*(state: AppState) =
  ## Keep the dashboards live while they are on screen; stop as soon as they are not.
  if not visibilityWatched:
    visibilityWatched = true
    onVisibilityChange(proc() =
      if proxmoxDashboardOnScreen(state):
        # Coming back shows current data at once, then keeps it live.
        discard refreshProxmoxOverview(state)
        discard refreshTailnetOverview(state)
        startProxmoxRefresh(state)
      else:
        stopProxmoxRefresh())
  if proxmoxTimer == 0:
    proxmoxTimer = everyInterval(proc() =
      if proxmoxDashboardOnScreen(state):
        discard refreshProxmoxOverview(state)
      else:
        stopProxmoxRefresh(),
      proxmoxRefreshMs)
  if tailnetTimer == 0:
    tailnetTimer = everyInterval(proc() =
      if proxmoxDashboardOnScreen(state):
        discard refreshTailnetOverview(state)
      else:
        stopProxmoxRefresh(),
      tailnetRefreshMs)

proc confirmingAction*(state: AppState): ProxmoxAction =
  for action in state.proxmoxActions:
    if action.actionId == state.proxmoxConfirming: return action

proc proposeGuestAction*(state: AppState, guest: ProxmoxGuest, action: string) {.async.} =
  ## Prepare one action for this exact guest; the confirmation decides it.
  if not state.auth.authenticated or state.proxmoxActionBusy or state.proxmoxConfirming.len > 0: return
  let request = beginProxmoxActionRequest(state)
  state.proxmoxActionBusy = true
  state.proxmoxActionError = ""
  redraw(kxi)
  try:
    let proposed = await proposeProxmoxAction(state.auth.csrfToken, guest.node, guest.vmid, action,
                                              $randomUuid())
    if not matchesProxmoxActionRequest(state, request): return
    state.proxmoxActions = mergeProxmoxAction(state.proxmoxActions, proposed)
    if proposed.status == "waiting_approval":
      state.proxmoxConfirming = proposed.actionId
      pendingProxmoxFocus = "proxmoxConfirmCancel"
  except CatchableError as exc:
    if matchesProxmoxActionRequest(state, request): state.proxmoxActionError = exc.msg
  finally:
    if matchesProxmoxActionRequest(state, request): state.proxmoxActionBusy = false
    redraw(kxi)

proc decideGuestAction*(state: AppState, actionId: string, approve: bool) {.async.} =
  ## Confirm or cancel the open proposal; the server records the decision once.
  if not state.auth.authenticated or state.proxmoxActionBusy or actionId.len == 0: return
  let request = beginProxmoxActionRequest(state)
  state.proxmoxActionBusy = true
  state.proxmoxActionError = ""
  redraw(kxi)
  var reread = false
  try:
    let decided = await decideProxmoxAction(state.auth.csrfToken, actionId, approve)
    if not matchesProxmoxActionRequest(state, request): return
    state.proxmoxActions = mergeProxmoxAction(state.proxmoxActions, decided)
    # The guest changed state: show it now instead of at the next refresh.
    if approve: discard refreshProxmoxOverview(state)
  except CatchableError as exc:
    if matchesProxmoxActionRequest(state, request):
      state.proxmoxActionError = exc.msg
      reread = true
  finally:
    if matchesProxmoxActionRequest(state, request):
      state.proxmoxActionBusy = false
      if state.proxmoxConfirming == actionId:
        state.proxmoxConfirming = ""
        pendingProxmoxFocus = "proxmoxActionsTitle"
    redraw(kxi)
  # The saved outcome is the truth; read it back instead of guessing.
  if reread: discard refreshProxmoxActions(state)

proc reviewGuestAction*(state: AppState, actionId: string) =
  if state.proxmoxActionBusy: return
  state.proxmoxActionError = ""
  state.proxmoxConfirming = actionId
  pendingProxmoxFocus = "proxmoxConfirmCancel"
  redraw(kxi)

proc askAboutGuest*(state: AppState, guest: ProxmoxGuest) =
  ## Prefill an exact read request in chat; the owner sends it.
  setComposerDraft(state, proxmoxAskText(guest.node, guest.vmid))
  stopProxmoxRefresh()
  setActiveView(state, viewChat)
  pendingProxmoxFocus = "messageInput"
  redraw(kxi)

proc openOperations*(state: AppState) =
  setActiveView(state, viewJobs)
  discard refreshOperations(state)
  discard refreshProxmoxOverview(state)
  discard refreshProxmoxActions(state)
  discard refreshTailnetOverview(state)
  startProxmoxRefresh(state)
