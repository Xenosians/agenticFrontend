import std/[json, options, unittest]
import ../src/app/proxmox_snapshot

proc database(vmid: int, status = "running", issues: seq[string] = @[]): JsonNode =
  %*{"vmid": vmid, "node": "pve-a", "type": "lxc", "name": "orders-db", "engine": "postgres",
    "status": status, "lock": nil, "memory_bytes": 536870912, "memory_total_bytes": 1073741824,
    "disk_bytes": nil, "disk_total_bytes": 8589934592, "uptime_seconds": 600, "backup_job": true,
    "issues": issues}

proc databases(rows: seq[JsonNode] = @[database(101)]): JsonNode =
  %*{"schema": "proxmox-database-inventory.v1", "count": rows.len, "truncated": false,
    "summary": {"running": 1, "not_running": 0, "without_backup_job": 0, "with_issues": 0},
    "backup_coverage_known": true, "backup_coverage_note": nil,
    "databases": rows,
    "storage": [{"node": "pve-a", "storage": "local-lvm", "type": "lvmthin", "shared": false,
      "status": "available", "used_bytes": 85899345920, "total_bytes": 107374182400}],
    "label_hint": nil}

proc overview(section: JsonNode = databases()): JsonNode =
  result = %*{"ok": true, "status": "success", "provider": "proxmox", "observed_at": "2026-11-16T06:00:00Z",
    "data": {"schema": "proxmox-overview.v1",
      "cluster": {"members": [], "truncated": false},
      "nodes": {"nodes": [], "truncated": false},
      "guests": {"guests": [], "truncated": false}}}
  if section != nil: result["data"]["databases"] = section

suite "Proxmox database hosts":
  test "tagged hosts are parsed with their engine, capacity, coverage and storage":
    let snapshot = parseProxmoxSnapshot(overview())
    check snapshot.databases.known
    # Counts come from the server's summary, not from the bounded host list.
    check snapshot.databases.running == 1 and snapshot.databases.notRunning == 0
    check snapshot.databases.withIssues == 0 and snapshot.databases.withoutBackupJob == some(0)
    check snapshot.databases.hosts.len == 1
    let host = snapshot.databases.hosts[0]
    check host.vmid == 101 and host.engine == "postgres" and host.name == "orders-db"
    check host.diskBytes.isNone and host.diskTotalBytes == some(8589934592.0)
    check host.backupJob == some(true)
    check snapshot.databases.coverageKnown
    check snapshot.databases.storage[0].storage == "local-lvm"
    check snapshot.databases.storage[0].shared == some(false)

  test "an overview from a service without the database section is not an empty inventory":
    let snapshot = parseProxmoxSnapshot(overview(nil))
    check not snapshot.databases.known
    check snapshot.databases.hosts.len == 0

  test "unknown coverage keeps its reason and an untagged cluster keeps the labelling hint":
    var section = databases(@[])
    section["backup_coverage_known"] = %false
    section["backup_coverage_note"] = %"Proxmox refused the backup coverage read (HTTP 403)."
    section["label_hint"] = %"Tag a guest db or db-<engine> in Proxmox to list it here."
    let parsed = parseProxmoxSnapshot(overview(section)).databases
    check parsed.known and not parsed.coverageKnown
    check parsed.coverageNote == "Proxmox refused the backup coverage read (HTTP 403)."
    check parsed.labelHint == "Tag a guest db or db-<engine> in Proxmox to list it here."

  test "unknown issue codes, wrong types and unknown schemas are refused":
    for change in [("issues", %*["exploded"]), ("backup_job", %"yes"), ("vmid", %"101"),
                   ("disk_total_bytes", %(-1)), ("engine", %7)]:
      var row = database(101)
      row[change[0]] = change[1]
      expect ValueError: discard parseProxmoxSnapshot(overview(databases(@[row])))
    for change in [("running", %(-1)), ("with_issues", %"2"), ("without_backup_job", %true)]:
      var section = databases()
      section["summary"][change[0]] = change[1]
      expect ValueError: discard parseProxmoxSnapshot(overview(section))
    var unknown = databases()
    unknown["summary"]["without_backup_job"] = newJNull()
    check parseProxmoxSnapshot(overview(unknown)).databases.withoutBackupJob.isNone
    var section = databases()
    section["schema"] = %"proxmox-database-inventory.v2"
    expect ValueError: discard parseProxmoxSnapshot(overview(section))
    var tooMany: seq[JsonNode]
    for vmid in 1 .. 201: tooMany.add database(vmid)
    expect ValueError: discard parseProxmoxSnapshot(overview(databases(tooMany)))

  test "issue labels are plain words, a lock names its reason and only a stopped host blocks":
    check databaseIssueLabel("not_running") == "Not running"
    check databaseIssueLabel("locked") == "Locked"
    check databaseIssueLabel("locked", "backup") == "Locked: backup"
    check databaseIssueLabel("no_backup_job") == "No backup job"
    check databaseIssueLabel("disk_nearly_full") == "Disk nearly full"
    # Every backup run locks its guest while it keeps serving: a lock is a warning.
    check databaseIssueBlocking("not_running")
    for issue in ["locked", "no_backup_job", "disk_nearly_full"]:
      check not databaseIssueBlocking(issue)

  test "a stopped host's memory is what it is assigned, not a measured zero":
    check databaseMemoryLabel(some(0.0), some(1073741824.0), running = false) == "1.0 GiB assigned"
    check databaseMemoryLabel(some(536870912.0), some(1073741824.0), running = true) == "512 MiB of 1.0 GiB"
    check databaseMemoryLabel(none(float), some(1073741824.0), running = true) == "1.0 GiB assigned"
    check databaseMemoryLabel(none(float), none(float), running = true) == "Not reported"

  test "an unmeasured disk splits into its size and a note, so it can wrap between them":
    check databaseDiskParts(none(float), some(8589934592.0)) == ("Size 8.0 GiB,", "use not measured")
    check databaseDiskParts(some(1020054733.0), some(1073741824.0)) == ("973 MiB of 1.0 GiB (95%)", "")

  test "disk use reads as measured or as size only, never as empty":
    check databaseDiskLabel(none(float), some(8589934592.0)) == "Size 8.0 GiB, use not measured"
    check databaseDiskLabel(some(1020054733.0), some(1073741824.0)) == "973 MiB of 1.0 GiB (95%)"
    check databaseDiskLabel(none(float), none(float)) == "Not reported"
    check backupJobLabel(some(true)) == "Covered by a backup job"
    check backupJobLabel(some(false)) == "No backup job"
    check backupJobLabel(none(bool)) == "Backup coverage unknown"
