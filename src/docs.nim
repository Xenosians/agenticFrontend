## The capabilities documentation page (FR-081, NFR-036): what Janus can do, by service.
##
## Its own page (docs.html), outside the workspace: every row comes from the
## trusted capability catalog for the signed-in user, grouped under the service
## whose setup it needs, with that service's setup state. Groups start collapsed;
## a search opens every group with a match. Setup is read from the AI service's
## configuration and labelled as such, never as a provider check. A signed-out
## visitor is sent to sign in; nothing is guessed.

include karax/prelude
import std/[asyncjs, json, strutils]

import api/client
import api/extensions
import api/auth_client
import app/capability_catalog
import app/integration_setup
import components/brand

type
  DocsState = object
    loading, signedOut, failed: bool
    catalog: JsonNode
    setup: seq[IntegrationSetup]
    setupLoaded, setupFailed, setupLoading: bool
    query: string

var docs = DocsState(loading: true)


proc plural(count: int, noun: string): string =
  $count & " " & noun & (if count == 1: "" else: "s")


proc approvalNote(count: int): string =
  $count & (if count == 1: " needs approval" else: " need approval")


proc readSetup() {.async.} =
  ## Setup is read once per visit and on request; a failed read is stated, never guessed.
  if docs.setupLoading: return
  docs.setupLoading = true
  redraw(kxi)
  try:
    let response = await getIntegrationStatus()
    docs.setup = parseIntegrationSetup(%*{"integrations": response.items})
    docs.setupFailed = false
  except CatchableError:
    docs.setup = @[]
    docs.setupFailed = true
  finally:
    docs.setupLoaded = true
    docs.setupLoading = false
    redraw(kxi)


proc start() {.async.} =
  try:
    discard await me()
  except CatchableError:
    docs.loading = false
    docs.signedOut = true
    redraw(kxi)
    return
  try:
    docs.catalog = await extensionCatalog()
  except CatchableError:
    docs.failed = true
  docs.loading = false
  redraw(kxi)
  await readSetup()


proc renderOperation(operation: Operation): VNode =
  result = buildHtml(tdiv(class = "capability-row")):
    tdiv(class = "capability-copy"):
      strong: text operation.name
      if operation.summary.len > 0:
        span: text operation.summary
    tdiv(class = "capability-tags"):
      span(class = "capability-tag"):
        text (if operation.change: "Change" else: "Read")
      if operation.approval:
        span(class = "capability-tag strong"): text "Needs approval"


proc renderService(group: ServiceGroup, operations: seq[Operation], searching: bool): VNode =
  ## A collapsed service: its name, what it offers and, when it needs attention, its setup.
  let
    missing = group.setup.missing
    approvals = approvalCount(group.operations)
  var parts = @[plural(group.operations.len, "operation")]
  if approvals > 0: parts.add approvalNote(approvals)
  result = buildHtml(details(class = "capability-group", open = searching)):
    summary(class = "capability-group-summary"):
      tdiv(class = "capability-group-heading"):
        strong(class = "capability-group-name"): text group.name
        span(class = "capability-group-meta"):
          for index, part in parts:
            if index > 0: text " · "
            span(class = "capability-meta-part"): text part
          if missing.len > 0:
            text " · Missing " & missing.join(", ")
      if group.setup.id.len > 0 and group.setup.state != "configured":
        span(class = (if group.setup.state == "not_configured": cstring"capability-tag strong"
                      else: cstring"capability-tag")):
          text setupLabel(group.setup.state)
    for operation in operations:
      renderOperation(operation)


proc renderSetupStatus(): VNode =
  result = buildHtml(tdiv(class = "integration-setup")):
    p(class = "integration-note", role = "status"):
      if docs.setupFailed: text "Setup status could not be read."
      elif not docs.setupLoaded: text "Reading setup status…"
      else: text "Setup reflects configuration; services are not tested live."
    button(class = "capability-tag integration-recheck", disabled = docs.setupLoading):
      text (if docs.setupLoading: "Checking…" else: "Check setup again")
      proc onclick(event: Event, node: VNode) = discard readSetup()


proc renderCatalog(): VNode =
  let
    operations = catalogOperations(docs.catalog)
    query = docs.query.strip()
    searching = query.len > 0
  var shown: seq[(ServiceGroup, seq[Operation])]
  for group in serviceGroups(operations, (if docs.setupFailed: @[] else: docs.setup)):
    var visible: seq[Operation]
    for operation in group.operations:
      if operation.matches(group.name, query): visible.add operation
    if visible.len > 0: shown.add (group, visible)
  result = buildHtml(tdiv):
    tdiv(class = "capability-toolbar"):
      input(class = "capability-search", `type` = "search", placeholder = "Search operations or services",
            `aria-label` = "Search capabilities", value = cstring(docs.query)):
        proc oninput(event: Event, node: VNode) =
          docs.query = $node.value
          redraw(kxi)
      if operations.len > 0:
        span(class = "capability-summary"):
          text plural(operations.len, "operation") & " · " & approvalNote(approvalCount(operations))
    renderSetupStatus()
    for (group, visible) in shown:
      renderService(group, visible, searching)
    if shown.len == 0:
      tdiv(class = "capability-empty"):
        text (if operations.len == 0: "The capability catalog is not available. Reload the page to try again."
              else: "No operation matches this search.")


proc renderDocs(): VNode =
  result = buildHtml(main(class = "docs-page")):
    header(class = "docs-header"):
      img(class = "brand-logo", src = productMark, alt = productName)
      a(class = "secondary-action docs-back", href = "./"): text "Back to the workspace"
    section(class = "developer-view capabilities-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h1: text "What " & productName & " can do"
          p: text "Every operation, by the service it touches. Changes run only after approval."
      if docs.loading:
        p(class = "integration-note", role = "status"): text "Loading…"
      elif docs.signedOut:
        p(class = "docs-signed-out"):
          text "Sign in to see what " & productName & " can do for you. "
          a(href = "./"): text "Sign in"
      else:
        renderCatalog()


setRenderer(renderDocs, "docs")
discard start()
