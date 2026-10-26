import types
import operations_snapshot
import feedback_review

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

proc beginReviewRequest*(state: AppState): OperationsRequestContext =
  inc state.reviewEpoch
  OperationsRequestContext(account: accountContext(state), epoch: state.reviewEpoch)

proc matchesReviewRequest*(state: AppState, request: OperationsRequestContext): bool =
  matchesAccount(state, request.account) and state.reviewEpoch == request.epoch

proc isReviewer*(state: AppState): bool =
  ## The backend enforces this; the UI only hides what would be refused.
  state.auth.authenticated and state.auth.role == "admin"

proc reviewQueueItems*(state: AppState): seq[ReviewItem] = state.reviewItems
