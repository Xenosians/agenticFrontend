include karax/prelude
import std/[json, strutils]
import ../app/[types, workflow_request, extension_bridge]

proc draftValue(state: AppState, field: string): string =
  if state.workflowArgumentDrafts != nil and state.workflowArgumentDrafts.kind == JObject and
      state.workflowArgumentDrafts.hasKey(field):
    return state.workflowArgumentDrafts[field].getStr

proc renderDraftStep(state: AppState, step: WorkflowStep, disabled: bool): VNode =
  # Each callback needs its own argument binding. JavaScript loop variables in
  # a Karax render otherwise make every Remove button target the last step.
  result = buildHtml(tdiv(class = "required-operation")):
    strong: text step.capability
    if step.afterSuccessOf.len > 0:
      span: text "After success of " & step.afterSuccessOf
    for field, values in step.groundedArguments:
      for value in values:
        span(class = "required-operation-target"): text field & ": " & value.getStr
    if state.workflowPanelOpen:
      button(class = "required-operation-remove", disabled = disabled,
          `aria-label` = cstring("Remove " & step.capability)):
        text "Remove"
        proc onclick(event: Event, node: VNode) =
          try:
            state.workflowSteps = removeWorkflowStep(state.workflowSteps, step.id)
            state.workflowError = ""
          except CatchableError as exc:
            state.workflowError = exc.msg

proc renderTargetInput(state: AppState, fieldName: string, disabled: bool): VNode =
  result = buildHtml(label(class = "required-operation-field")):
    span: text fieldName.replace("_", " ") & " (optional)"
    textarea(class = "required-operation-input", rows = "1", disabled = disabled,
        `aria-label` = cstring("Exact " & fieldName), value = cstring(draftValue(state, fieldName))):
      proc onchange(event: Event, node: VNode) =
        if state.workflowArgumentDrafts == nil: state.workflowArgumentDrafts = newJObject()
        state.workflowArgumentDrafts[fieldName] = %($node.value)

proc renderWorkflowReview*(contract: JsonNode): VNode =
  result = buildHtml(tdiv(class = "required-operations-review")):
    if contract != nil and contract.kind == JObject and contract.hasKey("steps") and
        contract["steps"].kind == JArray:
      for step in contract["steps"]:
        tdiv(class = "required-operation"):
          strong: text step["capability"].getStr
          if step.hasKey("after_success_of") and step["after_success_of"].kind == JString:
            span: text "After success of " & step["after_success_of"].getStr
          if step.hasKey("grounded_arguments") and step["grounded_arguments"].kind == JObject:
            for field, values in step["grounded_arguments"]:
              if values.kind == JArray:
                for value in values:
                  if value.kind == JString:
                    span(class = "required-operation-target"): text field & ": " & value.getStr

proc renderRequiredOperations*(state: AppState, disabled: bool): VNode =
  result = buildHtml(tdiv(class = "required-operations")):
    button(class = "required-operations-toggle", disabled = disabled,
        `aria-expanded` = cstring($state.workflowPanelOpen)):
      text (if state.workflowSteps.len == 0: "Required operations"
            else: "Required operations · " & $state.workflowSteps.len)
      proc onclick(event: Event, node: VNode) =
        state.workflowPanelOpen = not state.workflowPanelOpen
        if state.workflowPanelOpen and state.extensionCatalog == nil:
          discard refreshExtensions(state)

    if state.workflowSteps.len > 0:
      tdiv(class = "required-operations-summary"):
        for step in state.workflowSteps:
          renderDraftStep(state, step, disabled)

    elif disabled and state.run.workflowContract != nil:
      renderWorkflowReview(state.run.workflowContract)

    if state.workflowPanelOpen:
      tdiv(class = "required-operations-editor"):
        p(class = "required-operations-hint"):
          text "Choose the operations this request must include. Send confirms this list; each action still follows its normal approvals. Leave empty for a normal chat request."
        if state.workflowSteps.len == 2 and state.workflowSteps[1].afterSuccessOf.len > 0:
          p(class = "required-operations-hint"):
            text "A success-dependent request supports this pair of operations. Remove a step to revise the request."
        if state.extensionBusy:
          p(class = "required-operations-hint"): text "Loading registered capabilities…"
        elif capabilityRows(state.extensionCatalog).len == 0:
          button(class = "secondary-action", disabled = disabled):
            text "Load registered capabilities"
            proc onclick(event: Event, node: VNode) =
              discard refreshExtensions(state)
        else:
          label(class = "required-operation-field"):
            span: text "Operation"
            select(class = "plugin-select", `aria-label` = "Required operation", disabled = disabled,
                value = cstring(state.workflowCapabilityDraft)):
              option(value = ""): text "Choose a registered capability"
              for row in capabilityRows(state.extensionCatalog):
                if row.kind == JObject and row.hasKey("id") and row["id"].kind == JString:
                  let capability = row["id"].getStr
                  if workflowCapabilityAvailable(state.extensionCatalog, state.workflowSteps, capability):
                    option(value = cstring(capability)): text capability.replace("_", " ")
              proc onchange(event: Event, node: VNode) =
                state.workflowCapabilityDraft = $node.value
                state.workflowArgumentDrafts = newJObject()
                state.workflowAfterDraft = ""
                state.workflowError = ""
          if state.workflowCapabilityDraft.len > 0:
            let selected = capabilityRow(state.extensionCatalog, state.workflowCapabilityDraft)
            if selected != nil and selected.hasKey("description") and selected["description"].kind == JString:
              p(class = "required-operations-hint"): text selected["description"].getStr
            p(class = "required-operations-hint"):
              text "Exact targets are optional. Each field pins its entire list, one unchanged value per line. Other targets still come from your message and normal checks. Never enter credentials."
            for field in groundedFields(state.extensionCatalog, state.workflowCapabilityDraft):
              renderTargetInput(state, field, disabled)
            label(class = "required-operation-field"):
              span: text "Dependency"
              select(class = "plugin-select", `aria-label` = "Success dependency", disabled = disabled,
                  value = cstring(state.workflowAfterDraft)):
                option(value = ""): text "Independent operation"
                for previous in state.workflowSteps:
                  if state.workflowSteps.len == 1 and supportsSuccessDependency(state.extensionCatalog, previous.capability, state.workflowCapabilityDraft):
                    option(value = cstring(previous.id)): text "After success of " & previous.capability
                proc onchange(event: Event, node: VNode) =
                  state.workflowAfterDraft = $node.value
            button(class = "secondary-action", disabled = disabled or state.workflowSteps.len >= maxWorkflowSteps):
              text "Add required operation"
              proc onclick(event: Event, node: VNode) =
                try:
                  state.workflowSteps = addWorkflowStep(state.extensionCatalog, state.workflowSteps,
                    state.workflowCapabilityDraft, state.workflowArgumentDrafts, state.workflowAfterDraft)
                  state.workflowCapabilityDraft = ""
                  state.workflowArgumentDrafts = nil
                  state.workflowAfterDraft = ""
                  state.workflowError = ""
                except CatchableError as exc:
                  state.workflowError = exc.msg
        if state.extensionError.len > 0:
          p(class = "required-operations-error"): text state.extensionError
        if state.workflowError.len > 0:
          p(class = "required-operations-error", role = "alert"): text state.workflowError
