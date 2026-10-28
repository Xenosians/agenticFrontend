## Owner-scoped learning readiness data. These receipts never represent a run.
import std/[json, strutils, sets]

type
  LearningMethod* = object
    id*, entrypoint*, requires*: string
    roles*, tuning*: seq[string]
  LearningModel* = object
    id*, name*, backend*, state*, sourceKind*: string
  LearningDataset* = object
    id*, name*, state*, sha256*, lineageId*, supersededBy*: string
    version*, trainCount*, validationCount*: int
  LearningCatalog* = object
    methods*: seq[LearningMethod]
    models*: seq[LearningModel]
    datasets*: seq[LearningDataset]
  LearningPreflight* = object
    sha256*, methodId*, role*, tuning*, resourceState*: string
    blockers*: seq[string]

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
  if text(data, "schema") != "learning-catalog.v1": invalid()
  disabled(data, ["execution_enabled", "promotion_enabled"])
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
    disabled(row, ["training_available"])
    let source = text(row, "source_kind")
    if source notin ["local", "outbound"]: invalid()
    result.models.add LearningModel(id: identity, name: text(row, "name"), backend: text(row, "backend"),
      state: text(row, "state"), sourceKind: source)
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
  if text(data, "schema") != "learning-selection-preflight.v1" or text(data, "status") != "blocked": invalid()
  disabled(data, ["execution_enabled", "model_loaded", "live_tool_execution", "promotion_enabled"])
  let contract = methodById(catalog, text(request, "method"))
  let model = modelById(catalog, text(request, "model_id"))
  let dataset = datasetById(catalog, text(request, "dataset_id"))
  for key in ["method", "role", "tuning"]:
    if text(data, key) != text(request, key): invalid()
  if text(data, "entrypoint") != contract.entrypoint or text(data, "resource_state") != "unknown": invalid()
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
  if blockers.len == 0: invalid()
  LearningPreflight(sha256: digest(data, "preflight_sha256"), methodId: text(data, "method"),
    role: text(data, "role"), tuning: text(data, "tuning"), resourceState: "unknown", blockers: blockers)

proc learningGateLabel*(code: string): string =
  ## One label per blocker the AI service reports; an unknown code stays readable.
  case code
  of "trusted_model_identity_required": "Verify the model, tokenizer and prompt identities."
  of "trusted_training_configuration_required": "Admit a reviewed training configuration."
  of "fixed_evaluation_required": "Bind an independent, fixed evaluation set."
  of "resource_unknown": "Measure available memory against this training configuration."
  of "host_dispatch_not_integrated": "Candidate-run dispatch is not connected yet."
  of "separate_promotion_required": "Promotion needs a separate evaluated decision."
  of "outbound_connection_is_inference_only": "This connection uses an outbound model; training needs local weights."
  of "reviewed_preference_partitions_required": "Provide reviewed chosen/rejected preference pairs."
  of "evaluated_adapter_checkpoint_required": "Start from an evaluated adapter checkpoint (SFT, then DPO)."
  of "independent_simulator_episodes_required": "Provide independent simulator episodes; PPO never calls live tools."
  else: code.replace('_', ' ').capitalizeAscii() & "."
