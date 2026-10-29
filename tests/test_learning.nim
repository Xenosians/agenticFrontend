import std/[json, strutils, unittest]
import ../src/app/learning

let model = "a".repeat(32)
let remote = "b".repeat(32)
let current = "c".repeat(32)
let replaced = "d".repeat(32)
let digest = "1".repeat(64)
let check = "9".repeat(64)
let runId = "f".repeat(32)

proc methodRow(id: string, roles, tuning: seq[string], entrypoint: string): JsonNode =
  %*{"id": id, "roles": roles, "tuning": tuning, "entrypoint": entrypoint, "requires": "reviewed data"}

proc catalogJson(): JsonNode =
  %*{"schema": "learning-catalog.v2", "promotion_enabled": false,
     "methods": [methodRow("sft", @["hub", "specialist"], @["full", "lora", "qlora"], "scripts/train_recipe.py"),
                 methodRow("dpo", @["specialist"], @["qlora"], "scripts/train_preferences.py"),
                 methodRow("ppo", @["hub"], @["qlora"], "scripts/train_ppo.py")],
     "models": [
       {"id": model, "name": "Hub model", "backend": "local", "state": "ready", "source_kind": "local",
        "training_available": true},
       {"id": remote, "name": "Outbound model", "backend": "http", "state": "ready", "source_kind": "outbound",
        "training_available": false}],
     "datasets": [
       {"id": replaced, "name": "Ticket triage", "purpose": "training", "state": "ready", "sha256": "2".repeat(64),
        "lineage_id": replaced, "version": 1, "train_count": 10, "validation_count": 2, "superseded_by": current},
       {"id": current, "name": "Ticket triage", "purpose": "training", "state": "ready", "sha256": digest,
        "lineage_id": replaced, "version": 2, "train_count": 11, "validation_count": 2, "superseded_by": nil}]}

proc receiptJson(request: JsonNode, blockers: seq[string] = @[]): JsonNode =
  %*{"schema": "learning-selection-preflight.v2", "status": (if blockers.len == 0: "ready" else: "blocked"),
     "preflight_sha256": check,
     "method": request["method"], "role": request["role"], "tuning": request["tuning"],
     "entrypoint": "scripts/train_recipe.py",
     "model": {"id": model, "backend": "local", "source_kind": "local", "state": "ready"},
     "dataset": {"id": current, "sha256": digest, "lineage_id": replaced, "version": 2,
                 "train_count": 11, "validation_count": 2},
     "blockers": blockers, "later_gates": ["fixed_evaluation_required", "separate_promotion_required"],
     "model_loaded": false, "live_tool_execution": false, "promotion_enabled": false}

proc runJson(state = "running", step = 0, id = runId): JsonNode =
  result = %*{"schema": "learning-run.v2", "run_id": id, "state": state, "method": "sft", "role": "hub",
     "submission_id": id, "request_sha256": "7".repeat(64),
     "tuning": "qlora", "model": {"id": model, "backend": "local", "source_kind": "local"},
     "dataset": {"id": current, "sha256": digest, "version": 2, "train_count": 11, "validation_count": 2},
     "preflight_sha256": check, "progress": {"step": step, "max_steps": 9},
     "metrics": {"train_loss": nil, "validation_loss": nil}, "candidate_sha256": nil, "error": nil,
     "started_at": "2026-10-29T07:00:00+00:00", "finished_at": nil,
     "serving_changed": false, "promotion_enabled": false}
  if state notin activeLearningRunStates:
    result["finished_at"] = %"2026-10-29T07:10:00+00:00"
  if state == "completed":
    result["candidate_sha256"] = %"8".repeat(64)
    result["metrics"] = %*{"train_loss": 0.5, "validation_loss": 0.75}
  if state == "failed":
    result["error"] = %"insufficient_gpu_memory"

