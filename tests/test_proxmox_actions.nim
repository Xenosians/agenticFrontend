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
    for change in [("action", %"format_disk"), ("vmid", %"102"), ("status", %"done"), ("action_id", %"x")]:
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
      discard proxmoxActionPayload("pve-b", 102, "format_disk", "6f1c2a4e-1b2c-4d3e-8f9a-0b1c2d3e4f5a")

  test "asking in chat names the exact guest":
    check proxmoxAskText("pve-a", 101) == "What is the current status of VMID 101 on node pve-a?"

suite "Proxmox guest changes from the dashboard":
  const submission = "6f1c2a4e-1b2c-4d3e-8f9a-0b1c2d3e4f5a"

  test "each guest offers the changes its state allows; a running guest is not deleted":
    check guestChangeActions("stopped") == @["set_resources", "resize_disk", "set_options", "snapshot_create",
                                             "backup_now", "clone", "snapshot_rollback", "snapshot_delete",
                                             "delete"]
    check "delete" notin guestChangeActions("running")
    check "snapshot_create" in guestChangeActions("running")
    check guestChangeActions("unknown").len == 0

  test "labels and destructive changes are named the way the server names them":
    check changeActionLabel("set_resources") == "CPU and memory"
    check changeActionLabel("snapshot_rollback") == "Roll back"
    check changeActionLabel("delete") == "Delete guest"
    for action in ["delete", "snapshot_delete", "snapshot_rollback", "backup_restore"]:
      check changeIsDestructive(action)
    for action in ["set_resources", "snapshot_create", "backup_now", "clone", "start"]:
      check not changeIsDestructive(action)

  test "a change carries only its own typed fields":
    let resources = proxmoxChangePayload("pve-b", 102, "set_resources", submission,
                                         %*{"cores": 2, "memory_mib": 256})
    check resources == %*{"node": "pve-b", "vmid": 102, "action": "set_resources", "submission_id": submission,
                          "cores": 2, "memory_mib": 256}
    let snapshot = proxmoxChangePayload("pve-b", 102, "snapshot_create", submission, %*{"snapshot": "before"})
    check snapshot["snapshot"] == %"before"
    check proxmoxChangePayload("pve-b", 102, "delete", submission, newJObject()) ==
      %*{"node": "pve-b", "vmid": 102, "action": "delete", "submission_id": submission}

  test "a change with a missing, extra or mistyped field is refused before it is sent":
    for (action, fields) in [("set_resources", newJObject()),
                             ("set_resources", %*{"cores": "2"}),
                             ("resize_disk", %*{"disk": "rootfs"}),
                             ("snapshot_create", %*{"snapshot": "before", "vmid": 9}),
                             ("clone", %*{"name": "x", "full": "yes"}),
                             ("delete", %*{"purge": true})]:
      expect ValueError:
        discard proxmoxChangePayload("pve-b", 102, action, submission, fields)

  test "a saved change parses, and a destructive one names the guest to type":
    var node = action()
    node["action"] = %"delete"
    node["name"] = %"janus-lab"
    node["destructive"] = %true
    let parsed = parseProxmoxAction(node)
    check parsed.action == "delete" and parsed.destructive
    check parsed.name == "janus-lab"
    check proxmoxActionLabel(parsed.action) == "Delete guest"
    check proxmoxActionLabel("start") == "Start"

  test "the decision sends the typed name only for a destructive approval":
    check proxmoxDecisionPayload(approve = true, confirmName = "janus-lab") == %*{"confirm_name": "janus-lab"}
    check proxmoxDecisionPayload(approve = true, confirmName = "") == newJObject()
    check proxmoxDecisionPayload(approve = false, confirmName = "janus-lab") == newJObject()
