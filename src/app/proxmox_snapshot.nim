## Strict, bounded presentation model for the live Proxmox dashboard response.
import std/[json, math, options, strutils]

type
  ProxmoxMember* = object
    id*, kind*, name*: string
    online*: Option[bool]
  ProxmoxNode* = object
    name*, status*: string
    cpuFraction*, cpuCount*, memoryBytes*, memoryTotalBytes*, diskBytes*, diskTotalBytes*, uptimeSeconds*: Option[float]
  ProxmoxGuest* = object
    vmid*: int
    node*, kind*, name*, status*: string
    cpuFraction*, memoryBytes*, memoryTotalBytes*: Option[float]
  ProxmoxDatabaseHost* = object
    vmid*: int
    node*, kind*, name*, engine*, status*, lock*: string
    memoryBytes*, memoryTotalBytes*, diskBytes*, diskTotalBytes*, uptimeSeconds*: Option[float]
    backupJob*: Option[bool]
    issues*: seq[string]
  ProxmoxStoragePool* = object
    node*, storage*, kind*, status*: string
    shared*: Option[bool]
    usedBytes*, totalBytes*: Option[float]
  ProxmoxDatabases* = object
    ## known is false when the service sent no database section (an older AI
    ## service): that is "not read", never an empty inventory.
    known*, truncated*, coverageKnown*: bool
    coverageNote*, labelHint*: string
    # Counts over every tagged host, from the server; the host list is bounded.
    running*, notRunning*, withIssues*: int
    withoutBackupJob*: Option[int]
    hosts*: seq[ProxmoxDatabaseHost]
    storage*: seq[ProxmoxStoragePool]
  ProxmoxSnapshot* = object
    observedAt*: string
    clusterMembers*: seq[ProxmoxMember]
    nodes*: seq[ProxmoxNode]
    guests*: seq[ProxmoxGuest]
    clusterTruncated*, nodesTruncated*, guestsTruncated*: bool
    databases*: ProxmoxDatabases

const databaseIssues* = ["not_running", "disk_nearly_full", "no_backup_job", "locked"]

proc invalid() {.noreturn.} =
  raise newException(ValueError, "The Proxmox dashboard response is invalid.")

proc member(node: JsonNode, key: string): JsonNode =
  if node == nil or node.kind != JObject or not node.hasKey(key): invalid()
  node[key]

proc objectValue(node: JsonNode, key: string): JsonNode =
  result = member(node, key)
  if result.kind != JObject: invalid()

proc text(node: JsonNode, key: string, nullable = false): string =
  let value = member(node, key)
  if nullable and value.kind == JNull: return ""
  if value.kind != JString: invalid()
  result = value.getStr
  if result.len == 0 or result.len > 512: invalid()

proc optionalNumber(node: JsonNode, key: string): Option[float] =
  let value = member(node, key)
  if value.kind == JNull: return none(float)
  if value.kind notin {JInt, JFloat}: invalid()
  let number = if value.kind == JInt: float(value.getBiggestInt) else: value.getFloat
  if number < 0 or number.classify in {fcNan, fcInf, fcNegInf}: invalid()
  some(number)

proc optionalBool(node: JsonNode, key: string): Option[bool] =
  let value = member(node, key)
  if value.kind == JNull: return none(bool)
  if value.kind != JBool: invalid()
  some(value.getBool)

proc rows(node: JsonNode, key: string, maximum: int): seq[JsonNode] =
  let value = member(node, key)
  if value.kind != JArray or value.len > maximum: invalid()
  for row in value.items:
    if row.kind != JObject: invalid()
    result.add row

proc truncated(node: JsonNode): bool =
  let value = member(node, "truncated")
  if value.kind != JBool: invalid()
  value.getBool

proc vmidOf(row: JsonNode): int =
  let vmid = member(row, "vmid")
  if vmid.kind != JInt or vmid.getBiggestInt < 1 or vmid.getBiggestInt > 2_147_483_647: invalid()
  int(vmid.getBiggestInt)

