import std/json
import workflow_request
import operations_snapshot
import feedback_review
import knowledge
import learning
import workflows
import engineering
import answer_references
import lua_transforms
import chat_list
export chat_list

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
    viewCapabilities,
    viewReview,
    viewKnowledge,
    viewLearning,
    viewHelp

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
    amResetPassword,
    amVerifyEmail

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
    references*: seq[AnswerReference]

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
    ## The server's verification step for this browser: when another
    ## email may be sent and a masked address. Never stored in the browser.
    verificationEmailHint*: string
    verificationResendAt*: float  ## performance.now() milliseconds
    verificationSecondsLeft*: int
    verificationEpoch*: int

  AppState* = ref object
    operations*: OperationsSnapshot
    operationsBusy*, operationsLoaded*: bool
    operationsError*, operationsExpandedJob*: string
    operationsEpoch*: int
    reviewItems*: seq[ReviewItem]
    reviewBusy*, reviewLoaded*, reviewShowDecided*: bool
    reviewError*, reviewDeciding*: string
    reviewItemErrors*: seq[(string, string)]
    reviewReasons*: seq[(string, string)]
    reviewEpoch*: int
    knowledgeHits*: seq[KnowledgeHit]
    knowledgeBusy*, knowledgeSearched*: bool
    knowledgeError*, knowledgeQuery*, knowledgeSource*: string
    knowledgeEpoch*: int
    ## Reopened answer passages by citation locator, and the one being reopened.
    referencePassages*: seq[(string, string)]
    referenceOpening*, referenceError*, referenceErrorLocator*: string
    referenceEpoch*: int
    learningCatalog*: LearningCatalog
    learningPreflight*: LearningPreflight
    learningLoaded*, learningBusy*, learningChecking*: bool
    learningError*, learningMethod*, learningRole*, learningTuning*, learningModel*, learningDataset*: string
    learningEpoch*: int
    ## Candidate runs: the newest first, which one is being started or cancelled.
    learningRuns*: seq[LearningRun]
    learningRunsLoaded*, learningStarting*: bool
    learningReconciling*, learningRecoveryChecked*: bool
    learningCancelling*, learningRunError*: string
    learningRunsError*, learningRecoveryError*: string
    learningRunsEpoch*: int
    learningMutationEpoch*: int
    learningCheckedRequest*: JsonNode
    learningPendingRequest*: JsonNode
    automationWorkflows*: seq[WorkflowSummary]
    automationDraft*: WorkflowDraft
    automationPendingRun*: WorkflowPendingRun
    automationRuns*: seq[WorkflowRunRow]
    automationLoaded*, automationBusy*, automationSaving*, automationRunning*, automationDirty*: bool
    automationError*, automationNotice*, automationSelectedNode*, automationRunMessage*, automationRecoveryError*: string
    automationRecoveryChecked*: bool
    automationRunConfirmed*: bool
    automationAddCapability*, automationAddAfter*: string
    automationEpoch*: int
    engineeringTopologies*: seq[TopologySummary]
    engineeringDraft*: TopologyDraft
    engineeringDrift*: DriftReport
    engineeringNetlist*: NetlistReport
    engineeringTab*, engineeringSelectedNode*, engineeringError*, engineeringNotice*: string
    engineeringNewKind*, engineeringNewName*, engineeringEdgeTarget*, engineeringEdgeRelation*: string
    engineeringNetlistText*, engineeringNetlistName*: string
    engineeringLoaded*, engineeringBusy*, engineeringSaving*, engineeringChecking*, engineeringDirty*: bool
    engineeringHasDrift*, engineeringHasNetlist*: bool
    engineeringEpoch*: int
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
    datasetScript*: string
    datasetTransformPreview*: TransformPreview
    datasetTransformPreviewed*: bool
    datasetTransformEpoch*: int
    datasetTransformOpen*: bool
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
    chatFilter*, chatRenameId*, chatRenameDraft*: string
    chatActionId*, chatActionError*: string
    chatsRefreshing*, chatsNeedRefresh*: bool
    chatMetadataEpoch*: int
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
    sessionsBusy*, sessionActionBusy*, sessionsNeedRefresh*: bool
    sessionsError*, sessionsNotice*: string
    sessionsEpoch*: int
    preferencesLoaded*, preferencesBusy*, preferencesSaving*: bool
    completionMail*, completionMailDraft*: bool
    preferencesError*, preferencesNotice*: string
    preferencesEpoch*: int
    nextMessageId*: int
    nextEventId*: int
