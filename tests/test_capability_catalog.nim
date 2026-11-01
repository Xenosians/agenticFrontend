import std/[json, unittest]
import ../src/app/capability_catalog
import ../src/app/integration_setup

let catalog = %*{"capabilities": [
  {"id": "ticket_create", "agent_names": ["tickets", "provider-tickets"], "provider": "ticketing",
   "effect": "mutation", "requires_approval": true,
   "description": "Create exactly one new ticket in a project. Use this only when asked."},
  {"id": "account_status", "agent_names": ["accounts"], "provider": "directory", "effect": "read",
   "requires_approval": false,
   "description": "Read only, changes nothing: check whether one account is enabled. Never unlocks it."},
  {"id": "service_health", "agent_names": ["operations"], "provider": "service_desk", "effect": "read",
   "requires_approval": false, "description": "Read only. Check the platform's own health endpoints."},
  {"id": "nobody_serves_this", "agent_names": [], "provider": "directory", "effect": "read",
   "description": "Not offered."},
  {"id": "", "agent_names": ["accounts"], "provider": "directory"},
  "not an object",
  {"id": "no_owner_list", "provider": "directory"}]}


suite "capability catalog":
  test "operation names read as words":
    check operationName("ticket_create") == "Ticket create"
    check operationName("fixture_directory_group_membership_bulk_reconcile") ==
      "Fixture directory group membership bulk reconcile"
    check operationName("network_dhcp_leases") == "Network DHCP leases"
    check operationName("sla_status") == "SLA status"
    check operationName("") == ""
    check serviceName("service_desk") == "Service desk"
    check serviceName("fixture-directory") == "Fixture directory"
    check serviceName("") == "Other"

  test "a summary is the first sentence, without a read-only lead the tag already shows":
    check operationSummary("Create exactly one new ticket in a project. Use this only when asked.") ==
      "Create exactly one new ticket in a project."
    check operationSummary("Read only, changes nothing: check whether one account is enabled. Never.") ==
      "Check whether one account is enabled."
    check operationSummary("Read only. Check the platform's own health endpoints.") ==
      "Check the platform's own health endpoints."
    check operationSummary("Read-only: list queues, e.g. Support. Then stop.") == "List queues, e.g. Support."
    # \"Read only\" as the verb is the description itself, not a lead.
    check operationSummary("Read only the first lines of a log.") == "Read only the first lines of a log."
    check operationSummary("No sentence break here") == "No sentence break here"
    check operationSummary("  ") == ""

  test "each served operation is offered once; unserved or malformed entries are not":
    let operations = catalogOperations(catalog)
    check operations.len == 3
    check operations[0].id == "account_status"
    check operations[0].name == "Account status"
    check operations[0].summary == "Check whether one account is enabled."
    check not operations[0].change and not operations[0].approval
    check operations[2].id == "ticket_create"
    check operations[2].change and operations[2].approval
    for catalogValue in [newJNull(), %*{}, %*{"capabilities": "x"}, %*{"capabilities": []}]:
      check catalogOperations(catalogValue).len == 0

  test "operations are grouped by the service whose setup they need":
    let setup = parseIntegrationSetup(%*{"integrations": [
      {"id": "ticketing", "name": "Ticketing (Jira)", "state": "simulated"},
      {"id": "directory", "name": "Directory (LDAP)", "state": "not_configured", "missing": ["AD_HOST"]}]})
    let groups = serviceGroups(catalogOperations(catalog), setup)
    check groups.len == 3
    # Sorted by the name people see; a service without a setup row is named from its id.
    check groups[0].name == "Directory (LDAP)"
    check groups[0].setup.state == "not_configured"
    check groups[0].setup.missing == @["AD_HOST"]
    check groups[1].name == "Service desk"
    check groups[1].setup.id == ""
    check groups[2].name == "Ticketing (Jira)"
    check groups[2].operations.len == 1
    check approvalCount(groups[2].operations) == 1
    check approvalCount(groups[0].operations) == 0

  test "search matches a name, description or service, ignoring case":
    let groups = serviceGroups(catalogOperations(catalog), @[])
    let tickets = groups[2]
    check tickets.name == "Ticketing"
    check tickets.operations[0].matches(tickets.name, "")
    check tickets.operations[0].matches(tickets.name, "  TICKET create ")
    check tickets.operations[0].matches(tickets.name, "project")
    check tickets.operations[0].matches(tickets.name, "ticketing")
    check tickets.operations[0].matches(tickets.name, "ticket_create")
    check not tickets.operations[0].matches(tickets.name, "directory")
