## Read-only store projections of the authenticated extension catalog.
## Tool metadata is the MCP capability registry, grouped into one package per
## service; Lua inventory is runtime-scoped.

import std/[json, strutils]

type
  ToolStoreEntry* = object
    id*, description*, effect*, risk*, permission*, provider*: string
    requiresApproval*: bool
    enabled*: bool  ## The owner's switch; only an explicit false from the service is off.
    agentNames*: seq[string]

  LuaPluginEntry* = object
    id*, protocol*, state*, source*, sha256*, reasonCode*: string

  ToolPackage* = object
    ## The tools of one service (Jira, the directory, OpenWrt…), as the AI service groups them.
    id*, name*, setup*: string
    known*: bool  ## False for tools whose package the service did not list.
    tools*: seq[ToolStoreEntry]


proc text(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    result = node[key].getStr


proc strings(node: JsonNode, key: string): seq[string] =
  if node == nil or node.kind != JObject or not node.hasKey(key) or node[key].kind != JArray:
    return
  for item in node[key]:
    if item.kind == JString and item.getStr.len > 0:
      result.add item.getStr


proc hex(value: string, length: int): bool =
  value.len == length and value.allCharsInSet({'0'..'9', 'a'..'f'})


proc validToolCatalog*(catalog: JsonNode): bool =
  catalog != nil and catalog.kind == JObject and
    text(catalog, "capabilities_schema") == "mcp-tool-catalog.v1" and
    catalog.hasKey("capabilities") and catalog["capabilities"].kind == JArray


proc catalogTools*(catalog: JsonNode): seq[ToolStoreEntry] =
  ## Ignore malformed rows; a partial response is never presented as a full catalog.
  if not validToolCatalog(catalog):
    return
  for node in catalog["capabilities"]:
    let id = text(node, "id")
    let description = text(node, "description")
    let effect = text(node, "effect")
    let risk = text(node, "risk")
    let permission = text(node, "permission")
    if node.kind != JObject or id.len == 0 or description.len == 0 or
        effect notin ["read", "mutation"] or risk.len == 0 or permission.len == 0 or
        not node.hasKey("requires_approval") or node["requires_approval"].kind != JBool:
      continue
    result.add ToolStoreEntry(id: id, description: description, effect: effect, risk: risk,
      permission: permission, provider: text(node, "provider"),
      requiresApproval: node["requires_approval"].getBool, agentNames: strings(node, "agent_names"),
      enabled: not (node.hasKey("enabled") and node["enabled"].kind == JBool and not node["enabled"].getBool))


proc toolSwitchLabel*(item: ToolStoreEntry): string =
  if item.enabled: "On" else: "Off"


proc toolRiskLabel*(item: ToolStoreEntry): string =
  ## A read tool's risk is the registry's "read" class; say it once, plainly.
  if item.risk == "read": "Read only" else: "Risk: " & item.risk


proc toolPackages*(catalog: JsonNode): seq[ToolPackage] =
  ## Packages in the service's order, each with its registered tools; a package
  ## without tools is left out. Tools whose package is not listed are kept
  ## together under "Other tools", never dropped.
  let tools = catalogTools(catalog)
  var placed: seq[string]
  if catalog != nil and catalog.kind == JObject and catalog.hasKey("tool_packages") and
      catalog["tool_packages"].kind == JArray:
    for node in catalog["tool_packages"]:
      let id = text(node, "id")
      let name = text(node, "name")
      if id.len == 0 or name.len == 0 or id in placed:
        continue
      var package = ToolPackage(id: id, name: name, setup: text(node, "state"), known: true)
      for tool in tools:
        if tool.provider == id: package.tools.add tool
      placed.add id
      if package.tools.len > 0: result.add package
  var other = ToolPackage(name: "Other tools")
  for tool in tools:
    if tool.provider notin placed: other.tools.add tool
  if other.tools.len > 0: result.add other


proc enabledCount*(package: ToolPackage): int =
  for tool in package.tools:
    if tool.enabled: inc result


proc allOn*(package: ToolPackage): bool = package.enabledCount == package.tools.len
proc allOff*(package: ToolPackage): bool = package.enabledCount == 0


proc switchLabel*(package: ToolPackage): string =
  if package.allOn: "On"
  elif package.allOff: "Off"
  else: $package.enabledCount & " of " & $package.tools.len & " on"


proc counts*(package: ToolPackage): string =
  var changes = 0
  for tool in package.tools:
    if tool.effect == "mutation": inc changes
  result = $package.tools.len & (if package.tools.len == 1: " tool" else: " tools")
  if changes > 0: result.add " · " & $changes & " can change data"


proc matches*(item: ToolStoreEntry, query: string): bool =
  query.len == 0 or query in (item.id & " " & item.description & " " & item.permission & " " &
    item.agentNames.join(" ")).toLowerAscii


proc searchPackages*(packages: seq[ToolPackage], query: string): seq[ToolPackage] =
  ## A package whose name matches keeps all its tools; otherwise only its matching tools.
  let query = query.strip.toLowerAscii
  for package in packages:
    if query.len == 0 or query in package.name.toLowerAscii:
      result.add package
      continue
    var found = package
    found.tools = @[]
    for tool in package.tools:
      if tool.matches(query): found.tools.add tool
    if found.tools.len > 0: result.add found


proc validLuaPluginCatalog*(catalog: JsonNode): bool =
  catalog != nil and catalog.kind == JObject and text(catalog, "schema") == "lua-plugin-catalog.v1" and
    text(catalog, "scope") == "runtime" and catalog.hasKey("plugins") and catalog["plugins"].kind == JArray


proc catalogLuaPlugins*(catalog: JsonNode): seq[LuaPluginEntry] =
  ## The UI can report resolution and provenance, never activate an artifact.
  if not validLuaPluginCatalog(catalog):
    return
  for node in catalog["plugins"]:
    let id = text(node, "id")
    let protocol = text(node, "protocol")
    let state = text(node, "state")
    let source = text(node, "source")
    if node.kind != JObject or id.len == 0 or protocol notin ["model", "connection", "source", "tool"] or
        state notin ["resolved", "unavailable"] or source notin ["packaged", "machine_profile", "unavailable"]:
      continue
    let digest = text(node, "sha256")
    if state == "resolved" and (source == "unavailable" or not hex(digest, 64)):
      continue
    if state == "unavailable" and source != "unavailable":
      continue
    result.add LuaPluginEntry(id: id, protocol: protocol, state: state, source: source,
      sha256: digest, reasonCode: text(node, "reason_code"))
