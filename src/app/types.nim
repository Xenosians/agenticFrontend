type
  MessageRole* = enum
    mrUser,
    mrAssistant

  ChatMessage* = object
    id*: int
    role*: MessageRole
    content*: string

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
    messages*: seq[ChatMessage]

    run*: RunState

    tools*: seq[ToolItem]
    plugins*: seq[PluginItem]

    nextMessageId*: int