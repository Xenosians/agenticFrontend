include karax/prelude
import std/[options, strutils]
import ../app/types
import ../app/operations_snapshot
import ../app/proxmox_snapshot
import ../app/proxmox_actions
import ../app/operations_bridge
import ../app/auth_bridge

proc eventKey(event: Event): cstring {.importjs: "#.key".}
proc stopEvent(event: Event) {.importjs: "((e) => { e.preventDefault(); e.stopPropagation(); })(#)".}

proc localTimestamp(value: cstring): cstring {.
  importjs: "((v) => { const d = new Date(v); return Number.isNaN(d.getTime()) ? v : d.toLocaleString(); })(#)".}

proc measurement(label, value: string): VNode =
  result = buildHtml(tdiv(class = "operation-measurement")):
    span: text label
    strong: text value

proc renderMetric(metric: OperationMetric): VNode =
  result = buildHtml(tdiv(class = "operation-call")):
    tdiv(class = "operation-call-heading"):
      strong: text operationStageLabel(metric.stage)
      span(class = "operation-call-outcome"):
        text metric.outcome.replace("_", " ")
    p(class = "operation-note"):
      text (if metric.role.len > 0: metric.role else: "Workspace") & " · " & metric.adapter &
        " · " & (if metric.operation == "warm": "Warm-up" else: "Generate")
    if metric.repairOf.len > 0:
      p(class = "operation-note"):
        text "Repair of " & operationStageLabel(metric.repairOf)
    tdiv(class = "operation-measurements"):
      measurement("Call duration", durationLabel(some(metric.durationMs)))
      measurement("Scheduler wait", durationLabel(metric.queueMs))
      measurement("Execution", durationLabel(metric.executionMs))
      measurement("First token", durationLabel(metric.firstTokenMs))
      measurement("Generated tokens", tokenLabel(metric.generatedTokens))
      measurement("Estimated input tokens", tokenLabel(metric.estimatedInputTokens))
    details(class = "operation-call-limits"):
      summary: text "Request limits"
      tdiv(class = "operation-measurements"):
        measurement("Request token budget", tokenLabel(metric.requestTokenBudget))
        measurement("Output token cap", tokenLabel(metric.outputTokenCap))
        measurement("Dropped context messages", tokenLabel(metric.droppedMessages))

proc renderOperationJob(state: AppState, job: OperationJob): VNode =
  # One invocation owns each immutable task/chat target captured by handlers.
  result = buildHtml(article(class = "operation-job", `data-job-id` = cstring(job.jobId))):
    tdiv(class = "operation-job-heading"):
      tdiv:
        strong(class = "mono operation-job-id"): text job.jobId
        p(class = "operation-note"):
          text "Attempt " & $job.attempt & " · " &
            (if job.selectedAgent.len > 0: job.selectedAgent else: "No specialist selected")
      span(class = "capability-badge"): text operationStatusLabel(job.status)
    tdiv(class = "operation-measurements"):
      measurement("Until current worker started", durationLabel(job.queueWaitMs))
      measurement("Task elapsed", durationLabel(job.elapsedMs))
    p(class = "operation-note"):
      text "Submitted " & $localTimestamp(cstring(job.createdAt))
    tdiv(class = "operation-job-actions"):
      if job.chatId.len > 0:
        button(class = "secondary-action"):
          text "Open chat"
          proc onclick(event: Event, node: VNode) =
            discard selectChat(state, job.chatId)
      if job.metrics.len > 0:
        button(class = "secondary-action", `aria-expanded` =
            (if state.operationsExpandedJob == job.jobId: cstring"true" else: cstring"false")):
          text (if state.operationsExpandedJob == job.jobId: "Hide recorded calls" else: "Show recorded calls")
          proc onclick(event: Event, node: VNode) =
            state.operationsExpandedJob = if state.operationsExpandedJob == job.jobId: "" else: job.jobId
            redraw(kxi)
      else:
        span(class = "operation-note"): text "Inference timings: Not recorded"
    if state.operationsExpandedJob == job.jobId:
      section(class = "operation-calls"):
        h4: text "Recorded calls · " & $job.metrics.len
        p(class = "operation-note"):
          text "Call times may overlap. Task elapsed includes approval waits."
        if job.metricsTruncated:
          p(class = "operation-note", role = "status"):
            text "More recorded calls are not shown for this attempt."
        for metric in job.metrics:
          renderMetric(metric)

proc proxmoxGuestKind(kind: string): string =
  case kind
  of "qemu": "VM"
  of "lxc": "LXC"
  else: kind.toUpperAscii

