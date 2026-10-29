import types
import operations_snapshot
import feedback_review
import learning
import workflows
import engineering

type
  AccountRequestContext* = object
    userId*, sessionId*: string
  ChatNavigationContext* = object
    account*: AccountRequestContext
    epoch*: int
  OperationsRequestContext* = object
    account*: AccountRequestContext
    epoch*: int

proc accountContext*(state: AppState): AccountRequestContext =
  AccountRequestContext(userId: state.auth.userId, sessionId: state.auth.sessionId)

proc matchesAccount*(state: AppState, context: AccountRequestContext): bool =
  state.auth.authenticated and context.userId.len > 0 and context.sessionId.len > 0 and
    state.auth.userId == context.userId and state.auth.sessionId == context.sessionId

proc navigationContext*(state: AppState): ChatNavigationContext =
  ChatNavigationContext(account: accountContext(state), epoch: state.chatNavigationEpoch)

proc beginNavigation*(state: AppState): ChatNavigationContext =
  inc state.chatNavigationEpoch
  navigationContext(state)

proc matchesNavigation*(state: AppState, context: ChatNavigationContext): bool =
  matchesAccount(state, context.account) and state.chatNavigationEpoch == context.epoch

proc beginAuthRequest*(state: AppState): int =
  inc state.authRequestEpoch
  state.authRequestEpoch

proc matchesAuthRequest*(state: AppState, epoch: int): bool =
  state.authRequestEpoch == epoch

proc beginOperationsRequest*(state: AppState): OperationsRequestContext =
  inc state.operationsEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.operationsEpoch)

proc matchesOperationsRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.operationsEpoch == request.epoch

proc clearOperations*(state: AppState) =
  inc state.operationsEpoch
  state.operations = OperationsSnapshot()
  state.operationsLoaded = false
  state.operationsBusy = false
  state.operationsError = ""
  state.operationsExpandedJob = ""
  # The review queue belongs to the signed-in reviewer as well.
  inc state.reviewEpoch
  state.reviewItems = @[]
  state.reviewLoaded = false
  state.reviewBusy = false
  state.reviewShowDecided = false
  state.reviewError = ""
  state.reviewDeciding = ""
  state.reviewItemErrors = @[]
  state.reviewReasons = @[]
  # Knowledge searches and hits belong to the signed-in owner.
  inc state.knowledgeEpoch
  state.knowledgeHits = @[]
  state.knowledgeSearched = false
  state.knowledgeBusy = false
  state.knowledgeError = ""
  state.knowledgeQuery = ""
  state.knowledgeSource = ""
  # Reopened answer passages are the signed-in owner's reference text.
  inc state.referenceEpoch
  state.referencePassages = @[]
  state.referenceOpening = ""
  state.referenceError = ""
  state.referenceErrorLocator = ""
  inc state.learningEpoch
  state.learningCatalog = LearningCatalog()
  state.learningPreflight = LearningPreflight()
  state.learningLoaded = false
  state.learningBusy = false
  state.learningChecking = false
  state.learningError = ""
  state.learningMethod = ""
  state.learningRole = ""
  state.learningTuning = ""
  state.learningModel = ""
  state.learningDataset = ""
  state.learningCheckedRequest = nil
  inc state.learningRunsEpoch
  inc state.learningMutationEpoch
  state.learningRuns = @[]
  state.learningRunsLoaded = false
  state.learningStarting = false
  state.learningCancelling = ""
  state.learningRunError = ""
  state.learningRunsError = ""
  state.learningRecoveryError = ""
  state.learningReconciling = false
  state.learningRecoveryChecked = false
  state.learningPendingRequest = nil
  # Saved workflows, the open canvas and its run identity belong to the owner.
  inc state.automationEpoch
  state.automationWorkflows = @[]
  state.automationDraft = WorkflowDraft(name: "New workflow")
  state.automationPendingRun = WorkflowPendingRun()
  state.automationRuns = @[]
  state.automationLoaded = false
  state.automationBusy = false
  state.automationSaving = false
  state.automationRunning = false
  state.automationDirty = false
  state.automationError = ""
  state.automationNotice = ""
  state.automationSelectedNode = ""
  state.automationRunMessage = ""
  state.automationRecoveryError = ""
  state.automationRecoveryChecked = false
  state.automationRunConfirmed = false
  state.automationAddCapability = ""
  state.automationAddAfter = ""
  # Topologies, drift reports and netlist reports belong to the signed-in owner.
  inc state.engineeringEpoch
  state.engineeringTopologies = @[]
  state.engineeringDraft = TopologyDraft(name: "New topology")
  state.engineeringDrift = DriftReport()
  state.engineeringNetlist = NetlistReport()
  state.engineeringHasDrift = false
  state.engineeringHasNetlist = false
  state.engineeringLoaded = false
  state.engineeringBusy = false
  state.engineeringSaving = false
  state.engineeringChecking = false
  state.engineeringDirty = false
  state.engineeringError = ""
  state.engineeringNotice = ""
  state.engineeringSelectedNode = ""
  state.engineeringEdgeTarget = ""
  state.engineeringNetlistText = ""
  state.engineeringNetlistName = ""
  # Account settings and session inventories are owned by this exact session.
  inc state.sessionsEpoch
  state.sessions = @[]
  state.sessionsLoaded = false
  state.sessionsBusy = false
  state.sessionActionBusy = false
  state.sessionsNeedRefresh = false
  state.sessionsError = ""
  state.sessionsNotice = ""
  inc state.preferencesEpoch
  state.preferencesLoaded = false
  state.preferencesBusy = false
  state.preferencesSaving = false
  state.completionMail = false
  state.completionMailDraft = false
  state.preferencesError = ""
  state.preferencesNotice = ""

