import std/[json, options, unittest]
import ../src/app/proxmox_actions

proc action(status = "waiting_approval"): JsonNode =
  %*{"action_id": "ffffffffffffffffffffffffffffffff", "action": "start", "node": "pve-b", "vmid": 102,
    "type": "lxc", "name": nil, "risk": "medium", "status": status,
    "approval_text": "Start LXC 102 on Proxmox node pve-b.", "created_at": "2026-11-16T03:00:00Z",
    "decided_at": nil, "error": nil}

suite "Proxmox power actions":
  test "only actions that fit the guest's state are offered":
    check guestPowerActions("running") == @["shutdown", "reboot", "force_stop"]
    check guestPowerActions("stopped") == @["start"]
    check guestPowerActions("paused") == @["force_stop"]
    check guestPowerActions("unknown").len == 0

  test "labels name the action and the outcome":
    check powerActionLabel("force_stop") == "Force stop"
    check powerActionLabel("shutdown") == "Shut down"
    check proxmoxActionStatusLabel("waiting_approval") == "Waiting for your confirmation"
    check proxmoxActionStatusLabel("outcome_unknown") == "Outcome unknown"
    check proxmoxActionStatusLabel("succeeded") == "Succeeded"

  test "a saved action and its read-back receipt are parsed exactly":
    var node = action("succeeded")
    node["observed_status"] = %"running"
    node["verification_ok"] = %true
    node["upid"] = %"UPID:pve-b:0001:0002:0003:vzstart:102:janus@pve!dashboard:"
    let parsed = parseProxmoxAction(node)
    check parsed.actionId == "ffffffffffffffffffffffffffffffff"
    check parsed.vmid == 102
    check parsed.name == ""
    check parsed.observedStatus == "running"
    check parsed.verificationOk == some(true)
    check proxmoxActionFinal(parsed.status)

  test "an action with an unknown shape or action is refused":
    for change in [("action", %"delete"), ("vmid", %"102"), ("status", %"done"), ("action_id", %"x")]:
      var node = action()
      node[change[0]] = change[1]
      expect ValueError:
        discard parseProxmoxAction(node)
    expect ValueError:
      discard parseProxmoxActions(%*{"actions": "none"})

  test "the list is newest first and an update replaces its saved row":
    let first = parseProxmoxAction(action())
    var changed = first
    changed.status = "rejected"
    let merged = mergeProxmoxAction(@[first], changed)
    check merged.len == 1
    check merged[0].status == "rejected"
    var other = first
    other.actionId = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    check mergeProxmoxAction(merged, other)[0].actionId == other.actionId

  test "a proposal names one exact guest and a fresh submission":
    let payload = proxmoxActionPayload("pve-b", 102, "start", "6f1c2a4e-1b2c-4d3e-8f9a-0b1c2d3e4f5a")
    check payload == %*{"node": "pve-b", "vmid": 102, "action": "start",
      "submission_id": "6f1c2a4e-1b2c-4d3e-8f9a-0b1c2d3e4f5a"}
    expect ValueError:
      discard proxmoxActionPayload("pve-b", 102, "delete", "6f1c2a4e-1b2c-4d3e-8f9a-0b1c2d3e4f5a")

  test "asking in chat names the exact guest":
    check proxmoxAskText("pve-a", 101) == "What is the current status of VMID 101 on node pve-a?"
