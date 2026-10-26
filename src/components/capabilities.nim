## Capabilities page: the governed ITSM operations the workspace can run.
##
## Hermes-style catalog (FR-081, NFR-036). Every row comes from the trusted
## capability catalog served by the backend: grouped by the specialist that
## serves it, labelled read or change, and marked when a change needs approval.
## An operation no specialist serves is not offered here. Each provider's
## setup state comes from the AI service's configuration; it is labelled as
## configuration, never as a provider check.

import std/[algorithm, asyncjs, json, strutils]

include karax/prelude

import ../api/client
import ../app/integration_setup
import ../app/types

type
  CapabilityRow = object
    id, description, owner, provider: string
    otherOwners: seq[string]
    change, approval: bool

  SetupState = object
    rows: seq[IntegrationSetup]
    loaded, failed, loading: bool
    session: string

var setup: SetupState


proc refreshIntegrationSetup*(state: AppState) {.async.} =
  ## Reads provider setup once per page visit; a failed read is stated, never guessed.
  if setup.loading or not state.auth.authenticated: return
  let session = state.auth.sessionId
  setup.loading = true
  try:
    let response = await getIntegrationStatus()
    if state.auth.sessionId != session: return
    setup = SetupState(rows: parseIntegrationSetup(%*{"integrations": response.items}),
                       loaded: true, session: session)
  except CatchableError:
    if state.auth.sessionId == session:
      setup = SetupState(failed: true, loaded: true, session: session)
  finally:
    setup.loading = false
    redraw(kxi)


proc setupFor(state: AppState, provider: string): IntegrationSetup =
  ## The provider's setup row for this session, or an empty row when unknown.
  if setup.session != state.auth.sessionId or provider.len == 0: return
  for row in setup.rows:
    if row.id == provider: return row


proc field(node: JsonNode, key: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr()
  else:
    ""


proc flag(node: JsonNode, key: string): bool =
  node.kind == JObject and node.hasKey(key) and node[key].kind == JBool and node[key].getBool()


proc capabilityRows*(state: AppState): seq[CapabilityRow] =
  ## One row per (operation, serving specialist); an empty list when the
  ## catalog is missing or malformed.
  let catalog = state.extensionCatalog
  if catalog == nil or catalog.kind != JObject or not catalog.hasKey("capabilities") or
     catalog["capabilities"].kind != JArray:
    return
  for item in catalog["capabilities"]:
    if item.kind != JObject or not item.hasKey("agent_names") or item["agent_names"].kind != JArray:
      continue
    var owners: seq[string]
    for owner in item["agent_names"]:
      if owner.kind == JString and owner.getStr().len > 0 and owner.getStr() notin owners:
        owners.add owner.getStr()
    for owner in owners:
      var others: seq[string]
      for other in owners:
        if other != owner: others.add other
      result.add CapabilityRow(
        id: field(item, "id"), description: field(item, "description"), owner: owner,
        provider: field(item, "provider"),
        otherOwners: others, change: field(item, "effect") == "mutation",
        approval: flag(item, "requires_approval"))
  result.sort(proc(a, b: CapabilityRow): int = cmp((a.owner, a.id), (b.owner, b.id)))


proc matches(row: CapabilityRow, query: string): bool =
  let needle = query.strip().toLowerAscii()
  needle.len == 0 or needle in row.id.toLowerAscii() or
    needle in row.description.toLowerAscii() or needle in row.owner.toLowerAscii()


proc plural(count: int, noun: string): string =
  $count & " " & noun & (if count == 1: "" else: "s")


proc renderCapabilityRow(row: CapabilityRow, provider: IntegrationSetup): VNode =
  # Long snake_case names may wrap only after an underscore.
  let parts = row.id.split('_')
  result = buildHtml(tdiv(class = "capability-row")):
    tdiv(class = "capability-copy"):
      strong:
        for index, part in parts:
          text (if index + 1 < parts.len: part & "_" else: part)
          if index + 1 < parts.len:
            wbr()
      if row.description.len > 0:
        span:
          text row.description
      if row.otherOwners.len > 0:
        span(class = "capability-shared"):
          text "Also served by " & row.otherOwners.join(", ")
    tdiv(class = "capability-tags"):
      span(class = "capability-tag"):
        text (if row.change: "Change" else: "Read")
      if row.approval:
        span(class = "capability-tag strong"):
          text "Needs approval"
      if provider.id.len > 0:
        span(class = "capability-tag", title = cstring(provider.name)):
          text setupLabel(provider.state)


proc renderIntegrationSetup(state: AppState): VNode =
  result = buildHtml(tdiv(class = "integration-setup")):
    tdiv(class = "integration-heading"):
      h3:
        text "Setup"
      button(class = "capability-tag integration-recheck", disabled = setup.loading):
        text (if setup.loading: "Checking…" else: "Check setup again")
        proc onclick(event: Event, node: VNode) =
          discard refreshIntegrationSetup(state)
    p(class = "integration-note"):
      text "Configured means the settings are present. It does not show that a provider answered or that an action succeeded."
    if setup.session == state.auth.sessionId and setup.failed:
      p(class = "integration-note", role = "status"):
        text "Setup status could not be read."
    elif setup.session != state.auth.sessionId or not setup.loaded:
      p(class = "integration-note", role = "status"):
        text "Reading setup status…"
    else:
      for row in setup.rows:
        tdiv(class = "integration-row"):
          tdiv(class = "capability-copy"):
            strong:
              text row.name
            if row.missing.len > 0:
              span:
                text "Missing " & row.missing.join(", ")
          # The state that asks for action is the emphasised one, as "Needs approval" is.
          span(class = (if row.state == "not_configured": cstring"capability-tag strong" else: cstring"capability-tag")):
            text setupLabel(row.state)


proc renderCapabilitiesView*(state: AppState): VNode =
  # Setup is read when the page is first shown for this session, however it
  # was opened; a later visit shows the same answer until the next refresh.
  if setup.session != state.auth.sessionId and not setup.loading:
    discard refreshIntegrationSetup(state)
  let rows = capabilityRows(state)
  var operations, owners: seq[string]
  var approvals = 0
  for row in rows:
    if row.id notin operations:
      operations.add row.id
      if row.approval: inc approvals
    if row.owner notin owners:
      owners.add row.owner

  var visible: seq[CapabilityRow]
  for row in rows:
    if row.matches(state.capabilityQuery):
      visible.add row

  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view capabilities-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "Capabilities"
          p:
            text "Governed operations each specialist can propose. Changes run only after approval."

      tdiv(class = "capability-toolbar"):
        input(
          class = "capability-search",
          `type` = "search",
          placeholder = "Search operations or specialists",
          `aria-label` = "Search capabilities",
          value = cstring(state.capabilityQuery)
        ):
          proc oninput(event: Event, node: VNode) =
            state.capabilityQuery = $node.value
            redraw(kxi)

        if rows.len > 0:
          span(class = "capability-summary"):
            text plural(operations.len, "operation") & " · " & plural(owners.len, "specialist") &
              " · " & $approvals & " need approval"

      renderIntegrationSetup(state)

      if visible.len == 0:
        tdiv(class = "capability-empty"):
          text (
            if rows.len == 0: "The capability catalog is not available. Refresh connections to load it."
            else: "No operation matches this search."
          )
      else:
        var start = 0
        while start < visible.len:
          let owner = visible[start].owner
          var stop = start
          while stop < visible.len and visible[stop].owner == owner:
            inc stop
          tdiv(class = "capability-group"):
            h3:
              text owner
            for index in start ..< stop:
              renderCapabilityRow(visible[index], setupFor(state, visible[index].provider))
          start = stop
