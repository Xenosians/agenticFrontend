## MCP tools with the owner's on/off switch, and the read-only Lua runtime catalog.
## A switch is saved by the AI service and read back; adapter lifecycle stays host-owned.

include karax/prelude
import std/[asyncjs, json, strutils]
import ../app/types
import ../app/store_catalog
import ../app/extension_bridge


proc containsQuery(value, query: string): bool =
  query.len == 0 or query in value.toLowerAscii


proc matches(item: ToolStoreEntry, query: string): bool =
  containsQuery(item.id & " " & item.description & " " & item.provider & " " &
    item.permission & " " & item.effect & " " & item.risk & " " & item.agentNames.join(" "), query)


proc renderToolCard(state: AppState, item: ToolStoreEntry): VNode =
  let cardClass = if item.enabled: cstring"store-card tool-store-card" else: cstring"store-card tool-store-card is-off"
  result = buildHtml(article(class = cardClass)):
    tdiv(class = "store-card-heading tool-card-heading"):
      h3: text item.id
      label(class = "tool-switch"):
        input(`type` = "checkbox", checked = item.enabled, disabled = state.extensionBusy,
              `aria-label` = cstring("Use " & item.id)):
          proc onchange(event: Event, node: VNode) =
            discard changeExtension(state, "tool_enable", %*{"id": item.id, "enabled": not item.enabled})
        span: text toolSwitchLabel(item)
    tdiv(class = "store-card-badges"):
      if item.effect == "mutation":
        span(class = "store-badge mutation"): text "Changes data"
      span(class = (if item.risk == "high": cstring"store-badge risk-high" else: cstring"store-badge")):
        text toolRiskLabel(item)
      span(class = (if item.requiresApproval: cstring"store-badge approval" else: cstring"store-badge")):
        text (if item.requiresApproval: "Approval required" else: "Approval not required")
    p(class = "store-card-description"): text item.description
    dl(class = "store-card-details"):
      dt: text "Provider"
      dd: text (if item.provider.len > 0: item.provider else: "Provider-neutral")
      dt: text "Permission"
      dd: text item.permission
      dt: text "Specialists"
      dd: text (if item.agentNames.len > 0: item.agentNames.join(", ") else: "No assigned specialist")


proc renderToolStore*(state: AppState): VNode =
  let valid = validToolCatalog(state.extensionCatalog)
  let rows = catalogTools(state.extensionCatalog)
  let query = state.toolStoreSearch.strip.toLowerAscii
  var visible = 0
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view store-view"):
      tdiv(class = "developer-view-header"):
        h2: text "MCP Tool Store"
        p: text "The registered MCP capability catalog. Turn a tool off to keep Janus from using it for your requests. Provider readiness is shown separately; mutations still use Janus’s approval and verification path."
      if state.extensionError.len > 0:
        p(class = "operation-error", role = "alert"): text state.extensionError
      if state.extensionBusy and not valid:
        p(class = "store-state", role = "status"): text "Loading the registered tool catalog…"
      elif not valid:
        p(class = "store-state", role = "status"): text "The MCP tool catalog is not available yet. Refresh it after the AI service is ready."
      else:
        tdiv(class = "store-summary"):
          strong: text $rows.len
          span: text (if rows.len == 1: " registered capability" else: " registered capabilities")
        label(class = "store-search-label", `for` = "toolStoreSearch"): text "Find a tool"
        input(id = "toolStoreSearch", `type` = "search", class = "store-search", placeholder = "Search tools, providers or specialists…",
          value = cstring(state.toolStoreSearch), `aria-label` = "Search MCP tools"):
          proc oninput(event: Event, node: VNode) =
            state.toolStoreSearch = $node.value
            redraw(kxi)
        if rows.len == 0:
          p(class = "store-state"): text "The runtime registered no MCP capabilities."
        else:
          tdiv(class = "store-grid"):
            for item in rows:
              if matches(item, query):
                inc visible
                renderToolCard(state, item)
          if visible == 0:
            p(class = "store-state"): text "No registered tools match this search."


proc sourceLabel(source: string): string =
  case source
  of "packaged": "Packaged Lua adapter"
  of "machine_profile": "Reviewed machine profile"
  else: "Unavailable"


proc renderPluginCard(item: LuaPluginEntry): VNode =
  let unavailable = item.state != "resolved"
  result = buildHtml(article(class = "store-card plugin-store-card")):
    tdiv(class = "store-card-heading"):
      h3: text item.id
      span(class = (if unavailable: cstring"store-badge unavailable" else: cstring"store-badge resolved")):
        text (if unavailable: "Unavailable" else: "Resolved")
    p(class = "store-card-description"):
      text ("Lua protocol adapter for " & item.protocol & " traffic. It translates bounded data; the host retains credentials, policy, transport and effect verification.")
    dl(class = "store-card-details"):
      dt: text "Source"
      dd: text sourceLabel(item.source)
      dt: text "Identity"
      dd: text (if item.sha256.len > 0: item.sha256 else: item.reasonCode)


proc renderPluginStore*(state: AppState): VNode =
  let catalog = if state.extensionCatalog != nil and state.extensionCatalog.kind == JObject and
      state.extensionCatalog.hasKey("plugin_catalog"): state.extensionCatalog["plugin_catalog"] else: newJNull()
  let valid = validLuaPluginCatalog(catalog)
  let rows = catalogLuaPlugins(catalog)
  let query = state.pluginStoreSearch.strip.toLowerAscii
  var visible = 0
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view store-view"):
      tdiv(class = "developer-view-header"):
        h2: text "Lua Plugin Store"
        p: text "Runtime inventory for the required Lua gate across models, connections, data sources and MCP tools."
      if state.extensionError.len > 0:
        p(class = "operation-error", role = "alert"): text state.extensionError
      p(class = "store-guidance"):
        text "This view reports packaged or administrator-selected Lua adapters. User-installed plugins are not enabled yet; they need per-account manifests, review, disable controls and history before execution."
      if state.extensionBusy and not valid:
        p(class = "store-state", role = "status"): text "Loading the Lua runtime inventory…"
      elif not valid:
        p(class = "store-state", role = "status"): text "The Lua plugin inventory is not available yet. Refresh it after the AI service is ready."
      elif rows.len == 0:
        p(class = "store-state"): text "No Lua adapters are currently registered. Required adapter failures stop dispatch."
      else:
        tdiv(class = "store-summary"):
          strong: text $rows.len
          span: text (if rows.len == 1: " runtime adapter" else: " runtime adapters")
        label(class = "store-search-label", `for` = "pluginStoreSearch"): text "Find an adapter"
        input(id = "pluginStoreSearch", `type` = "search", class = "store-search", placeholder = "Search adapter IDs or protocol types…",
          value = cstring(state.pluginStoreSearch), `aria-label` = "Search Lua plugins"):
          proc oninput(event: Event, node: VNode) =
            state.pluginStoreSearch = $node.value
            redraw(kxi)
        tdiv(class = "store-grid"):
          for item in rows:
            if containsQuery(item.id & " " & item.protocol & " " & item.state & " " & item.source, query):
              inc visible
              renderPluginCard(item)
        if visible == 0:
          p(class = "store-state"): text "No Lua adapters match this search."
