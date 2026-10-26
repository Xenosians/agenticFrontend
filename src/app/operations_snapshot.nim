## Public, content-free Operations snapshot. Missing measurements remain unknown.
import std/[json, math, options, strutils]

const
  operationStatuses* = ["pending", "processing", "waiting_approval", "reconciliation_required",
    "denied", "outcome_unknown", "completed", "failed"]
  operationStages* = ["CONTROL_ROUTING", "CANDIDATE_NARROWING", "SEMANTIC_ROUTING",
    "SEMANTIC_ROUTING_BROAD", "SPECIALIST_REASONING", "PRIMARY_RESPONSE", "SYNTHESIS",
    "REPAIR", "NETWORKING", "NETWORKING_SELECTED", "INVALID"]

type
  OperationMetric* = object
    eventId*, recordedAt*, stage*, operation*, adapter*, role*, outcome*, repairOf*: string
    attempt*: int
    durationMs*: float
    queueMs*, executionMs*, firstTokenMs*: Option[float]
    generatedTokens*, estimatedInputTokens*, requestTokenBudget*, outputTokenCap*, droppedMessages*: Option[int]
  OperationJob* = object
    jobId*, chatId*, status*, selectedAgent*, createdAt*, claimedAt*, completedAt*: string
    attempt*: int
    queueWaitMs*, elapsedMs*: Option[float]
    metricsTruncated*: bool
    metrics*: seq[OperationMetric]
  OperationsSnapshot* = object
    observedAt*: string
    counts*: array[operationStatuses.len, int]
    jobs*: seq[OperationJob]

proc invalid() {.noreturn.} =
  raise newException(ValueError, "The operations snapshot is invalid.")

proc member(node: JsonNode, key: string): JsonNode =
  if node == nil or node.kind != JObject or not node.hasKey(key): invalid()
  node[key]

proc text(node: JsonNode, key: string, nullable = false): string =
  let value = member(node, key)
  if nullable and value.kind == JNull: return ""
  if value.kind != JString: invalid()
  result = value.getStr
  if result.len == 0 or result.len > 256: invalid()

proc integer(node: JsonNode, key: string, positive = false): int =
  let value = member(node, key)
  if value.kind != JInt: invalid()
  let number = value.getBiggestInt
  if number < (if positive: 1 else: 0) or number > 1_000_000_000: invalid()
  int(number)

proc observedInteger(node: JsonNode, key: string): Option[int] =
  if member(node, key).kind == JNull: return none(int)
  some(integer(node, key))

proc observedNumber(node: JsonNode, key: string): Option[float] =
  let value = member(node, key)
  if value.kind == JNull: return none(float)
  if value.kind notin {JInt, JFloat}: invalid()
  let number = if value.kind == JInt: float(value.getBiggestInt) else: value.getFloat
  if classify(number) in {fcNan, fcInf, fcNegInf} or number < 0: invalid()
  some(number)

proc hexIdentity(value: string): bool =
  value.len == 32 and value.allCharsInSet({'a'..'f', '0'..'9'})

proc metric(node: JsonNode, attempt: int): OperationMetric =
  result.eventId = text(node, "event_id")
  result.attempt = integer(node, "attempt", positive = true)
  result.recordedAt = text(node, "recorded_at")
  result.stage = text(node, "stage")
  result.operation = text(node, "operation")
  result.adapter = text(node, "adapter")
  result.role = text(node, "role", nullable = true)
  result.outcome = text(node, "outcome")
  result.repairOf = text(node, "repair_of", nullable = true)
  if not hexIdentity(result.eventId) or result.attempt != attempt or result.stage notin operationStages or
      result.operation notin ["generate", "warm"] or
      result.adapter notin ["local", "hf-causal", "http", "pi", "opencode", "unresolved"] or
      result.outcome notin ["success", "error", "cancelled", "budget_rejected", "skipped"] or
      (result.repairOf.len > 0 and result.repairOf notin operationStages): invalid()
  let duration = observedNumber(node, "duration_ms")
  if duration.isNone or duration.get > 86_400_000: invalid()
  result.durationMs = duration.get
  result.queueMs = observedNumber(node, "queue_ms")
  result.executionMs = observedNumber(node, "execution_ms")
  result.firstTokenMs = observedNumber(node, "first_token_ms")
  for measurement in [result.queueMs, result.executionMs, result.firstTokenMs]:
    if measurement.isSome and measurement.get > 86_400_000: invalid()
  result.generatedTokens = observedInteger(node, "generated_tokens")
  result.estimatedInputTokens = observedInteger(node, "estimated_input_tokens")
  result.requestTokenBudget = observedInteger(node, "request_token_budget")
  result.outputTokenCap = observedInteger(node, "output_token_cap")
  result.droppedMessages = observedInteger(node, "dropped_messages")

