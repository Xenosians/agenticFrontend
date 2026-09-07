import types


proc emptyRunState(): RunState =
  RunState(
    active: false,

    request: "",

    jobId: "",
    status: "",

    agent: "",
    tool: ""
  )


proc initAppState*(): AppState =
  AppState(
    activeView: viewChat,
    inspectorTab: tabRun,
    composerPanel: cpNone,

    inspectorOpen: true,
    headerMenuOpen: false,

    composerDraft: "",
    searchDraft: "",

    composerSelectedToolId: "",
    selectedToolId: "",
    selectedPluginId: "",

    toastMessage: "",

    messages: @[],

    run: emptyRunState(),
    runEvents: @[],

    tools: @[
      ToolItem(
        id: "shell",
        name: "Shell",
        enabled: true
      ),

      ToolItem(
        id: "account",
        name: "Account",
        enabled: true
      ),

      ToolItem(
        id: "access",
        name: "Access",
        enabled: true
      ),

      ToolItem(
        id: "files",
        name: "Files",
        enabled: false
      ),

      ToolItem(
        id: "git",
        name: "Git",
        enabled: false
      )
    ],

    plugins: @[
      PluginItem(
        id: "github",
        name: "GitHub",
        connected: false
      ),

      PluginItem(
        id: "jira",
        name: "Jira",
        connected: false
      ),

      PluginItem(
        id: "slack",
        name: "Slack",
        connected: false
      )
    ],

    nextMessageId: 1,
    nextEventId: 1
  )


proc showToast*(
  state: AppState,
  message: string
) =
  state.toastMessage = message


proc clearToast*(
  state: AppState
) =
  state.toastMessage = ""


proc setActiveView*(
  state: AppState,
  view: AppView
) =
  state.activeView = view
  state.headerMenuOpen = false


proc setInspectorTab*(
  state: AppState,
  tab: InspectorTab
) =
  state.inspectorTab = tab


proc toggleInspector*(
  state: AppState
) =
  state.inspectorOpen =
    not state.inspectorOpen

  state.headerMenuOpen = false


proc toggleHeaderMenu*(
  state: AppState
) =
  state.headerMenuOpen =
    not state.headerMenuOpen


proc setComposerDraft*(
  state: AppState,
  value: string
) =
  state.composerDraft = value


proc setSearchDraft*(
  state: AppState,
  value: string
) =
  state.searchDraft = value


proc setComposerPanel*(
  state: AppState,
  panel: ComposerPanel
) =
  if state.composerPanel == panel:
    state.composerPanel = cpNone
  else:
    state.composerPanel = panel


proc closeComposerPanel*(
  state: AppState
) =
  state.composerPanel = cpNone


proc clearComposerTool*(
  state: AppState
) =
  state.composerSelectedToolId = ""

  showToast(
    state,
    "Tool selection returned to automatic routing."
  )


proc selectComposerTool*(
  state: AppState,
  toolId: string
) =
  state.composerSelectedToolId =
    toolId

  state.composerPanel =
    cpNone

  var
    toolName = toolId
    enabled = false

  for tool in state.tools:
    if tool.id == toolId:
      toolName = tool.name
      enabled = tool.enabled
      break

  if enabled:
    showToast(
      state,
      toolName &
      " selected for the next requests."
    )

  else:
    showToast(
      state,
      toolName &
      " selected in preview mode. " &
      "The backend capability is not connected yet."
    )


proc openToolView*(
  state: AppState,
  toolId: string
) =
  state.selectedToolId = toolId
  state.activeView = viewTool
  state.headerMenuOpen = false


proc openPluginView*(
  state: AppState,
  pluginId: string
) =
  state.selectedPluginId = pluginId
  state.activeView = viewPlugin
  state.headerMenuOpen = false


proc openPluginCatalog*(
  state: AppState
) =
  state.selectedPluginId = ""
  state.activeView = viewPlugin
  state.headerMenuOpen = false


proc togglePluginConnection*(
  state: AppState,
  pluginId: string
) =
  for i in 0 ..< state.plugins.len:
    if state.plugins[i].id == pluginId:

      state.plugins[i].connected =
        not state.plugins[i].connected

      if state.plugins[i].connected:
        showToast(
          state,
          state.plugins[i].name &
          " connected in frontend preview mode."
        )
      else:
        showToast(
          state,
          state.plugins[i].name &
          " disconnected."
        )

      return


proc addPreviewPlugin*(
  state: AppState
) =
  let previewId =
    "custom-preview"

  for plugin in state.plugins:
    if plugin.id == previewId:
      openPluginView(
        state,
        previewId
      )

      showToast(
        state,
        "Custom Plugin already exists in the preview registry."
      )

      return

  state.plugins.add(
    PluginItem(
      id: previewId,
      name: "Custom Plugin",
      connected: false
    )
  )

  state.selectedPluginId =
    previewId

  state.activeView =
    viewPlugin

  showToast(
    state,
    "Custom Plugin added to the local frontend registry."
  )


proc addRunEvent*(
  state: AppState,
  kind: string,
  message: string
) =
  state.runEvents.add(
    RunEvent(
      id: state.nextEventId,
      kind: kind,
      message: message
    )
  )

  inc state.nextEventId


proc addUserMessage*(
  state: AppState,
  content: string
) =
  state.messages.add(
    ChatMessage(
      id: state.nextMessageId,
      role: mrUser,
      content: content
    )
  )

  inc state.nextMessageId


proc addAssistantMessage*(
  state: AppState,
  content: string
) =
  state.messages.add(
    ChatMessage(
      id: state.nextMessageId,
      role: mrAssistant,
      content: content
    )
  )

  inc state.nextMessageId


proc startLocalRun*(
  state: AppState,
  request: string
) =
  state.run = RunState(
    active: true,

    request: request,

    jobId: "local-preview",
    status: "processing",

    agent: "",
    tool: ""
  )

  state.runEvents.setLen(0)

  state.inspectorTab =
    tabRun

  addRunEvent(
    state,
    "request",
    "Request accepted by frontend runtime."
  )

  addRunEvent(
    state,
    "run",
    "Local preview run started."
  )


proc completeLocalRun*(
  state: AppState,
  agent: string,
  tool: string
) =
  state.run.agent =
    agent

  state.run.tool =
    tool

  addRunEvent(
    state,
    "routing",
    "Selected agent: " & agent
  )

  addRunEvent(
    state,
    "tool",
    "Selected tool: " & tool
  )

  state.run.status =
    "completed"

  addRunEvent(
    state,
    "run",
    "Local preview run completed."
  )


proc clearRun*(
  state: AppState
) =
  state.run =
    emptyRunState()

  state.runEvents.setLen(0)

  state.inspectorTab =
    tabRun

  state.headerMenuOpen =
    false

  showToast(
    state,
    "Local run state cleared."
  )


proc resetConversation*(
  state: AppState
) =
  state.messages.setLen(0)
  state.runEvents.setLen(0)

  state.run =
    emptyRunState()

  state.composerDraft =
    ""

  state.searchDraft =
    ""

  state.composerPanel =
    cpNone

  state.nextMessageId =
    1

  state.nextEventId =
    1

  state.activeView =
    viewChat

  state.inspectorTab =
    tabRun

  state.headerMenuOpen =
    false

  showToast(
    state,
    "New local session started."
  )