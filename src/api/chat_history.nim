import std/sets

type ChatHistoryMessage* = object
  role*: string
  content*: string
  jobId*: string
  status*: string

const observableJobStates* = [
  "pending", "processing", "waiting_approval", "approving",
  "outcome_unknown", "reconciliation_required"
]

const restorableJobStates* = [
  "pending", "processing", "waiting_approval", "approving", "rejecting",
  "outcome_unknown", "reconciliation_required", "completed", "failed", "denied"
]

proc outstandingHistoryJob*(history: openArray[ChatHistoryMessage]): ChatHistoryMessage =
  ## History is chronological. Only the newest saved state for each job
  ## counts: an earlier approval record must not resurrect a completed job.
  var seen = initHashSet[string]()
  for index in countdown(history.high, 0):
    let item = history[index]
    if item.jobId.len == 0 or item.jobId in seen:
      continue
    seen.incl(item.jobId)
    if item.status in observableJobStates:
      return item

proc historyJobForRestore*(history: openArray[ChatHistoryMessage]): ChatHistoryMessage =
  result = outstandingHistoryJob(history)
  if result.jobId.len > 0:
    return
  for index in countdown(history.high, 0):
    let item = history[index]
    if item.jobId.len > 0 and item.status in restorableJobStates:
      return item