proc parseOperationsSnapshot*(node: JsonNode): OperationsSnapshot =
  if text(node, "schema") != "operations-snapshot.v1": invalid()
  result.observedAt = text(node, "observed_at")
  let counts = member(node, "counts")
  for index, status in operationStatuses:
    result.counts[index] = integer(counts, status)
  let jobs = member(node, "jobs")
  if jobs.kind != JArray or jobs.len > 100: invalid()
  var seenJobs: seq[string]
  for row in jobs:
    var job = OperationJob(
      jobId: text(row, "job_id"), chatId: text(row, "chat_id", nullable = true),
      status: text(row, "status"), attempt: integer(row, "attempt"),
      selectedAgent: text(row, "selected_agent", nullable = true),
      createdAt: text(row, "created_at"), claimedAt: text(row, "claimed_at", nullable = true),
      completedAt: text(row, "completed_at", nullable = true),
      queueWaitMs: observedNumber(row, "queue_wait_ms"), elapsedMs: observedNumber(row, "elapsed_ms"))
    if not hexIdentity(job.jobId) or job.jobId in seenJobs or job.status notin operationStatuses: invalid()
    seenJobs.add(job.jobId)
    let truncated = member(row, "metrics_truncated")
    if truncated.kind != JBool: invalid()
    job.metricsTruncated = truncated.getBool
    let metrics = member(row, "metrics")
    if metrics.kind != JArray or metrics.len > 64: invalid()
    var seenEvents: seq[string]
    for event in metrics:
      let observed = metric(event, job.attempt)
      if observed.eventId in seenEvents: invalid()
      seenEvents.add(observed.eventId)
      job.metrics.add(observed)
    result.jobs.add(job)

proc operationCount*(snapshot: OperationsSnapshot, status: string): int =
  for index, current in operationStatuses:
    if current == status: return snapshot.counts[index]
  raise newException(ValueError, "Unknown operation status.")

proc operationStatusLabel*(status: string): string =
  case status
  of "pending": "Queued"
  of "processing": "Running"
  of "waiting_approval": "Awaiting approval"
  of "reconciliation_required": "Needs reconciliation"
  of "denied": "Denied"
  of "outcome_unknown": "Outcome unknown"
  of "completed": "Completed"
  of "failed": "Failed"
  else: "Unknown"

proc operationStageLabel*(stage: string): string =
  case stage
  of "CONTROL_ROUTING": "Routing"
  of "CANDIDATE_NARROWING": "Narrowing candidates"
  of "SEMANTIC_ROUTING": "Matching capabilities"
  of "SEMANTIC_ROUTING_BROAD": "Broad capability match"
  of "SPECIALIST_REASONING": "Specialist reasoning"
  of "PRIMARY_RESPONSE": "Response"
  of "SYNTHESIS": "Combining results"
  of "REPAIR": "Protocol repair"
  of "NETWORKING": "Networking"
  of "NETWORKING_SELECTED": "Selected networking model"
  of "INVALID": "Invalid stage"
  else: "Unknown stage"

proc durationLabel*(value: Option[float]): string =
  if value.isNone: return "Not recorded"
  let duration = value.get
  if duration < 1000: formatFloat(duration, ffDecimal, 0) & " ms"
  elif duration < 60_000: formatFloat(duration / 1000, ffDecimal, 2) & " s"
  else: formatFloat(duration / 60_000, ffDecimal, 2) & " min"

proc tokenLabel*(value: Option[int]): string =
  if value.isSome: $value.get else: "Not recorded"
