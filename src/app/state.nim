import types

proc clearWorkflowDraft*(state: AppState) =
  state.workflowSteps.setLen(0)
  state.workflowCapabilityDraft = ""
  state.workflowAfterDraft = ""
  state.workflowArgumentDrafts = nil
  state.workflowError = ""
  state.workflowPanelOpen = false

proc emptyRunState():
  RunState =

  RunState(
    active:
      false,

    request:
      "",

    jobId:
      "",

    status:
      "",

    agent:
      "",

    tool:
      "",

    presentations:
      @[]
  )


proc emptySystemState():
  SystemState =

  SystemState(
    checked:
      false,

    checking:
      false,

    backendConnected:
      false,

    aiReachable:
      false,

    aiHealthy:
      false,

    aiReady:
      false,

    integrationsError:
      "",

    error:
      ""
  )


proc initAppState*():
  AppState =

  AppState(
    activeView:
      viewChat,

    pluginSection:
      "public",

    pluginSearchDraft:
      "",

    inspectorTab:
      tabRun,

    composerPanel:
      cpNone,

    inspectorOpen:
      false,

    headerMenuOpen:
      false,

    composerDraft:
      "",

    searchDraft:
      "",

    composerSelectedToolId:
      "",

    selectedToolId:
      "",

    selectedPluginId:
      "",

    pendingDeleteChatId:
      "",

    toastMessage:
      "",

    messages:
      @[],

    run:
      emptyRunState(),

    runEvents:
      @[],

    system:
      emptySystemState(),

    tools: @[],

    plugins: @[],

    nextMessageId:
      1,

    nextEventId:
      1
  )


proc showToast*(
  state: AppState,
  message: string
) =

  state.toastMessage =
    message


proc clearToast*(
  state: AppState
) =

  state.toastMessage =
    ""


proc setActiveView*(
  state: AppState,
  view: AppView
) =

  state.activeView =
    view

  state.headerMenuOpen =
    false


proc setInspectorTab*(
  state: AppState,
  tab: InspectorTab
) =

  state.inspectorTab =
    tab


proc toggleInspector*(
  state: AppState
) =

  state.inspectorOpen =
    not state.inspectorOpen

  state.headerMenuOpen =
    false


proc toggleHeaderMenu*(
  state: AppState
) =

  state.headerMenuOpen =
    not state.headerMenuOpen


proc setComposerDraft*(
  state: AppState,
  value: string
) =

  state.composerDraft =
    value


proc setSearchDraft*(
  state: AppState,
  value: string
) =

  state.searchDraft =
    value


proc setComposerPanel*(
  state: AppState,
  panel: ComposerPanel
) =

  if state.composerPanel ==
     panel:

    state.composerPanel =
      cpNone

  else:

    state.composerPanel =
      panel


proc closeComposerPanel*(
  state: AppState
) =

  state.composerPanel =
    cpNone


proc clearComposerTool*(
  state: AppState
) =

  state.composerSelectedToolId =
    ""

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
    toolName =
      toolId

    enabled =
      false


  for tool in state.tools:

    if tool.id ==
       toolId:

      toolName =
        tool.name

      enabled =
        tool.enabled

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

  state.selectedToolId =
    toolId

  state.activeView =
    viewTool

  state.headerMenuOpen =
    false


proc openPluginView*(
  state: AppState,
  pluginId: string
) =

  state.selectedPluginId =
    pluginId

  state.activeView =
    viewPlugin

  state.headerMenuOpen =
    false


proc openPluginCatalog*(
  state: AppState
) =

  state.selectedPluginId =
    ""

  state.activeView =
    viewPlugin

  state.headerMenuOpen =
    false




proc addRunEvent*(
  state: AppState,
  kind: string,
  message: string
) =

  state.runEvents.add(
    RunEvent(
      id:
        state.nextEventId,

      kind:
        kind,

      message:
        message
    )
  )

  inc state.nextEventId


proc addUserMessage*(
  state: AppState,
  content: string
) =

  state.messages.add(
    ChatMessage(
      id:
        state.nextMessageId,

      role:
        mrUser,

      content:
        content,

      cards:
        @[]
    )
  )

  inc state.nextMessageId


proc addAssistantMessage*(
  state: AppState,
  content: string,
  cards: seq[
    ResultCard
  ] = @[],
  jobId: string = ""
) =

  state.messages.add(
    ChatMessage(
      id:
        state.nextMessageId,

      role:
        mrAssistant,

      jobId: jobId,

      content:
        content,

      cards:
        cards
    )
  )

  inc state.nextMessageId


proc restoreAssistantJobMessage*(state: AppState, jobId, content: string,
                                 cards: seq[ResultCard]) =
  ## Replace the saved response for this exact job, preserving other turns.
  ## If history has only its request, append the newly observed response.
  if jobId.len > 0:
    for index in countdown(state.messages.high, 0):
      if state.messages[index].role == mrAssistant and state.messages[index].jobId == jobId:
        state.messages[index].content = content
        state.messages[index].cards = cards
        return
  addAssistantMessage(state, content, cards, jobId)




proc clearRun*(
  state: AppState
) =

  state.run =
    emptyRunState()

  state.runEvents.setLen(
    0
  )

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

  clearWorkflowDraft(state)

  state.messages.setLen(
    0
  )

  state.runEvents.setLen(
    0
  )

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
