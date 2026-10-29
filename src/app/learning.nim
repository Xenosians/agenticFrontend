## Owner-scoped learning data: the catalog, readiness checks and candidate runs.
## A ready check can start one candidate run; nothing here serves or promotes a model.
import std/[json, strutils, sets, strformat]

type
  LearningMethod* = object
    id*, entrypoint*, requires*: string
    roles*, tuning*: seq[string]
  LearningModel* = object
    id*, name*, backend*, state*, sourceKind*: string
    trainingAvailable*: bool
  LearningDataset* = object
    id*, name*, state*, sha256*, lineageId*, supersededBy*: string
    version*, trainCount*, validationCount*: int
  LearningCatalog* = object
    methods*: seq[LearningMethod]
    models*: seq[LearningModel]
    datasets*: seq[LearningDataset]
  LearningPreflight* = object
    sha256*, methodId*, role*, tuning*: string
    ready*: bool
    blockers*, laterGates*: seq[string]
  LearningRun* = object
    id*, state*, role*, tuning*, modelId*, datasetId*, error*, candidateSha256*: string
    trainLoss*, validationLoss*, startedAt*, finishedAt*: string
    datasetVersion*, step*, maxSteps*: int

const
  laterGateCodes = ["fixed_evaluation_required", "separate_promotion_required"]
  runStates = ["running", "completed", "failed", "interrupted", "cancelled"]
  runErrors = ["insufficient_gpu_memory", "chat_template_unsupported", "example_too_long", "cuda_unavailable",
               "dataset_admission_failed", "training_failed", "trainer_unavailable"]

proc invalid(message = "The learning response was invalid. Refresh to check again.") =
  raise newException(ValueError, message)

proc field(node: JsonNode, key: string): JsonNode =
  if node == nil or node.kind != JObject or not node.hasKey(key): invalid()
  node[key]

proc text(node: JsonNode, key: string): string =
  let value = field(node, key)
  if value.kind != JString or value.getStr.len == 0 or value.getStr.len > 1000: invalid()
  value.getStr

proc count(node: JsonNode, key: string, minimum = 0): int =
  let value = field(node, key)
  if value.kind != JInt or value.getInt < minimum: invalid()
  value.getInt

proc disabled(node: JsonNode, keys: openArray[string]) =
  for key in keys:
    let value = field(node, key)
    if value.kind != JBool or value.getBool: invalid()

proc digest(node: JsonNode, key: string): string =
  result = text(node, key)
  if result.len != 64 or not result.allCharsInSet({'0'..'9', 'a'..'f'}): invalid()

proc rows(node: JsonNode, key: string): seq[JsonNode] =
  let value = field(node, key)
  if value.kind != JArray or value.len > 1000: invalid()
  for row in value: result.add row

proc choices(node: JsonNode, key: string, allowed: openArray[string]): seq[string] =
  for value in rows(node, key):
    if value.kind != JString or value.getStr notin allowed or value.getStr in result: invalid()
    result.add value.getStr
  if result.len == 0: invalid()

proc unique(ids: var HashSet[string], identity: string) =
  if identity in ids: invalid()
  ids.incl identity

proc parseLearningCatalog*(data: JsonNode): LearningCatalog =
  if text(data, "schema") != "learning-catalog.v2": invalid()
  disabled(data, ["promotion_enabled"])
  var methods, models, datasets = initHashSet[string]()
  for row in rows(data, "methods"):
    let identity = text(row, "id")
    if identity notin ["sft", "dpo", "ppo"]: invalid()
    unique(methods, identity)
    result.methods.add LearningMethod(id: identity, entrypoint: text(row, "entrypoint"),
      requires: text(row, "requires"), roles: choices(row, "roles", ["hub", "specialist"]),
      tuning: choices(row, "tuning", ["full", "lora", "qlora"]))
  if methods.len == 0: invalid()
  for row in rows(data, "models"):
    let identity = text(row, "id")
    unique(models, identity)
    let source = text(row, "source_kind")
    if source notin ["local", "outbound"]: invalid()
    let available = field(row, "training_available")
    if available.kind != JBool or (available.getBool and source != "local"): invalid()
    result.models.add LearningModel(id: identity, name: text(row, "name"), backend: text(row, "backend"),
      state: text(row, "state"), sourceKind: source, trainingAvailable: available.getBool)
  for row in rows(data, "datasets"):
    let identity = text(row, "id")
    unique(datasets, identity)
    if text(row, "purpose") != "training": invalid()
    let replaced = field(row, "superseded_by")
    if replaced.kind notin {JString, JNull}: invalid()
    if replaced.kind == JString and replaced.getStr.len == 0: invalid()
    result.datasets.add LearningDataset(id: identity, name: text(row, "name"), state: text(row, "state"),
      sha256: digest(row, "sha256"), lineageId: text(row, "lineage_id"), version: count(row, "version", 1),
      trainCount: count(row, "train_count"), validationCount: count(row, "validation_count"),
      supersededBy: (if replaced.kind == JString: replaced.getStr else: ""))

