include karax/prelude
import std/[json, options, sequtils, strutils]
import ../app/types
import ../app/operations_snapshot
import ../app/proxmox_snapshot
import ../app/proxmox_actions
import ../app/proxmox_health
import ../app/tailnet_snapshot
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

proc summaryPhrases(parts: openArray[string]): VNode =
  ## A summary line whose phrases ("1 never backed up") wrap between, never inside.
  ## A first phrase ending in a colon introduces the rest without a separator.
  result = buildHtml(span(class = "summary-phrases")):
    for index, part in parts:
      if index > 0 and not parts[index - 1].endsWith(":"):
        text " · "
      elif index > 0:
        text " "
      span(class = "summary-part"): text part

proc attentionPhrase(count: int): string =
  if count == 0: "none need attention"
  elif count == 1: "1 needs attention"
  else: $count & " need attention"

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
    if guestChangeActions(guest.status).len > 0:
      button(id = cstring("proxmoxChange" & $guest.vmid), class = "secondary-action proxmox-change",
          `aria-label` = cstring("Change " & $guest.vmid), `aria-haspopup` = "dialog", disabled = blocked,
          title = "Change this guest's resources, snapshots, backups or copies"):
        text "Change"
        proc onclick(event: Event, node: VNode) = openGuestChanges(state, guest)
    button(class = "secondary-action proxmox-ask", `aria-label` = cstring("Ask in chat about " & $guest.vmid),
        title = "Ask about this guest in chat"):
      text "Ask in chat"
      proc onclick(event: Event, node: VNode) = askAboutGuest(state, guest)

# The change dialog keeps each field's text as typed; the payload is built and checked only on Prepare.
var changeDraft: seq[(string, string)]

proc draftValue(name: string): string =
  for (key, value) in changeDraft:
    if key == name: return value

proc setDraft(name, value: string) =
  for index, entry in changeDraft:
    if entry[0] == name:
      changeDraft[index] = (name, value)
      return
  changeDraft.add (name, value)

proc positiveInt(text: string): int =
  ## 0 for anything that is not a whole number from 1 up.
  let trimmed = text.strip
  if trimmed.len == 0 or trimmed.len > 9 or not trimmed.allCharsInSet(Digits): return 0
  result = parseInt(trimmed)

proc snapshotNameOk(text: string): bool =
  ## Proxmox snapshot names: a letter first, then letters, digits, - or _ (at most 40).
  text.len in 1 .. 40 and text[0] in Letters and text.allCharsInSet(Letters + Digits + {'-', '_'})

proc plainTextOk(text: string, limit = 64): bool =
  text.len in 1 .. limit and text.allCharsInSet(Letters + Digits + {'-', '_', '.', ';', ':'})

proc changeFields(action: string): Option[JsonNode] =
  ## The typed fields of the change as entered, or none while a value is missing or invalid.
  var fields = newJObject()
  case action
  of "set_resources":
    let cores = positiveInt(draftValue("cores"))
    let memory = positiveInt(draftValue("memory_mib"))
    if draftValue("cores").strip.len > 0:
      if cores == 0: return none(JsonNode)
      fields["cores"] = %cores
    if draftValue("memory_mib").strip.len > 0:
      if memory == 0: return none(JsonNode)
      fields["memory_mib"] = %memory
    if fields.len == 0: return none(JsonNode)
  of "resize_disk":
    let disk = draftValue("disk").strip
    let grow = positiveInt(draftValue("grow_gib"))
    if not plainTextOk(disk, 16) or grow == 0: return none(JsonNode)
    fields["disk"] = %disk
    fields["grow_gib"] = %grow
  of "set_options":
    let tags = draftValue("tags").strip
    let onBoot = draftValue("on_boot")
    if tags.len > 0:
      if not plainTextOk(tags, 128): return none(JsonNode)
      fields["tags"] = %tags
    if onBoot in ["yes", "no"]: fields["on_boot"] = %(onBoot == "yes")
    if fields.len == 0: return none(JsonNode)
  of "snapshot_create", "snapshot_rollback", "snapshot_delete":
    let name = draftValue("snapshot").strip
    if not snapshotNameOk(name): return none(JsonNode)
    fields["snapshot"] = %name
  of "backup_now":
    let storage = draftValue("storage").strip
    if not plainTextOk(storage, 64): return none(JsonNode)
    fields["storage"] = %storage
  of "clone":
    let name = draftValue("name").strip
    if not plainTextOk(name, 63): return none(JsonNode)
    fields["name"] = %name
    fields["full"] = %(draftValue("full") != "no")
  of "delete": discard
  else: return none(JsonNode)
  some(fields)

