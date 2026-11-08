import std/[json, unittest, strutils]
import ../src/app/[store_catalog, integration_setup]

let tool = %*{
  "id": "ticket_create", "description": "Create an issue in the selected project.",
  "effect": "mutation", "risk": "high", "permission": "jira.write",
  "provider": "jira", "requires_approval": true, "agent_names": ["jira-specialist"]
}
let readTool = %*{
  "id": "account_status", "description": "Read one account status.",
  "effect": "read", "risk": "read", "permission": "directory.read",
  "provider": "directory", "requires_approval": false, "agent_names": ["account-specialist"]
}

suite "MCP tool store catalog":
  test "parses the registered capability metadata without inventing readiness":
    let catalog = %*{"capabilities_schema": "mcp-tool-catalog.v1", "capabilities": [tool, readTool]}
    let rows = catalogTools(catalog)
    check validToolCatalog(catalog)
    check rows.len == 2
    check rows[0].id == "ticket_create"
    check rows[0].effect == "mutation" and rows[0].requiresApproval
    check rows[0].provider == "jira" and rows[0].agentNames == @["jira-specialist"]
    check rows[1].effect == "read" and not rows[1].requiresApproval

  test "rejects an unknown catalog schema and skips malformed rows":
    check not validToolCatalog(%*{"capabilities_schema": "future", "capabilities": [tool]})
    check catalogTools(%*{"capabilities_schema": "future", "capabilities": [tool]}).len == 0
    var malformed = parseJson($tool)
    malformed["requires_approval"] = %"false"
    let rows = catalogTools(%*{"capabilities_schema": "mcp-tool-catalog.v1", "capabilities": [tool, malformed]})
    check rows.len == 1 and rows[0].id == "ticket_create"

  test "reads the owner's on/off state; only an explicit false is off":
    var off = parseJson($readTool)
    off["enabled"] = %false
    var odd = parseJson($tool)
    odd["enabled"] = %"no"
    let rows = catalogTools(%*{"capabilities_schema": "mcp-tool-catalog.v1", "capabilities": [off, odd]})
    check rows.len == 2
    check not rows[0].enabled and rows[1].enabled
    check catalogTools(%*{"capabilities_schema": "mcp-tool-catalog.v1", "capabilities": [readTool]})[0].enabled
    check toolSwitchLabel(rows[0]) == "Off" and toolSwitchLabel(rows[1]) == "On"

  test "risk is named once: read tools say read only, others name their risk":
    let rows = catalogTools(%*{"capabilities_schema": "mcp-tool-catalog.v1", "capabilities": [readTool, tool]})
    check toolRiskLabel(rows[0]) == "Read only"
    check toolRiskLabel(rows[1]) == "Risk: high"

suite "Lua runtime plugin catalog":
  test "reports exact resolved source state and unavailable state":
    let catalog = %*{"schema": "lua-plugin-catalog.v1", "scope": "runtime", "plugins": [
      {"id": "tool.default", "protocol": "tool", "state": "resolved", "source": "packaged", "sha256": "a".repeat(64)},
      {"id": "model.local", "protocol": "model", "state": "unavailable", "source": "unavailable",
       "reason_code": "lua_adapter_configuration_invalid"}
    ]}
    let rows = catalogLuaPlugins(catalog)
    check validLuaPluginCatalog(catalog)
    check rows.len == 2
    check rows[0].state == "resolved" and rows[0].source == "packaged"
    check rows[1].state == "unavailable" and rows[1].reasonCode == "lua_adapter_configuration_invalid"

  test "does not display malformed or contradictory adapter state":
    let catalog = %*{"schema": "lua-plugin-catalog.v1", "scope": "runtime", "plugins": [
      {"id": "tool.default", "protocol": "tool", "state": "resolved", "source": "packaged", "sha256": "short"},
      {"id": "model.local", "protocol": "model", "state": "resolved", "source": "unavailable", "sha256": "b".repeat(64)}
    ]}
    check catalogLuaPlugins(catalog).len == 0
    check not validLuaPluginCatalog(%*{"schema": "lua-plugin-catalog.v1", "scope": "owner", "plugins": []})

suite "MCP tool packages":
  let unlock = %*{
    "id": "account_unlock", "description": "Unlock one account.", "effect": "mutation", "risk": "medium",
    "permission": "directory.write", "provider": "directory", "requires_approval": true,
    "agent_names": ["account-specialist"], "enabled": false}
  let catalog = %*{"capabilities_schema": "mcp-tool-catalog.v1",
    "capabilities": [tool, readTool, unlock],
    "tool_packages": [
      {"id": "directory", "name": "Directory (LDAP)", "kind": "provider", "state": "configured"},
      {"id": "proxmox", "name": "Proxmox VE", "kind": "provider", "state": "not_configured"},
      {"id": "", "name": "No identity", "kind": "provider", "state": "configured"},
      {"id": "broken", "kind": "provider", "state": "configured"}]}

  test "tools are grouped by their package in the service's order, empty packages left out":
    let packages = toolPackages(catalog)
    check packages.len == 2
    check packages[0].id == "directory" and packages[0].name == "Directory (LDAP)"
    check packages[0].tools.len == 2
    check packages[0].tools[0].id == "account_status" and packages[0].tools[1].id == "account_unlock"
    check packages[0].known and packages[0].setup == "configured"
    # A tool whose package the service did not list is still shown, never dropped.
    check packages[1].id == "" and packages[1].name == "Other tools" and not packages[1].known
    check packages[1].tools.len == 1 and packages[1].tools[0].id == "ticket_create"

  test "a package counts its tools, changes and switch state":
    let directory = toolPackages(catalog)[0]
    check directory.counts == "2 tools · 1 can change data"
    check directory.enabledCount == 1
    check directory.switchLabel == "1 of 2 on"
    check not directory.allOn and not directory.allOff
    var on = parseJson($catalog)
    on["capabilities"][2]["enabled"] = %true
    check toolPackages(on)[0].switchLabel == "On" and toolPackages(on)[0].allOn
    var off = parseJson($catalog)
    off["capabilities"][1]["enabled"] = %false
    check toolPackages(off)[0].switchLabel == "Off" and toolPackages(off)[0].allOff
    var single = parseJson($catalog)
    single["capabilities"] = %*[readTool]
    check toolPackages(single)[0].counts == "1 tool"

  test "a package keeps the service's setup state as sent; the label is the Capabilities page's":
    let packages = toolPackages(catalog)
    check setupLabel(packages[0].setup) == "Configured"
    var unknown = parseJson($catalog)
    unknown["tool_packages"][0]["state"] = %"ready-ish"
    check setupLabel(toolPackages(unknown)[0].setup) == "Setup unknown"

  test "search keeps packages whose name or tools match, with only the matching tools":
    let packages = toolPackages(catalog)
    let byTool = searchPackages(packages, "unlock")
    check byTool.len == 1 and byTool[0].tools.len == 1 and byTool[0].tools[0].id == "account_unlock"
    let byName = searchPackages(packages, "ldap")
    check byName.len == 1 and byName[0].tools.len == 2
    check searchPackages(packages, "").len == 2
    check searchPackages(packages, "nothing like this").len == 0

  test "an old catalog without packages groups every tool under other tools":
    let old = %*{"capabilities_schema": "mcp-tool-catalog.v1", "capabilities": [tool, readTool]}
    let packages = toolPackages(old)
    check packages.len == 1 and not packages[0].known and packages[0].tools.len == 2
