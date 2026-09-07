type
  AppView* = enum
    viewChat,
    viewSearch,
    viewJobs,
    viewRuns,
    viewLogs,
    viewSystem,
    viewTool,
    viewPlugin


  InspectorTab* = enum
    tabRun,
    tabTools,
    tabEvents,
    tabRaw


  ComposerPanel* = enum
    cpNone,
    cpAttach,
    cpTools


  MessageRole* = enum
    mrUser,
    mrAssistant


  ChatMessage* = object
    id*: int
    role*: MessageRole
    content*: string


  RunEvent* = object
    id*: int
    kind*: string
    message*: string


  RunState* = object
    active*: bool

    request*: string

    jobId*: string
    status*: string

    agent*: string
    tool*: string


  ToolItem* = object
    id*: string
    name*: string
    enabled*: bool


  PluginItem* = object
    id*: string
    name*: string
    connected*: bool


  AppState* = ref object
    activeView*: AppView
    inspectorTab*: InspectorTab
    composerPanel*: ComposerPanel

    inspectorOpen*: bool
    headerMenuOpen*: bool

    composerDraft*: string
    searchDraft*: string

    composerSelectedToolId*: string
    selectedToolId*: string
    selectedPluginId*: string

    toastMessage*: string

    messages*: seq[ChatMessage]

    run*: RunState
    runEvents*: seq[RunEvent]

    tools*: seq[ToolItem]
    plugins*: seq[PluginItem]

    nextMessageId*: int
    nextEventId*: int