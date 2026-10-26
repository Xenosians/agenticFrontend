import std/[json, unittest]
import ../src/app/integration_setup

suite "provider setup readiness":
  test "each provider row keeps its state and the settings it is missing":
    let rows = parseIntegrationSetup(%*{"integrations": [
      {"id": "directory", "name": "Directory (LDAP)", "kind": "provider", "state": "not_configured",
       "configured": false, "missing": ["AD_HOST", "AD_BIND_PASSWORD"], "mode": "read_write",
       "capabilities": ["account_create"]},
      {"id": "ticketing", "name": "Ticketing (Jira)", "kind": "provider", "state": "simulated",
       "configured": false, "missing": [], "mode": "read_write", "capabilities": ["ticket_get"]}]})
    check rows.len == 2
    check rows[0].id == "directory"
    check rows[0].state == "not_configured"
    check rows[0].missing == @["AD_HOST", "AD_BIND_PASSWORD"]
    check rows[1].state == "simulated"

  test "an unknown or missing state is never shown as set up":
    let rows = parseIntegrationSetup(%*{"integrations": [
      {"id": "future", "name": "Future provider", "state": "healthy", "configured": true},
      {"id": "older", "name": "Older AI service", "configured": true},
      {"id": "", "name": "No identity", "state": "configured"}]})
    check rows.len == 2
    check rows[0].state == "unknown"
    # An older AI service reports only `configured`; that is still configuration, not a check.
    check rows[1].state == "configured"

  test "labels say configuration, not a provider check":
    check setupLabel("configured") == "Configured"
    check setupLabel("simulated") == "Simulated"
    check setupLabel("not_configured") == "Needs setup"
    check setupLabel("unknown") == "Setup unknown"
    check setupLabel("healthy") == "Setup unknown"

  test "a malformed response yields no rows":
    check parseIntegrationSetup(%*{"detail": "outage"}).len == 0
    check parseIntegrationSetup(newJArray()).len == 0