proc renderDraftField(name, labelText, hint: string, numeric = false, placeholder = ""): VNode =
  let fieldId = "proxmoxChangeField-" & name
  result = buildHtml(tdiv(class = "proxmox-change-field")):
    label(`for` = cstring(fieldId)): text labelText
    input(id = cstring(fieldId), class = "proxmox-change-input", `type` = "text", autocomplete = "off",
          spellcheck = "false", inputmode = (if numeric: cstring"numeric" else: cstring"text"),
          placeholder = cstring(placeholder), value = cstring(draftValue(name)),
          `aria-describedby` = cstring(fieldId & "-hint")):
      proc oninput(event: Event, node: VNode) = setDraft(name, $node.value)
    if hint.len > 0:
      span(id = cstring(fieldId & "-hint"), class = "operation-note"): text hint

proc renderDraftChoice(name, labelText: string, choices: openArray[(string, string)]): VNode =
  let fieldId = "proxmoxChangeField-" & name
  let current = draftValue(name)
  result = buildHtml(tdiv(class = "proxmox-change-field")):
    label(`for` = cstring(fieldId)): text labelText
    select(id = cstring(fieldId), class = "proxmox-change-input"):
      for (value, caption) in choices:
        option(value = cstring(value), selected = (value == current)): text caption
      proc onchange(event: Event, node: VNode) = setDraft(name, $node.value)

proc renderChangeForm(action: string): VNode =
  result = buildHtml(tdiv(class = "proxmox-change-form")):
    case action
    of "set_resources":
      p(class = "operation-note proxmox-change-lead"): text "Fill in at least one; an empty field keeps its value."
      renderDraftField("cores", "CPU cores", "", numeric = true, placeholder = "Keep the current value")
      renderDraftField("memory_mib", "Memory (MiB)", "", numeric = true, placeholder = "Keep the current value")
    of "resize_disk":
      renderDraftField("disk", "Disk", "For example rootfs, scsi0 or virtio0.")
      renderDraftField("grow_gib", "Grow by (GiB)", "Disks only grow; Proxmox cannot shrink them.", numeric = true)
    of "set_options":
      renderDraftField("tags", "Tags", "Separate tags with ; — they replace the current tags.")
      renderDraftChoice("on_boot", "Start at boot", [("", "Keep as it is"), ("yes", "Yes"), ("no", "No")])
    of "snapshot_create":
      renderDraftField("snapshot", "Snapshot name", "A letter first, then letters, digits, - or _.")
    of "snapshot_rollback":
      renderDraftField("snapshot", "Snapshot name", "The guest returns to this snapshot; later changes are lost.")
    of "snapshot_delete":
      renderDraftField("snapshot", "Snapshot name", "The snapshot is removed for good.")
    of "backup_now":
      renderDraftField("storage", "Backup storage", "A storage that holds backups, for example local.")
    of "clone":
      renderDraftField("name", "New guest name", "Letters, digits, - and . only.")
      renderDraftChoice("full", "Copy", [("yes", "Full copy (independent disks)"), ("no", "Linked copy (shares the template's disks)")])
    of "delete":
      p(class = "operation-note"):
        text "The guest and its disks are removed. You confirm by typing its name on the next step."
    else: discard