suite "learning catalog":
  test "methods, models and dataset versions are read with their identities":
    let catalog = parseLearningCatalog(catalogJson())
    check catalog.methods.len == 3
    check catalog.methods[2].roles == @["hub"]
    check catalog.models[0].trainingAvailable
    check not catalog.models[1].trainingAvailable
    check catalog.models[1].sourceKind == "outbound"
    check catalog.datasets[0].supersededBy == current
    check catalog.datasets[1].supersededBy == ""
    check catalog.datasets[1].version == 2

  test "a catalog that claims it can promote is refused":
    var data = catalogJson()
    data["promotion_enabled"] = %true
    expect ValueError: discard parseLearningCatalog(data)

  test "an outbound connection that claims it is trainable is refused":
    var data = catalogJson()
    data["models"][1]["training_available"] = %true
    expect ValueError: discard parseLearningCatalog(data)

  test "malformed catalogs are refused, never shown as empty":
    var unknownMethod = catalogJson()
    unknownMethod["methods"][0]["id"] = %"rag"
    var duplicate = catalogJson()
    duplicate["datasets"][1]["id"] = %replaced
    var shortDigest = catalogJson()
    shortDigest["datasets"][1]["sha256"] = %"abc"
    var noMethods = catalogJson()
    noMethods["methods"] = newJArray()
    var oldSchema = catalogJson()
    oldSchema["schema"] = %"learning-catalog.v1"
    for data in [unknownMethod, duplicate, shortDigest, noMethods, oldSchema, %*{"detail": "outage"}]:
      expect ValueError: discard parseLearningCatalog(data)

suite "learning readiness check":
  test "the request pins the current dataset version by digest":
    let catalog = parseLearningCatalog(catalogJson())
    check learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current) ==
      %*{"method": "sft", "role": "hub", "tuning": "qlora", "model_id": model,
         "dataset_id": current, "dataset_sha256": digest}

  test "only current datasets, ready models and supported settings can be checked":
    let catalog = parseLearningCatalog(catalogJson())
    expect ValueError: discard learningPreflightPayload(catalog, "sft", "hub", "qlora", model, replaced)
    expect ValueError: discard learningPreflightPayload(catalog, "sft", "hub", "qlora", "e".repeat(32), current)
    expect ValueError: discard learningPreflightPayload(catalog, "dpo", "hub", "qlora", model, current)
    expect ValueError: discard learningPreflightPayload(catalog, "ppo", "hub", "lora", model, current)
    expect ValueError: discard learningPreflightPayload(catalog, "rag", "hub", "qlora", model, current)

  test "a ready receipt for exactly this selection has no blockers":
    let catalog = parseLearningCatalog(catalogJson())
    let request = learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current)
    let receipt = parseLearningPreflight(receiptJson(request), request, catalog)
    check receipt.ready
    check receipt.blockers.len == 0
    check receipt.laterGates == @["fixed_evaluation_required", "separate_promotion_required"]
    check receipt.sha256 == check

  test "a blocked receipt lists its blockers":
    let catalog = parseLearningCatalog(catalogJson())
    let request = learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current)
    let receipt = parseLearningPreflight(receiptJson(request, @["local_weights_unavailable"]), request, catalog)
    check not receipt.ready
    check receipt.blockers == @["local_weights_unavailable"]

  test "a receipt for anything else, or with a contradictory status, is refused":
    let catalog = parseLearningCatalog(catalogJson())
    let request = learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current)
    var otherModel = receiptJson(request)
    otherModel["model"]["id"] = %remote
    var otherVersion = receiptJson(request)
    otherVersion["dataset"]["version"] = %1
    var loaded = receiptJson(request)
    loaded["model_loaded"] = %true
    var promoted = receiptJson(request)
    promoted["promotion_enabled"] = %true
    var readyWithBlockers = receiptJson(request, @["local_weights_unavailable"])
    readyWithBlockers["status"] = %"ready"
    var blockedWithout = receiptJson(request)
    blockedWithout["status"] = %"blocked"
    var otherMethod = receiptJson(request)
    otherMethod["tuning"] = %"lora"
    var noLaterGates = receiptJson(request)
    noLaterGates["later_gates"] = newJArray()
    for data in [otherModel, otherVersion, loaded, promoted, readyWithBlockers, blockedWithout, otherMethod,
                 noLaterGates]:
      expect ValueError: discard parseLearningPreflight(data, request, catalog)

  test "every blocker the AI service reports has a readable label":
    for code in ["local_weights_unavailable", "full_tuning_not_offered", "fixed_evaluation_required",
                 "host_dispatch_not_integrated", "separate_promotion_required",
                 "outbound_connection_is_inference_only", "reviewed_preference_partitions_required",
                 "evaluated_adapter_checkpoint_required", "independent_simulator_episodes_required"]:
      let label = learningGateLabel(code)
      check '_' notin label
      check label.endsWith(".")

