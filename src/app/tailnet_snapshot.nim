## Strict, bounded presentation model for the tailnet overview (device health and DNS settings).
##
## Only fields the AI normalized are read: no addresses, endpoints, routes or
## keys reach the browser. A missing report stays unknown (`none`), never healthy.
import std/[json, math, options, strutils]

const tailnetIssues* = ["key_expired", "key_expiring", "waiting_for_approval", "tailnet_lock_error",
                        "routes_waiting_for_approval", "blocks_incoming", "udp_blocked", "update_available"]

type
  TailnetDevice* = object
    name*, dnsName*, os*, clientVersion*, lastSeen*: string
    online*, authorized*, updateAvailable*, blocksIncoming*: Option[bool]
    keyExpiryDisabled*: bool
    keyExpiresInDays*: Option[int]
    routesAdvertised*, routesWaiting*: Option[int]
    exitNodeOffered*: Option[bool]
    udp*, hardNat*: Option[bool]
    nearestRelay*: string
    relayLatencyMs*: Option[float]
    tags*, issues*: seq[string]
  TailnetSnapshot* = object
    observedAt*: string
    count*, online*, offline*, withIssues*: int
    truncated*: bool
    devices*: seq[TailnetDevice]
    dnsLoaded*, magicDns*, overrideLocalDns*: bool
    resolvers*, splitDomains*: seq[string]
    dnsError*: string

proc invalid() {.noreturn.} =
  raise newException(ValueError, "The tailnet overview response is invalid.")

proc member(node: JsonNode, key: string): JsonNode =
  if node == nil or node.kind != JObject or not node.hasKey(key): invalid()
  node[key]

proc objectValue(node: JsonNode, key: string): JsonNode =
  result = member(node, key)
  if result.kind != JObject: invalid()

proc text(node: JsonNode, key: string, nullable = false, limit = 255): string =
  let value = member(node, key)
  if nullable and value.kind == JNull: return ""
  if value.kind != JString: invalid()
  result = value.getStr
  if result.len > limit or (result.len == 0 and not nullable): invalid()

proc flag(node: JsonNode, key: string): bool =
  let value = member(node, key)
  if value.kind != JBool: invalid()
  value.getBool

proc optionalFlag(node: JsonNode, key: string): Option[bool] =
  let value = member(node, key)
  if value.kind == JNull: return none(bool)
  if value.kind != JBool: invalid()
  some(value.getBool)

proc optionalInt(node: JsonNode, key: string, minimum = 0): Option[int] =
  let value = member(node, key)
  if value.kind == JNull: return none(int)
  if value.kind != JInt or value.getBiggestInt < minimum or value.getBiggestInt > 1_000_000: invalid()
  some(int(value.getBiggestInt))

proc count(node: JsonNode, key: string): int =
  let value = optionalInt(node, key)
  if value.isNone: invalid()
  value.get

proc strings(node: JsonNode, key: string, maximum: int, limit = 255): seq[string] =
  let value = member(node, key)
  if value.kind != JArray or value.len > maximum: invalid()
  for item in value.items:
    if item.kind != JString or item.getStr.len == 0 or item.getStr.len > limit: invalid()
    result.add item.getStr

proc parseDevice(row: JsonNode): TailnetDevice =
  if row.kind != JObject: invalid()
  result = TailnetDevice(
    name: text(row, "name", limit = 120), dnsName: text(row, "dns_name", nullable = true),
    os: text(row, "os", nullable = true, limit = 40), clientVersion: text(row, "client_version", nullable = true, limit = 60),
    lastSeen: text(row, "last_seen", nullable = true, limit = 40),
    online: optionalFlag(row, "online"), authorized: optionalFlag(row, "authorized"),
    updateAvailable: optionalFlag(row, "update_available"), blocksIncoming: optionalFlag(row, "blocks_incoming"),
    keyExpiryDisabled: flag(row, "key_expiry_disabled"),
    keyExpiresInDays: optionalInt(row, "key_expires_in_days", minimum = -1_000_000),
    routesAdvertised: optionalInt(row, "routes_advertised"), routesWaiting: optionalInt(row, "routes_waiting_for_approval"),
    exitNodeOffered: optionalFlag(row, "exit_node_offered"),
    tags: strings(row, "tags", 20, 60), issues: strings(row, "issues", tailnetIssues.len, 40))
  for issue in result.issues:
    if issue notin tailnetIssues: invalid()
  let connectivity = member(row, "connectivity")
  if connectivity.kind == JObject:
    result.udp = optionalFlag(connectivity, "udp")
    result.hardNat = optionalFlag(connectivity, "hard_nat")
    result.nearestRelay = text(connectivity, "nearest_relay", nullable = true, limit = 60)
    let latency = member(connectivity, "relay_latency_ms")
    if latency.kind in {JInt, JFloat}:
      let value = if latency.kind == JInt: float(latency.getBiggestInt) else: latency.getFloat
      if value < 0 or value.classify in {fcNan, fcInf, fcNegInf}: invalid()
      result.relayLatencyMs = some(value)
    elif latency.kind != JNull: invalid()
  elif connectivity.kind != JNull: invalid()

