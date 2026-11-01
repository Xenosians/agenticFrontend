## Capabilities page: what Janus can do, by the service it touches.
##
## Hermes-style catalog (FR-081, NFR-036). Every row comes from the trusted
## capability catalog served by the backend, grouped under the service whose
## setup it needs (see app/capability_catalog). Groups start collapsed, so the
## page opens on the services, their setup state and what each offers; a
## search opens every group with a match. Each service's setup state comes
## from the AI service's configuration and is labelled as configuration,
## never as a provider check.

import std/[asyncjs, json, strutils]

include karax/prelude

import ../api/client
import ../app/capability_catalog
import ../app/integration_setup
import ../app/types

type
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


proc knownSetup(state: AppState): seq[IntegrationSetup] =
  ## This session's setup rows; none while unread or unreadable, so no state is claimed.
  if setup.session == state.auth.sessionId and setup.loaded and not setup.failed:
    setup.rows
  else:
    @[]


proc plural(count: int, noun: string): string =
  $count & " " & noun & (if count == 1: "" else: "s")


proc approvalNote(count: int): string =
  $count & (if count == 1: " needs approval" else: " need approval")


proc renderOperation(operation: Operation): VNode =
  result = buildHtml(tdiv(class = "capability-row")):
    tdiv(class = "capability-copy"):
      strong:
        text operation.name
      if operation.summary.len > 0:
        span:
          text operation.summary
    tdiv(class = "capability-tags"):
      span(class = "capability-tag"):
        text (if operation.change: "Change" else: "Read")
      if operation.approval:
        span(class = "capability-tag strong"):
          text "Needs approval"


proc renderService(group: ServiceGroup, operations: seq[Operation], searching: bool): VNode =
  ## A collapsed service row: name, what it offers and, when it needs attention,
  ## its setup state; a search opens it. "Configured" is the normal case and goes
  ## unlabelled; "Needs setup", "Simulated" and "Setup unknown" are stated.
  let
    missing = group.setup.missing
    approvals = approvalCount(group.operations)
  var parts = @[plural(group.operations.len, "operation")]
  if approvals > 0: parts.add approvalNote(approvals)
  result = buildHtml(details(class = "capability-group", open = searching)):
    summary(class = "capability-group-summary"):
      tdiv(class = "capability-group-heading"):
        strong(class = "capability-group-name"):
          text group.name
        span(class = "capability-group-meta"):
          # Each count stays whole when the line wraps; the settings list may wrap between names.
          for index, part in parts:
            if index > 0:
              text " · "
            span(class = "capability-meta-part"):
              text part
          if missing.len > 0:
            text " · Missing " & missing.join(", ")
      if group.setup.id.len > 0 and group.setup.state != "configured":
        span(class = (if group.setup.state == "not_configured": cstring"capability-tag strong"
                      else: cstring"capability-tag")):
          text setupLabel(group.setup.state)
    for operation in operations:
      renderOperation(operation)


proc renderSetupStatus(state: AppState): VNode =
  result = buildHtml(tdiv(class = "integration-setup")):
    p(class = "integration-note", role = "status"):
      if setup.session == state.auth.sessionId and setup.failed:
        text "Setup status could not be read."
      elif setup.session != state.auth.sessionId or not setup.loaded:
        text "Reading setup status…"
      else:
        text "Setup reflects configuration; services are not tested live."
    button(class = "capability-tag integration-recheck", disabled = setup.loading):
      text (if setup.loading: "Checking…" else: "Check setup again")
      proc onclick(event: Event, node: VNode) =
        discard refreshIntegrationSetup(state)


proc renderCapabilitiesView*(state: AppState): VNode =
  # Setup is read when the page is first shown for this session, however it
  # was opened; a later visit shows the same answer until the next refresh.
  if setup.session != state.auth.sessionId and not setup.loading:
    discard refreshIntegrationSetup(state)
  let
    operations = catalogOperations(state.extensionCatalog)
    query = state.capabilityQuery.strip()
    searching = query.len > 0
  # Each service with the operations that match the search (all of them without one).
  var shown: seq[(ServiceGroup, seq[Operation])]
  for group in serviceGroups(operations, knownSetup(state)):
    var visible: seq[Operation]
    for operation in group.operations:
      if operation.matches(group.name, query):
        visible.add operation
    if visible.len > 0:
      shown.add (group, visible)

  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view capabilities-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2:
            text "Capabilities"
          p:
            text "What Janus can do for you. Changes run only after approval."

      tdiv(class = "capability-toolbar"):
        input(
          class = "capability-search",
          `type` = "search",
          placeholder = "Search operations or services",
          `aria-label` = "Search capabilities",
          value = cstring(state.capabilityQuery)
        ):
          proc oninput(event: Event, node: VNode) =
            state.capabilityQuery = $node.value
            redraw(kxi)

        if operations.len > 0:
          span(class = "capability-summary"):
            text plural(operations.len, "operation") & " · " & approvalNote(approvalCount(operations))

      renderSetupStatus(state)

      for (group, visible) in shown:
        renderService(group, visible, searching)
      if shown.len == 0:
        tdiv(class = "capability-empty"):
          text (
            if operations.len == 0: "The capability catalog is not available. Refresh connections to load it."
            else: "No operation matches this search."
          )
