import std/unittest
import ../src/api/chat_history

suite "durable job restoration from saved history":
  test "an outstanding approval survives a later completed turn":
    let history = [
      ChatHistoryMessage(role: "assistant", content: "Approval required", jobId: "approval-job", status: "waiting_approval"),
      ChatHistoryMessage(role: "assistant", content: "A later answer", jobId: "read-job", status: "completed")]
    let pending = outstandingHistoryJob(history)
    check pending.jobId == "approval-job"
    check pending.status == "waiting_approval"

  test "a newer terminal record prevents resurrecting an earlier approval":
    let history = [
      ChatHistoryMessage(jobId: "job", status: "waiting_approval"),
      ChatHistoryMessage(jobId: "job", status: "completed")]
    check outstandingHistoryJob(history).jobId == ""

  test "empty content still identifies the authoritative job to fetch":
    let pending = outstandingHistoryJob([
      ChatHistoryMessage(content: "", jobId: "job", status: "waiting_approval")])
    check pending.jobId == "job"

  test "the latest outstanding job is selected and must be reread":
    for status in observableJobStates:
      let pending = outstandingHistoryJob([
        ChatHistoryMessage(jobId: "older", status: "waiting_approval"),
        ChatHistoryMessage(jobId: "newer", status: status)])
      check pending.jobId == "newer"
      check pending.status == status

  test "missing identity, unknown states and terminal states cannot expose approval":
    for status in ["completed", "failed", "denied", "invented"]:
      check outstandingHistoryJob([ChatHistoryMessage(jobId: "job", status: status)]).jobId == ""
    check outstandingHistoryJob([ChatHistoryMessage(status: "waiting_approval")]).jobId == ""
    check outstandingHistoryJob(newSeq[ChatHistoryMessage]()).jobId == ""

  test "an interrupted local rejection can be reread without resubmitting it":
    check "rejecting" in restorableJobStates

  test "latest completed job is reread to hydrate its result when no job is outstanding":
    let selected = historyJobForRestore([
      ChatHistoryMessage(jobId: "older", status: "completed"),
      ChatHistoryMessage(jobId: "latest", status: "completed")])
    check selected.jobId == "latest"
    check selected.status == "completed"

  test "an older outstanding approval takes priority over latest completed hydration":
    check historyJobForRestore([
      ChatHistoryMessage(jobId: "approval", status: "waiting_approval"),
      ChatHistoryMessage(jobId: "completed", status: "completed")]).jobId == "approval"