proc renderGuestAction(state: AppState, guest: ProxmoxGuest, action: string, blocked: bool): VNode =
  let label = powerActionLabel(action)
  result = buildHtml(button(class = "secondary-action proxmox-power", `data-action` = cstring(action),
      `aria-label` = cstring(label & " " & $guest.vmid), disabled = blocked)):
    text label
    proc onclick(event: Event, node: VNode) = discard proposeGuestAction(state, guest, action)

proc renderGuestActions(state: AppState, guest: ProxmoxGuest): VNode =
  ## One proc per guest row, so every button keeps its own exact target.
  let blocked = state.proxmoxActionBusy or state.proxmoxConfirming.len > 0
  result = buildHtml(tdiv(class = "proxmox-guest-actions")):
    for action in guestPowerActions(guest.status):
      renderGuestAction(state, guest, action, blocked)
    button(class = "secondary-action proxmox-ask", `aria-label` = cstring("Ask in chat about " & $guest.vmid),
        title = "Ask about this guest in chat"):
      text "Ask in chat"
      proc onclick(event: Event, node: VNode) = askAboutGuest(state, guest)

proc renderProxmoxConfirm(state: AppState): VNode =
  ## The server's own description of the exact target; nothing runs until Confirm.
  let action = confirmingAction(state)
  let label = powerActionLabel(action.action)
  result = buildHtml(tdiv(class = "proxmox-confirm-backdrop")):
    tdiv(class = "proxmox-confirm", role = "dialog", `aria-modal` = "true",
         `aria-labelledby` = "proxmoxConfirmTitle", `aria-describedby` = "proxmoxConfirmText"):
      h3(id = "proxmoxConfirmTitle"): text "Confirm Proxmox action"
      if action.action == "force_stop":
        p(class = "proxmox-confirm-warning", role = "note"):
          strong: text "Data loss risk. "
          text "Force stop cuts power to the guest without letting it shut down. Unsaved work in it is lost."
      p(id = "proxmoxConfirmText", class = "proxmox-confirm-text"): text action.approvalText
      dl(class = "proxmox-confirm-target"):
        tdiv:
          dt: text "Guest"
          dd: text proxmoxGuestKind(action.kind) & " " & $action.vmid &
            (if action.name.len > 0: " (" & action.name & ")" else: "")
        tdiv:
          dt: text "Node"
          dd: text action.node
        tdiv:
          dt: text "Risk"
          dd(`data-risk` = cstring(action.risk)):
            text (if action.risk.len > 0: action.risk.capitalizeAscii else: "Not reported")
      tdiv(class = "proxmox-confirm-actions"):
        button(id = "proxmoxConfirmCancel", class = "secondary-action", disabled = state.proxmoxActionBusy):
          text "Cancel"
          proc onclick(event: Event, node: VNode) = discard decideGuestAction(state, action.actionId, false)
        button(class = (if action.action == "force_stop": cstring"primary-action proxmox-confirm-danger"
                        else: cstring"primary-action"),
            disabled = state.proxmoxActionBusy):
          text (if state.proxmoxActionBusy: "Working…" else: label)
          proc onclick(event: Event, node: VNode) = discard decideGuestAction(state, action.actionId, true)
      proc onkeydown(event: Event, node: VNode) =
        if eventKey(event) == "Escape" and not state.proxmoxActionBusy:
          stopEvent(event)
          discard decideGuestAction(state, action.actionId, false)

proc renderProxmoxAction(state: AppState, action: ProxmoxAction): VNode =
  result = buildHtml(li(class = "proxmox-action", `data-status` = cstring(action.status))):
    tdiv(class = "proxmox-action-heading"):
      strong: text powerActionLabel(action.action) & " " & proxmoxGuestKind(action.kind) & " " & $action.vmid &
        (if action.name.len > 0: " (" & action.name & ")" else: "") & " on " & action.node
      span(class = "capability-badge"): text proxmoxActionStatusLabel(action.status)
    if action.observedStatus.len > 0:
      p(class = "operation-note"):
        text "Read back: " & action.observedStatus &
          (if action.verificationOk == some(true): " (as expected)" elif action.expectedStatus.len > 0:
             " (expected " & action.expectedStatus & ")" else: "")
    if action.error.len > 0:
      p(class = "operation-note"): text action.error
    if action.status == "outcome_unknown":
      p(class = "operation-note"): text "Check the guest's state below before trying again."
    p(class = "operation-note"):
      text "Requested " & $localTimestamp(cstring(action.createdAt))
    if action.status == "waiting_approval":
      button(class = "secondary-action", disabled = state.proxmoxActionBusy or state.proxmoxConfirming.len > 0):
        text "Review"
        proc onclick(event: Event, node: VNode) = reviewGuestAction(state, action.actionId)

