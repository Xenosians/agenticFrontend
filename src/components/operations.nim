include karax/prelude
import std/[options, strutils]
import ../app/types
import ../app/operations_snapshot
import ../app/operations_bridge
import ../app/auth_bridge

proc localTimestamp(value: cstring): cstring {.
  importjs: "((v) => { const d = new Date(v); return Number.isNaN(d.getTime()) ? v : d.toLocaleString(); })(#)".}

proc measurement(label, value: string): VNode =
  result = buildHtml(tdiv(class = "operation-measurement")):
    span: text label
    strong: text value

proc renderMetric(metric: OperationMetric): VNode =
  result = buildHtml(tdiv(class = "operation-call")):
    tdiv(class = "operation-call-heading"):
      strong: text operationStageLabel(metric.stage)
      span(class = "operation-call-outcome"):
        text metric.outcome.replace("_", " ")
    p(class = "operation-note"):
      text (if metric.role.len > 0: metric.role else: "Workspace") & " · " & metric.adapter &
        " · " & (if metric.operation == "warm": "Warm-up" else: "Generate")
    if metric.repairOf.len > 0:
      p(class = "operation-note"):
        text "Repair of " & operationStageLabel(metric.repairOf)
    tdiv(class = "operation-measurements"):
      measurement("Call duration", durationLabel(some(metric.durationMs)))
      measurement("Scheduler wait", durationLabel(metric.queueMs))
      measurement("Execution", durationLabel(metric.executionMs))
      measurement("First token", durationLabel(metric.firstTokenMs))
      measurement("Generated tokens", tokenLabel(metric.generatedTokens))
      measurement("Estimated input tokens", tokenLabel(metric.estimatedInputTokens))
    details(class = "operation-call-limits"):
      summary: text "Request limits"
      tdiv(class = "operation-measurements"):
        measurement("Request token budget", tokenLabel(metric.requestTokenBudget))
        measurement("Output token cap", tokenLabel(metric.outputTokenCap))
        measurement("Dropped context messages", tokenLabel(metric.droppedMessages))

proc renderOperationJob(state: AppState, job: OperationJob): VNode =
  # One invocation owns each immutable task/chat target captured by handlers.
  result = buildHtml(article(class = "operation-job", `data-job-id` = cstring(job.jobId))):
    tdiv(class = "operation-job-heading"):
      tdiv:
        strong(class = "mono operation-job-id"): text job.jobId
        p(class = "operation-note"):
          text "Attempt " & $job.attempt & " · " &
            (if job.selectedAgent.len > 0: job.selectedAgent else: "No specialist selected")
      span(class = "capability-badge"): text operationStatusLabel(job.status)
    tdiv(class = "operation-measurements"):
      measurement("Until current worker started", durationLabel(job.queueWaitMs))
      measurement("Task elapsed", durationLabel(job.elapsedMs))
    p(class = "operation-note"):
      text "Submitted " & $localTimestamp(cstring(job.createdAt))
    tdiv(class = "operation-job-actions"):
      if job.chatId.len > 0:
        button(class = "secondary-action"):
          text "Open chat"
          proc onclick(event: Event, node: VNode) =
            discard selectChat(state, job.chatId)
      if job.metrics.len > 0:
        button(class = "secondary-action", `aria-expanded` =
            (if state.operationsExpandedJob == job.jobId: cstring"true" else: cstring"false")):
          text (if state.operationsExpandedJob == job.jobId: "Hide recorded calls" else: "Show recorded calls")
          proc onclick(event: Event, node: VNode) =
            state.operationsExpandedJob = if state.operationsExpandedJob == job.jobId: "" else: job.jobId
            redraw(kxi)
      else:
        span(class = "operation-note"): text "Inference timings: Not recorded"
    if state.operationsExpandedJob == job.jobId:
      section(class = "operation-calls"):
        h4: text "Recorded calls · " & $job.metrics.len
        p(class = "operation-note"):
          text "Call times may overlap. Task elapsed includes approval waits."
        if job.metricsTruncated:
          p(class = "operation-note", role = "status"):
            text "More recorded calls are not shown for this attempt."
        for metric in job.metrics:
          renderMetric(metric)

proc renderOperationsPanel*(state: AppState): VNode =
  result = buildHtml(tdiv(class = "developer-view operations-panel")):
    tdiv(class = "developer-view-header"):
      tdiv:
        h2: text "Operations"
        p: text "Your task queue and recorded inference timings."
      button(class = "secondary-action", disabled = state.operationsBusy, `aria-label` = "Refresh operations"):
        text (if state.operationsBusy: "Refreshing…" else: "Refresh")
        proc onclick(event: Event, node: VNode) =
          discard refreshOperations(state)
    if state.operationsError.len > 0:
      p(class = "operation-error", role = "alert"): text state.operationsError
    if state.operationsBusy and not state.operationsLoaded:
      p(class = "operation-note", role = "status"): text "Loading your operations…"
    elif not state.operationsLoaded:
      if state.operationsError.len == 0:
        p(class = "operation-note"): text "Refresh to load your operations."
    else:
      p(class = "operation-note operation-snapshot", role = "status"):
        text "Snapshot · " & $localTimestamp(cstring(state.operations.observedAt))
      tdiv(class = "operation-counts"):
        for index, status in operationStatuses:
          tdiv(class = "developer-card operation-count", `data-status` = cstring(status)):
            span(class = "run-label"): text operationStatusLabel(status)
            strong: text $state.operations.counts[index]
      tdiv(class = "section-heading-row"):
        h3: text "Recent tasks"
        span: text $state.operations.jobs.len & " shown"
      p(class = "operation-note"):
        text "Counts cover all your tasks. This list shows the most recent tasks."
      if state.operations.jobs.len == 0:
        tdiv(class = "empty-card"): text "No recent tasks were returned."
      else:
        for job in state.operations.jobs:
          renderOperationJob(state, job)
