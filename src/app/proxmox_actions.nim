## Proxmox guest power actions and changes started from the dashboard: the
## strict model of a saved action, the actions a guest's state allows, each
## change's typed fields (the same table the backend checks), and the exact
## request text used when the owner asks about a guest in chat.
##
## The backend owns the action. A button press only proposes it; nothing runs
## until the owner confirms the server's exact description of the target.
import std/[json, options]

type
  ProxmoxAction* = object
    actionId*, action*, node*, kind*, name*, risk*, status*: string
    vmid*: int
    destructive*: bool  ## approved only with the guest's name typed (checked by the server)
    approvalText*, createdAt*, decidedAt*, error*: string
    observedStatus*, expectedStatus*, upid*, taskExitStatus*, observedAt*: string
    verificationOk*: Option[bool]

  FieldKind = enum fkInt, fkBool, fkText

  ChangeSpec = object
    required, optional: seq[(string, FieldKind)]
    minFields: int

const
  powerActions* = ["start", "shutdown", "reboot", "force_stop"]
  ## Changes offered on an existing guest, in the order the dashboard lists them.
  guestChanges* = ["set_resources", "resize_disk", "set_options", "snapshot_create", "backup_now", "clone",
                   "snapshot_rollback", "snapshot_delete", "delete"]
  ## Changes the server accepts that make a new guest (no source guest is changed).
  newGuestChanges* = ["create", "backup_restore"]
  destructiveChanges = ["delete", "snapshot_delete", "snapshot_rollback", "backup_restore"]
  actionStatuses = ["waiting_approval", "executing", "rejecting", "succeeded", "failed",
                    "rejected", "outcome_unknown"]

proc changeSpec(action: string): ChangeSpec =
  ## The typed fields each change carries beyond its target: the backend's own table
  ## (`ItsmBackend.ProxmoxActions` @changes). The AI's trusted policy checks the values again.
  case action
  of "set_resources": ChangeSpec(optional: @[("cores", fkInt), ("memory_mib", fkInt)], minFields: 1)
  of "resize_disk": ChangeSpec(required: @[("disk", fkText), ("grow_gib", fkInt)])
  of "set_options": ChangeSpec(optional: @[("tags", fkText), ("on_boot", fkBool)], minFields: 1)
  of "snapshot_create": ChangeSpec(required: @[("snapshot", fkText)], optional: @[("description", fkText)])
  of "snapshot_delete", "snapshot_rollback": ChangeSpec(required: @[("snapshot", fkText)])
  of "backup_now": ChangeSpec(required: @[("storage", fkText)], optional: @[("mode", fkText)])
  of "backup_restore": ChangeSpec(required: @[("volume", fkText), ("name", fkText)],
                                  optional: @[("newid", fkInt), ("storage", fkText), ("pool", fkText)])
  of "clone": ChangeSpec(required: @[("name", fkText), ("full", fkBool)],
                         optional: @[("newid", fkInt), ("pool", fkText)])
  of "create": ChangeSpec(required: @[("hostname", fkText), ("template", fkText), ("cores", fkInt),
                                      ("memory_mib", fkInt), ("disk_gib", fkInt), ("storage", fkText)],
                          optional: @[("newid", fkInt), ("pool", fkText), ("description", fkText)])
  of "delete": ChangeSpec()
  else: raise newException(ValueError, "Choose one action for one exact guest.")

proc knownAction(action: string): bool =
  action in powerActions or action in guestChanges or action in newGuestChanges

proc guestChangeActions*(status: string): seq[string] =
  ## The changes offered for a guest in this state; the server and Proxmox re-check them.
  ## A running guest is shut down before it is deleted, so delete is not offered for it.
  case status
  of "stopped": result = @guestChanges
  of "running", "paused":
    for action in guestChanges:
      if action != "delete": result.add action
  else: discard

proc changeIsDestructive*(action: string): bool = action in destructiveChanges

proc changeActionLabel*(action: string): string =
  case action
  of "set_resources": "CPU and memory"
  of "resize_disk": "Grow disk"
  of "set_options": "Tags and boot"
  of "snapshot_create": "Snapshot"
  of "snapshot_rollback": "Roll back"
  of "snapshot_delete": "Delete snapshot"
  of "backup_now": "Back up now"
  of "backup_restore": "Restore backup"
  of "clone": "Clone"
  of "create": "Create container"
  of "delete": "Delete guest"
  else: action

proc invalid() {.noreturn.} =
  raise newException(ValueError, "The Proxmox action response is invalid.")

proc guestPowerActions*(status: string): seq[string] =
  ## The actions Proxmox accepts from this state; the server re-checks it.
  case status
  of "running": @["shutdown", "reboot", "force_stop"]
  of "stopped": @["start"]
  of "paused": @["force_stop"]
  else: @[]

proc powerActionLabel*(action: string): string =
  case action
  of "start": "Start"
  of "shutdown": "Shut down"
  of "reboot": "Reboot"
  of "force_stop": "Force stop"
  else: action

proc proxmoxActionLabel*(action: string): string =
  ## The label of any saved action, power or change.
  if action in powerActions: powerActionLabel(action) else: changeActionLabel(action)

proc proxmoxActionStatusLabel*(status: string): string =
  case status
  of "waiting_approval": "Waiting for your confirmation"
  of "executing": "Running"
  of "rejecting": "Cancelling"
  of "succeeded": "Succeeded"
  of "failed": "Failed"
  of "rejected": "Rejected"
  of "outcome_unknown": "Outcome unknown"
  else: status

