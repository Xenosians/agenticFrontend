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
  ProxmoxSnapshot* = object
    observedAt*: string
    clusterMembers*: seq[ProxmoxMember]
    nodes*: seq[ProxmoxNode]
    guests*: seq[ProxmoxGuest]
    clusterTruncated*, nodesTruncated*, guestsTruncated*: bool

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
    let vmid = member(row, "vmid")
    if vmid.kind != JInt or vmid.getBiggestInt < 1 or vmid.getBiggestInt > 2_147_483_647: invalid()
    result.guests.add ProxmoxGuest(
      vmid: int(vmid.getBiggestInt), node: text(row, "node"), kind: text(row, "type"),
      name: text(row, "name", nullable = true), status: text(row, "status"),
      cpuFraction: optionalNumber(row, "cpu_fraction"), memoryBytes: optionalNumber(row, "memory_bytes"),
      memoryTotalBytes: optionalNumber(row, "memory_total_bytes"))

proc countOnlineNodes*(snapshot: ProxmoxSnapshot): int =
  for node in snapshot.nodes:
    if node.status == "online": inc result

proc formatProxmoxBytes*(value: Option[float]): string =
  if value.isNone: return "Not reported"
  let bytes = value.get
  if bytes >= 1_073_741_824: formatFloat(bytes / 1_073_741_824, ffDecimal, 1) & " GiB"
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
