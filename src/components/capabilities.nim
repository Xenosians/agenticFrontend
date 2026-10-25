## Capabilities page: the governed ITSM operations the workspace can run.
##
## Hermes-style catalog (FR-081, NFR-036). Every row comes from the trusted
## capability catalog served by the backend: grouped by the specialist that
## serves it, labelled read or change, and marked when a change needs approval.
## An operation no specialist serves is not offered here.

import std/[algorithm, json, strutils]

include karax/prelude

import ../app/types

type
  CapabilityRow = object
    id, description, owner: string
    otherOwners: seq[string]
    change, approval: bool


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
        otherOwners: others, change: field(item, "effect") == "mutation",
        approval: flag(item, "requires_approval"))
  result.sort(proc(a, b: CapabilityRow): int = cmp((a.owner, a.id), (b.owner, b.id)))


proc matches(row: CapabilityRow, query: string): bool =
  let needle = query.strip().toLowerAscii()
  needle.len == 0 or needle in row.id.toLowerAscii() or
    needle in row.description.toLowerAscii() or needle in row.owner.toLowerAscii()


proc plural(count: int, noun: string): string =
  $count & " " & noun & (if count == 1: "" else: "s")


proc renderCapabilityRow(row: CapabilityRow): VNode =
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


proc renderCapabilitiesView*(state: AppState): VNode =
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
              renderCapabilityRow(visible[index])
          start = stop
