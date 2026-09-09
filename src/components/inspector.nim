include karax/prelude

import ../app/types
import ../app/state


proc statusTitle(
  status: string
): string =

  case status

  of "pending":
    "Pending"

  of "processing":
    "Processing"

  of "approving":
    "Approving"

  of "completed":
    "Completed"

  of "failed":
    "Failed"

  of "waiting_approval":
    "Waiting approval"

  else:
    "Idle"


proc statusDescription(
  status: string
): string =

  case status

  of "pending":
    "Waiting for backend dispatch"

  of "processing":
    "Agent is processing the request"

  of "approving":
    "Submitting explicit approval"

  of "completed":
    "Run completed successfully"

  of "failed":
    "Run failed"

  of "waiting_approval":
    "User approval is required"

  else:
    "No active run"


proc indicatorClass(
  status: string
): cstring =

  case status

  of "processing",
     "approving":
    cstring"status-indicator processing"

  of "completed":
    cstring"status-indicator completed"

  of "failed":
    cstring"status-indicator failed"

  of "waiting_approval":
    cstring"status-indicator waiting-approval"

  else:
    cstring"status-indicator pending"


proc tabClass(
  current: InspectorTab,
  target: InspectorTab
): cstring =

  if current == target:
    cstring"active"
  else:
    cstring""


proc displayValue(
  value: string,
  fallback: string
): string =

  if value.len == 0:
    fallback
  else:
    value


proc renderRunTab(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "inspector-panel")
  ):

    if not state.run.active:

      tdiv(class = "run-empty"):

        tdiv(class = "run-empty-icon"):
          text "◌"

        h3:
          text "No active run"

        p:
          text """
Send a request to inspect routing,
tool usage and execution state.
"""


    else:

      tdiv(class = "run-details"):

        tdiv(class = "run-status"):

          span(
            class =
              indicatorClass(
                state.run.status
              )
          )

          tdiv:

            strong:
              text statusTitle(
                state.run.status
              )

            span:
              text statusDescription(
                state.run.status
              )


        tdiv(class = "run-section"):

          span(class = "run-label"):
            text "Job"

          tdiv(class = "run-value mono"):
            text displayValue(
              state.run.jobId,
              "Not assigned"
            )


        tdiv(class = "run-section"):

          span(class = "run-label"):
            text "Request"

          tdiv(class = "run-value"):
            text state.run.request


        tdiv(class = "run-section"):

          span(class = "run-label"):
            text "Agent"

          tdiv(class = "run-value"):
            text displayValue(
              state.run.agent,
              "Not selected"
            )


        tdiv(class = "run-section"):

          span(class = "run-label"):
            text "Tool"

          tdiv(class = "run-value"):
            text displayValue(
              state.run.tool,
              "Not selected"
            )


proc renderInspectorTool(
  state: AppState,
  tool: ToolItem
): VNode =

  result = buildHtml(
    button(class = "tool-inspector-row")
  ):

    tdiv:

      strong:
        text tool.name

      span:
        text tool.id


    if tool.enabled:

      span(class = "capability-badge enabled"):
        text "Enabled"

    else:

      span(class = "capability-badge disabled"):
        text "Preview"


    proc onclick(
      event: Event,
      node: VNode
    ) =
      openToolView(
        state,
        tool.id
      )


proc renderToolsTab(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "inspector-panel")
  ):

    tdiv(class = "inspector-section-heading"):

      strong:
        text "Capabilities"

      span:
        text "Select a tool to inspect it."


    for tool in state.tools:
      renderInspectorTool(
        state,
        tool
      )


proc renderEventsTab(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "inspector-panel")
  ):

    if state.runEvents.len == 0:

      tdiv(class = "run-empty"):

        tdiv(class = "run-empty-icon"):
          text "≡"

        h3:
          text "No events"

        p:
          text "Runtime events will appear here."


    else:

      tdiv(class = "event-list"):

        for runEvent in state.runEvents:

          tdiv(class = "event-row"):

            tdiv(class = "event-marker")

            tdiv:

              span(class = "event-kind"):
                text runEvent.kind

              p:
                text runEvent.message


proc renderRawTab(
  state: AppState
): VNode =

  result = buildHtml(
    tdiv(class = "inspector-panel")
  ):

    pre(class = "raw-state"):

      if not state.run.active:

        text """
{
  "active": false
}
"""

      else:

        text (
          "{\n" &
          "  \"active\": true,\n" &
          "  \"job_id\": \"" &
          state.run.jobId &
          "\",\n" &
          "  \"status\": \"" &
          state.run.status &
          "\",\n" &
          "  \"agent\": \"" &
          state.run.agent &
          "\",\n" &
          "  \"tool\": \"" &
          state.run.tool &
          "\",\n" &
          "  \"events\": " &
          $state.runEvents.len &
          "\n" &
          "}"
        )


proc renderInspector*(
  state: AppState
): VNode =

  result = buildHtml(
    aside(class = "inspector")
  ):

    header(class = "inspector-header"):

      tdiv:

        strong:
          text "Run Inspector"

        span:
          text "Execution context"


      button(
        class = "inspector-close",
        title = "Hide inspector"
      ):

        text "×"

        proc onclick(
          event: Event,
          node: VNode
        ) =
          toggleInspector(
            state
          )


    tdiv(class = "inspector-tabs"):

      button(
        class =
          tabClass(
            state.inspectorTab,
            tabRun
          )
      ):

        text "Run"

        proc onclick(
          event: Event,
          node: VNode
        ) =
          setInspectorTab(
            state,
            tabRun
          )


      button(
        class =
          tabClass(
            state.inspectorTab,
            tabTools
          )
      ):

        text "Tools"

        proc onclick(
          event: Event,
          node: VNode
        ) =
          setInspectorTab(
            state,
            tabTools
          )


      button(
        class =
          tabClass(
            state.inspectorTab,
            tabEvents
          )
      ):

        text "Events"

        proc onclick(
          event: Event,
          node: VNode
        ) =
          setInspectorTab(
            state,
            tabEvents
          )


      button(
        class =
          tabClass(
            state.inspectorTab,
            tabRaw
          )
      ):

        text "Raw"

        proc onclick(
          event: Event,
          node: VNode
        ) =
          setInspectorTab(
            state,
            tabRaw
          )


    section(class = "inspector-content"):

      case state.inspectorTab

      of tabRun:
        renderRunTab(
          state
        )

      of tabTools:
        renderToolsTab(
          state
        )

      of tabEvents:
        renderEventsTab(
          state
        )

      of tabRaw:
        renderRawTab(
          state
        )