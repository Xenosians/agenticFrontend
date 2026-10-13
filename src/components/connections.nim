include karax/prelude

import std/[json, strutils]

import ../app/[types, extension_bridge]


proc nodeText(
  node: JsonNode,
  key: string
): string =

  if node != nil and
     node.kind == JObject and
     node.hasKey(key) and
     node[key].kind == JString:

    return node[key].getStr

  return ""


proc nodeBool(
  node: JsonNode,
  key: string
): bool =

  if node != nil and
     node.kind == JObject and
     node.hasKey(key) and
     node[key].kind == JBool:

    return node[key].getBool

  return false


proc arrayLength(
  state: AppState,
  key: string
): int =

  if state.extensionCatalog != nil and
     state.extensionCatalog.kind == JObject and
     state.extensionCatalog.hasKey(key) and
     state.extensionCatalog[key].kind == JArray:

    return state.extensionCatalog[key].len

  return 0


proc selection(
  state: AppState,
  key: string
): string =

  if state.extensionCatalog != nil and
     state.extensionCatalog.kind == JObject and
     state.extensionCatalog.hasKey("selected"):

    let selected =
      state.extensionCatalog["selected"]

    if selected.kind == JObject and
       selected.hasKey(key) and
       selected[key].kind == JString:

      return selected[key].getStr

  return ""


proc resourceName(
  state: AppState,
  resourceId: string,
  fallback: string
): string =

  if resourceId.len == 0:
    return fallback

  if state.extensionCatalog == nil or
     state.extensionCatalog.kind != JObject or
     not state.extensionCatalog.hasKey("resources"):

    return resourceId

  for row in state.extensionCatalog["resources"]:

    if nodeText(
         row,
         "id"
       ) == resourceId:

      let name =
        nodeText(
          row,
          "name"
        )

      if name.len > 0:
        return name

  return resourceId


proc matchesSearch(
  state: AppState,
  values: varargs[string]
): bool =

  let query =
    state.pluginSearchDraft
      .strip()
      .toLowerAscii()

  if query.len == 0:
    return true

  for value in values:

    if query in
       value.toLowerAscii():

      return true

  return false


proc setPluginSection(
  state: AppState,
  section: string
) =

  state.pluginSection =
    section

  redraw(kxi)


proc tabClass(
  state: AppState,
  section: string
): cstring =

  if state.pluginSection == section:
    cstring"plugin-tab active"
  else:
    cstring"plugin-tab"


proc textField(
  labelText: string,
  value: string,
  change: proc(value: string),
  secret = false,
  placeholder = ""
): VNode =

  result = buildHtml(
    tdiv(class = "plugin-field")
  ):

    label:
      text labelText

    input(
      `type` =
        if secret:
          cstring"password"
        else:
          cstring"text",

      value = cstring(value),
      placeholder = cstring(placeholder)
    ):

      proc oninput(
        event: Event,
        node: VNode
      ) =

        change(
          $node.value
        )


proc providerGlyph(
  id: string
): string =

  case id

  of "groq":
    "G"

  of "openrouter-free":
    "OR"

  of "ollama-local":
    "O"

  of "lm-studio-local":
    "LM"

  else:
    "AI"


proc resourceGlyph(
  row: JsonNode
): string =

  case nodeText(
         row,
         "kind"
       )

  of "model":
    "AI"

  of "dataset":
    "D"

  else:
    "P"


