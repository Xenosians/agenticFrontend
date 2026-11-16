## Strict, bounded model of the Proxmox backups and physical-disk health read.
import std/[json, math, options, strutils]
import proxmox_snapshot

type
  BackupCopy* = object
    storage*, verified*: string
    time*, ageDays*: float
    sizeBytes*: Option[float]
    protected*, encrypted*: bool
  GuestBackups* = object
    vmid*: int
    node*, kind*, name*: string
    backupJob*: Option[bool]
    backups*: int
    latest*: Option[BackupCopy]
    issues*: seq[string]
  BackupStorage* = object
    node*, storage*, kind*: string
    shared*: bool
    backups*: int
  UnreadableStorage* = object
    node*, storage*, reason*: string
  ProxmoxBackups* = object
    ## known is false when the read failed; error then holds the service's words.
    known*, coverageKnown*, listingComplete*, truncated*: bool
    error*, coverageNote*: string
    staleAfterDays*: int  ## the service's threshold for an overdue backup
    jobs*, enabledJobs*: Option[int]
    withRecentBackup*, stale*, never*: int
    withoutBackupJob*: Option[int]
    guests*: seq[GuestBackups]
    storages*: seq[BackupStorage]
    unreadable*: seq[UnreadableStorage]
  PhysicalDisk* = object
    device*, kind*, model*, health*, usedBy*: string
    sizeBytes*: Option[float]
    wearUsedPercent*: Option[int]
    issues*: seq[string]
  NodeDisks* = object
    node*, error*: string
    disks*: seq[PhysicalDisk]
    truncated*: bool
  ProxmoxHealth* = object
    backups*: ProxmoxBackups
    disks*: seq[NodeDisks]

const backupIssues* = ["no_backup_job", "never_backed_up", "backup_stale"]
const diskIssues* = ["smart_failed", "worn_out"]
const diskHealths* = ["passed", "failed", "smart_disabled", "unknown"]

proc invalid() {.noreturn.} =
  raise newException(ValueError, "The Proxmox health response is invalid.")

proc member(node: JsonNode, key: string): JsonNode =
  if node == nil or node.kind != JObject or not node.hasKey(key): invalid()
  node[key]

proc text(node: JsonNode, key: string, nullable = false): string =
  let value = member(node, key)
  if nullable and value.kind == JNull: return ""
  if value.kind != JString: invalid()
  result = value.getStr
  if result.len == 0 or result.len > 512: invalid()

proc flag(node: JsonNode, key: string): bool =
  let value = member(node, key)
  if value.kind != JBool: invalid()
  value.getBool

proc count(node: JsonNode, key: string, maximum = 1_000_000): int =
  let value = member(node, key)
  if value.kind != JInt or value.getBiggestInt < 0 or value.getBiggestInt > maximum: invalid()
  int(value.getBiggestInt)

proc optionalCount(node: JsonNode, key: string): Option[int] =
  if member(node, key).kind == JNull: none(int) else: some(count(node, key))

proc number(node: JsonNode, key: string): float =
  let value = member(node, key)
  if value.kind notin {JInt, JFloat}: invalid()
  result = if value.kind == JInt: float(value.getBiggestInt) else: value.getFloat
  if result < 0 or result.classify in {fcNan, fcInf, fcNegInf}: invalid()

proc optionalNumber(node: JsonNode, key: string): Option[float] =
  if member(node, key).kind == JNull: none(float) else: some(number(node, key))

proc optionalBool(node: JsonNode, key: string): Option[bool] =
  if member(node, key).kind == JNull: none(bool) else: some(flag(node, key))

proc rows(node: JsonNode, key: string, maximum: int): seq[JsonNode] =
  let value = member(node, key)
  if value.kind != JArray or value.len > maximum: invalid()
  for row in value.items:
    if row.kind != JObject: invalid()
    result.add row

proc codes(node: JsonNode, key: string, allowed: openArray[string]): seq[string] =
  let value = member(node, key)
  if value.kind != JArray or value.len > allowed.len: invalid()
  for item in value.items:
    if item.kind != JString or item.getStr notin allowed: invalid()
    result.add item.getStr

proc readFailure(node: JsonNode): string =
  ## The service's fixed words for a failed read; never empty.
  result = text(node, "error", nullable = true)
  if result.len == 0: result = "The read did not succeed."

proc parseBackups(node: JsonNode): ProxmoxBackups =
  if not flag(node, "ok"):
    result.error = readFailure(node)
    return
  let data = member(node, "data")
  if text(data, "schema") != "proxmox-backups.v1": invalid()
  result.known = true
  result.coverageKnown = flag(data, "coverage_known")
  result.coverageNote = text(data, "coverage_note", nullable = true)
  result.listingComplete = flag(data, "listing_complete")
  result.truncated = flag(data, "truncated")
  result.staleAfterDays = count(data, "stale_after_days", 366)
  if result.staleAfterDays < 1: invalid()
  let jobs = member(data, "jobs")
  if jobs.kind != JNull:
    result.jobs = some(count(jobs, "count"))
    result.enabledJobs = some(count(jobs, "enabled"))
  let summary = member(data, "summary")
  result.withRecentBackup = count(summary, "with_recent_backup")
  result.stale = count(summary, "stale")
  result.never = count(summary, "never")
  result.withoutBackupJob = optionalCount(summary, "without_backup_job")
  for row in rows(data, "guests", 200):
    let vmid = count(row, "vmid", 2_147_483_647)
    if vmid < 1: invalid()
    var guest = GuestBackups(vmid: vmid, node: text(row, "node"), kind: text(row, "type"),
                             name: text(row, "name", nullable = true), backupJob: optionalBool(row, "backup_job"),
                             backups: count(row, "backups"), issues: codes(row, "issues", backupIssues))
    let copy = member(row, "latest")
    if copy.kind != JNull:
      guest.latest = some(BackupCopy(
        storage: text(copy, "storage"), time: number(copy, "time"), ageDays: number(copy, "age_days"),
        sizeBytes: optionalNumber(copy, "size_bytes"), protected: flag(copy, "protected"),
        encrypted: flag(copy, "encrypted"), verified: text(copy, "verified", nullable = true)))
    result.guests.add guest
  for row in rows(data, "storages", 50):
    result.storages.add BackupStorage(node: text(row, "node"), storage: text(row, "storage"),
                                      kind: text(row, "type"), shared: flag(row, "shared"),
                                      backups: count(row, "backups"))
  for row in rows(data, "unreadable_storages", 50):
    result.unreadable.add UnreadableStorage(node: text(row, "node"), storage: text(row, "storage"),
                                            reason: text(row, "reason"))

