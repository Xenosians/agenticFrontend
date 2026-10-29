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
    let origin =
      if item.sourceKind == "outbound": "outbound connection"
      elif item.trainingAvailable: "local weights"
      else: "local weights unavailable on this host"
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
  let busy = learningRunActive(state)
  result = buildHtml(section(class = "learning-result", `aria-label` = "Readiness")):
    tdiv(class = "operation-job-heading"):
      strong: text (if receipt.ready: "Ready for a candidate run" else: "Not ready to train")
      span(class = "review-status"):
        text (if receipt.ready: "No blockers" else: $receipt.blockers.len & " blockers")
    p(class = "knowledge-meta"): text datasetText
    p(class = "knowledge-meta"): text "Trainer " & entrypoint
    if receipt.blockers.len > 0:
      ul(class = "learning-gates", `aria-label` = "Blockers"):
        for code in receipt.blockers:
          li(class = "learning-gate", `data-gate` = cstring(code)): text learningGateLabel(code)
    p(class = "knowledge-meta"): text "After a run, still required:"
    ul(class = "learning-gates learning-later", `aria-label` = "Later gates"):
      for code in receipt.laterGates:
        li(class = "learning-gate", `data-gate` = cstring(code)): text learningGateLabel(code)
    p(class = "knowledge-meta"):
      span: text "Check "
      code(class = "knowledge-citation"): text receipt.sha256
    if receipt.ready:
      tdiv(class = "learning-actions"):
        button(`type` = "button", class = "primary-action", disabled = state.learningStarting or busy):
          text (if state.learningStarting: "Starting…" else: "Start candidate run")
          proc onclick(event: Event, node: VNode) = discard startLearningRun(state)
      if busy:
        p(class = "operation-note", role = "status"): text "A run is already training on this host."

proc renderRun(state: AppState, run: LearningRun): VNode =
  let cancelling = state.learningCancelling == run.id
  result = buildHtml(li(class = "learning-run", `data-run` = cstring(run.id), `data-state` = cstring(run.state))):
    tdiv(class = "operation-job-heading"):
      strong: text "SFT · " & (if run.tuning == "qlora": "QLoRA" else: "LoRA") & " · dataset v" & $run.datasetVersion
      span(class = "review-status"): text learningRunStateLabel(run.state)
    tdiv(class = "learning-progress"):
      progress(max = cstring($run.maxSteps), value = cstring($run.step),
               `aria-label` = cstring("Training steps " & $run.step & " of " & $run.maxSteps))
      span(class = "knowledge-meta"): text "Step " & $run.step & " of " & $run.maxSteps
    p(class = "knowledge-meta"):
      text "Training loss " & (if run.trainLoss.len > 0: run.trainLoss else: "–") &
        " · validation loss " & (if run.validationLoss.len > 0: run.validationLoss else: "–")
    if run.error.len > 0:
      p(class = "operation-error", role = "alert"): text learningRunErrorLabel(run.error)
    if run.candidateSha256.len > 0:
      p(class = "knowledge-meta"):
        span: text "Candidate "
        code(class = "knowledge-citation"): text run.candidateSha256
      p(class = "operation-note"): text "Not serving. Evaluate and promote it separately."
    if run.state == "running":
      tdiv(class = "learning-actions"):
        button(`type` = "button", class = "secondary-action", disabled = state.learningCancelling.len > 0):
          text (if cancelling: "Cancelling…" else: "Cancel run")
          proc onclick(event: Event, node: VNode) = discard cancelLearningRun(state, run.id)

proc renderRuns(state: AppState): VNode =
  result = buildHtml(section(class = "learning-runs", `aria-label` = "Candidate runs")):
    tdiv(class = "operation-job-heading"):
      strong: text "Candidate runs"
      button(`type` = "button", class = "secondary-action"):
        text "Refresh"
        proc onclick(event: Event, node: VNode) = discard refreshLearningRuns(state)
    if state.learningRunError.len > 0:
      p(class = "operation-error", role = "alert"): text state.learningRunError
    if state.learningRuns.len == 0:
      p(class = "knowledge-meta"):
        text (if state.learningRunsLoaded: "No runs yet." else: "Loading runs…")
    else:
      ul(class = "learning-run-list"):
        for run in state.learningRuns:
          renderRun(state, run)

proc renderLearningPanel*(state: AppState): VNode =
  let catalog = state.learningCatalog
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view learning-panel"):
      tdiv(class = "developer-view-header"):
        tdiv:
          h2: text "Learning"
          p: text "Choose a model and a training dataset version, check readiness, then start a candidate run."
      p(class = "operation-note"):
        text "A candidate run trains an adapter on this host and never changes what serves your requests. Evaluation and promotion are separate steps."
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
      renderRuns(state)
