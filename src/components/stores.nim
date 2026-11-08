## The Store: one page with three sections.
##   Tools        — MCP tools grouped into one package per service, each with an
##                  owner switch for the whole package and one per tool.
##   Skill Library — the owner's SKILL.md guidance (components/skills).
##   Plugin Store — the Lua plugins the runtime resolved (read-only inventory).
## A switch is saved by the AI service and read back; plugin lifecycle stays host-owned.

include karax/prelude
import karax/kdom
import std/[json, strutils]
import ../app/types
import ../app/store_catalog
import ../app/integration_setup
import ../app/extension_bridge
import skills


const storeSections = [(storeTools, "Tools", "storeTabTools", "storePanelTools"),
                       (storeSkills, "Skill Library", "storeTabSkills", "storePanelSkills"),
                       (storePlugins, "Plugin Store", "storeTabPlugins", "storePanelPlugins")]

proc focusStoreTab(id: cstring) {.importjs: "requestAnimationFrame(() => document.getElementById(#)?.focus())".}
proc syncMixedSwitches() {.importjs: """(() => document.querySelectorAll('.tool-package-heading .tool-switch input')
  .forEach(input => { input.indeterminate = input.closest('.tool-switch').classList.contains('mixed'); }))()""".}

proc afterStoreRender*() =
  ## A partly-on package shows the browser's mixed checkbox; only a DOM property can say so.
  syncMixedSwitches()
proc eventKey(event: Event): cstring {.importjs: "#.key".}


proc containsQuery(value, query: string): bool =
  query.len == 0 or query in value.toLowerAscii


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
      dt: text "Permission"
      dd: text item.permission
      dt: text "Specialists"
      dd: text (if item.agentNames.len > 0: item.agentNames.join(", ") else: "No assigned specialist")


proc packageKey(package: ToolPackage): string =
  ## "Other tools" has no service identity; it is still opened and closed on its own.
  if package.known: package.id else: "other"


proc renderPackage(state: AppState, package: ToolPackage, searching: bool): VNode =
  ## One service's tools. A search shows the matching tools at once; otherwise
  ## the package opens on request and stays open across catalog reloads.
  let key = packageKey(package)
  let expanded = searching or key in state.openToolPackages
  let packageClass = if package.allOff: cstring"tool-package is-off" else: cstring"tool-package"
  result = buildHtml(section(class = packageClass, `aria-label` = cstring(package.name))):
    tdiv(class = "tool-package-heading"):
      tdiv(class = "tool-package-title"):
        button(class = "tool-package-toggle", `aria-expanded` = (if expanded: cstring"true" else: cstring"false"),
               `aria-label` = cstring((if expanded: "Hide " else: "Show ") & package.name & " tools")):
          span(class = "tool-package-chevron", `aria-hidden` = "true"): text (if expanded: "▾" else: "▸")
          proc onclick(event: Event, node: VNode) =
            if key in state.openToolPackages:
              var kept: seq[string]
              for item in state.openToolPackages:
                if item != key: kept.add item
              state.openToolPackages = kept
            else:
              state.openToolPackages.add key
        tdiv(class = "tool-package-summary"):
          h3: text package.name
          span(class = "tool-package-counts"): text package.counts
      if package.known:
        tdiv(class = "tool-package-controls"):
          span(class = "store-badge tool-package-setup"): text setupLabel(package.setup)
          label(class = (if package.allOn or package.allOff: cstring"tool-switch" else: cstring"tool-switch mixed")):
            input(`type` = "checkbox", checked = package.allOn, disabled = state.extensionBusy,
                  `aria-label` = cstring("Use all " & package.name & " tools")):
              proc onchange(event: Event, node: VNode) =
                discard changeExtension(state, "tool_package_enable",
                  %*{"package": package.id, "enabled": not package.allOn})
            span: text package.switchLabel
    if expanded:
      tdiv(class = "store-grid tool-package-tools"):
        for item in package.tools:
          renderToolCard(state, item)


proc renderToolsSection(state: AppState): VNode =
  let valid = validToolCatalog(state.extensionCatalog)
  let query = state.toolStoreSearch.strip
  let packages = toolPackages(state.extensionCatalog)
  let visible = searchPackages(packages, query)
  var total = 0
  for package in packages: total += package.tools.len
  result = buildHtml(tdiv):
    p(class = "store-intro"):
      text "Tools are grouped by the service they use. Turn a package or a single tool off to keep Janus from using it for your requests; changes still need approval."
    if state.extensionBusy and not valid:
      p(class = "store-state", role = "status"): text "Loading the tool packages…"
    elif not valid:
      p(class = "store-state", role = "status"): text "The tool list is not available yet. Refresh it after the AI service is ready."
    elif packages.len == 0:
      p(class = "store-state"): text "No tools are registered."
    else:
      tdiv(class = "store-summary"):
        strong: text $total
        span: text (if total == 1: " tool in " else: " tools in ")
        strong: text $packages.len
        span: text (if packages.len == 1: " package" else: " packages")
      label(class = "store-search-label", `for` = "toolStoreSearch"): text "Find a tool"
      input(id = "toolStoreSearch", `type` = "search", class = "store-search", placeholder = "Search tools or services…",
        value = cstring(state.toolStoreSearch), `aria-label` = "Search tools"):
        proc oninput(event: Event, node: VNode) =
          state.toolStoreSearch = $node.value
          redraw(kxi)
      if visible.len == 0:
        p(class = "store-state"): text "No tools match this search."
      else:
        tdiv(class = "tool-packages"):
          for package in visible:
            renderPackage(state, package, query.len > 0)


