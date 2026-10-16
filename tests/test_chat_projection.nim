import std/unittest
import ../src/app/[types, state]

suite "authoritative saved job result projection":
  test "completed GET hydrates cards and replaces the matching saved response only":
    let app = initAppState()
    app.messages = @[
      ChatMessage(id: 1, jobId: "write", role: mrUser, content: "Create directory"),
      ChatMessage(id: 2, jobId: "write", role: mrAssistant, content: "Approval required"),
      ChatMessage(id: 3, jobId: "read", role: mrAssistant, content: "Unrelated later answer")]
    let cards = @[ResultCard(title: "Directory created", status: "success")]
    restoreAssistantJobMessage(app, "write", "Created", cards)
    check app.messages.len == 3
    check app.messages[0].content == "Create directory"
    check app.messages[1].content == "Created"
    check app.messages[1].cards[0].title == "Directory created"
    check app.messages[2].content == "Unrelated later answer"
    restoreAssistantJobMessage(app, "write", "Created", cards)
    check app.messages.len == 3

  test "a job completed while disconnected adds its response once":
    let app = initAppState()
    app.messages = @[ChatMessage(id: 1, jobId: "job", role: mrUser, content: "Read project")]
    app.nextMessageId = 2
    restoreAssistantJobMessage(app, "job", "Project information", @[])
    check app.messages.len == 2
    check app.messages[1].jobId == "job"
    restoreAssistantJobMessage(app, "job", "Project information", @[])
    check app.messages.len == 2
