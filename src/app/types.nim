import std/json
import workflow_request
import operations_snapshot

type
  AppView* = enum
    viewChat,
    viewChats,
    viewSearch,
    viewJobs,
    viewRuns,
    viewLogs,
    viewSystem,
    viewTool,
    viewPlugin,
    viewNodeBuilder,
    viewSimulator,
    viewAccount,
    viewCapabilities

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
    jobId*: string
    role*: MessageRole
    content*: string
    cards*: seq[ResultCard]

  RunEvent* = object
    id*: int
    kind*: string
    message*: string

  ToolProposal* = object
    tool*: string
    arguments*: JsonNode
    approvalId*: string

  RunState* = object
    active*: bool
    request*: string
    jobId*: string
    status*: string
    agent*: string
    tool*: string
    proposal*: ToolProposal
    decisionError*: string
    observationMode*: string
    progressStage*: string
    presentations*: seq[ResultCard]
    workflowContract*: JsonNode
    workflowContractHash*: string

  SystemState* = object
    checked*: bool
    checking*: bool
    backendConnected*: bool
    aiReachable*: bool
    aiHealthy*: bool
    aiReady*: bool
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
    operations*: OperationsSnapshot
    operationsBusy*, operationsLoaded*: bool
    operationsError*, operationsExpandedJob*: string
    operationsEpoch*: int
    extensionCatalog*: JsonNode
    commandPaletteOpen*: bool
    commandQuery*: string
    pluginSection*: string
    pluginSearchDraft*: string
    extensionBusy*: bool
    extensionError*: string
    connectionName*: string
    connectionBackend*: string
    connectionModel*: string
    connectionUrl*: string
    connectionKey*: string
    connectionOptionsId*: string
    connectionTpm*: string
    connectionRpm*: string
    connectionMaxWait*: string
    connectionReasoning*: string
    connectionThinking*: string
    connectionApiFormat*: string
    connectionProviderId*: string
    connectionModelChoices*: seq[tuple[id, name: string]]
    connectionNetworkingInference*: string
    datasetName*: string
    datasetSource*: string
    datasetLicense*: string
    datasetPurpose*: string
    datasetText*: string
    datasetApiKey*: string
    datasetReviewed*: bool
    datasetReplaces*: string
    activeView*: AppView
    inspectorTab*: InspectorTab
    composerPanel*: ComposerPanel
    inspectorOpen*: bool
    headerMenuOpen*: bool
    composerDraft*: string
    workflowPanelOpen*: bool
    workflowCapabilityDraft*, workflowAfterDraft*, workflowError*: string
    workflowArgumentDrafts*: JsonNode
    workflowSteps*: seq[WorkflowStep]
    searchDraft*: string
    capabilityQuery*: string
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
    jobObservationEpoch*: int
    chatNavigationEpoch*: int
    authRequestEpoch*: int
    sessions*: seq[AuthSessionItem]
    sessionsLoaded*: bool
    nextMessageId*: int
    nextEventId*: int