proc renderProxmoxChange(state: AppState): VNode =
  ## Choose a change and its values for one exact guest; Prepare asks the server to describe it.
  var guest: ProxmoxGuest
  for candidate in state.proxmox.guests:
    if candidate.vmid == state.proxmoxChangeGuest and candidate.node == state.proxmoxChangeNode:
      guest = candidate
  if changeDraftDone:
    changeDraft = @[]
    changeDraftDone = false
  let chosen = state.proxmoxChangeAction
  let fields = changeFields(chosen)
  let title = "Change guest " & $state.proxmoxChangeGuest
  result = buildHtml(tdiv(class = "proxmox-confirm-backdrop")):
    tdiv(class = "proxmox-confirm proxmox-change", role = "dialog", `aria-modal` = "true",
         `aria-label` = cstring(title)):
      h3: text title
      p(class = "operation-note"):
        text proxmoxGuestKind(guest.kind) & " " & $guest.vmid &
          (if guest.name.len > 0: " (" & guest.name & ")" else: "") & " on " & guest.node & " · " & guest.status
      if guest.vmid == 0:
        p(class = "operation-error", role = "alert"): text "This guest is no longer in the inventory."
      elif state.proxmoxActionError.len > 0:
        # A refusal is shown where the owner is looking; the values stay for another try.
        p(class = "operation-error", role = "alert"): text state.proxmoxActionError
      if guest.vmid != 0:
        let offered = guestChangeActions(guest.status)
        for destructiveGroup in [false, true]:
          let group = offered.filterIt(changeIsDestructive(it) == destructiveGroup)
          if group.len > 0:
            tdiv(class = (if destructiveGroup: cstring"proxmox-change-group destructive"
                          else: cstring"proxmox-change-group"),
                 role = "group", `aria-label` = (if destructiveGroup: cstring"Cannot be undone"
                                                 else: cstring"Choose a change")):
              span(class = "proxmox-change-group-title"):
                text (if destructiveGroup: "Cannot be undone" else: "Choose a change")
              tdiv(class = "proxmox-change-choices"):
                for action in group:
                  button(class = "secondary-action proxmox-change-choice",
                      `aria-pressed` = (if action == chosen: cstring"true" else: cstring"false"),
                      `data-action` = cstring(action), disabled = state.proxmoxActionBusy):
                    text changeActionLabel(action)
                    proc onclick(event: Event, node: VNode) =
                      let picked = $node.getAttr("data-action")
                      if picked != state.proxmoxChangeAction:
                        changeDraft = @[]
                        state.proxmoxChangeAction = picked
        if chosen.len > 0:
          renderChangeForm(chosen)
      tdiv(class = "proxmox-confirm-actions"):
        button(id = "proxmoxChangeClose", class = "secondary-action", disabled = state.proxmoxActionBusy):
          text "Close"
          proc onclick(event: Event, node: VNode) =
            changeDraft = @[]
            closeGuestChanges(state)
        button(class = "primary-action",
            disabled = state.proxmoxActionBusy or guest.vmid == 0 or chosen.len == 0 or fields.isNone):
          text (if state.proxmoxActionBusy: "Preparing…" else: "Prepare")
          proc onclick(event: Event, node: VNode) =
            # The draft is kept until the server answers: a refusal leaves the values for another try,
            # and the bridge closes this dialog only when the confirmation opens.
            let ready = changeFields(state.proxmoxChangeAction)
            if ready.isSome:
              discard proposeGuestAction(state, guest, state.proxmoxChangeAction, ready.get)
      proc onkeydown(event: Event, node: VNode) =
        if eventKey(event) == "Escape" and not state.proxmoxActionBusy:
          stopEvent(event)
          changeDraft = @[]
          closeGuestChanges(state)