proc sourceLabel(source: string): string =
  case source
  of "packaged": "Packaged Lua plugin"
  of "machine_profile": "Reviewed machine profile"
  else: "Unavailable"


proc protocolLabel(protocol: string): string =
  case protocol
  of "model": "model"
  of "connection": "connection"
  of "source": "data source"
  of "tool": "tool"
  else: protocol


proc renderPluginCard(item: LuaPluginEntry): VNode =
  let unavailable = item.state != "resolved"
  result = buildHtml(article(class = "store-card plugin-store-card")):
    tdiv(class = "store-card-heading"):
      h3: text item.id
      span(class = (if unavailable: cstring"store-badge unavailable" else: cstring"store-badge resolved")):
        text (if unavailable: "Unavailable" else: "Active")
    p(class = "store-card-description"):
      text ("Checks and shapes " & protocolLabel(item.protocol) & " traffic before it leaves Janus. " &
            "Janus keeps the credentials, the policy and the final check of every change.")
    dl(class = "store-card-details"):
      dt: text "Source"
      dd: text sourceLabel(item.source)
      dt: text "Identity"
      dd: text (if item.sha256.len > 0: item.sha256 else: item.reasonCode)


proc renderPluginsSection(state: AppState): VNode =
  let catalog = if state.extensionCatalog != nil and state.extensionCatalog.kind == JObject and
      state.extensionCatalog.hasKey("plugin_catalog"): state.extensionCatalog["plugin_catalog"] else: newJNull()
  let valid = validLuaPluginCatalog(catalog)
  let rows = catalogLuaPlugins(catalog)
  let query = state.pluginStoreSearch.strip.toLowerAscii
  var visible = 0
  result = buildHtml(tdiv):
    p(class = "store-intro"):
      text "Lua plugins extend Janus: every model, connection, data source and tool request passes through one before it runs."
    p(class = "store-guidance"):
      text "Installing your own plugins is not available yet. This list shows the plugins packaged with Janus or chosen for this machine by an administrator."
    if state.extensionBusy and not valid:
      p(class = "store-state", role = "status"): text "Loading the plugins…"
    elif not valid:
      p(class = "store-state", role = "status"): text "The plugin list is not available yet. Refresh it after the AI service is ready."
    elif rows.len == 0:
      p(class = "store-state"): text "No plugins are active. Requests that need one are stopped."
    else:
      tdiv(class = "store-summary"):
        strong: text $rows.len
        span: text (if rows.len == 1: " plugin" else: " plugins")
      label(class = "store-search-label", `for` = "pluginStoreSearch"): text "Find a plugin"
      input(id = "pluginStoreSearch", `type` = "search", class = "store-search", placeholder = "Search plugins…",
        value = cstring(state.pluginStoreSearch), `aria-label` = "Search plugins"):
        proc oninput(event: Event, node: VNode) =
          state.pluginStoreSearch = $node.value
          redraw(kxi)
      tdiv(class = "store-grid"):
        for item in rows:
          if containsQuery(item.id & " " & item.protocol & " " & item.state & " " & item.source, query):
            inc visible
            renderPluginCard(item)
      if visible == 0:
        p(class = "store-state"): text "No plugins match this search."


proc renderStoreTab(state: AppState, section: StoreSection, title, tabId, panelId: string): VNode =
  ## One tab per call, so its handlers keep their own section.
  let selected = state.storeSection == section
  result = buildHtml(button(id = cstring(tabId), class = (if selected: cstring"store-tab active" else: cstring"store-tab"),
      role = "tab", `aria-selected` = (if selected: cstring"true" else: cstring"false"),
      `aria-controls` = cstring(panelId), tabindex = (if selected: cstring"0" else: cstring"-1"))):
    text title
    proc onclick(event: Event, node: VNode) = state.storeSection = section
    proc onkeydown(event: Event, node: VNode) =
      # Arrow keys, Home and End move between the sections, as in any tab list.
      let count = ord(high(StoreSection)) + 1
      let target = case $eventKey(event)
        of "ArrowRight": StoreSection((ord(section) + 1) mod count)
        of "ArrowLeft": StoreSection((ord(section) + count - 1) mod count)
        of "Home": low(StoreSection)
        of "End": high(StoreSection)
        else: section
      if target != section:
        event.preventDefault()
        state.storeSection = target
        focusStoreTab(cstring(storeSections[ord(target)][2]))


proc renderStore*(state: AppState): VNode =
  let current = storeSections[ord(state.storeSection)]
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view store-view"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2: text "Store"
          p: text "Tools Janus can use, the skills that shape its answers, and the plugins every request passes through."
      tdiv(class = "store-tabs", role = "tablist", `aria-label` = "Store sections"):
        for (section, title, tabId, panelId) in storeSections:
          renderStoreTab(state, section, title, tabId, panelId)
      if state.extensionError.len > 0:
        p(class = "operation-error", role = "alert"): text state.extensionError
      tdiv(id = cstring(current[3]), class = "store-panel", role = "tabpanel", `aria-labelledby` = cstring(current[2])):
        case state.storeSection
        of storeTools: renderToolsSection(state)
        of storeSkills: renderSkillLibrary(state)
        of storePlugins: renderPluginsSection(state)