proc methodById*(catalog: LearningCatalog, identity: string): LearningMethod =
  for item in catalog.methods:
    if item.id == identity: return item
  raise newException(ValueError, "Choose a learning method.")

proc modelById*(catalog: LearningCatalog, identity: string): LearningModel =
  for item in catalog.models:
    if item.id == identity and item.state == "ready": return item
  raise newException(ValueError, "Choose a ready model from your connections.")

proc datasetById*(catalog: LearningCatalog, identity: string): LearningDataset =
  for item in catalog.datasets:
    if item.id == identity and item.state == "ready" and item.supersededBy.len == 0: return item
  raise newException(ValueError, "Choose a current training dataset.")

proc learningPreflightPayload*(catalog: LearningCatalog, methodId, role, tuning, modelId, datasetId: string): JsonNode =
  let contract = methodById(catalog, methodId)
  discard modelById(catalog, modelId)
  let dataset = datasetById(catalog, datasetId)
  if role notin contract.roles or tuning notin contract.tuning:
    raise newException(ValueError, "Choose a supported role and adaptation setting.")
  %*{"method": methodId, "role": role, "tuning": tuning, "model_id": modelId,
     "dataset_id": datasetId, "dataset_sha256": dataset.sha256}

proc parseLearningPreflight*(data, request: JsonNode, catalog: LearningCatalog): LearningPreflight =
  if text(data, "schema") != "learning-selection-preflight.v2": invalid()
  let status = text(data, "status")
  if status notin ["ready", "blocked"]: invalid()
  disabled(data, ["model_loaded", "live_tool_execution", "promotion_enabled"])
  let contract = methodById(catalog, text(request, "method"))
  let model = modelById(catalog, text(request, "model_id"))
  let dataset = datasetById(catalog, text(request, "dataset_id"))
  for key in ["method", "role", "tuning"]:
    if text(data, key) != text(request, key): invalid()
  if text(data, "entrypoint") != contract.entrypoint: invalid()
  let modelReceipt = field(data, "model")
  for pair in [("id", model.id), ("backend", model.backend), ("source_kind", model.sourceKind), ("state", model.state)]:
    if text(modelReceipt, pair[0]) != pair[1]: invalid()
  let datasetReceipt = field(data, "dataset")
  for pair in [("id", dataset.id), ("sha256", dataset.sha256), ("lineage_id", dataset.lineageId)]:
    if text(datasetReceipt, pair[0]) != pair[1]: invalid()
  for pair in [("version", dataset.version), ("train_count", dataset.trainCount), ("validation_count", dataset.validationCount)]:
    if count(datasetReceipt, pair[0]) != pair[1]: invalid()
  var blockers: seq[string]
  for blocker in rows(data, "blockers"):
    if blocker.kind != JString or blocker.getStr.len == 0 or blocker.getStr.len > 200 or blocker.getStr in blockers: invalid()
    blockers.add blocker.getStr
  # Ready means nothing blocks a run; anything else must say what does.
  if (status == "ready") != (blockers.len == 0): invalid()
  let laterGates = choices(data, "later_gates", laterGateCodes)
  if laterGates != @laterGateCodes: invalid()
  LearningPreflight(sha256: digest(data, "preflight_sha256"), methodId: text(data, "method"),
    role: text(data, "role"), tuning: text(data, "tuning"), ready: status == "ready", blockers: blockers,
    laterGates: laterGates)

proc learningRunPayload*(request: JsonNode, receipt: LearningPreflight): JsonNode =
  ## A run starts only from the exact ready check the owner saw.
  if not receipt.ready or receipt.sha256.len != 64:
    raise newException(ValueError, "Check readiness again before starting a run.")
  result = copy(request)
  result["preflight_sha256"] = %receipt.sha256

proc optionalText(node: JsonNode, key: string): string =
  let value = field(node, key)
  if value.kind == JNull: return ""
  if value.kind != JString or value.getStr.len == 0 or value.getStr.len > 200: invalid()
  value.getStr