proc renderProxmoxConfirm(state: AppState): VNode =
  ## The server's own description of the exact target; nothing runs until Confirm.
  let action = confirmingAction(state)
  let isChange = action.action notin powerActions
  let label = if action.action == "delete": "Delete guest"
              elif isChange: "Apply change"
              else: powerActionLabel(action.action)
  # A destructive change is approved only with the guest's name typed exactly (the server checks it too).
  let nameNeeded = action.destructive and action.name.len > 0
  let nameMatches = not nameNeeded or state.proxmoxConfirmName == action.name
  result = buildHtml(tdiv(class = "proxmox-confirm-backdrop")):
    tdiv(class = "proxmox-confirm", role = "dialog", `aria-modal` = "true",
         `aria-labelledby` = "proxmoxConfirmTitle", `aria-describedby` = "proxmoxConfirmText"):
      h3(id = "proxmoxConfirmTitle"): text "Confirm Proxmox action"
      if action.action == "force_stop":
        p(class = "proxmox-confirm-warning", role = "note"):
          strong: text "Data loss risk. "
          text "Force stop cuts power to the guest without letting it shut down. Unsaved work in it is lost."
      if action.destructive:
        p(class = "proxmox-confirm-warning", role = "note"):
          strong: text "Cannot be undone. "
          text (case action.action
                of "delete": "The guest and its disks are removed for good."
                of "snapshot_delete": "The snapshot is removed for good."
                of "snapshot_rollback": "Everything the guest changed after the snapshot is lost."
                else: "The restored guest replaces nothing, but its data comes only from the backup.")
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
      if nameNeeded:
        label(class = "proxmox-confirm-name", `for` = "proxmoxConfirmName"):
          text "Type "
          code: text action.name
          text " to confirm"
        input(id = "proxmoxConfirmName", class = "proxmox-change-input", `type` = "text", autocomplete = "off",
              spellcheck = "false", `aria-label` = "Guest name", `aria-describedby` = "proxmoxConfirmNameHint",
              value = cstring(state.proxmoxConfirmName)):
          proc oninput(event: Event, node: VNode) =
            state.proxmoxConfirmName = $node.value
        p(id = "proxmoxConfirmNameHint", class = "operation-note proxmox-confirm-name-hint", `aria-live` = "polite"):
          text (if state.proxmoxConfirmName.len == 0: "The approval stays locked until the name matches."
                elif nameMatches: "The name matches."
                else: "The name does not match yet.")
      tdiv(class = "proxmox-confirm-actions"):
        button(id = "proxmoxConfirmCancel", class = "secondary-action", disabled = state.proxmoxActionBusy):
          text "Cancel"
          proc onclick(event: Event, node: VNode) = discard decideGuestAction(state, action.actionId, false)
        button(class = (if action.action == "force_stop" or action.destructive:
                          cstring"primary-action proxmox-confirm-danger"
                        else: cstring"primary-action"),
            disabled = state.proxmoxActionBusy or not nameMatches):
          text (if state.proxmoxActionBusy: "Working…" else: label)
          proc onclick(event: Event, node: VNode) = discard decideGuestAction(state, action.actionId, true)
      proc onkeydown(event: Event, node: VNode) =
        if eventKey(event) == "Escape" and not state.proxmoxActionBusy:
          stopEvent(event)
          discard decideGuestAction(state, action.actionId, false)

proc renderProxmoxAction(state: AppState, action: ProxmoxAction): VNode =
  result = buildHtml(li(class = "proxmox-action", `data-status` = cstring(action.status))):
    tdiv(class = "proxmox-action-heading"):
      strong: text proxmoxActionLabel(action.action) & " " & proxmoxGuestKind(action.kind) & " " & $action.vmid &
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
      tdiv(class = "empty-card"): text "No guest actions yet. Each one asks for your confirmation first."
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

proc databaseAttention(host: ProxmoxDatabaseHost): string =
  if host.issues.len == 0: return "none"
  for issue in host.issues:
    if databaseIssueBlocking(issue): return "blocking"
  "warning"

proc renderDatabaseHost(host: ProxmoxDatabaseHost): VNode =
  let name = if host.name.len > 0: host.name else: "Unnamed"
  # A lock's reason is said once, on its chip.
  let about = (if host.kind == "qemu": "VM " else: "LXC ") & $host.vmid & " on " & host.node & " · " & host.status
  result = buildHtml(li(class = "database-host", `data-vmid` = cstring($host.vmid),
                        `data-attention` = cstring(databaseAttention(host)))):
    tdiv(class = "database-host-heading"):
      strong(class = "database-host-name"): text name
      if host.engine.len > 0:
        span(class = "database-engine"): text host.engine
    p(class = "operation-note"): text about
    dl(class = "database-facts"):
      tdiv:
        dt: text "Memory"
        dd(`data-fact` = "memory"):
          text databaseMemoryLabel(host.memoryBytes, host.memoryTotalBytes, host.status == "running")
      tdiv:
        dt: text "Disk"
        let (diskValue, diskNote) = databaseDiskParts(host.diskBytes, host.diskTotalBytes)
        if diskNote.len > 0:
          dd(`data-fact` = "disk", title = cstring(
              if host.kind == "qemu": "Proxmox does not measure the disk use of a virtual machine."
              else: "Proxmox measures a container's disk use only while it runs.")):
            span(class = "database-fact-value"): text diskValue
            text " "
            span(class = "database-fact-value"): text diskNote
        else:
          dd(`data-fact` = "disk"):
            span(class = "database-fact-value"): text diskValue
      tdiv:
        dt: text "Backup"
        dd(`data-fact` = "backup"): text backupJobLabel(host.backupJob)
    if host.issues.len > 0:
      ul(class = "database-issues", `aria-label` = cstring("Needs attention: " & name)):
        for issue in host.issues:
          li(class = "database-issue", `data-issue` = cstring(issue),
             `data-blocking` = cstring(if databaseIssueBlocking(issue): "true" else: "false")):
            text databaseIssueLabel(issue, host.lock)

