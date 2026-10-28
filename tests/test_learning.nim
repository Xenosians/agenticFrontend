import std/[json, strutils, unittest]
import ../src/app/learning

let model = "a".repeat(32)
let remote = "b".repeat(32)
let current = "c".repeat(32)
let replaced = "d".repeat(32)
let digest = "1".repeat(64)

proc methodRow(id: string, roles, tuning: seq[string], entrypoint: string): JsonNode =
  %*{"id": id, "roles": roles, "tuning": tuning, "entrypoint": entrypoint, "requires": "reviewed data"}

proc catalogJson(): JsonNode =
  %*{"schema": "learning-catalog.v1", "execution_enabled": false, "promotion_enabled": false,
     "methods": [methodRow("sft", @["hub", "specialist"], @["full", "lora", "qlora"], "scripts/train_recipe.py"),
                 methodRow("dpo", @["specialist"], @["qlora"], "scripts/train_preferences.py"),
                 methodRow("ppo", @["hub"], @["qlora"], "scripts/train_ppo.py")],
     "models": [
       {"id": model, "name": "Hub model", "backend": "local", "state": "ready", "source_kind": "local",
        "training_available": false},
       {"id": remote, "name": "Outbound model", "backend": "http", "state": "ready", "source_kind": "outbound",
        "training_available": false}],
     "datasets": [
       {"id": replaced, "name": "Ticket triage", "purpose": "training", "state": "ready", "sha256": "2".repeat(64),
        "lineage_id": replaced, "version": 1, "train_count": 10, "validation_count": 2, "superseded_by": current},
       {"id": current, "name": "Ticket triage", "purpose": "training", "state": "ready", "sha256": digest,
        "lineage_id": replaced, "version": 2, "train_count": 11, "validation_count": 2, "superseded_by": nil}]}

proc receiptJson(request: JsonNode): JsonNode =
  %*{"schema": "learning-selection-preflight.v1", "status": "blocked", "preflight_sha256": "9".repeat(64),
     "method": request["method"], "role": request["role"], "tuning": request["tuning"],
     "entrypoint": "scripts/train_recipe.py", "resource_state": "unknown",
     "model": {"id": model, "backend": "local", "source_kind": "local", "state": "ready"},
     "dataset": {"id": current, "sha256": digest, "lineage_id": replaced, "version": 2,
                 "train_count": 11, "validation_count": 2},
     "blockers": ["fixed_evaluation_required", "host_dispatch_not_integrated"],
     "execution_enabled": false, "model_loaded": false, "live_tool_execution": false, "promotion_enabled": false}

suite "learning catalog":
  test "methods, models and dataset versions are read with their identities":
    let catalog = parseLearningCatalog(catalogJson())
    check catalog.methods.len == 3
    check catalog.methods[2].roles == @["hub"]
    check catalog.models[1].sourceKind == "outbound"
    check catalog.datasets[0].supersededBy == current
    check catalog.datasets[1].supersededBy == ""
    check catalog.datasets[1].version == 2

  test "a catalog that claims it can run or promote is refused":
    for key in ["execution_enabled", "promotion_enabled"]:
      var data = catalogJson()
      data[key] = %true
      expect ValueError: discard parseLearningCatalog(data)

  test "a model that claims it is trainable is refused":
    var data = catalogJson()
    data["models"][0]["training_available"] = %true
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
    for data in [unknownMethod, duplicate, shortDigest, noMethods, %*{"detail": "outage"}]:
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

  test "a receipt for exactly this selection lists its blockers":
    let catalog = parseLearningCatalog(catalogJson())
    let request = learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current)
    let receipt = parseLearningPreflight(receiptJson(request), request, catalog)
    check receipt.blockers == @["fixed_evaluation_required", "host_dispatch_not_integrated"]
    check receipt.resourceState == "unknown"
    check receipt.sha256 == "9".repeat(64)

  test "a receipt for anything else, or one that claims a run, is refused":
    let catalog = parseLearningCatalog(catalogJson())
    let request = learningPreflightPayload(catalog, "sft", "hub", "qlora", model, current)
    var otherModel = receiptJson(request)
    otherModel["model"]["id"] = %remote
    var otherVersion = receiptJson(request)
    otherVersion["dataset"]["version"] = %1
    var running = receiptJson(request)
    running["execution_enabled"] = %true
    var loaded = receiptJson(request)
    loaded["model_loaded"] = %true
    var ready = receiptJson(request)
    ready["status"] = %"ready"
    var unblocked = receiptJson(request)
    unblocked["blockers"] = newJArray()
    var otherMethod = receiptJson(request)
    otherMethod["tuning"] = %"lora"
    for data in [otherModel, otherVersion, running, loaded, ready, unblocked, otherMethod]:
      expect ValueError: discard parseLearningPreflight(data, request, catalog)

  test "every blocker the AI service reports has a readable label":
    for code in ["trusted_model_identity_required", "trusted_training_configuration_required",
                 "fixed_evaluation_required", "resource_unknown", "host_dispatch_not_integrated",
                 "separate_promotion_required", "outbound_connection_is_inference_only",
                 "reviewed_preference_partitions_required", "evaluated_adapter_checkpoint_required",
                 "independent_simulator_episodes_required"]:
      let label = learningGateLabel(code)
      check '_' notin label
      check label.endsWith(".")
