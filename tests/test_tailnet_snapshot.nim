import std/[json, options, unittest]
import ../src/app/tailnet_snapshot

proc device(name = "hummingbird", issues: seq[string] = @[]): JsonNode =
  %*{"name": name, "dns_name": name & ".tail1234.ts.net", "os": "linux", "client_version": "1.104.4",
    "update_available": false, "online": true, "last_seen": "2026-11-16T05:00:00Z",
    "key_expires": "2027-05-01T00:00:00Z", "key_expiry_disabled": false, "key_expires_in_days": 166,
    "authorized": true, "shared_from_another_tailnet": false, "tags": ["tag:janus-lab"],
    "blocks_incoming": false, "routes_advertised": 0, "routes_waiting_for_approval": 0,
    "exit_node_offered": false, "tailnet_lock_error": false,
    "connectivity": {"udp": true, "hard_nat": false, "port_mapping": false, "nearest_relay": "Singapore",
                     "relay_latency_ms": 27.2},
    "issues": issues}

proc overview(devices: seq[JsonNode], dns: JsonNode = nil, dnsError: JsonNode = nil): JsonNode =
  %*{"ok": true, "status": "success", "provider": "tailscale", "observed_at": "2026-11-16T05:00:00+00:00",
    "data": {"schema": "tailnet-overview.v1",
             "devices": {"count": devices.len, "truncated": false,
                         "summary": {"online": devices.len, "offline": 0, "with_issues": 0},
                         "devices": devices},
             "dns": (if dns == nil: newJNull() else: dns),
             "dns_error": (if dnsError == nil: newJNull() else: dnsError)}}

suite "Tailnet overview":
  test "a device's health is parsed exactly as the service read it":
    let parsed = parseTailnetSnapshot(overview(@[device()], %*{"magic_dns": true, "override_local_dns": false,
      "nameservers": [{"address": "1.1.1.1", "encrypted": true}], "split_dns": [], "search_domains": []}))
    check parsed.observedAt == "2026-11-16T05:00:00+00:00"
    check parsed.count == 1 and parsed.online == 1 and parsed.withIssues == 0
    let row = parsed.devices[0]
    check row.name == "hummingbird" and row.os == "linux" and row.clientVersion == "1.104.4"
    check row.online == some(true) and row.keyExpiresInDays == some(166)
    check row.nearestRelay == "Singapore" and row.relayLatencyMs == some(27.2)
    check row.udp == some(true) and row.hardNat == some(false)
    check row.issues.len == 0
    check parsed.dnsLoaded and parsed.magicDns and not parsed.overrideLocalDns
    check parsed.resolvers == @["1.1.1.1 (encrypted)"]

  test "a device that sent no connectivity report stays unknown":
    var quiet = device("phone")
    quiet["connectivity"] = newJNull()
    quiet["online"] = %false
    let row = parseTailnetSnapshot(overview(@[quiet])).devices[0]
    check row.udp.isNone and row.hardNat.isNone and row.nearestRelay == ""
    check connectionLabel(row) == "Not reported" and relayLabel(row) == ""

  test "a failed DNS read is named beside the devices":
    let parsed = parseTailnetSnapshot(overview(@[device()], dnsError = %*{"reason": "provider_error",
      "message": "Tailscale refused the read (HTTP 403)."}))
    check not parsed.dnsLoaded
    check parsed.dnsError == "Tailscale refused the read (HTTP 403)."

  test "issues read as plain words, most urgent first":
    let row = parseTailnetSnapshot(overview(@[device("kiosk", @["key_expiring", "udp_blocked"])])).devices[0]
    check row.issues == @["key_expiring", "udp_blocked"]
    check tailnetIssueLabel("key_expired") == "Key expired"
    check tailnetIssueLabel("key_expiring") == "Key expires soon"
    check tailnetIssueLabel("waiting_for_approval") == "Device needs approval"
    check tailnetIssueLabel("routes_waiting_for_approval") == "Routes need approval"
    check tailnetIssueLabel("tailnet_lock_error") == "Tailnet lock error"
    check tailnetIssueLabel("blocks_incoming") == "Blocks incoming connections"
    check tailnetIssueLabel("udp_blocked") == "UDP blocked"
    check tailnetIssueLabel("update_available") == "Update available"

  test "issues that cut a device off are marked as blocking":
    for issue in ["key_expired", "tailnet_lock_error", "waiting_for_approval"]:
      check tailnetIssueBlocking(issue)
    for issue in ["key_expiring", "routes_waiting_for_approval", "blocks_incoming", "udp_blocked", "update_available"]:
      check not tailnetIssueBlocking(issue)

  test "devices needing attention come first, blocking ones before the rest":
    let parsed = parseTailnetSnapshot(overview(@[device("alpha"), device("bravo", @["update_available"]),
                                                 device("charlie", @["key_expired"]), device("delta")]))
    var names: seq[string]
    for row in attentionOrder(parsed.devices): names.add row.name
    check names == @["charlie", "bravo", "alpha", "delta"]

  test "connection, nearest relay and key expiry read as plain words":
    var row = parseTailnetSnapshot(overview(@[device()])).devices[0]
    check connectionLabel(row) == "Direct"
    check relayLabel(row) == "Singapore 27 ms"
    row.udp = some(false)
    check connectionLabel(row) == "Relayed"
    row.udp = some(true)
    row.hardNat = some(true)
    check connectionLabel(row) == "Often relayed (hard NAT)"
    row.relayLatencyMs = none(float)
    check relayLabel(row) == "Singapore"
    check keyExpiryLabel(row) == "In 166 days"
    row.keyExpiresInDays = some(1)
    check keyExpiryLabel(row) == "In 1 day"
    row.keyExpiresInDays = some(-3)
    check keyExpiryLabel(row) == "Expired 3 days ago"
    row.keyExpiresInDays = some(0)
    row.issues = @["key_expired"]
    check keyExpiryLabel(row) == "Expired"
    row.keyExpiryDisabled = true
    check keyExpiryLabel(row) == "Never expires"

  test "an unknown issue code or a malformed answer is refused, not shown":
    expect ValueError:
      discard parseTailnetSnapshot(overview(@[device("x", @["made_up"])]))
    var bad = device()
    bad["online"] = %"yes"
    expect ValueError:
      discard parseTailnetSnapshot(overview(@[bad]))
    var wrong = overview(@[device()])
    wrong["data"]["schema"] = %"tailnet-overview.v0"
    expect ValueError:
      discard parseTailnetSnapshot(wrong)