proc renderInstalledRail(
  state: AppState
): VNode =

  let
    selectedModel =
      selection(
        state,
        "model_id"
      )

    selectedDataset =
      selection(
        state,
        "dataset_id"
      )

  result = buildHtml(
    aside(class = "plugin-installed")
  ):

    tdiv(class = "plugin-installed-header"):

      strong:
        text "Installed"

      span:
        text (
          $arrayLength(
            state,
            "resources"
          )
        )

    button(
      class =
        if state.pluginSection == "personal":
          cstring"installed-item active"
        else:
          cstring"installed-item"
    ):

      span(class = "installed-icon"):
        text "AI"

      tdiv:

        strong:
          text resourceName(
            state,
            selectedModel,
            "Local models"
          )

        span:
          text "Active inference"

      proc onclick(
        event: Event,
        node: VNode
      ) =

        setPluginSection(
          state,
          "personal"
        )

    if selectedDataset.len > 0:

      button(
        class =
          if state.pluginSection == "data":
            cstring"installed-item active"
          else:
            cstring"installed-item"
      ):

        span(class = "installed-icon"):
          text "R"

        tdiv:

          strong:
            text resourceName(
              state,
              selectedDataset,
              "Reference dataset"
            )

          span:
            text "RAG reference"

        proc onclick(
          event: Event,
          node: VNode
        ) =

          setPluginSection(
            state,
            "data"
          )

    if state.extensionCatalog != nil and
       state.extensionCatalog.hasKey("resources"):

      for row in state.extensionCatalog["resources"]:

        let
          item = row
          itemName =
            nodeText(
              item,
              "name"
            )

        if matchesSearch(
             state,
             itemName,
             nodeText(item, "kind"),
             nodeText(item, "backend")
           ):

          button(
            class = "installed-item"
          ):

            span(class = "installed-icon"):
              text resourceGlyph(
                item
              )

            tdiv:

              strong:
                text itemName

              span:
                text (
                  nodeText(
                    item,
                    "kind"
                  ) &
                  " · " &
                  nodeText(
                    item,
                    "state"
                  )
                )

            proc onclick(
              event: Event,
              node: VNode
            ) =

              if nodeText(
                   item,
                   "kind"
                 ) == "dataset":

                setPluginSection(
                  state,
                  "data"
                )

              else:

                setPluginSection(
                  state,
                  "personal"
                )


proc renderCurrentSelection(
  state: AppState
): VNode =

  let
    modelId =
      selection(
        state,
        "model_id"
      )

    datasetId =
      selection(
        state,
        "dataset_id"
      )

  result = buildHtml(
    tdiv(class = "plugin-selection-grid")
  ):

    tdiv(class = "plugin-selection-card"):

      tdiv(class = "selection-heading"):

        span(class = "plugin-icon"):
          text "AI"

        tdiv:

          span:
            text "Active model"

          strong:
            text resourceName(
              state,
              modelId,
              "Default local models"
            )

      select(
        class = "plugin-select",
        disabled = state.extensionBusy
      ):

        option(
          value = "",
          selected =
            modelId == ""
        ):
          text "Default local models"

        for row in state.extensionCatalog["resources"]:

          if nodeText(
               row,
               "kind"
             ) == "model":

            option(
              value = cstring(
                nodeText(
                  row,
                  "id"
                )
              ),

              selected =
                nodeText(
                  row,
                  "id"
                ) == modelId
            ):

              text nodeText(
                row,
                "name"
              )

        proc onchange(
          event: Event,
          node: VNode
        ) =

          discard changeExtension(
            state,
            "select",
            %*{
              "model_id":
                $node.value,

              "dataset_id":
                datasetId
            }
          )

    tdiv(class = "plugin-selection-card"):

      tdiv(class = "selection-heading"):

        span(class = "plugin-icon"):
          text "R"

        tdiv:

          span:
            text "Reference data"

          strong:
            text resourceName(
              state,
              datasetId,
              "None"
            )

      select(
        class = "plugin-select",
        disabled = state.extensionBusy
      ):

        option(
          value = "",
          selected =
            datasetId == ""
        ):
          text "No additional dataset"

        for row in state.extensionCatalog["resources"]:

          if nodeText(
               row,
               "kind"
             ) == "dataset" and
             nodeText(
               row,
               "purpose"
             ) == "rag":

            option(
              value = cstring(
                nodeText(
                  row,
                  "id"
                )
              ),

              selected =
                nodeText(
                  row,
                  "id"
                ) == datasetId
            ):

              text nodeText(
                row,
                "name"
              )

        proc onchange(
          event: Event,
          node: VNode
        ) =

          discard changeExtension(
            state,
            "select",
            %*{
              "model_id":
                modelId,

              "dataset_id":
                $node.value
            }
          )


