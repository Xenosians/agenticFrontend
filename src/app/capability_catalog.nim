## The capability catalog as people read it (FR-081, NFR-036).
##
## The trusted catalog lists every governed operation with the specialists
## that serve it, its effect, whether it needs approval, and the provider
## whose setup it needs. People look for an operation by the service it
## touches, so operations are grouped by that provider and named in words.
## A summary is the description's first sentence: the rest is guidance for
## the model choosing the operation. The identifier stays available to search.

import std/[algorithm, json, strutils]

import integration_setup

type
  Operation* = object
    id*, name*, summary*, provider*: string
    change*, approval*: bool

  ServiceGroup* = object
    id*, name*: string
    setup*: IntegrationSetup  ## Empty when the setup state is unknown.
    operations*: seq[Operation]

# Written in capitals inside a name; identifiers are lower case by convention.
const acronyms = ["api", "dhcp", "dns", "http", "imap", "ip", "itsm", "ldap", "sla", "smtp", "ssh", "url", "vpn"]


proc field(node: JsonNode, key: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString: node[key].getStr
  else: ""


proc words(identifier: string): string =
  ## "network_dhcp_leases" -> "Network DHCP leases".
  var parts: seq[string]
  for part in identifier.multiReplace(("_", " "), ("-", " ")).splitWhitespace():
    parts.add (if part.toLowerAscii() in acronyms: part.toUpperAscii() else: part)
  result = parts.join(" ")
  if result.len > 0:
    result[0] = result[0].toUpperAscii()


proc operationName*(id: string): string =
  words(id)


proc serviceName*(provider: string): string =
  if provider.len == 0: "Other" else: words(provider)


proc withoutReadOnlyLead(text: string): string =
  ## "Read only, changes nothing: check ..." -> "check ...". The Read tag
  ## already says so; "Read only the first lines" is the description itself.
  let lowered = text.toLowerAscii()
  for lead in ["read only", "read-only"]:
    if lowered.startsWith(lead) and text.len > lead.len and text[lead.len] in {',', ':', '.'}:
      let stop = text.find({':', '.'}, lead.len)
      let rest = text[stop + 1 .. ^1].strip()
      if rest.len > 0:
        return rest
  text


proc firstSentence(text: string): string =
  ## Up to the first full stop that ends a sentence; "e.g." does not.
  var wordStart = 0
  for index, character in text:
    if character == ' ':
      wordStart = index + 1
    elif character == '.' and index + 2 < text.len and text[index + 1] == ' ' and
        text[index + 2] in {'A'..'Z'} and '.' notin text[wordStart ..< index]:
      return text[0 .. index]
  text


proc operationSummary*(description: string): string =
  result = firstSentence(withoutReadOnlyLead(description.strip()))
  if result.len > 0:
    result[0] = result[0].toUpperAscii()


proc served(item: JsonNode): bool =
  ## Offered only when a specialist serves it.
  if not item.hasKey("agent_names") or item["agent_names"].kind != JArray: return false
  for owner in item["agent_names"]:
    if owner.kind == JString and owner.getStr.len > 0: return true


proc catalogOperations*(catalog: JsonNode): seq[Operation] =
  ## One entry per served operation, by identifier; none for a missing or malformed catalog.
  if catalog == nil or catalog.kind != JObject or not catalog.hasKey("capabilities") or
     catalog["capabilities"].kind != JArray:
    return
  for item in catalog["capabilities"]:
    if item.kind != JObject or field(item, "id").len == 0 or not served(item):
      continue
    let id = field(item, "id")
    result.add Operation(
      id: id, name: operationName(id), summary: operationSummary(field(item, "description")),
      provider: field(item, "provider"), change: field(item, "effect") == "mutation",
      approval: item.hasKey("requires_approval") and item["requires_approval"].kind == JBool and
        item["requires_approval"].getBool)
  result.sort(proc(a, b: Operation): int = cmp(a.id, b.id))


proc serviceGroups*(operations: seq[Operation], setup: seq[IntegrationSetup]): seq[ServiceGroup] =
  ## Operations under the service whose setup they need, sorted by the name people see.
  for operation in operations:
    var index = -1
    for position, group in result:
      if group.id == operation.provider:
        index = position
        break
    if index < 0:
      var group = ServiceGroup(id: operation.provider, name: serviceName(operation.provider))
      for row in setup:
        if row.id == operation.provider:
          group.setup = row
          group.name = row.name
      result.add group
      index = result.high
    result[index].operations.add operation
  result.sort(proc(a, b: ServiceGroup): int = cmp(a.name.toLowerAscii(), b.name.toLowerAscii()))


proc approvalCount*(operations: seq[Operation]): int =
  for operation in operations:
    if operation.approval: inc result


proc matches*(operation: Operation, service, query: string): bool =
  ## Case-insensitive match on what the row shows, its service, or its identifier.
  let needle = query.strip().toLowerAscii()
  needle.len == 0 or needle in operation.name.toLowerAscii() or needle in operation.id.toLowerAscii() or
    needle in operation.summary.toLowerAscii() or needle in service.toLowerAscii()
