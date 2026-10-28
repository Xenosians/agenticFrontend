## The Learning surface (FR-087): choose a model and dataset version, then
## check readiness. Training, evaluation and promotion stay separate actions.
include karax/prelude
import karax/kdom
import ../app/types
import ../app/learning
import ../app/learning_bridge

proc selectField(state: AppState, field, label: string, value: string,
                 options: seq[(string, string, bool)]): VNode =
  ## `options` holds (value, label, enabled); a disabled option stays visible.
  let id = "learning" & field
  result = buildHtml(tdiv(class = "learning-field")):
    label(class = "review-label", `for` = cstring(id)): text label
    # Changing a field while a check runs discards that check (see learning_bridge).
    select(id = cstring(id), class = "learning-select"):
      for (optionValue, optionLabel, enabled) in options:
        option(value = cstring(optionValue), selected = optionValue == value, disabled = not enabled):
          text optionLabel
      proc onchange(event: Event, node: VNode) =
        changeLearningSelection(state, field, $node.value)
        redraw(kxi)

proc methodOptions(catalog: LearningCatalog): seq[(string, string, bool)] =
  for item in catalog.methods:
    let name = case item.id
      of "sft": "SFT · supervised fine-tuning"
      of "dpo": "DPO · preference optimization"
      else: "PPO · reinforcement on simulator episodes"
    result.add (item.id, name, true)

proc choiceOptions(values: seq[string]): seq[(string, string, bool)] =
  for value in values:
    let name = case value
      of "hub": "Hub"
      of "specialist": "Specialist"
      of "qlora": "QLoRA (4-bit)"
      of "lora": "LoRA"
      else: "Full fine-tuning"
    result.add (value, name, true)

proc modelOptions(catalog: LearningCatalog): seq[(string, string, bool)] =
  for item in catalog.models:
    let origin = if item.sourceKind == "local": "local weights" else: "outbound connection"
    result.add (item.id, item.name & " · " & origin, item.state == "ready")

proc datasetLabel(item: LearningDataset): string =
  item.name & " v" & $item.version & " · " & $item.trainCount & " training · " &
    $item.validationCount & " validation"

proc datasetOptions(catalog: LearningCatalog): seq[(string, string, bool)] =
  for item in catalog.datasets:
    var name = datasetLabel(item)
    var current = item.state == "ready" and item.supersededBy.len == 0
    if item.supersededBy.len > 0:
      for newer in catalog.datasets:
        if newer.id == item.supersededBy: name &= " · replaced by v" & $newer.version
    result.add (item.id, name, current)

proc renderReceipt(state: AppState): VNode =
  let receipt = state.learningPreflight
  var datasetText = ""
  for item in state.learningCatalog.datasets:
    if item.id == state.learningDataset: datasetText = datasetLabel(item)
  var entrypoint = ""
  for item in state.learningCatalog.methods:
    if item.id == receipt.methodId: entrypoint = item.entrypoint
  result = buildHtml(section(class = "learning-result", `aria-label` = "Readiness")):
    tdiv(class = "operation-job-heading"):
      strong: text "Not ready to train"
      span(class = "review-status"): text $receipt.blockers.len & " gates open"
    p(class = "knowledge-meta"): text datasetText
    p(class = "knowledge-meta"): text "Trainer " & entrypoint & " · resources " & receipt.resourceState
    ul(class = "learning-gates"):
      for code in receipt.blockers:
        li(class = "learning-gate", `data-gate` = cstring(code)): text learningGateLabel(code)
    p(class = "knowledge-meta"):
      span: text "Check "
      code(class = "knowledge-citation"): text receipt.sha256

proc renderLearningPanel*(state: AppState): VNode =
  let catalog = state.learningCatalog
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view learning-panel"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2: text "Learning"
          p: text "Choose a model and a training dataset version, then check what a candidate run still needs."
      p(class = "operation-note"):
        text "Checking readiness never starts training, loads a model or changes what serves your requests. Runs, evaluation and promotion are separate steps."
      if state.learningError.len > 0:
        p(class = "operation-error", role = "alert"): text state.learningError
      if state.learningBusy:
        p(class = "operation-note", role = "status"): text "Loading your models and datasets…"
      elif state.learningLoaded:
        if catalog.models.len == 0:
          tdiv(class = "empty-card"):
            text "No models yet. Add a local model or a connection under Connections."
        elif catalog.datasets.len == 0:
          tdiv(class = "empty-card"):
            text "No training datasets yet. Add one under Connections → Data & automation with the purpose Training."
        else:
          form(class = "learning-form"):
            proc onsubmit(event: Event, node: VNode) =
              event.preventDefault()
              discard preflightLearning(state)
            let contract = methodById(catalog, state.learningMethod)
            selectField(state, "method", "Method", state.learningMethod, methodOptions(catalog))
            selectField(state, "role", "Role", state.learningRole, choiceOptions(contract.roles))
            selectField(state, "tuning", "Adaptation", state.learningTuning, choiceOptions(contract.tuning))
            selectField(state, "model", "Model", state.learningModel, modelOptions(catalog))
            selectField(state, "dataset", "Dataset", state.learningDataset, datasetOptions(catalog))
            tdiv(class = "learning-actions"):
              button(`type` = "submit", class = "secondary-action", disabled = state.learningChecking):
                text (if state.learningChecking: "Checking…" else: "Check readiness")
          if state.learningPreflight.sha256.len > 0:
            renderReceipt(state)
