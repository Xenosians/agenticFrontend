include karax/prelude

import std/[json, strutils]

import ../app/[types, extension_bridge]
import ../app/connection_draft
import ../api/connection_options


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


proc resetConnectionOptions(state: AppState) =
  state.clearUsageDraft()

proc optionText(item: JsonNode, key: string): string =
  if item != nil and item.kind == JObject and item.hasKey(key):
    case item[key].kind
    of JString: return item[key].getStr
    of JInt, JFloat: return $item[key]
    else: discard
  return ""

proc renderUsageControls(state: AppState): VNode =
  result = buildHtml(tdiv(class = "plugin-form-grid")):
    textField("Provider tokens per minute", state.connectionTpm,
      proc(value: string) = state.connectionTpm = value,
      placeholder = "Optional: your account's limit")
    textField("Provider requests per minute", state.connectionRpm,
      proc(value: string) = state.connectionRpm = value,
      placeholder = "Optional: your account's limit")
    textField("Maximum queue wait (seconds)", state.connectionMaxWait,
      proc(value: string) = state.connectionMaxWait = value,
      placeholder = "Leave empty for the server default")
    let efforts = reasoningEffortsFor(state.extensionCatalog, state.connectionBackend,
                                      state.connectionModel, state.connectionUrl)
    if efforts.len > 0:
      tdiv(class = "plugin-field"):
        label:
          text "Reasoning effort"
        select(class = "plugin-select", value = cstring(state.connectionReasoning)):
          option(value = ""): text "Provider default"
          for effort in efforts:
            option(value = cstring(effort)): text effort.capitalizeAscii()
          proc onchange(event: Event, node: VNode) =
            state.connectionReasoning = $node.value
      tdiv(class = "plugin-field-hint plugin-field-wide"):
        text "Reasoning effort is optional and must be supported by this model and connection."
    tdiv(class = "plugin-field-hint plugin-field-wide"):
      text "Use the limits from your provider account. Connections sharing a credential and model share the queue. Leave limits empty when unknown."

proc renderUsageSettings(state: AppState): VNode =
  result = buildHtml(tdiv(class = "plugin-content-section")):
    h3: text "Usage settings: " & state.connectionName
    p: text "Adjust provider limits without entering your API key again."
    renderUsageControls(state)
    button(class = "plugin-primary", disabled = state.extensionBusy):
      text (if state.extensionBusy: "Saving…" else: "Save settings")
      proc onclick(event: Event, node: VNode) =
        discard saveConnectionOptions(state, existing = true)
    button(class = "plugin-action-button", disabled = state.extensionBusy):
      text "Back to connections"
      proc onclick(event: Event, node: VNode) =
        setPluginSection(state, "personal")

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

                    resetConnectionOptions(state)

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

      if nodeText(item, "backend") in ["http", "pi", "opencode"]:
        button(class = "plugin-action-button", disabled = state.extensionBusy):
          text "Usage settings"
          proc onclick(event: Event, node: VNode) =
            state.connectionOptionsId = nodeText(item, "id")
            state.connectionName = nodeText(item, "name")
            state.connectionBackend = nodeText(item, "backend")
            state.connectionModel = nodeText(item, "model")
            state.connectionUrl = nodeText(item, "url")
            state.connectionTpm = optionText(item, "provider_tokens_per_minute")
            state.connectionRpm = optionText(item, "provider_requests_per_minute")
            state.connectionMaxWait = optionText(item, "admission_max_wait_seconds")
            state.connectionReasoning = optionText(item, "reasoning_effort")
            state.connectionKey = ""
            setPluginSection(state, "limits")

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


proc connectionPresetId(
  state: AppState
): string =

  if state.extensionCatalog == nil or
     state.extensionCatalog.kind != JObject or
     not state.extensionCatalog.hasKey(
       "connection_presets"
     ):

    return ""

  for row in
      state.extensionCatalog[
        "connection_presets"
      ]:

    if nodeText(
         row,
         "backend"
       ) != state.connectionBackend:

      continue

    if nodeText(
         row,
         "model"
       ) != state.connectionModel:

      continue

    if state.connectionBackend == "http" and
       nodeText(
         row,
         "url"
       ) != state.connectionUrl:

      continue

    return nodeText(
      row,
      "id"
    )

  return ""


