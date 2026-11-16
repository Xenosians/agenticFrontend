import std/[json, options, unittest]
import ../src/app/[proxmox_health, proxmox_snapshot]

proc guest(vmid: int, issues: seq[string] = @[], latest: JsonNode = nil): JsonNode =
  result = %*{"vmid": vmid, "node": "pve-a", "type": "lxc", "name": "cache", "backup_job": true, "backups": 1,
    "latest": nil, "issues": issues}
  if latest != nil: result["latest"] = latest

proc latest(ageDays = 0.5): JsonNode =
  %*{"storage": "pbs", "time": 1794800000, "age_days": ageDays, "size_bytes": 536870912, "protected": true,
    "encrypted": false, "verified": "ok"}

proc backups(guests: seq[JsonNode]): JsonNode =
  %*{"ok": true, "status": "success", "provider": "proxmox", "observed_at": "2026-11-16T08:00:00Z",
    "data": {"schema": "proxmox-backups.v1", "jobs": {"count": 1, "enabled": 1}, "coverage_known": true,
      "coverage_note": nil, "listing_complete": true, "stale_after_days": 8, "unreadable_storages": [],
      "summary": {"guests": guests.len, "with_recent_backup": 1, "stale": 0, "never": 0, "without_backup_job": 0},
      "storages": [{"node": "pve-a", "storage": "pbs", "type": "pbs", "shared": true, "backups": 1}],
      "count": guests.len, "truncated": false, "guests": guests}}

proc disk(device: string, health = "passed", wear: JsonNode = newJNull(), issues: seq[string] = @[]): JsonNode =
  %*{"device": device, "type": "nvme", "model": "INTEL SSDPEKNW512G8", "size_bytes": 512110190592,
    "health": health, "wear_used_percent": wear, "used_by": "BIOS boot", "issues": issues}

proc health(backupsBody: JsonNode, disks: seq[JsonNode]): JsonNode =
  %*{"schema": "proxmox-health.v1", "backups": backupsBody,
    "disks": [{"node": "pve-a", "result": {"ok": true, "status": "success", "provider": "proxmox",
      "observed_at": "2026-11-16T08:00:00Z",
      "data": {"node": "pve-a", "count": disks.len, "truncated": false,
        "summary": {"disks": disks.len, "failing": 0, "worn": 0, "health_unknown": 0}, "disks": disks}}}]}