proc renderPublicProviders(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "plugin-content-section")
  ):

    tdiv(class = "plugin-section-heading"):

      tdiv:

        h3:
          text "Available providers"

        p:
          text "Inference providers that can be connected to this workspace."

    if not state.extensionCatalog.hasKey(
      "provider_presets"
    ):

      tdiv(class = "plugin-empty"):
        text "No provider presets are available."

    else:

      tdiv(class = "marketplace-grid"):

        for row in
            state.extensionCatalog[
              "provider_presets"
            ]:

          let
            preset = row
            name =
              nodeText(
                preset,
                "name"
              )

            description =
              nodeText(
                preset,
                "description"
              )

            model =
              nodeText(
                preset,
                "recommended_model"
              )

          if matchesSearch(
               state,
               name,
               description,
               model
             ):

            tdiv(class = "marketplace-card"):

              tdiv(class = "marketplace-card-main"):

                span(class = "marketplace-icon"):
                  text providerGlyph(
                    nodeText(
                      preset,
                      "id"
                    )
                  )

                tdiv:

                  strong:
                    text name

                  if model.len > 0:

                    span(class = "marketplace-model"):
                      text model

                  else:

                    span(class = "marketplace-model"):
                      text "Local endpoint"

              p:
                text description

              tdiv(class = "marketplace-card-footer"):

                if nodeBool(
                     preset,
                     "requires_api_key"
                   ):

                  span(class = "plugin-chip"):
                    text "API key"

                else:

                  span(class = "plugin-chip quiet"):
                    text "Local"

                button(
                  class = "plugin-add-small",
                  disabled = state.extensionBusy,
                  title = "Configure provider"
                ):

                  text "+"

                  proc onclick(
                    event: Event,
                    node: VNode
                  ) =

                    state.connectionName =
                      name

                    state.connectionBackend =
                      nodeText(
                        preset,
                        "backend"
                      )

                    state.connectionModel =
                      model

                    state.connectionUrl =
                      nodeText(
                        preset,
                        "url"
                      )

                    state.connectionKey =
                      ""

                    state.pluginSection =
                      "add"

                    redraw(kxi)


proc renderResourceActions(
  state: AppState,
  item: JsonNode
): VNode =

  result = buildHtml(
    tdiv(class = "personal-resource-actions")
  ):

    if nodeText(
         item,
         "kind"
       ) == "model":

      button(
        class = "plugin-action-button",
        disabled = state.extensionBusy
      ):

        text "Use"

        proc onclick(
          event: Event,
          node: VNode
        ) =

          discard changeExtension(
            state,
            "select",
            %*{
              "model_id":
                nodeText(
                  item,
                  "id"
                ),

              "dataset_id":
                selection(
                  state,
                  "dataset_id"
                )
            }
          )

      button(
        class = "plugin-action-button",
        disabled = state.extensionBusy
      ):

        text "Test"

        proc onclick(
          event: Event,
          node: VNode
        ) =

          discard changeExtension(
            state,
            "probe",
            %*{
              "id":
                nodeText(
                  item,
                  "id"
                )
            }
          )

    elif nodeText(
           item,
           "purpose"
         ) == "rag":

      button(
        class = "plugin-action-button",
        disabled = state.extensionBusy
      ):

        text "Use"

        proc onclick(
          event: Event,
          node: VNode
        ) =

          discard changeExtension(
            state,
            "select",
            %*{
              "model_id":
                selection(
                  state,
                  "model_id"
                ),

              "dataset_id":
                nodeText(
                  item,
                  "id"
                )
            }
          )

    elif nodeText(
           item,
           "purpose"
         ) == "training":

      button(
        class = "plugin-action-button",
        disabled = state.extensionBusy
      ):

        text "Export"

        proc onclick(
          event: Event,
          node: VNode
        ) =

          discard changeExtension(
            state,
            "export_dataset",
            %*{
              "id":
                nodeText(
                  item,
                  "id"
                )
            }
          )

    button(
      class = "plugin-action-button danger",
      disabled = state.extensionBusy
    ):

      text "Remove"

      proc onclick(
        event: Event,
        node: VNode
      ) =

        discard changeExtension(
          state,
          "delete",
          %*{
            "id":
              nodeText(
                item,
                "id"
              )
          }
        )