proc renderDatabaseHosts(databases: ProxmoxDatabases): VNode =
  result = buildHtml(tdiv(class = "proxmox-table-section proxmox-databases")):
    tdiv(class = "section-heading-row"):
      h4: text "Database hosts"
      span: text $databases.hosts.len & " tagged"
    if databases.hosts.len == 0:
      tdiv(class = "empty-card"):
        text "No database hosts are tagged yet. " & databases.labelHint
    else:
      p(class = "database-summary", role = "status"):
        summaryPhrases([$databases.running & " running", $databases.notRunning & " not running",
                        attentionPhrase(databases.withIssues)])
      if not databases.coverageKnown:
        p(class = "operation-note database-coverage-note"):
          text "Backup coverage unknown" &
            (if databases.coverageNote.len > 0: ": " & databases.coverageNote else: ".")
      # The service orders hosts by their most urgent issue, healthy hosts last.
      ul(class = "database-host-list"):
        for host in databases.hosts:
          renderDatabaseHost(host)
      if databases.truncated:
        p(class = "operation-note", role = "status"): text "More database hosts exist than this dashboard displays."
      if databases.storage.len > 0:
        p(class = "operation-note database-storage"):
          text "Guest disk storage: " & databases.storage.mapIt(
            it.storage & (if it.kind.len > 0: " (" & it.kind & ")" else: "") & " on " & it.node &
            (if it.usedBytes.isSome and it.totalBytes.isSome and it.totalBytes.get > 0:
               ", " & formatProxmoxBytes(it.usedBytes) & " of " & formatProxmoxBytes(it.totalBytes) & " used (" &
               formatProxmoxPercent(it.usedBytes, it.totalBytes) & ")"
             else: "")).join("; ") & "."
      p(class = "operation-note"):
        text "Read from Proxmox tags and backup jobs. Janus holds no database credentials and runs no queries."

proc issueAttention(issues: seq[string], blocking: proc(issue: string): bool): string =
  if issues.len == 0: return "none"
  for issue in issues:
    if blocking(issue): return "blocking"
  "warning"

proc renderBackupGuest(guest: GuestBackups, staleAfterDays: int): VNode =
  let name = if guest.name.len > 0: guest.name else: "Unnamed"
  let ageDays = if guest.latest.isSome: some(guest.latest.get.ageDays) else: none(float)
  result = buildHtml(li(class = "backup-guest", `data-vmid` = cstring($guest.vmid),
                        `data-attention` = cstring(issueAttention(guest.issues, backupIssueBlocking)))):
    strong(class = "backup-guest-name"): text name
    p(class = "operation-note"):
      text (if guest.kind == "qemu": "VM " else: "LXC ") & $guest.vmid & " on " & guest.node
    # Every card keeps its facts in the same places; the long copy line comes last.
    dl(class = "backup-facts"):
      tdiv:
        dt: text "Newest backup"
        dd(`data-fact` = "latest"): text backupAgeLabel(ageDays)
      tdiv:
        dt: text "Backup job"
        dd(`data-fact` = "job"): text backupJobLabel(guest.backupJob)
      if guest.latest.isSome:
        tdiv(class = "backup-copy"):
          dt: text "Newest copy"
          dd(`data-fact` = "copy"): text backupCopyLabel(guest.latest.get)
    if guest.issues.len > 0:
      ul(class = "backup-issues", `aria-label` = cstring("Needs attention: " & name)):
        for issue in guest.issues:
          li(class = "backup-issue", `data-issue` = cstring(issue),
             `data-blocking` = cstring(if backupIssueBlocking(issue): "true" else: "false")):
            text backupIssueLabel(issue, staleAfterDays)

