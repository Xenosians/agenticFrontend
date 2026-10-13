include karax/prelude
import std/json
import ../app/[types, extension_bridge]

proc textField(label, value: string, change: proc(value: string), secret = false): VNode =
  result = buildHtml(tdiv(class = "form-field")):
    label: text label
    input(`type` = (if secret: cstring"password" else: cstring"text"), value = cstring(value)):
      proc oninput(event: Event, node: VNode) = change($node.value)

proc selection(state: AppState, key: string): string =
  if state.extensionCatalog != nil and state.extensionCatalog.hasKey("selected"):
    let value = state.extensionCatalog["selected"][key]
    if value.kind == JString: return value.getStr

proc renderConnections*(state: AppState): VNode =
  result = buildHtml(section(class = "conversation")):
    tdiv(class = "developer-view"):
      h2: text "Models, harnesses and datasets"
      p: text "Local models are the default. Your selections apply to future requests; networking keeps its existing model."
      button(disabled = state.extensionBusy):
        text "Refresh connections"
        proc onclick(event: Event, node: VNode) = discard refreshExtensions(state)
      if state.extensionBusy:
        p: text "Working..."
      if state.extensionError.len > 0:
        p(class = "error-message"): text state.extensionError
      if state.toastMessage.len > 0:
        p: text state.toastMessage
      if state.extensionCatalog != nil:
        h3: text "Use for this account"
        label: text "Model or harness"
        select(disabled = state.extensionBusy):
          option(value = "", selected = selection(state, "model_id") == ""): text "Default local models"
          for row in state.extensionCatalog["resources"]:
            if row["kind"].getStr == "model":
              option(value = cstring(row["id"].getStr), selected = selection(state, "model_id") == row["id"].getStr):
                text row["name"].getStr
          proc onchange(event: Event, node: VNode) =
            discard changeExtension(state, "select", %*{"model_id": $node.value, "dataset_id": selection(state, "dataset_id")})
        label: text "Reference dataset"
        select(disabled = state.extensionBusy):
          option(value = "", selected = selection(state, "dataset_id") == ""): text "No additional dataset"
          for row in state.extensionCatalog["resources"]:
            if row["kind"].getStr == "dataset" and row["purpose"].getStr == "rag":
              option(value = cstring(row["id"].getStr), selected = selection(state, "dataset_id") == row["id"].getStr): text row["name"].getStr
          proc onchange(event: Event, node: VNode) =
            discard changeExtension(state, "select", %*{"model_id": selection(state, "model_id"), "dataset_id": $node.value})
        h3: text "Add a connection"
        textField("Name", state.connectionName, proc(value: string) = state.connectionName = value)
        select(value = cstring(state.connectionBackend)):
          option(value = ""): text "Choose connection type"
          option(value = "http"): text "Model API"
          option(value = "local"): text "Installed local model"
          for row in state.extensionCatalog["harnesses"]:
            if row["available"].getBool:
              option(value = cstring(row["id"].getStr)): text row["id"].getStr
          proc onchange(event: Event, node: VNode) = state.connectionBackend = $node.value
        if state.connectionBackend == "local":
          select(value = cstring(state.connectionModel)):
            option(value = ""): text "Choose installed model"
            for row in state.extensionCatalog["local_profiles"]:
              option(value = cstring(row["id"].getStr)): text row["id"].getStr
            proc onchange(event: Event, node: VNode) = state.connectionModel = $node.value
        else:
          textField("Model identifier", state.connectionModel, proc(value: string) = state.connectionModel = value)
        if state.connectionBackend == "http":
          textField("API base URL", state.connectionUrl, proc(value: string) = state.connectionUrl = value)
        if state.connectionBackend in ["http", "pi", "opencode"]:
          textField("API key (optional for providers that allow it)", state.connectionKey, proc(value: string) = state.connectionKey = value, true)
        button(disabled = state.extensionBusy):
          text "Save connection"
          proc onclick(event: Event, node: VNode) =
            discard changeExtension(state, "model", %*{"name": state.connectionName, "backend": state.connectionBackend,
              "model": state.connectionModel, "url": state.connectionUrl, "api_key": state.connectionKey})
        h3: text "Upload a local model"
        p: text "Choose a Transformers model folder with safetensors weights and tokenizer files. Custom executable model code is not accepted."
        input(id = "modelFiles", `type` = "file", multiple = "multiple", webkitdirectory = "")
        button(disabled = state.extensionBusy):
          text "Upload model folder"
          proc onclick(event: Event, node: VNode) = discard uploadUserModel(state)
        h3: text "Add your dataset"
        textField("Dataset name", state.datasetName, proc(value: string) = state.datasetName = value)
        textField("Source or provenance", state.datasetSource, proc(value: string) = state.datasetSource = value)
        textField("License or permission to use", state.datasetLicense, proc(value: string) = state.datasetLicense = value)
        select(value = cstring(state.datasetPurpose)):
          option(value = ""): text "Choose dataset purpose"
          option(value = "rag"): text "Reference documents (RAG)"
          option(value = "training"): text "Reviewed training examples (JSONL)"
          proc onchange(event: Event, node: VNode) = state.datasetPurpose = $node.value
        input(id = "datasetFile", `type` = "file", accept = ".txt,.md,.jsonl")
        label:
          input(`type` = "checkbox", checked = state.datasetReviewed):
            proc onchange(event: Event, node: VNode) = state.datasetReviewed = not state.datasetReviewed
          text "I reviewed this dataset, removed secrets/personal identifiers, and have permission to use it."
        button(disabled = state.extensionBusy):
          text "Upload dataset"
          proc onclick(event: Event, node: VNode) = discard saveDatasetFile(state)
        textField("Or dataset API URL (returns text)", state.datasetText, proc(value: string) = state.datasetText = value)
        textField("Dataset API key (if required)", state.datasetApiKey, proc(value: string) = state.datasetApiKey = value, true)
        button(disabled = state.extensionBusy):
          text "Import from dataset API"
          proc onclick(event: Event, node: VNode) =
            discard changeExtension(state, "dataset_url", %*{"url": state.datasetText, "name": state.datasetName,
              "license": state.datasetLicense, "purpose": state.datasetPurpose, "reviewed": state.datasetReviewed, "api_key": state.datasetApiKey})
        h3: text "Saved resources"
        for row in state.extensionCatalog["resources"]:
          let item = row
          tdiv(class = "empty-card"):
            strong: text item["name"].getStr
            p: text item["kind"].getStr & " - " & item["state"].getStr
            if item["kind"].getStr == "model":
              button(disabled = state.extensionBusy):
                text "Test connection"
                proc onclick(event: Event, node: VNode) = discard changeExtension(state, "probe", %*{"id": item["id"].getStr})
            elif item["purpose"].getStr == "training":
              button(disabled = state.extensionBusy):
                text "Download reviewed training dataset"
                proc onclick(event: Event, node: VNode) = discard changeExtension(state, "export_dataset", %*{"id": item["id"].getStr})
            button(disabled = state.extensionBusy):
              text "Remove connection"
              proc onclick(event: Event, node: VNode) = discard changeExtension(state, "delete", %*{"id": item["id"].getStr})
        h3: text "Available capabilities"
        for row in state.extensionCatalog["capabilities"]:
          details:
            summary: text row["id"].getStr
            p: text row["description"].getStr
        h3: text "Automation connections"
        for row in state.extensionCatalog["connections"]:
          p: text row["id"].getStr & ": " & row["state"].getStr
