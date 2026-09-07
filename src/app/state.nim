import types


proc emptyRunState(): RunState =
  RunState(
    active: false,

    request: "",

    jobId: "",
    status: "",

    agent: "",
    tool: ""
  )


proc initAppState*(): AppState =
  AppState(
    messages: @[],

    run: emptyRunState(),

    tools: @[
      ToolItem(
        id: "shell",
        name: "Shell",
        enabled: true
      ),

      ToolItem(
        id: "account",
        name: "Account",
        enabled: true
      ),

      ToolItem(
        id: "access",
        name: "Access",
        enabled: true
      ),

      ToolItem(
        id: "files",
        name: "Files",
        enabled: false
      ),

      ToolItem(
        id: "git",
        name: "Git",
        enabled: false
      )
    ],

    plugins: @[
      PluginItem(
        id: "github",
        name: "GitHub",
        connected: false
      ),

      PluginItem(
        id: "jira",
        name: "Jira",
        connected: false
      ),

      PluginItem(
        id: "slack",
        name: "Slack",
        connected: false
      )
    ],

    nextMessageId: 1
  )


proc addUserMessage*(
  state: AppState,
  content: string
) =
  state.messages.add(
    ChatMessage(
      id: state.nextMessageId,
      role: mrUser,
      content: content
    )
  )

  inc state.nextMessageId


proc addAssistantMessage*(
  state: AppState,
  content: string
) =
  state.messages.add(
    ChatMessage(
      id: state.nextMessageId,
      role: mrAssistant,
      content: content
    )
  )

  inc state.nextMessageId


proc startLocalRun*(
  state: AppState,
  request: string
) =
  state.run = RunState(
    active: true,

    request: request,

    jobId: "",
    status: "pending",

    agent: "",
    tool: ""
  )


proc resetConversation*(
  state: AppState
) =
  state.messages.setLen(0)

  state.run = emptyRunState()

  state.nextMessageId = 1