proc renderBackups(backups: ProxmoxBackups): VNode =
  result = buildHtml(tdiv(class = "proxmox-table-section proxmox-backups")):
    tdiv(class = "section-heading-row"):
      h4: text "Backups"
      span: text $backups.guests.len & (if backups.guests.len == 1: " guest" else: " guests")
    p(class = "backup-summary", role = "status"): summaryPhrases(backupSummaryParts(backups))
    if not backups.coverageKnown and backups.coverageNote.len > 0:
      p(class = "operation-note backup-coverage-note"): text "Backup jobs unknown: " & backups.coverageNote
    if not backups.listingComplete:
      p(class = "operation-note backup-incomplete"):
        text "Not every backup storage could be read (" & backups.unreadable.mapIt(
          it.storage & " on " & it.node & ": " & it.reason).join("; ") &
          "), so missing or overdue backups cannot be confirmed."
    if backups.guests.len == 0:
      tdiv(class = "empty-card"): text "Proxmox listed no guests."
    else:
      # The service orders guests by their most urgent backup gap.
      ul(class = "backup-guest-list"):
        for guest in backups.guests:
          renderBackupGuest(guest, backups.staleAfterDays)
    if backups.truncated:
      p(class = "operation-note", role = "status"): text "More guests exist than this dashboard displays."
    if backups.storages.len > 0:
      p(class = "operation-note backup-storages"):
        text "Backup storage: " & backups.storages.mapIt(
          it.storage & " on " & it.node & " (" & it.kind & (if it.shared: ", shared" else: "") & ") holds " &
          $it.backups & (if it.backups == 1: " backup" else: " backups")).join("; ") & "."

proc renderPhysicalDisk(node: string, disk: PhysicalDisk): VNode =
  let name = disk.device & " on " & node
  result = buildHtml(li(class = "physical-disk", `data-device` = cstring(disk.device), `data-node` = cstring(node),
                        `data-attention` = cstring(issueAttention(disk.issues, diskIssueBlocking)))):
    strong(class = "physical-disk-name"): text name
    p(class = "operation-note"):
      text @[diskKindLabel(disk.kind), disk.model, formatProxmoxBytes(disk.sizeBytes)].filterIt(
        it.len > 0 and it != "Not reported").join(" · ")
    dl(class = "disk-facts"):
      tdiv:
        dt: text "Health"
        dd(`data-fact` = "health"): text diskHealthLabel(disk.health)
      tdiv:
        dt: text "Wear"
        dd(`data-fact` = "wear"): text diskWearLabel(disk.wearUsedPercent)
      if disk.usedBy.len > 0:
        tdiv:
          dt: text "Usage"
          dd(`data-fact` = "usage"): text disk.usedBy
    if disk.issues.len > 0:
      ul(class = "disk-issues", `aria-label` = cstring("Needs attention: " & name)):
        for issue in disk.issues:
          li(class = "disk-issue", `data-issue` = cstring(issue),
             `data-blocking` = cstring(if diskIssueBlocking(issue): "true" else: "false")):
            text diskIssueLabel(issue)

proc renderUnreadableNode(node: NodeDisks): VNode =
  result = buildHtml(li(class = "disk-node-unavailable", `data-node` = cstring(node.node),
                        `data-attention` = "warning")):
    strong(class = "physical-disk-name"): text node.node
    p(class = "operation-note"): text "Disks could not be read: " & node.error
    ul(class = "disk-issues", `aria-label` = cstring("Needs attention: " & node.node)):
      li(class = "disk-issue", `data-issue` = "unreadable", `data-blocking` = "false"): text "Disks unknown"

proc renderPhysicalDisks(nodes: seq[NodeDisks]): VNode =
  var count, unreadable = 0
  for node in nodes:
    count += node.disks.len
    if node.error.len > 0: inc unreadable
  # Across every node: failing disks, then nodes whose disks are unknown, then the rest.
  let failing = proc(disk: PhysicalDisk): bool = disk.issues.anyIt(diskIssueBlocking(it))
  result = buildHtml(tdiv(class = "proxmox-table-section proxmox-disks")):
    tdiv(class = "section-heading-row"):
      h4: text "Physical disks"
      span: text $count & (if count == 1: " disk" else: " disks") &
        (if unreadable > 0: " · " & $unreadable & (if unreadable == 1: " node" else: " nodes") & " unreadable"
         else: "")
    if count == 0 and unreadable == 0:
      tdiv(class = "empty-card"): text "No physical disks were listed."
    else:
      ul(class = "physical-disk-list"):
        for node in nodes:
          for disk in node.disks:
            if failing(disk): renderPhysicalDisk(node.node, disk)
        for node in nodes:
          if node.error.len > 0: renderUnreadableNode(node)
        for node in nodes:
          for disk in node.disks:
            if not failing(disk): renderPhysicalDisk(node.node, disk)
    for node in nodes:
      if node.truncated:
        p(class = "operation-note", role = "status"):
          text node.node & " has more disks than this dashboard displays."
    p(class = "operation-note"): text "SMART health and wear from Proxmox. Serial numbers are never shown."

