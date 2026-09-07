import ../app/types


proc renderTool(tool: ToolItem): string =
  let
    itemClass =
      if tool.enabled:
        "nav-item"
      else:
        "nav-item disabled"

    dotClass =
      if tool.enabled:
        "status-dot online"
      else:
        "status-dot offline"

    displayName =
      if tool.id == "shell":
        "&gt;_ " & tool.name
      else:
        tool.name

  result =
    "<button class=\"" & itemClass & "\">" &
      "<span class=\"" & dotClass & "\"></span>" &
      "<span>" & displayName & "</span>" &
    "</button>"


proc renderPlugin(plugin: PluginItem): string =
  let
    itemClass =
      if plugin.connected:
        "nav-item"
      else:
        "nav-item disabled"

    dotClass =
      if plugin.connected:
        "status-dot online"
      else:
        "status-dot offline"

  result =
    "<button class=\"" & itemClass & "\">" &
      "<span class=\"" & dotClass & "\"></span>" &
      "<span>" & plugin.name & "</span>" &
    "</button>"


proc renderSidebar*(state: AppState): string =
  var toolsHtml = ""

  for tool in state.tools:
    toolsHtml.add(renderTool(tool))

  var pluginsHtml = ""

  for plugin in state.plugins:
    pluginsHtml.add(renderPlugin(plugin))

  result = """
    <div class="brand">
      <span class="brand-mark">A</span>
      <span class="brand-name">Agentic</span>
    </div>

    <button
        id="newSessionButton"
        class="new-session"
    >
        + New Session
    </button>

    <nav class="nav-section">
      <span class="section-label">Workspace</span>

      <button class="nav-item active">
        <span>◈</span>
        <span>Chat</span>
      </button>

      <button class="nav-item">
        <span>⌕</span>
        <span>Search</span>
      </button>
    </nav>

    <nav class="nav-section">
      <span class="section-label">Tools</span>
  """ &
  toolsHtml &
  """
    </nav>

    <nav class="nav-section">
      <span class="section-label">Plugins</span>
  """ &
  pluginsHtml &
  """
      <button class="nav-item add-plugin">
        <span>+</span>
        <span>Add plugin</span>
      </button>
    </nav>

    <nav class="nav-section">
      <span class="section-label">Developer</span>

      <button class="nav-item">
        <span>▣</span>
        <span>Jobs</span>
      </button>

      <button class="nav-item">
        <span>◌</span>
        <span>Runs</span>
      </button>

      <button class="nav-item">
        <span>≡</span>
        <span>Logs</span>
      </button>

      <button class="nav-item">
        <span>⚙</span>
        <span>System</span>
      </button>
    </nav>

    <div class="sidebar-footer">
      <div class="avatar">X</div>

      <div class="user-info">
        <strong>xenos</strong>
        <span>Developer</span>
      </div>
    </div>
  """