proc parseTailnetSnapshot*(node: JsonNode): TailnetSnapshot =
  if text(node, "provider") != "tailscale" or text(node, "status") != "success": invalid()
  if not flag(node, "ok"): invalid()
  result.observedAt = text(node, "observed_at", limit = 64)
  let data = objectValue(node, "data")
  if text(data, "schema") != "tailnet-overview.v1": invalid()
  let devices = objectValue(data, "devices")
  result.count = count(devices, "count")
  result.truncated = flag(devices, "truncated")
  let summary = objectValue(devices, "summary")
  result.online = count(summary, "online")
  result.offline = count(summary, "offline")
  result.withIssues = count(summary, "with_issues")
  let rows = member(devices, "devices")
  if rows.kind != JArray or rows.len > 200: invalid()
  for row in rows.items:
    result.devices.add parseDevice(row)
  let dns = member(data, "dns")
  if dns.kind == JObject:
    result.dnsLoaded = true
    result.magicDns = flag(dns, "magic_dns")
    result.overrideLocalDns = flag(dns, "override_local_dns")
    let servers = member(dns, "nameservers")
    if servers.kind != JArray or servers.len > 50: invalid()
    for server in servers.items:
      result.resolvers.add text(server, "address", limit = 64) &
        (if flag(server, "encrypted"): " (encrypted)" else: " (plain DNS)")
    let split = member(dns, "split_dns")
    if split.kind != JArray or split.len > 50: invalid()
    for domain in split.items:
      result.splitDomains.add text(domain, "domain")
  elif dns.kind != JNull: invalid()
  let failure = member(data, "dns_error")
  if failure.kind == JObject:
    result.dnsError = text(failure, "message", limit = 300)
  elif failure.kind != JNull: invalid()

proc tailnetIssueLabel*(issue: string): string =
  case issue
  of "key_expired": "Key expired"
  of "key_expiring": "Key expires soon"
  of "waiting_for_approval": "Device needs approval"
  of "routes_waiting_for_approval": "Routes need approval"
  of "tailnet_lock_error": "Tailnet lock error"
  of "blocks_incoming": "Blocks incoming connections"
  of "udp_blocked": "UDP blocked"
  of "update_available": "Update available"
  else: issue

proc tailnetIssueBlocking*(issue: string): bool =
  ## The device cannot take part in the tailnet until this is resolved.
  issue in ["key_expired", "tailnet_lock_error", "waiting_for_approval"]

proc attentionRank(device: TailnetDevice): int =
  for issue in device.issues:
    if tailnetIssueBlocking(issue): return 0
  if device.issues.len > 0: 1 else: 2

proc attentionOrder*(devices: seq[TailnetDevice]): seq[TailnetDevice] =
  ## Blocking problems first, then other issues, then healthy devices; names keep their order within each.
  for rank in 0 .. 2:
    for device in devices:
      if attentionRank(device) == rank: result.add device

proc connectionLabel*(device: TailnetDevice): string =
  ## How the device reaches peers, from its last report.
  if device.udp.isNone and device.hardNat.isNone and device.nearestRelay.len == 0: "Not reported"
  elif device.udp == some(false): "Relayed"
  elif device.hardNat == some(true): "Often relayed (hard NAT)"
  elif device.udp == some(true): "Direct"
  else: "Not reported"

proc relayLabel*(device: TailnetDevice): string =
  if device.nearestRelay.len == 0: return ""
  result = device.nearestRelay
  if device.relayLatencyMs.isSome:
    result.add " " & formatFloat(device.relayLatencyMs.get, ffDecimal, 0) & " ms"

proc keyExpiryLabel*(device: TailnetDevice): string =
  if device.keyExpiryDisabled: return "Never expires"
  if device.keyExpiresInDays.isNone: return "Not reported"
  let days = device.keyExpiresInDays.get
  if days < 0: "Expired " & $(-days) & " days ago"
  elif "key_expired" in device.issues: "Expired"
  elif days == 1: "In 1 day"
  else: "In " & $days & " days"