suite "candidate runs":
  test "a run request is the checked selection with its check digest":
    let catalog = parseLearningCatalog(catalogJson())
    let request = learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current)
    let receipt = parseLearningPreflight(receiptJson(request), request, catalog)
    let body = learningRunPayload(request, receipt, runId)
    check body["preflight_sha256"].getStr == check
    check body["model_id"].getStr == model
    check body["submission_id"].getStr == runId
    check body.len == 8

  test "a blocked check cannot start a run":
    let catalog = parseLearningCatalog(catalogJson())
    let request = learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current)
    let receipt = parseLearningPreflight(receiptJson(request, @["local_weights_unavailable"]), request, catalog)
    expect ValueError: discard learningRunPayload(request, receipt, runId)

  test "runs are read with progress, metrics and outcome":
    let runs = parseLearningRuns(%*{"schema": "learning-runs.v2",
      "runs": [runJson("completed", 9, "e".repeat(32)), runJson("running", 3)]})
    check runs.len == 2
    check runs[0].state == "completed"
    check runs[0].candidateSha256 == "8".repeat(64)
    check runs[0].validationLoss == "0.750"
    check runs[1].step == 3 and runs[1].maxSteps == 9
    check runs[1].trainLoss == ""
    # The same run listed twice is a damaged list, not two runs.
    expect ValueError:
      discard parseLearningRuns(%*{"schema": "learning-runs.v2", "runs": [runJson(), runJson()]})

  test "a run that claims serving or promotion, or an impossible outcome, is refused":
    var serving = runJson()
    serving["serving_changed"] = %true
    var promoted = runJson()
    promoted["promotion_enabled"] = %true
    var noCandidate = runJson("completed", 9)
    noCandidate["candidate_sha256"] = newJNull()
    var unknownError = runJson("failed")
    unknownError["error"] = %"Traceback: private"
    var pastEnd = runJson("running", 10)
    var outbound = runJson()
    outbound["model"]["source_kind"] = %"outbound"
    for data in [serving, promoted, noCandidate, unknownError, pastEnd, outbound]:
      expect ValueError: discard parseLearningRun(data)

  test "every run state and error has a readable label":
    for state in ["starting", "running", "cancelling", "outcome_unknown", "completed", "failed", "interrupted", "cancelled"]:
      check learningRunStateLabel(state).len > 0
    for code in ["insufficient_gpu_memory", "chat_template_unsupported", "example_too_long", "cuda_unavailable",
                 "dataset_admission_failed", "training_failed", "trainer_unavailable"]:
      let label = learningRunErrorLabel(code)
      check '_' notin label
      check label.endsWith(".")

  test "a start receipt must match every immutable requested identity":
    let catalog = parseLearningCatalog(catalogJson())
    let selection = learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current)
    let receipt = parseLearningPreflight(receiptJson(selection), selection, catalog)
    let request = learningRunPayload(selection, receipt, runId)
    check parseStartedLearningRun(runJson(), request).submissionId == runId
    for key in ["submission_id", "preflight_sha256", "role", "tuning"]:
      var changed = runJson()
      changed[key] = %(case key
        of "submission_id": "e".repeat(32)
        of "preflight_sha256": "e".repeat(64)
        of "role": "specialist"
        else: "lora")
      expect ValueError: discard parseStartedLearningRun(changed, request)
    for key in ["id", "sha256"]:
      var changed = runJson()
      changed["dataset"][key] = %(if key == "id": "e".repeat(32) else: "e".repeat(64))
      expect ValueError: discard parseStartedLearningRun(changed, request)

  test "unfinished and legacy states cannot imply a newly confirmed request":
    for state in activeLearningRunStates:
      check parseLearningRun(runJson(state)).finishedAt == ""
      var finished = runJson(state)
      finished["finished_at"] = %"2026-10-29T07:10:00+00:00"
      expect ValueError: discard parseLearningRun(finished)
    var legacy = runJson()
    legacy["submission_id"] = newJNull()
    legacy["request_sha256"] = newJNull()
    check parseLearningRun(legacy).submissionId == ""
    let selection = %*{"method":"sft", "role":"hub", "tuning":"qlora", "model_id":model,
                       "dataset_id":current,"dataset_sha256":digest,"preflight_sha256":check,"submission_id":runId}
    expect ValueError: discard parseStartedLearningRun(legacy, selection)