proc proxmoxActionFinal*(status: string): bool =
  status in ["succeeded", "failed", "rejected", "outcome_unknown"]

proc text(node: JsonNode, key: string, nullable = false, limit = 600): string =
  if node.kind != JObject or not node.hasKey(key):
    if nullable: return ""
    invalid()
  let value = node[key]
  if nullable and value.kind == JNull: return ""
  if value.kind != JString or value.getStr.len > limit: invalid()
  if not nullable and value.getStr.len == 0: invalid()
  value.getStr

proc parseProxmoxAction*(node: JsonNode): ProxmoxAction =
  if node.kind != JObject: invalid()
  result.actionId = text(node, "action_id", limit = 32)
  if result.actionId.len != 32: invalid()
  for ch in result.actionId:
    if ch notin {'0'..'9', 'a'..'f'}: invalid()
  result.action = text(node, "action")
  if not knownAction(result.action): invalid()
  result.status = text(node, "status")
  if result.status notin actionStatuses: invalid()
  result.node = text(node, "node", limit = 64)
  let vmid = node{"vmid"}
  if vmid == nil or vmid.kind != JInt or vmid.getBiggestInt < 1 or vmid.getBiggestInt > 999_999_999: invalid()
  result.vmid = int(vmid.getBiggestInt)
  result.kind = text(node, "type", nullable = true, limit = 16)
  result.name = text(node, "name", nullable = true, limit = 128)
  result.risk = text(node, "risk", nullable = true, limit = 16)
  result.approvalText = text(node, "approval_text", nullable = true)
  result.createdAt = text(node, "created_at", nullable = true, limit = 64)
  result.decidedAt = text(node, "decided_at", nullable = true, limit = 64)
  result.error = text(node, "error", nullable = true, limit = 300)
  result.observedStatus = text(node, "observed_status", nullable = true, limit = 32)
  result.expectedStatus = text(node, "expected_status", nullable = true, limit = 32)
  result.upid = text(node, "upid", nullable = true, limit = 256)
  result.taskExitStatus = text(node, "task_exit_status", nullable = true, limit = 128)
  result.observedAt = text(node, "observed_at", nullable = true, limit = 64)
  let destructive = node{"destructive"}
  if destructive != nil and destructive.kind == JBool: result.destructive = destructive.getBool
  elif destructive != nil and destructive.kind != JNull: invalid()
  let verified = node{"verification_ok"}
  if verified != nil and verified.kind == JBool: result.verificationOk = some(verified.getBool)
  elif verified != nil and verified.kind != JNull: invalid()

proc parseProxmoxActions*(node: JsonNode): seq[ProxmoxAction] =
  let rows = node{"actions"}
  if rows == nil or rows.kind != JArray or rows.len > 50: invalid()
  for row in rows.items:
    result.add parseProxmoxAction(row)

proc mergeProxmoxAction*(actions: seq[ProxmoxAction], action: ProxmoxAction): seq[ProxmoxAction] =
  ## The newest action first; a saved row is replaced, never duplicated.
  result = @[action]
  for existing in actions:
    if existing.actionId != action.actionId: result.add existing

proc proxmoxActionPayload*(node: string, vmid: int, action, submissionId: string): JsonNode =
  if action notin powerActions or node.len == 0 or vmid < 1 or submissionId.len == 0:
    raise newException(ValueError, "Choose one action for one exact guest.")
  %*{"node": node, "vmid": vmid, "action": action, "submission_id": submissionId}

proc proxmoxChangePayload*(node: string, vmid: int, action, submissionId: string, fields: JsonNode): JsonNode =
  ## One change for one exact guest with exactly its own typed fields; anything else is refused
  ## here, before it is sent (the server refuses it too).
  if action in powerActions or not knownAction(action) or node.len == 0 or vmid < 1 or submissionId.len == 0 or
     fields.kind != JObject:
    raise newException(ValueError, "Choose one action for one exact guest.")
  let spec = changeSpec(action)
  var allowed: seq[(string, FieldKind)]
  allowed.add spec.required
  allowed.add spec.optional
  result = %*{"node": node, "vmid": vmid, "action": action, "submission_id": submissionId}
  var given = 0
  for key, value in fields.pairs:
    var kind = fkText
    var known = false
    for (name, fieldKind) in allowed:
      if name == key:
        known = true
        kind = fieldKind
    if not known: raise newException(ValueError, "The change has a field it does not take: " & key & ".")
    let fits = case kind
      of fkInt: value.kind == JInt and value.getBiggestInt >= 1
      of fkBool: value.kind == JBool
      of fkText: value.kind == JString and value.getStr.len in 1 .. 256
    if not fits: raise newException(ValueError, "The value of " & key & " is not valid.")
    result[key] = value
    inc given
  for (name, _) in spec.required:
    if not fields.hasKey(name): raise newException(ValueError, "The change needs " & name & ".")
  if given < spec.minFields: raise newException(ValueError, "Enter at least one value to change.")

proc proxmoxDecisionPayload*(approve: bool, confirmName: string): JsonNode =
  ## A destructive approval carries the name the owner typed; a rejection never needs it.
  if approve and confirmName.len > 0: %*{"confirm_name": confirmName} else: newJObject()

proc proxmoxAskText*(node: string, vmid: int): string =
  ## The same wording the Proxmox specialist is taught for a live status read.
  "What is the current status of VMID " & $vmid & " on node " & node & "?"