proc flag(node: JsonNode, key: string): bool =
  let value = member(node, key)
  if value.kind != JBool: invalid()
  value.getBool

proc count(node: JsonNode, key: string): int =
  let value = member(node, key)
  if value.kind != JInt or value.getBiggestInt < 0 or value.getBiggestInt > 1_000_000: invalid()
  int(value.getBiggestInt)

proc parseDatabases(data: JsonNode): ProxmoxDatabases =
  if not data.hasKey("databases"): return
  let section = objectValue(data, "databases")
  if text(section, "schema") != "proxmox-database-inventory.v1": invalid()
  result.known = true
  result.truncated = truncated(section)
  result.coverageKnown = flag(section, "backup_coverage_known")
  result.coverageNote = text(section, "backup_coverage_note", nullable = true)
  result.labelHint = text(section, "label_hint", nullable = true)
  let summary = objectValue(section, "summary")
  result.running = count(summary, "running")
  result.notRunning = count(summary, "not_running")
  result.withIssues = count(summary, "with_issues")
  if member(summary, "without_backup_job").kind != JNull:
    result.withoutBackupJob = some(count(summary, "without_backup_job"))
  for row in rows(section, "databases", 200):
    let issues = member(row, "issues")
    if issues.kind != JArray or issues.len > databaseIssues.len: invalid()
    var host = ProxmoxDatabaseHost(
      vmid: vmidOf(row), node: text(row, "node"), kind: text(row, "type"), name: text(row, "name", nullable = true),
      engine: text(row, "engine", nullable = true), status: text(row, "status"),
      lock: text(row, "lock", nullable = true),
      memoryBytes: optionalNumber(row, "memory_bytes"), memoryTotalBytes: optionalNumber(row, "memory_total_bytes"),
      diskBytes: optionalNumber(row, "disk_bytes"), diskTotalBytes: optionalNumber(row, "disk_total_bytes"),
      uptimeSeconds: optionalNumber(row, "uptime_seconds"), backupJob: optionalBool(row, "backup_job"))
    for issue in issues.items:
      if issue.kind != JString or issue.getStr notin databaseIssues: invalid()
      host.issues.add issue.getStr
    result.hosts.add host
  for row in rows(section, "storage", 200):
    result.storage.add ProxmoxStoragePool(
      node: text(row, "node"), storage: text(row, "storage"), kind: text(row, "type", nullable = true),
      status: text(row, "status", nullable = true), shared: optionalBool(row, "shared"),
      usedBytes: optionalNumber(row, "used_bytes"), totalBytes: optionalNumber(row, "total_bytes"))

proc parseProxmoxSnapshot*(node: JsonNode): ProxmoxSnapshot =
  if text(node, "provider") != "proxmox" or text(node, "status") != "success": invalid()
  let ok = member(node, "ok")
  if ok.kind != JBool or not ok.getBool: invalid()
  result.observedAt = text(node, "observed_at")
  let data = objectValue(node, "data")
  if text(data, "schema") != "proxmox-overview.v1": invalid()

  let cluster = objectValue(data, "cluster")
  result.clusterTruncated = truncated(cluster)
  for row in rows(cluster, "members", 200):
    result.clusterMembers.add ProxmoxMember(
      id: text(row, "id"), kind: text(row, "type"), name: text(row, "name", nullable = true),
      online: optionalBool(row, "online"))

  let nodes = objectValue(data, "nodes")
  result.nodesTruncated = truncated(nodes)
  for row in rows(nodes, "nodes", 200):
    result.nodes.add ProxmoxNode(
      name: text(row, "node"), status: text(row, "status"), cpuFraction: optionalNumber(row, "cpu_fraction"),
      cpuCount: optionalNumber(row, "cpu_count"),
      memoryBytes: optionalNumber(row, "memory_bytes"), memoryTotalBytes: optionalNumber(row, "memory_total_bytes"),
      diskBytes: optionalNumber(row, "disk_bytes"), diskTotalBytes: optionalNumber(row, "disk_total_bytes"),
      uptimeSeconds: optionalNumber(row, "uptime_seconds"))

  let guests = objectValue(data, "guests")
  result.guestsTruncated = truncated(guests)
  for row in rows(guests, "guests", 200):
    result.guests.add ProxmoxGuest(
      vmid: vmidOf(row), node: text(row, "node"), kind: text(row, "type"),
      name: text(row, "name", nullable = true), status: text(row, "status"),
      cpuFraction: optionalNumber(row, "cpu_fraction"), memoryBytes: optionalNumber(row, "memory_bytes"),
      memoryTotalBytes: optionalNumber(row, "memory_total_bytes"))
  result.databases = parseDatabases(data)