proc applyConnectionPreset(
  state: AppState,
  presetId: string
) =

  if presetId.len == 0:
    return

  if state.extensionCatalog == nil or
     state.extensionCatalog.kind != JObject or
     not state.extensionCatalog.hasKey(
       "connection_presets"
     ):

    return

  for row in
      state.extensionCatalog[
        "connection_presets"
      ]:

    if nodeText(
         row,
         "id"
       ) != presetId:

      continue

    state.connectionName =
      nodeText(
        row,
        "name"
      )

    state.connectionBackend =
      nodeText(
        row,
        "backend"
      )

    state.connectionModel =
      nodeText(
        row,
        "model"
      )

    state.connectionUrl =
      nodeText(
        row,
        "url"
      )

    # Never carry a credential from one provider
    # selection into another provider selection.
    state.connectionKey =
      ""

    resetConnectionOptions(state)

    redraw(kxi)

    return


proc connectionRequiresCredential(
  state: AppState
): bool =

  let presetId =
    connectionPresetId(
      state
    )

  if presetId.len > 0 and
     state.extensionCatalog != nil and
     state.extensionCatalog.hasKey(
       "connection_presets"
     ):

    for row in
        state.extensionCatalog[
          "connection_presets"
        ]:

      if nodeText(
           row,
           "id"
         ) == presetId:

        return nodeBool(
          row,
          "requires_api_key"
        )

  if state.connectionBackend in [
    "pi",
    "opencode"
  ]:

    return true

  if state.connectionBackend == "http":

    return not (
      state.connectionUrl.startsWith(
        "http://127.0.0.1:"
      )
    )

  return false


proc connectionCredentialLabel(
  state: AppState
): string =

  let presetId =
    connectionPresetId(
      state
    )

  if presetId.len > 0 and
     state.extensionCatalog != nil and
     state.extensionCatalog.hasKey(
       "connection_presets"
     ):

    for row in
        state.extensionCatalog[
          "connection_presets"
        ]:

      if nodeText(
           row,
           "id"
         ) == presetId:

        let label =
          nodeText(
            row,
            "credential_label"
          )

        if label.len > 0:
          return label

  return "Provider API key"