proc beginReviewRequest*(state: AppState): OperationsRequestContext =
  inc state.reviewEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.reviewEpoch)

proc matchesReviewRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.reviewEpoch == request.epoch

proc beginKnowledgeRequest*(state: AppState): OperationsRequestContext =
  inc state.knowledgeEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.knowledgeEpoch)

proc matchesKnowledgeRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.knowledgeEpoch == request.epoch

proc beginReferenceRequest*(state: AppState): OperationsRequestContext =
  inc state.referenceEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.referenceEpoch)

proc matchesReferenceRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.referenceEpoch == request.epoch

proc beginLearningRunsRequest*(state: AppState): OperationsRequestContext =
  inc state.learningRunsEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.learningRunsEpoch)

proc matchesLearningRunsRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.learningRunsEpoch == request.epoch

proc beginLearningMutationRequest*(state: AppState): OperationsRequestContext =
  inc state.learningMutationEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.learningMutationEpoch)

proc matchesLearningMutationRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.learningMutationEpoch == request.epoch

proc beginLearningRequest*(state: AppState): OperationsRequestContext =
  inc state.learningEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.learningEpoch)

proc matchesLearningRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.learningEpoch == request.epoch

proc beginWorkflowRequest*(state: AppState): OperationsRequestContext =
  inc state.automationEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.automationEpoch)

proc matchesWorkflowRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.automationEpoch == request.epoch

proc beginEngineeringRequest*(state: AppState): OperationsRequestContext =
  inc state.engineeringEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.engineeringEpoch)

proc matchesEngineeringRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.engineeringEpoch == request.epoch

proc isReviewer*(state: AppState): bool =
  ## The backend enforces this; the UI only hides what would be refused.
  state.auth.authenticated and state.auth.role == "admin"

proc reviewQueueItems*(state: AppState): seq[ReviewItem] = state.reviewItems

proc beginSessionsRequest*(state: AppState): OperationsRequestContext =
  inc state.sessionsEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.sessionsEpoch)

proc matchesSessionsRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.sessionsEpoch == request.epoch

proc beginPreferencesRequest*(state: AppState): OperationsRequestContext =
  inc state.preferencesEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.preferencesEpoch)

proc matchesPreferencesRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.preferencesEpoch == request.epoch
