import std/[json, options, unittest]
import ../src/app/operations_snapshot
import ../src/app/state
import ../src/app/request_context

proc event(): JsonNode =
  %*{"event_id": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "attempt": 1,
    "recorded_at": "2026-10-26T09:00:00Z", "stage": "SPECIALIST_REASONING",
    "operation": "generate", "adapter": "local", "role": "fixture-specialist",
    "outcome": "success", "duration_ms": 1250, "queue_ms": 0, "execution_ms": 1250,
    "first_token_ms": nil, "generated_tokens": nil, "estimated_input_tokens": nil,
    "request_token_budget": nil, "output_token_cap": nil, "dropped_messages": nil, "repair_of": nil}

proc snapshot(): JsonNode =
  %*{"schema": "operations-snapshot.v1", "observed_at": "2026-10-26T09:00:00Z",
    "counts": {"pending": 9, "processing": 1, "waiting_approval": 2,
      "reconciliation_required": 0, "denied": 0, "outcome_unknown": 1, "completed": 20, "failed": 3},
    "jobs": [{"job_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "chat_id": "fixture-chat",
      "status": "processing", "attempt": 1, "selected_agent": "fixture-specialist",
      "created_at": "2026-10-26T08:00:00Z", "claimed_at": "2026-10-26T08:00:01Z", "completed_at": nil,
      "queue_wait_ms": 1000, "elapsed_ms": 3600000, "metrics_truncated": false, "metrics": [event()]}]}

suite "owner operations snapshots":
  test "all-task counts remain independent of the bounded recent list":
    let observed = parseOperationsSnapshot(snapshot())
    check observed.jobs.len == 1
    check observed.operationCount("pending") == 9
    check observed.operationCount("completed") == 20
    check observed.jobs[0].metrics[0].queueMs == some(0.0)
    check observed.jobs[0].metrics[0].generatedTokens.isNone
    var uploaded = snapshot()
    uploaded["jobs"][0]["metrics"][0]["adapter"] = %"hf-causal"
    check parseOperationsSnapshot(uploaded).jobs[0].metrics[0].adapter == "hf-causal"

  test "missing measurements stay unknown and measured zero remains zero":
    check durationLabel(none(float)) == "Not recorded"
    check durationLabel(some(0.0)) == "0 ms"
    check durationLabel(some(1250.0)) == "1.25 s"
    check durationLabel(some(120000.0)) == "2.00 min"
    check tokenLabel(none(int)) == "Not recorded"
    check tokenLabel(some(0)) == "0"
    var legacy = snapshot()
    legacy["jobs"][0]["metrics"] = newJArray()
    check parseOperationsSnapshot(legacy).jobs[0].metrics.len == 0

  test "missing or malformed counts cannot become a verified zero queue":
    for invalidValue in [newJInt(-1), newJString("0"), newJBool(false), newJNull()]:
      var invalid = snapshot()
      invalid["counts"]["pending"] = invalidValue
      expect ValueError: discard parseOperationsSnapshot(invalid)
    var missing = snapshot()
    missing["counts"].delete("pending")
    expect ValueError: discard parseOperationsSnapshot(missing)

  test "stale attempts, duplicate identities and unsupported stages reject the snapshot":
    var stale = snapshot()
    stale["jobs"][0]["metrics"][0]["attempt"] = %2
    expect ValueError: discard parseOperationsSnapshot(stale)
    var duplicate = snapshot()
    duplicate["jobs"].add(duplicate["jobs"][0])
    expect ValueError: discard parseOperationsSnapshot(duplicate)
    var duplicateEvent = snapshot()
    duplicateEvent["jobs"][0]["metrics"].add(event())
    expect ValueError: discard parseOperationsSnapshot(duplicateEvent)
    var unknownStage = snapshot()
    unknownStage["jobs"][0]["metrics"][0]["stage"] = %"arbitrary-provider-output"
    expect ValueError: discard parseOperationsSnapshot(unknownStage)

  test "bad timing and token values never become recorded measurements":
    for invalidValue in [newJInt(-1), newJString("0"), newJBool(false)]:
      var invalid = snapshot()
      invalid["jobs"][0]["metrics"][0]["duration_ms"] = invalidValue
      expect ValueError: discard parseOperationsSnapshot(invalid)
    var boolTokens = snapshot()
    boolTokens["jobs"][0]["metrics"][0]["generated_tokens"] = %true
    expect ValueError: discard parseOperationsSnapshot(boolTokens)
    var noDuration = snapshot()
    noDuration["jobs"][0]["metrics"][0]["duration_ms"] = newJNull()
    expect ValueError: discard parseOperationsSnapshot(noDuration)

  test "server bounds and protocol version are required":
    var rows = snapshot()
    for index in 1..100: rows["jobs"].add(snapshot()["jobs"][0])
    expect ValueError: discard parseOperationsSnapshot(rows)
    var events = snapshot()
    for index in 1..64: events["jobs"][0]["metrics"].add(event())
    expect ValueError: discard parseOperationsSnapshot(events)
    var version = snapshot()
    version["schema"] = %"operations-snapshot.v2"
    expect ValueError: discard parseOperationsSnapshot(version)

  test "late refreshes cannot cross owner, session, generation or confirmed sign-out":
    let state = initAppState()
    state.auth.authenticated = true
    state.auth.userId = "first-owner"
    state.auth.sessionId = "first-session"
    let first = beginOperationsRequest(state)
    check matchesOperationsRequest(state, first)
    let newer = beginOperationsRequest(state)
    check not matchesOperationsRequest(state, first)
    check matchesOperationsRequest(state, newer)
    state.auth.userId = "second-owner"
    check not matchesOperationsRequest(state, newer)
    state.auth.userId = "first-owner"
    state.auth.sessionId = "second-session"
    check not matchesOperationsRequest(state, newer)
    state.auth.sessionId = "first-session"
    state.operations = parseOperationsSnapshot(snapshot())
    state.operationsLoaded = true
    clearOperations(state)
    check not matchesOperationsRequest(state, newer)
    check not state.operationsLoaded
    check state.operations.jobs.len == 0
