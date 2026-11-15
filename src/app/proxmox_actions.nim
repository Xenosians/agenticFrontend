## Proxmox guest power actions started from the dashboard: the strict model
## of a saved action, the actions a guest's state allows, and the exact
## request text used when the owner asks about a guest in chat.
##
## The backend owns the action. A button press only proposes it; nothing runs
## until the owner confirms the server's exact description of the target.
import std/[json, options]

type
  ProxmoxAction* = object
    actionId*, action*, node*, kind*, name*, risk*, status*: string
    vmid*: int
    approvalText*, createdAt*, decidedAt*, error*: string
    observedStatus*, expectedStatus*, upid*, taskExitStatus*, observedAt*: string
    verificationOk*: Option[bool]

const
  powerActions* = ["start", "shutdown", "reboot", "force_stop"]
  actionStatuses = ["waiting_approval", "executing", "rejecting", "succeeded", "failed",
                    "rejected", "outcome_unknown"]

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
  if result.action notin powerActions: invalid()
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

proc proxmoxAskText*(node: string, vmid: int): string =
  ## The same wording the Proxmox specialist is taught for a live status read.
  "What is the current status of VMID " & $vmid & " on node " & node & "?"
