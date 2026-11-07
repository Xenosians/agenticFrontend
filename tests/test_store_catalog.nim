import std/[json, unittest, strutils]
import ../src/app/store_catalog

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
