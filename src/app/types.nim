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


  ResultCardField* = object
    label*: string
    value*: string


  ResultCardSection* = object
    kind*: string
    title*: string

    content*: string
    items*: seq[string]


  ResultCard* = object
    schema*: string

    kind*: string
    title*: string
    status*: string

    fields*: seq[
      ResultCardField
    ]

    sections*: seq[
      ResultCardSection
    ]


  ChatMessage* = object
    id*: int

    role*: MessageRole

    content*: string

    cards*: seq[
      ResultCard
    ]


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

    presentations*: seq[
      ResultCard
    ]


  SystemState* = object
    checked*: bool
    checking*: bool

    backendConnected*: bool

    aiReachable*: bool
    aiHealthy*: bool
    aiReady*: bool

    error*: string


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

    messages*: seq[
      ChatMessage
    ]

    run*: RunState

    runEvents*: seq[
      RunEvent
    ]

    system*: SystemState

    tools*: seq[
      ToolItem
    ]

    plugins*: seq[
      PluginItem
    ]

    nextMessageId*: int
    nextEventId*: int