proc renderProxmoxActions(state: AppState): VNode =
  result = buildHtml(tdiv(class = "proxmox-table-section proxmox-actions")):
    tdiv(class = "section-heading-row"):
      h4(id = "proxmoxActionsTitle", tabindex = "-1"): text "Recent actions"
      span: text $state.proxmoxActions.len & " shown"
    if state.proxmoxActionsError.len > 0:
      p(class = "operation-note", role = "status"): text state.proxmoxActionsError
    if state.proxmoxActions.len == 0:
      tdiv(class = "empty-card"): text "No power actions yet. Each one asks for your confirmation first."
    else:
      ul(class = "proxmox-action-list"):
        for action in state.proxmoxActions:
          renderProxmoxAction(state, action)

proc proxmoxFailureTitle(code: string): string =
  case code
  of "proxmox_not_configured": "Connection not configured"
  of "proxmox_configuration_invalid": "Configuration invalid"
  else: "Proxmox data unavailable"

proc proxmoxFailureHelp(state: AppState): string =
  case state.proxmoxError
  of "proxmox_not_configured":
    "Add the tailnet HTTPS origin and a least-privilege token to the AI connections (see Proxmox prep), then refresh."
  of "proxmox_configuration_invalid":
    "The origin or token shape was rejected. Use https://<machine>.tailXXX.ts.net (serve, 443) or https://<machine>.tailXXX.ts.net:8006 (native) with user@realm!token, never a loopback alias."
  else:
    (if state.proxmoxErrorMessage.len > 0: state.proxmoxErrorMessage & " " else: "") &
      "Check tailscale status, serve status, token permissions and AI logs; never disable TLS verification."

proc renderProxmoxDashboard(state: AppState): VNode =
  let snapshot = state.proxmox
  var virtualMachines, containers: int
  for guest in snapshot.guests:
    if guest.kind == "qemu": inc virtualMachines
    elif guest.kind == "lxc": inc containers
  result = buildHtml(section(class = "proxmox-dashboard", `aria-labelledby` = "proxmoxDashboardTitle")):
    tdiv(class = "proxmox-dashboard-heading"):
      tdiv:
        h3(id = "proxmoxDashboardTitle"): text "Proxmox VE"
        p(class = "operation-note"):
          text "Live inventory from your Proxmox API, refreshed while this page is open. Power actions ask for your confirmation first."
      button(class = "secondary-action", disabled = state.proxmoxBusy,
          `aria-label` = "Refresh Proxmox dashboard"):
        text (if state.proxmoxBusy: "Refreshing…" else: "Refresh")
        proc onclick(event: Event, node: VNode) = discard refreshProxmoxOverview(state)
    if state.proxmoxActionError.len > 0:
      p(class = "operation-error", role = "alert"): text state.proxmoxActionError
    if state.proxmoxBusy and not state.proxmoxLoaded:
      p(class = "operation-note", role = "status"): text "Reading Proxmox…"
    elif state.proxmoxError.len > 0:
      tdiv(class = "proxmox-unavailable", role = "status", `data-error-code` = cstring(state.proxmoxError),
           `data-error-reason` = cstring(state.proxmoxErrorReason)):
        strong: text proxmoxFailureTitle(state.proxmoxError)
        p(class = "operation-note"): text proxmoxFailureHelp(state)
    elif not state.proxmoxLoaded:
      p(class = "operation-note", role = "status"): text "No Proxmox snapshot has been loaded. Refresh to query the provider."
    else:
      tdiv(class = "proxmox-live-status", role = "status"):
        span(class = "proxmox-status-dot", `aria-hidden` = "true")
        strong: text "Connected"
        span(class = "operation-note"): text "Observed " & $localTimestamp(cstring(snapshot.observedAt))
      tdiv(class = "proxmox-summary-grid"):
        tdiv(class = "developer-card proxmox-summary-card"):
          span(class = "run-label"): text "Cluster members"
          strong: text $snapshot.clusterMembers.len
        tdiv(class = "developer-card proxmox-summary-card"):
          span(class = "run-label"): text "Nodes online"
          strong: text $countOnlineNodes(snapshot) & " / " & $snapshot.nodes.len
        tdiv(class = "developer-card proxmox-summary-card"):
          span(class = "run-label"): text "Virtual machines"
          strong: text $virtualMachines
        tdiv(class = "developer-card proxmox-summary-card"):
          span(class = "run-label"): text "Containers"
          strong: text $containers
      tdiv(class = "proxmox-table-section"):
        tdiv(class = "section-heading-row"):
          h4: text "Nodes"
          span: text $snapshot.nodes.len & " shown"
        if snapshot.nodes.len == 0:
          tdiv(class = "empty-card"): text "The provider returned no nodes."
        else:
          table(class = "proxmox-table"):
            thead:
              tr:
                th(scope = "col"): text "Node"
                th(scope = "col"): text "Status"
                th(scope = "col"): text "CPU"
                th(scope = "col"): text "Memory"
                th(scope = "col"): text "Storage"
                th(scope = "col"): text "Uptime"
            tbody:
              for node in snapshot.nodes:
                tr:
                  th(scope = "row"): text node.name
                  td:
                    span(class = (if node.status == "online": cstring"proxmox-state online" else: cstring"proxmox-state")):
                      text node.status
                  td: text formatProxmoxPercent(node.cpuFraction, some(1.0))
                  td: text formatProxmoxBytes(node.memoryBytes) & " / " & formatProxmoxBytes(node.memoryTotalBytes)
                  td: text formatProxmoxBytes(node.diskBytes) & " / " & formatProxmoxBytes(node.diskTotalBytes)
                  td: text formatProxmoxUptime(node.uptimeSeconds)
        if snapshot.nodesTruncated:
          p(class = "operation-note", role = "status"): text "More nodes exist than this dashboard displays."
      tdiv(class = "proxmox-table-section"):
        tdiv(class = "section-heading-row"):
          h4: text "Guests"
          span: text $snapshot.guests.len & " shown"
        if snapshot.guests.len == 0:
          tdiv(class = "empty-card"): text "The provider returned no guests."
        else:
          table(class = "proxmox-table"):
            thead:
              tr:
                th(scope = "col"): text "VMID"
                th(scope = "col"): text "Name"
                th(scope = "col"): text "Type"
                th(scope = "col"): text "Node"
                th(scope = "col"): text "Status"
                th(scope = "col"): text "Memory"
                th(scope = "col"): text "Actions"
            tbody:
              for guest in snapshot.guests:
                tr(class = "proxmox-guest-row", `data-vmid` = cstring($guest.vmid)):
                  th(scope = "row"): text $guest.vmid
                  td: text (if guest.name.len > 0: guest.name else: "Unnamed")
                  td: text guest.kind
                  td: text guest.node
                  td: text guest.status
                  td: text formatProxmoxBytes(guest.memoryBytes) & " / " & formatProxmoxBytes(guest.memoryTotalBytes)
                  td: renderGuestActions(state, guest)
        if snapshot.guestsTruncated:
          p(class = "operation-note", role = "status"): text "More guests exist than this dashboard displays."
    renderProxmoxActions(state)
    if state.proxmoxConfirming.len > 0 and confirmingAction(state).actionId.len > 0:
      renderProxmoxConfirm(state)