proc loss(node: JsonNode, key: string): string =
  let value = field(node, key)
  case value.kind
  of JNull: ""
  of JInt: (if value.getInt < 0: (invalid(); "") else: &"{value.getInt.float:.3f}")
  of JFloat: (if value.getFloat < 0: (invalid(); "") else: &"{value.getFloat:.3f}")
  else: (invalid(); "")

proc parseLearningRun*(row: JsonNode): LearningRun =
  if text(row, "schema") != "learning-run.v1" or text(row, "method") != "sft": invalid()
  disabled(row, ["serving_changed", "promotion_enabled"])
  result.id = text(row, "run_id")
  if result.id.len != 32 or not result.id.allCharsInSet({'0'..'9', 'a'..'f'}): invalid()
  result.state = text(row, "state")
  if result.state notin runStates: invalid()
  result.role = text(row, "role")
  result.tuning = text(row, "tuning")
  if result.role notin ["hub", "specialist"] or result.tuning notin ["lora", "qlora"]: invalid()
  let model = field(row, "model")
  if text(model, "source_kind") != "local": invalid()
  result.modelId = text(model, "id")
  let dataset = field(row, "dataset")
  result.datasetId = text(dataset, "id")
  discard digest(dataset, "sha256")
  result.datasetVersion = count(dataset, "version", 1)
  discard digest(row, "preflight_sha256")
  let progress = field(row, "progress")
  result.maxSteps = count(progress, "max_steps", 1)
  result.step = count(progress, "step")
  if result.step > result.maxSteps: invalid()
  let metrics = field(row, "metrics")
  result.trainLoss = loss(metrics, "train_loss")
  result.validationLoss = loss(metrics, "validation_loss")
  result.startedAt = text(row, "started_at")
  result.finishedAt = optionalText(row, "finished_at")
  result.error = optionalText(row, "error")
  result.candidateSha256 = optionalText(row, "candidate_sha256")
  # Only a completed run has a candidate; only a failed one has an error; only an active one is unfinished.
  if (result.state == "running") != (result.finishedAt.len == 0): invalid()
  if (result.state == "completed") != (result.candidateSha256.len > 0): invalid()
  if result.candidateSha256.len > 0: discard digest(row, "candidate_sha256")
  if (result.state == "failed") != (result.error.len > 0): invalid()
  if result.error.len > 0 and result.error notin runErrors: invalid()

proc parseLearningRuns*(data: JsonNode): seq[LearningRun] =
  if text(data, "schema") != "learning-runs.v1": invalid()
  var ids = initHashSet[string]()
  for row in rows(data, "runs"):
    let run = parseLearningRun(row)
    unique(ids, run.id)
    result.add run

proc learningRunStateLabel*(state: string): string =
  case state
  of "running": "Training"
  of "completed": "Candidate ready"
  of "failed": "Failed"
  of "interrupted": "Interrupted"
  of "cancelled": "Cancelled"
  else: state

proc learningRunErrorLabel*(code: string): string =
  case code
  of "insufficient_gpu_memory": "Not enough free GPU memory for this model."
  of "chat_template_unsupported": "This model's chat template cannot separate prompts from answers."
  of "example_too_long": "An example is longer than the training sequence limit."
  of "cuda_unavailable": "No GPU is available for training."
  of "dataset_admission_failed": "The dataset version failed training admission."
  of "trainer_unavailable": "The trainer could not be started."
  else: "Training failed. The trainer log on the host has details."

proc learningGateLabel*(code: string): string =
  ## One label per blocker or later gate the AI service reports; an unknown code stays readable.
  case code
  of "local_weights_unavailable": "This host cannot read the model's weights; add or re-upload the model."
  of "full_tuning_not_offered": "Full fine-tuning is not offered here; choose LoRA or QLoRA."
  of "fixed_evaluation_required": "Evaluate the candidate on a fixed, independent set."
  of "host_dispatch_not_integrated": "Runs of this method cannot be started from the web yet."
  of "separate_promotion_required": "Serving a candidate needs a separate, evaluated decision."
  of "outbound_connection_is_inference_only": "This connection uses an outbound model; training needs local weights."
  of "reviewed_preference_partitions_required": "Provide reviewed chosen/rejected preference pairs."
  of "evaluated_adapter_checkpoint_required": "Start from an evaluated adapter checkpoint (SFT, then DPO)."
  of "independent_simulator_episodes_required": "Provide independent simulator episodes; PPO never calls live tools."
  else: code.replace('_', ' ').capitalizeAscii() & "."