proc renderPersonal(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "plugin-content-section")
  ):

    tdiv(class = "plugin-section-heading"):

      tdiv:

        h3:
          text "Personal"

        p:
          text "Models and datasets connected specifically to your account."

    renderCurrentSelection(
      state
    )

    tdiv(class = "personal-resource-list"):

      var visible =
        0

      for row in
          state.extensionCatalog[
            "resources"
          ]:

        let
          item = row
          name =
            nodeText(
              item,
              "name"
            )

        if matchesSearch(
             state,
             name,
             nodeText(
               item,
               "kind"
             ),
             nodeText(
               item,
               "backend"
             ),
             nodeText(
               item,
               "state"
             )
           ):

          inc visible

          tdiv(class = "personal-resource-row"):

            span(class = "plugin-icon"):
              text resourceGlyph(
                item
              )

            tdiv(class = "personal-resource-copy"):

              strong:
                text name

              span:
                text (
                  nodeText(
                    item,
                    "kind"
                  ) &
                  " · " &
                  nodeText(
                    item,
                    "state"
                  )
                )

            renderResourceActions(
              state,
              item
            )

      if visible == 0:

        tdiv(class = "plugin-empty"):

          strong:
            text "Nothing here yet"

          p:
            text "Add a provider, local model, or dataset to create a personal resource."


proc renderConnectionForm(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "plugin-setup")
  ):

    tdiv(class = "plugin-setup-header"):

      button(
        class = "plugin-back-button"
      ):

        text "←"

        proc onclick(
          event: Event,
          node: VNode
        ) =

          setPluginSection(
            state,
            "public"
          )

      tdiv:

        h3:
          text "Add model connection"

        p:
          text "Connect a hosted model API, local model, or supported external harness."

    tdiv(class = "plugin-setup-card"):

      tdiv(class = "plugin-form-grid"):

        textField(
          "Name",
          state.connectionName,
          proc(value: string) =
            state.connectionName =
              value,
          placeholder =
            "Connection name"
        )

        tdiv(class = "plugin-field"):

          label:
            text "Connection type"

          select(
            class = "plugin-select",
            value = cstring(
              state.connectionBackend
            )
          ):

            option(value = ""):
              text "Choose connection type"

            option(value = "http"):
              text "Model API"

            option(value = "local"):
              text "Installed local model"

            for row in
                state.extensionCatalog[
                  "harnesses"
                ]:

              if nodeBool(
                   row,
                   "available"
                 ):

                option(
                  value = cstring(
                    nodeText(
                      row,
                      "id"
                    )
                  )
                ):

                  text nodeText(
                    row,
                    "id"
                  )

            proc onchange(
              event: Event,
              node: VNode
            ) =

              state.connectionBackend =
                $node.value

        if state.connectionBackend == "local":

          tdiv(class = "plugin-field"):

            label:
              text "Installed model"

            select(
              class = "plugin-select",
              value = cstring(
                state.connectionModel
              )
            ):

              option(value = ""):
                text "Choose installed model"

              for row in
                  state.extensionCatalog[
                    "local_profiles"
                  ]:

                option(
                  value = cstring(
                    nodeText(
                      row,
                      "id"
                    )
                  )
                ):

                  text nodeText(
                    row,
                    "id"
                  )

              proc onchange(
                event: Event,
                node: VNode
              ) =

                state.connectionModel =
                  $node.value

        else:

          textField(
            "Model identifier",
            state.connectionModel,
            proc(value: string) =
              state.connectionModel =
                value,
            placeholder =
              "Provider model identifier"
          )

        if state.connectionBackend == "http":

          textField(
            "API base URL",
            state.connectionUrl,
            proc(value: string) =
              state.connectionUrl =
                value,
            placeholder =
              "https://provider.example/v1"
          )

        if state.connectionBackend in [
          "http",
          "pi",
          "opencode"
        ]:

          textField(
            "API key",
            state.connectionKey,
            proc(value: string) =
              state.connectionKey =
                value,
            secret = true,
            placeholder =
              "Stored server-side"
          )

      tdiv(class = "plugin-form-footer"):

        tdiv:

          strong:
            text "Governed inference"

          span:
            text "This connection supplies model output only. Application tools remain behind Agentic policy and approvals."

        button(
          class = "plugin-primary",
          disabled = state.extensionBusy
        ):

          if state.extensionBusy:
            text "Saving…"
          else:
            text "Save connection"

          proc onclick(
            event: Event,
            node: VNode
          ) =

            discard changeExtension(
              state,
              "model",
              %*{
                "name":
                  state.connectionName,

                "backend":
                  state.connectionBackend,

                "model":
                  state.connectionModel,

                "url":
                  state.connectionUrl,

                "api_key":
                  state.connectionKey
              }
            )