proc renderOperationsPanel*(state: AppState): VNode =
  result = buildHtml(tdiv(class = "developer-view operations-panel")):
    tdiv(class = "developer-view-header"):
      tdiv:
        h2: text "Operations"
        p: text "Your recent tasks and how long each step took."
      button(class = "secondary-action", disabled = state.operationsBusy, `aria-label` = "Refresh operations"):
        text (if state.operationsBusy: "Refreshing…" else: "Refresh")
        proc onclick(event: Event, node: VNode) =
          discard refreshOperations(state)
    renderProxmoxDashboard(state)
    if state.operationsError.len > 0:
      p(class = "operation-error", role = "alert"): text state.operationsError
    if state.operationsBusy and not state.operationsLoaded:
      p(class = "operation-note", role = "status"): text "Loading your operations…"
    elif not state.operationsLoaded:
      if state.operationsError.len == 0:
        p(class = "operation-note"): text "Refresh to load your operations."
    else:
      p(class = "operation-note operation-snapshot", role = "status"):
        text "Snapshot · " & $localTimestamp(cstring(state.operations.observedAt))
      tdiv(class = "operation-counts"):
        for index, status in operationStatuses:
          tdiv(class = "developer-card operation-count", `data-status` = cstring(status)):
            span(class = "run-label"): text operationStatusLabel(status)
            strong: text $state.operations.counts[index]
      tdiv(class = "section-heading-row"):
        h3: text "Recent tasks"
        span: text $state.operations.jobs.len & " shown"
      p(class = "operation-note"):
        text "Counts cover all your tasks. This list shows the most recent tasks."
      if state.operations.jobs.len == 0:
        tdiv(class = "empty-card"): text "No recent tasks were returned."
      else:
        for job in state.operations.jobs:
          renderOperationJob(state, job)