proc renderConnectionForm(
  state: AppState
): VNode =

  let
    presetId =
      connectionPresetId(
        state
      )

    credentialRequired =
      connectionRequiresCredential(
        state
      )

    credentialLabel =
      connectionCredentialLabel(
        state
      )

    missingCredential =
      credentialRequired and
      state.connectionKey
        .strip()
        .len == 0

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
          text "Choose a known provider path or configure one manually."

    tdiv(class = "plugin-setup-card"):

      tdiv(class = "plugin-provider-callout"):

        strong:
          text "Provider path"

        span:
          text "Pi and OpenCode are isolated inference harnesses. Their API credential still belongs to the underlying provider."

      tdiv(class = "plugin-form-grid"):

        tdiv(class = "plugin-field plugin-field-wide"):

          label:
            text "Connection preset"

          select(
            class = "plugin-select",
            value = cstring(
              presetId
            )
          ):

            option(
              value = "",
              selected =
                presetId.len == 0
            ):
              text "Custom / manual"

            if state.extensionCatalog != nil and
               state.extensionCatalog.hasKey(
                 "connection_presets"
               ):

              for row in
                  state.extensionCatalog[
                    "connection_presets"
                  ]:

                let preset =
                  row

                option(
                  value = cstring(
                    nodeText(
                      preset,
                      "id"
                    )
                  ),
                  selected =
                    nodeText(
                      preset,
                      "id"
                    ) == presetId
                ):

                  text nodeText(
                    preset,
                    "name"
                  )

            proc onchange(
              event: Event,
              node: VNode
            ) =

              let selected =
                $node.value

              if selected.len > 0:

                applyConnectionPreset(
                  state,
                  selected
                )

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
              text "Direct model API"

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

                let harnessId =
                  nodeText(
                    row,
                    "id"
                  )

                option(
                  value = cstring(
                    harnessId
                  )
                ):

                  if harnessId == "pi":
                    text "Pi harness"
                  elif harnessId == "opencode":
                    text "OpenCode harness"
                  else:
                    text harnessId

            proc onchange(
              event: Event,
              node: VNode
            ) =

              state.connectionBackend =
                $node.value

              state.connectionKey = ""
              resetConnectionOptions(state)

              redraw(kxi)

        if state.connectionBackend == "local":

          tdiv(class = "plugin-field plugin-field-wide"):

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

                if reasoningEffortsFor(state.extensionCatalog, state.connectionBackend,
                    state.connectionModel, state.connectionUrl).len == 0:
                  state.connectionReasoning = ""
                redraw(kxi)

        else:

          tdiv(class = "plugin-field"):

            label:
              text "Model identifier"

            input(
              `type` = "text",
              value = cstring(
                state.connectionModel
              ),
              placeholder =
                if state.connectionBackend in [
                  "pi",
                  "opencode"
                ]:
                  cstring"provider/model-id"
                else:
                  cstring"Provider model identifier"
            ):

              proc oninput(
                event: Event,
                node: VNode
              ) =

                let previousProvider = state.connectionModel.split('/')[0]
                let nextModel = $node.value
                if state.connectionBackend in ["pi", "opencode"] and
                   previousProvider != nextModel.split('/')[0]:
                  state.connectionKey = ""
                  resetConnectionOptions(state)
                state.connectionModel =
                  nextModel
                if reasoningEffortsFor(state.extensionCatalog, state.connectionBackend,
                    state.connectionModel, state.connectionUrl).len == 0:
                  state.connectionReasoning = ""
                redraw(kxi)

          if state.connectionBackend in [
            "pi",
            "opencode"
          ]:

            tdiv(class = "plugin-field-hint"):

              if state.connectionBackend == "pi":

                text "Stored form: provider/model. Example: openrouter/openrouter/free → Pi receives provider=openrouter and model=openrouter/free."

              else:

                text "OpenCode uses provider-prefixed model IDs such as openrouter/openrouter/free."

        if state.connectionBackend == "http":

          tdiv(class = "plugin-field plugin-field-wide"):

            label:
              text "API base URL"

            input(
              `type` = "text",
              value = cstring(
                state.connectionUrl
              ),
              placeholder =
                "https://provider.example/v1"
            ):

              proc oninput(
                event: Event,
                node: VNode
              ) =

                state.connectionUrl =
                  $node.value

                state.connectionKey = ""
                resetConnectionOptions(state)
                redraw(kxi)

        if state.connectionBackend in [
          "http",
          "pi",
          "opencode"
        ]:

          tdiv(class = "plugin-field plugin-field-wide"):

            label:

              if credentialRequired:
                text credentialLabel & " · required"
              else:
                text credentialLabel & " · optional"

            input(
              `type` = "password",
              value = cstring(
                state.connectionKey
              ),
              placeholder =
                if credentialRequired:
                  cstring"Paste provider API key"
                else:
                  cstring"No credential required"
            ):

              proc oninput(
                event: Event,
                node: VNode
              ) =

                state.connectionKey =
                  $node.value

                redraw(kxi)

            tdiv(class = "plugin-field-hint"):

              if state.connectionBackend == "pi":

                text "Pi receives only this provider credential inside its temporary isolated process. No Pi-specific key is needed."

              elif state.connectionBackend == "opencode":

                text "OpenCode receives only this provider credential inside its isolated temporary HOME. Your normal OpenCode login is not reused."

              elif credentialRequired:

                text "The key is sent to Phoenix and stored encrypted in the owner-scoped extension store. It is not returned by catalog/list requests."

              else:

                text "Local OpenAI-compatible endpoints can remain credential-free."

      if state.connectionBackend in ["http", "pi", "opencode"]:
        tdiv(class = "plugin-setup-card"):
          h4: text "Optional usage settings"
          renderUsageControls(state)

      if missingCredential:

        tdiv(class = "plugin-credential-warning"):

          strong:
            text "Credential required"

          span:
            text "This hosted provider cannot be saved until its API key is supplied."

      tdiv(class = "plugin-form-footer"):

        tdiv:

          strong:
            text "Governed inference"

          span:
            text "The external model supplies inference only. SemanticGuard, approvals and ToolGateway remain authoritative."

        button(
          class = "plugin-primary",
          disabled =
            state.extensionBusy or
            missingCredential
        ):

          if state.extensionBusy:
            text "Saving…"
          else:
            text "Save connection"

          proc onclick(
            event: Event,
            node: VNode
          ) =

            discard saveConnectionOptions(state)


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

    of "limits":
      renderUsageSettings(state)

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

              state.clearConnectionDraft()
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