proc countOnlineNodes*(snapshot: ProxmoxSnapshot): int =
  for node in snapshot.nodes:
    if node.status == "online": inc result

proc formatProxmoxBytes*(value: Option[float]): string =
  if value.isNone: return "Not reported"
  let bytes = value.get
  if bytes >= 1_099_511_627_776.0: formatFloat(bytes / 1_099_511_627_776.0, ffDecimal, 1) & " TiB"
  elif bytes >= 1_073_741_824: formatFloat(bytes / 1_073_741_824, ffDecimal, 1) & " GiB"
  elif bytes >= 1_048_576: formatFloat(bytes / 1_048_576, ffDecimal, 0) & " MiB"
  elif bytes >= 1024: formatFloat(bytes / 1024, ffDecimal, 0) & " KiB"
  else: formatFloat(bytes, ffDecimal, 0) & " B"

proc formatProxmoxPercent*(used, total: Option[float]): string =
  if used.isNone or total.isNone or total.get <= 0: return "Not reported"
  formatFloat(min(100.0, used.get / total.get * 100.0), ffDecimal, 0) & "%"

proc formatProxmoxUptime*(value: Option[float]): string =
  if value.isNone: return "Not reported"
  let seconds = int(value.get)
  let days = seconds div 86_400
  let hours = (seconds mod 86_400) div 3_600
  let minutes = (seconds mod 3_600) div 60
  if days > 0: $days & "d " & $hours & "h"
  elif hours > 0: $hours & "h " & $minutes & "m"
  else: $minutes & "m"

proc databaseIssueLabel*(issue: string, lock = ""): string =
  case issue
  of "not_running": "Not running"
  of "locked": (if lock.len > 0: "Locked: " & lock else: "Locked")
  of "no_backup_job": "No backup job"
  of "disk_nearly_full": "Disk nearly full"
  else: issue

proc databaseIssueBlocking*(issue: string): bool =
  ## A stopped database host serves nothing. A lock is a warning: every backup
  ## run locks its guest while the guest keeps serving.
  issue == "not_running"

proc databaseDiskLabel*(used, total: Option[float]): string =
  if total.isNone or total.get <= 0: return "Not reported"
  if used.isNone: return "Size " & formatProxmoxBytes(total) & ", use not measured"
  formatProxmoxBytes(used) & " of " & formatProxmoxBytes(total) & " (" & formatProxmoxPercent(used, total) & ")"

proc databaseDiskParts*(used, total: Option[float]): (string, string) =
  ## The disk label as its value and an optional note, so a narrow card wraps
  ## between them instead of inside a number.
  if used.isNone and total.isSome and total.get > 0:
    ("Size " & formatProxmoxBytes(total) & ",", "use not measured")
  else:
    (databaseDiskLabel(used, total), "")

proc databaseMemoryLabel*(used, total: Option[float], running: bool): string =
  ## A stopped guest uses no memory, so its assigned memory is the useful fact.
  if total.isNone or total.get <= 0: return "Not reported"
  if not running or used.isNone: return formatProxmoxBytes(total) & " assigned"
  formatProxmoxBytes(used) & " of " & formatProxmoxBytes(total)

proc backupJobLabel*(value: Option[bool]): string =
  if value.isNone: "Backup coverage unknown"
  elif value.get: "Covered by a backup job"
  else: "No backup job"
