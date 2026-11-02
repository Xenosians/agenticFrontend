import types
import answer_references
import skills

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

  state.commandPaletteOpen =
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
  jobId: string = "",
  references: seq[AnswerReference] = @[],
  skills: seq[AnswerSkill] = @[]
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
        cards,

      references: references,

      skills: skills
    )
  )

  inc state.nextMessageId


proc restoreAssistantJobMessage*(state: AppState, jobId, content: string,
                                 cards: seq[ResultCard], references: seq[AnswerReference] = @[],
                                 skills: seq[AnswerSkill] = @[]) =
  ## Replace the saved response for this exact job, preserving other turns.
  ## If history has only its request, append the newly observed response.
  ## Citations restored from history stay unless the job read carries its own.
  if jobId.len > 0:
    for index in countdown(state.messages.high, 0):
      if state.messages[index].role == mrAssistant and state.messages[index].jobId == jobId:
        state.messages[index].content = content
        state.messages[index].cards = cards
        if references.len > 0:
          state.messages[index].references = references
        if skills.len > 0:
          state.messages[index].skills = skills
        return
  addAssistantMessage(state, content, cards, jobId, references, skills)