proc renderLocalModelUpload(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "data-card")
  ):

    tdiv(class = "data-card-heading"):

      span(class = "plugin-icon"):
        text "AI"

      tdiv:

        strong:
          text "Local model"

        span:
          text "Transformers + safetensors"

    p:
      text "Upload a model folder. Executable custom model code is rejected."

    tdiv(class = "file-surface"):

      input(
        id = "modelFiles",
        `type` = "file",
        multiple = "multiple",
        webkitdirectory = ""
      )

      span:
        text "Choose model folder"

    button(
      class = "plugin-secondary",
      disabled = state.extensionBusy
    ):

      text "Upload"

      proc onclick(
        event: Event,
        node: VNode
      ) =

        discard uploadUserModel(
          state
        )


proc renderDatasetManager(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "data-card")
  ):

    tdiv(class = "data-card-heading"):

      span(class = "plugin-icon"):
        text "D"

      tdiv:

        strong:
          text "Dataset"

        span:
          text "RAG or reviewed training data"

    textField(
      "Name",
      state.datasetName,
      proc(value: string) =
        state.datasetName =
          value,
      placeholder =
        "Dataset name"
    )

    textField(
      "Source / provenance",
      state.datasetSource,
      proc(value: string) =
        state.datasetSource =
          value,
      placeholder =
        "Owned documentation"
    )

    textField(
      "License / permission",
      state.datasetLicense,
      proc(value: string) =
        state.datasetLicense =
          value,
      placeholder =
        "Internal / owned"
    )

    tdiv(class = "plugin-field"):

      label:
        text "Purpose"

      select(
        class = "plugin-select",
        value = cstring(
          state.datasetPurpose
        )
      ):

        option(value = ""):
          text "Choose purpose"

        option(value = "rag"):
          text "Reference documents (RAG)"

        option(value = "training"):
          text "Reviewed training examples"

        proc onchange(
          event: Event,
          node: VNode
        ) =

          state.datasetPurpose =
            $node.value

    input(
      id = "datasetFile",
      class = "dataset-file",
      `type` = "file",
      accept = ".txt,.md,.jsonl"
    )

    label(class = "dataset-review"):

      input(
        `type` = "checkbox",
        checked =
          state.datasetReviewed
      ):

        proc onchange(
          event: Event,
          node: VNode
        ) =

          state.datasetReviewed =
            not state.datasetReviewed

      span:
        text "Reviewed, sanitized, and permitted for use."

    button(
      class = "plugin-secondary",
      disabled = state.extensionBusy
    ):

      text "Upload dataset"

      proc onclick(
        event: Event,
        node: VNode
      ) =

        discard saveDatasetFile(
          state
        )

    details(class = "dataset-api"):

      summary:
        text "Import from API"

      tdiv(class = "dataset-api-body"):

        textField(
          "Dataset API URL",
          state.datasetText,
          proc(value: string) =
            state.datasetText =
              value,
          placeholder =
            "https://..."
        )

        textField(
          "API key",
          state.datasetApiKey,
          proc(value: string) =
            state.datasetApiKey =
              value,
          secret = true,
          placeholder =
            "Optional"
        )

        button(
          class = "plugin-secondary",
          disabled = state.extensionBusy
        ):

          text "Import"

          proc onclick(
            event: Event,
            node: VNode
          ) =

            discard changeExtension(
              state,
              "dataset_url",
              %*{
                "url":
                  state.datasetText,

                "name":
                  state.datasetName,

                "license":
                  state.datasetLicense,

                "purpose":
                  state.datasetPurpose,

                "reviewed":
                  state.datasetReviewed,

                "api_key":
                  state.datasetApiKey
              }
            )