proc parseNodeDisks(node: string, result_json: JsonNode): NodeDisks =
  result.node = node
  if not flag(result_json, "ok"):
    result.error = readFailure(result_json)
    return
  let data = member(result_json, "data")
  if text(data, "node") != node: invalid()
  result.truncated = flag(data, "truncated")
  for row in rows(data, "disks", 200):
    let device = text(row, "device")
    if not device.startsWith("/dev/"): invalid()
    let health = text(row, "health")
    if health notin diskHealths: invalid()
    var wear = none(int)
    if member(row, "wear_used_percent").kind != JNull:
      let value = count(row, "wear_used_percent", 100)
      wear = some(value)
    result.disks.add PhysicalDisk(device: device, kind: text(row, "type"), model: text(row, "model", nullable = true),
                                  health: health, usedBy: text(row, "used_by", nullable = true),
                                  sizeBytes: optionalNumber(row, "size_bytes"), wearUsedPercent: wear,
                                  issues: codes(row, "issues", diskIssues))

proc parseProxmoxHealth*(node: JsonNode): ProxmoxHealth =
  if text(node, "schema") != "proxmox-health.v1": invalid()
  result.backups = parseBackups(member(node, "backups"))
  for entry in rows(node, "disks", 64):
    result.disks.add parseNodeDisks(text(entry, "node"), member(entry, "result"))

proc backupAgeLabel*(ageDays: Option[float]): string =
  if ageDays.isNone: return "Never"
  let days = ageDays.get
  if days < 1: "Today"
  elif days < 1.5: "1 day ago"
  else: $int(round(days)) & " days ago"

proc backupIssueLabel*(issue: string, staleAfterDays: int): string =
  case issue
  of "no_backup_job": "No backup job"
  of "never_backed_up": "Never backed up"
  of "backup_stale": "Overdue: older than " & $staleAfterDays & " days"
  else: issue

proc diskHealthLabel*(health: string): string =
  case health
  of "passed": "SMART passed"
  of "failed": "SMART failed"
  of "smart_disabled": "SMART disabled"
  else: "Health unknown"

proc diskWearLabel*(wear: Option[int]): string =
  if wear.isNone: "Not reported" else: $wear.get & "% of rated life used"

proc diskIssueLabel*(issue: string): string =
  case issue
  of "smart_failed": "Failing: replace it"
  of "worn_out": "Worn out: plan a replacement"
  else: issue

proc diskIssueBlocking*(issue: string): bool =
  ## A failing disk can lose data now; a worn one should be replaced soon.
  issue == "smart_failed"

proc backupIssueBlocking*(issue: string): bool =
  ## No backup at all is the one gap that leaves nothing to restore.
  issue == "never_backed_up"

proc diskKindLabel*(kind: string): string =
  case kind
  of "nvme": "NVMe"
  of "hdd": "HDD"
  of "ssd": "SSD"
  of "usb": "USB"
  else: kind

const unbreakable = "\u00A0"
  ## Joins the words of one fact so a narrow card wraps between facts, not inside one.

proc backupCopyLabel*(copy: BackupCopy): string =
  ## A phrase, so a wrapped line ends at a comma instead of a dangling separator.
  var parts = @[if copy.sizeBytes.isSome:
                  formatProxmoxBytes(copy.sizeBytes).replace(" ", unbreakable) & " on " & copy.storage
                else: "On " & copy.storage]
  if copy.protected: parts.add "protected"
  if copy.encrypted: parts.add "encrypted"
  if copy.verified == "ok": parts.add "verified" & unbreakable & "ok"
  elif copy.verified.len > 0: parts.add "verification" & unbreakable & copy.verified
  parts.join(", ")

proc backupSummaryLabel*(backups: ProxmoxBackups): string =
  ## Guests first, then the jobs that protect them: two different counts, never one list.
  let guests = $backups.guests.len & (if backups.guests.len == 1: " guest: " else: " guests: ")
  let jobs =
    if backups.jobs.isNone: "backup jobs unknown"
    else:
      let count = backups.jobs.get
      let disabled = count - backups.enabledJobs.get(count)
      $count & (if count == 1: " backup job" else: " backup jobs") &
        (if disabled > 0: " (" & $disabled & " disabled)" else: "")
  # Overdue and missing backups are judged only from a complete listing.
  let gaps =
    if not backups.listingComplete: "overdue and missing backups unknown"
    else: $backups.stale & " overdue · " & $backups.never & " never backed up"
  guests & $backups.withRecentBackup & " up to date · " & gaps & " · " & jobs
