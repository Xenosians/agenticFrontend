import types

type
  AccountRequestContext* = object
    userId*, sessionId*: string
  ChatNavigationContext* = object
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