proc renderProxmoxHealth(state: AppState): VNode =
  ## Backups and disks come from their own, slower read; its failure never hides the inventory.
  result = buildHtml(tdiv(class = "proxmox-health")):
    if state.proxmoxHealthError.len > 0:
      tdiv(class = "proxmox-health-unavailable", role = "status",
           `data-error-code` = cstring(state.proxmoxHealthError),
           `data-error-reason` = cstring(state.proxmoxHealthErrorReason)):
        strong: text "Backups and disks could not be read"
        p(class = "operation-note"):
          text (if state.proxmoxHealthErrorMessage.len > 0: state.proxmoxHealthErrorMessage
                else: "The read did not succeed.") &
            " They are read again every minute while this page is open. The guest inventory is unaffected."
    elif not state.proxmoxHealthLoaded:
      p(class = "operation-note", role = "status"): text "Reading backups and disks…"
    else:
      if state.proxmoxHealth.backups.known:
        renderBackups(state.proxmoxHealth.backups)
      else:
        p(class = "operation-note proxmox-health-unavailable", role = "status"):
          text "Backups could not be read: " & state.proxmoxHealth.backups.error
      renderPhysicalDisks(state.proxmoxHealth.disks)

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
          text "Live inventory from your Proxmox API, refreshed while this page is open. Power actions and changes ask for your confirmation first."
      button(class = "secondary-action", disabled = state.proxmoxBusy,
          `aria-label` = "Refresh Proxmox dashboard"):
        text (if state.proxmoxBusy: "Refreshing…" else: "Refresh")
        proc onclick(event: Event, node: VNode) =
          discard refreshProxmoxOverview(state)
          discard refreshProxmoxHealth(state)
    if state.proxmoxActionError.len > 0 and state.proxmoxChangeGuest == 0:
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
      if snapshot.databases.known:
        renderDatabaseHosts(snapshot.databases)
      renderProxmoxHealth(state)
    renderProxmoxActions(state)
    if state.proxmoxConfirming.len > 0 and confirmingAction(state).actionId.len > 0:
      renderProxmoxConfirm(state)
    elif state.proxmoxChangeGuest > 0:
      renderProxmoxChange(state)

proc tailnetFailureTitle(code: string): string =
  case code
  of "tailnet_not_configured": "Connection not configured"
  else: "Tailscale data unavailable"

proc tailnetFailureHelp(state: AppState): string =
  case state.tailnetError
  of "tailnet_not_configured":
    "Add TAILSCALE_CLIENT_ID and TAILSCALE_CLIENT_SECRET (a read-only OAuth client with devices:core:read and dns:read) to the AI connections, then refresh."
  else:
    (if state.tailnetErrorMessage.len > 0: state.tailnetErrorMessage & " " else: "") &
      "Check the OAuth client's scopes and the AI logs; nothing on the tailnet was changed."

proc attentionLevel(device: TailnetDevice): string =
  if device.issues.len == 0: return "none"
  for issue in device.issues:
    if tailnetIssueBlocking(issue): return "blocking"
  "warning"