suite "Proxmox backups and physical disks":
  test "each guest's newest backup and every node's disks are parsed exactly":
    let parsed = parseProxmoxHealth(health(backups(@[guest(102, latest = latest(0.5))]),
                                           @[disk("/dev/nvme0n1", wear = %12)]))
    check parsed.backups.known and parsed.backups.coverageKnown and parsed.backups.listingComplete
    check parsed.backups.jobs == some(1) and parsed.backups.staleAfterDays == 8
    let row = parsed.backups.guests[0]
    check row.vmid == 102 and row.backupJob == some(true) and row.latest.isSome
    check row.latest.get.storage == "pbs" and row.latest.get.ageDays == 0.5 and row.latest.get.verified == "ok"
    check parsed.disks.len == 1 and parsed.disks[0].node == "pve-a" and parsed.disks[0].error.len == 0
    check parsed.disks[0].disks[0].wearUsedPercent == some(12)

  test "a failed backups read or one node's failed disk read is kept with its own words":
    var body = health(backups(@[]), @[])
    body["backups"] = %*{"ok": false, "status": "error", "provider": "proxmox", "error_code": "provider_timeout",
      "error": "Proxmox VE did not answer in time."}
    body["disks"][0]["result"] = %*{"ok": false, "status": "error", "provider": "proxmox",
      "error_code": "provider_error", "error": "Proxmox refused the read (HTTP 403)."}
    let parsed = parseProxmoxHealth(body)
    check not parsed.backups.known
    check parsed.backups.error == "Proxmox VE did not answer in time."
    check parsed.disks[0].error == "Proxmox refused the read (HTTP 403)."
    check parsed.disks[0].disks.len == 0

  test "unknown issue or health codes, wrong types and schemas are refused":
    for bad in [guest(1, issues = @["exploded"]), guest(0), guest(2, latest = %*{"storage": "x"})]:
      expect ValueError: discard parseProxmoxHealth(health(backups(@[bad]), @[]))
    for bad in [disk("/dev/sda", health = "fine"), disk("/dev/sda", wear = %"12"), disk("sda"),
                disk("/dev/sda", issues = @["melted"])]:
      expect ValueError: discard parseProxmoxHealth(health(backups(@[]), @[bad]))
    var body = health(backups(@[]), @[])
    body["schema"] = %"proxmox-health.v2"
    expect ValueError: discard parseProxmoxHealth(body)
    for days in [%0, %"8", newJNull()]:
      var unbounded = health(backups(@[]), @[])
      unbounded["backups"]["data"]["stale_after_days"] = days
      expect ValueError: discard parseProxmoxHealth(unbounded)

  test "labels say the age, the issue and the wear in plain words":
    check backupAgeLabel(some(0.4)) == "Today"
    check backupAgeLabel(some(1.0)) == "1 day ago"
    check backupAgeLabel(some(12.0)) == "12 days ago"
    check backupAgeLabel(none(float)) == "Never"
    check backupIssueLabel("no_backup_job", 8) == "No backup job"
    check backupIssueLabel("never_backed_up", 8) == "Never backed up"
    # Overdue names the threshold it was judged by.
    check backupIssueLabel("backup_stale", 8) == "Overdue: older than 8 days"
    # A guest in a scheduled job is judged by that job: its last due run left no copy.
    check backupIssueLabel("missed_run", 8) == "Missed its last scheduled run"
    check diskHealthLabel("passed") == "SMART passed"
    check diskHealthLabel("failed") == "SMART failed"
    check diskHealthLabel("unknown") == "Health unknown"
    check diskWearLabel(some(12)) == "12% of rated life used"
    check diskWearLabel(none(int)) == "Not reported"

  test "a disk's issue and kind and a backup copy read in plain words":
    check diskIssueLabel("smart_failed") == "Failing: replace it"
    check diskIssueLabel("worn_out") == "Worn out: plan a replacement"
    check diskIssueBlocking("smart_failed") and not diskIssueBlocking("worn_out")
    # No backup at all is the one backup state that blocks; a missing job or an old copy warns.
    check backupIssueBlocking("never_backed_up")
    check not backupIssueBlocking("no_backup_job") and not backupIssueBlocking("backup_stale")
    check not backupIssueBlocking("missed_run")
    check diskKindLabel("nvme") == "NVMe" and diskKindLabel("hdd") == "HDD" and diskKindLabel("ssd") == "SSD"
    check formatProxmoxBytes(some(4000787030016.0)) == "3.6 TiB"
    check formatProxmoxBytes(some(2147483648.0)) == "2.0 GiB"
    # A phrase that wraps at its commas; a size and "verified ok" never split across lines.
    check backupCopyLabel(BackupCopy(storage: "pbs", sizeBytes: some(2147483648.0), encrypted: true,
                                     verified: "ok")) == "2.0\u00A0GiB on pbs, encrypted, verified\u00A0ok"
    check backupCopyLabel(BackupCopy(storage: "local", protected: true, verified: "failed")) ==
      "On local, protected, verification\u00A0failed"

  test "a missed scheduled run is parsed and counted beside overdue copies":
    var body = backups(@[guest(104, issues = @["missed_run"], latest = latest(2.0))])
    body["data"]["summary"]["missed_run"] = %1
    body["data"]["missed_run_grace_hours"] = %12
    let parsed = parseProxmoxHealth(health(body, @[])).backups
    check parsed.guests[0].issues == @["missed_run"] and parsed.missedRun == 1
    check backupSummaryLabel(parsed) ==
      "1 guest: 1 up to date · 1 missed a scheduled run · 0 overdue · 0 never backed up · 1 backup job"
    # The phrases a summary line wraps between; the label is exactly these, joined.
    check backupSummaryParts(parsed) ==
      @["1 guest:", "1 up to date", "1 missed a scheduled run", "0 overdue", "0 never backed up", "1 backup job"]

  test "the backup summary counts jobs and never judges overdue backups from a partial listing":
    var parsed = parseProxmoxHealth(health(backups(@[guest(102, latest = latest(0.5))]), @[])).backups
    check backupSummaryLabel(parsed) == "1 guest: 1 up to date · 0 overdue · 0 never backed up · 1 backup job"
    parsed.jobs = some(3)
    parsed.enabledJobs = some(2)
    check backupSummaryLabel(parsed) ==
      "1 guest: 1 up to date · 0 overdue · 0 never backed up · 3 backup jobs (1 disabled)"
    parsed.listingComplete = false
    parsed.jobs = none(int)
    check backupSummaryLabel(parsed) ==
      "1 guest: 1 up to date · overdue and missing backups unknown · backup jobs unknown"
