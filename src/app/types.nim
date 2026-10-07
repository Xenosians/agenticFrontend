type
  AppView* = enum
    viewChat,
    viewSearch,
    viewJobs,
    viewRuns,
    viewLogs,
    viewSystem,
    viewTool,
    viewPlugin,
    viewNodeBuilder,
    viewSimulator,
    viewAccount

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

  AuthMode* = enum
    amLogin,
    amRegister,
    amForgotPassword,
    amResetPassword

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
    fields*: seq[ResultCardField]
    sections*: seq[ResultCardSection]

  ChatMessage* = object
    id*: int
    role*: MessageRole
    content*: string
    cards*: seq[ResultCard]

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
    presentations*: seq[ResultCard]

  SystemState* = object
    checked*: bool
    checking*: bool
    backendConnected*: bool
    aiReachable*: bool
    aiHealthy*: bool
    aiReady*: bool
    paloAltoConfigured*: bool
    paloAltoHost*: string
    paloAltoMode*: string
    integrationsError*: string
    error*: string

  ToolItem* = object
    id*: string
    name*: string
    enabled*: bool

  PluginItem* = object
    id*: string
    name*: string
    connected*: bool

  ChatItem* = object
    chatId*: string
    title*: string
    updatedAt*: string

  AuthSessionItem* = object
    sessionId*: string
    createdAt*: string
    lastSeenAt*: string
    expiresAt*: string
    revokedAt*: string
    userAgent*: string
    current*: bool

  AuthState* = object
    checked*: bool
    loading*: bool
    authenticated*: bool
    mode*: AuthMode
    userId*: string
    email*: string
    displayName*: string
    role*: string
    csrfToken*: string
    sessionId*: string
    expiresAt*: string
    error*: string
    notice*: string
    emailDraft*: string
    passwordDraft*: string
    displayNameDraft*: string
    newPasswordDraft*: string
    resetToken*: string

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
    pendingDeleteChatId*: string
    toastMessage*: string
    messages*: seq[ChatMessage]
    run*: RunState
    runEvents*: seq[RunEvent]
    system*: SystemState
    tools*: seq[ToolItem]
    plugins*: seq[PluginItem]
    auth*: AuthState
    chats*: seq[ChatItem]
    currentChatId*: string
    sessions*: seq[AuthSessionItem]
    sessionsLoaded*: bool
    nextMessageId*: int
    nextEventId*: int