proc renderTailnetDevice(device: TailnetDevice): VNode =
  let online = device.online == some(true)
  let state =
    if online: "Online"
    elif device.lastSeen.len >= 10: "Offline since " & device.lastSeen[0 ..< 10]
    elif device.online == some(false): "Offline"
    else: "State not reported"
  let about = [device.os, (if device.clientVersion.len > 0: "Tailscale " & device.clientVersion else: "")]
  result = buildHtml(li(class = "tailnet-device", `data-name` = cstring(device.name),
                        `data-online` = cstring(if online: "true" else: "false"),
                        `data-attention` = cstring(attentionLevel(device)))):
    tdiv(class = "tailnet-device-heading"):
      strong(class = "tailnet-device-name"): text device.name
      span(class = "tailnet-device-state", `data-online` = cstring(if online: "true" else: "false")):
        span(class = "tailnet-state-mark", `aria-hidden` = "true")
        text state
    p(class = "operation-note"):
      text about.filterIt(it.len > 0).join(" · ")
    dl(class = "tailnet-device-facts"):
      tdiv:
        dt: text "Key expiry"
        dd(`data-fact` = "key"): text keyExpiryLabel(device)
      # Only a connected device has a current path; an offline one's last report is history.
      if online:
        tdiv:
          dt: text "Connection"
          dd(`data-fact` = "connection"): text connectionLabel(device)
        if relayLabel(device).len > 0:
          tdiv:
            dt: text "Nearest relay"
            dd(`data-fact` = "relay"): text relayLabel(device)
    if device.issues.len > 0:
      ul(class = "tailnet-issues", `aria-label` = cstring("Needs attention: " & device.name)):
        for issue in device.issues:
          li(class = "tailnet-issue", `data-issue` = cstring(issue),
             `data-blocking` = cstring(if tailnetIssueBlocking(issue): "true" else: "false")):
            text tailnetIssueLabel(issue)

proc renderTailnetDashboard(state: AppState): VNode =
  let snapshot = state.tailnet
  result = buildHtml(section(class = "tailnet-dashboard", `aria-labelledby` = "tailnetDashboardTitle")):
    tdiv(class = "proxmox-dashboard-heading"):
      tdiv:
        h3(id = "tailnetDashboardTitle"): text "Tailscale network"
        p(class = "operation-note"):
          text "Each device's health from the Tailscale API, read-only and refreshed while this page is open."
      button(class = "secondary-action", disabled = state.tailnetBusy,
          `aria-label` = "Refresh Tailscale network"):
        text (if state.tailnetBusy: "Refreshing…" else: "Refresh")
        proc onclick(event: Event, node: VNode) = discard refreshTailnetOverview(state)
    if state.tailnetBusy and not state.tailnetLoaded and state.tailnetError.len == 0:
      p(class = "operation-note", role = "status"): text "Reading the tailnet…"
    elif state.tailnetError.len > 0:
      tdiv(class = "tailnet-unavailable", role = "status",
           `data-error-code` = cstring(state.tailnetError), `data-error-reason` = cstring(state.tailnetErrorReason)):
        strong: text tailnetFailureTitle(state.tailnetError)
        p(class = "operation-note"): text tailnetFailureHelp(state)
    elif not state.tailnetLoaded:
      p(class = "operation-note", role = "status"): text "No tailnet snapshot has been loaded. Refresh to read it."
    else:
      tdiv(class = "tailnet-live-status", role = "status"):
        if snapshot.withIssues == 0 and snapshot.offline == 0:
          span(class = "proxmox-status-dot", `aria-hidden` = "true")
        strong(class = "tailnet-summary"):
          summaryPhrases([$snapshot.online & " online", $snapshot.offline & " offline",
                          attentionPhrase(snapshot.withIssues)])
        span(class = "operation-note"): text "Observed " & $localTimestamp(cstring(snapshot.observedAt))
      if snapshot.devices.len == 0:
        tdiv(class = "empty-card"): text "The tailnet returned no devices."
      else:
        ul(class = "tailnet-device-list"):
          for device in attentionOrder(snapshot.devices):
            renderTailnetDevice(device)
      if snapshot.truncated:
        p(class = "operation-note", role = "status"): text "More devices exist than this dashboard displays."
      p(class = "operation-note tailnet-dns"):
        if snapshot.dnsLoaded:
          text "DNS: MagicDNS " & (if snapshot.magicDns: "on" else: "off") & "; " &
            (if snapshot.resolvers.len == 0: "devices use the local network's resolvers"
             elif snapshot.overrideLocalDns: "tailnet resolvers " & snapshot.resolvers.join(", ")
             else: "local resolvers first, then " & snapshot.resolvers.join(", ")) &
            (if snapshot.splitDomains.len > 0: "; split DNS for " & snapshot.splitDomains.join(", ") else: "") & "."
        else:
          text "DNS settings could not be read: " &
            (if snapshot.dnsError.len > 0: snapshot.dnsError else: "no reason was given.")

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
    renderTailnetDashboard(state)
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