proc renderDataAutomation(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "plugin-content-section")
  ):

    tdiv(class = "plugin-section-heading"):

      tdiv:

        h3:
          text "Data & automation"

        p:
          text "Bring your own local models, reference data, and future orchestration connections."

    tdiv(class = "data-grid"):

      renderLocalModelUpload(
        state
      )

      renderDatasetManager(
        state
      )

    tdiv(class = "automation-panel"):

      tdiv(class = "plugin-section-heading compact"):

        tdiv:

          h3:
            text "Automation connections"

          p:
            text "Prepared orchestration surfaces. Execution remains governed."

      if arrayLength(
           state,
           "connections"
         ) == 0:

        tdiv(class = "plugin-empty"):
          text "No automation connectors are currently exposed."

      else:

        for row in
            state.extensionCatalog[
              "connections"
            ]:

          tdiv(class = "automation-row"):

            span(class = "automation-dot"):
              text ""

            tdiv:

              strong:
                text nodeText(
                  row,
                  "id"
                )

              span:
                text nodeText(
                  row,
                  "state"
                )

    details(class = "developer-capabilities"):

      summary:

        tdiv:

          strong:
            text "Developer capabilities"

          span:
            text "Typed server-side capability catalog"

        span(class = "plugin-count"):
          text (
            $arrayLength(
              state,
              "capabilities"
            )
          )

      tdiv(class = "capability-grid"):

        for row in
            state.extensionCatalog[
              "capabilities"
            ]:

          if matchesSearch(
               state,
               nodeText(
                 row,
                 "id"
               ),
               nodeText(
                 row,
                 "description"
               )
             ):

            details(class = "capability-item"):

              summary:
                text nodeText(
                  row,
                  "id"
                )

              p:
                text nodeText(
                  row,
                  "description"
                )


proc renderMainContent(
  state: AppState
): VNode =

  result = buildHtml(
    main(class = "plugin-main")
  ):

    case state.pluginSection

    of "personal":

      renderPersonal(
        state
      )

    of "data":

      renderDataAutomation(
        state
      )

    of "add":

      renderConnectionForm(
        state
      )

    else:

      renderPublicProviders(
        state
      )


proc renderConnections*(
  state: AppState
): VNode =

  result = buildHtml(
    section(
      class =
        "conversation plugin-conversation"
    )
  ):

    tdiv(class = "plugin-library-page"):

      tdiv(class = "plugin-library-header"):

        tdiv:

          h2:
            text "Plugins"

          p:
            text "Connect models, data sources and automation services to your Agentic workspace."

        tdiv(class = "plugin-header-actions"):

          tdiv(class = "plugin-search"):

            span:
              text "⌕"

            input(
              `type` = "search",
              placeholder = "Search plugins",
              value = cstring(
                state.pluginSearchDraft
              )
            ):

              proc oninput(
                event: Event,
                node: VNode
              ) =

                state.pluginSearchDraft =
                  $node.value

                redraw(kxi)

          button(
            class = "plugin-icon-button",
            disabled = state.extensionBusy,
            title = "Refresh"
          ):

            text "↻"

            proc onclick(
              event: Event,
              node: VNode
            ) =

              discard refreshExtensions(
                state
              )

          button(
            class = "plugin-add-button",
            disabled = state.extensionBusy
          ):

            span:
              text "+"

            text "Add"

            proc onclick(
              event: Event,
              node: VNode
            ) =

              setPluginSection(
                state,
                "add"
              )

      tdiv(class = "plugin-tabs"):

        button(
          class =
            tabClass(
              state,
              "public"
            )
        ):

          text "Public"

          proc onclick(
            event: Event,
            node: VNode
          ) =

            setPluginSection(
              state,
              "public"
            )

        button(
          class =
            tabClass(
              state,
              "personal"
            )
        ):

          text "Personal"

          proc onclick(
            event: Event,
            node: VNode
          ) =

            setPluginSection(
              state,
              "personal"
            )

        button(
          class =
            tabClass(
              state,
              "data"
            )
        ):

          text "Data & automation"

          proc onclick(
            event: Event,
            node: VNode
          ) =

            setPluginSection(
              state,
              "data"
            )

      if state.extensionError.len > 0:

        tdiv(class = "plugin-notice error"):

          span:
            text "!"

          p:
            text state.extensionError

      elif state.toastMessage.len > 0:

        tdiv(class = "plugin-notice"):

          span:
            text "✓"

          p:
            text state.toastMessage

      if state.extensionCatalog == nil:

        tdiv(class = "plugin-loading"):

          span(class = "plugin-spinner"):
            text ""

          p:
            text "Loading plugins…"

      else:

        tdiv(class = "plugin-library-layout"):

          renderInstalledRail(
            state
          )

          renderMainContent(
            state
          )
