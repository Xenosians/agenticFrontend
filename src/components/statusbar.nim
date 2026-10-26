## Status bar: the workspace's persistent service and job state.
##
## Hermes keeps one quiet bar under its panes for backend health, the running
## turn and pane toggles. Janus carries the same organisation for ITSM work
## (FR-077, FR-080): public backend and AI runtime health, the live-update
## state of the observed durable job on every page, and the run inspector.
## Health is the backend's public summary only; it is not provider evidence.

include karax/prelude

import ../app/types

proc healthLabel*(system: SystemState): string =
  ## One label for the public health summary. An unread result stays unknown.
  if system.checking and not system.checked: "Checking services"
  elif not system.checked: "Services not checked"
  elif not system.backendConnected: "Backend unavailable"
  elif system.aiReady: "Services ready"
  elif system.aiReachable: "AI runtime starting"
  else: "AI runtime unavailable"


proc healthClass(system: SystemState): cstring =
  if not system.checked: cstring"statusbar-item statusbar-health unknown"
  elif system.backendConnected and system.aiReady: cstring"statusbar-item statusbar-health ready"
  elif system.backendConnected and system.aiReachable: cstring"statusbar-item statusbar-health starting"
  else: cstring"statusbar-item statusbar-health unavailable"


proc observationLabel*(mode: string): string =
  ## How the observed job reaches this page; durable state stays authoritative.
  case mode
  of "live": "Live updates"
  of "connecting": "Connecting to live updates"
  of "reconnecting": "Reconnecting · checking for updates"
  of "polling": "Checking for updates"
  of "interrupted": "Connection interrupted"
  else: "Checking saved progress"


proc observedJob*(run: RunState): bool =
  ## Only a job this page is still observing; a finished one leaves the bar.
  run.active and run.jobId.len > 0 and run.observationMode.len > 0


proc renderStatusbar*(state: AppState, openView: proc(view: AppView),
                      toggleInspector: proc()): VNode =
  result = buildHtml(footer(class = "statusbar", `aria-label` = "Status")):
    tdiv(class = "statusbar-group"):
      button(class = healthClass(state.system), title = "Open system status"):
        span(class = "statusbar-dot", `aria-hidden` = "true"):
          text ""
        text healthLabel(state.system)
        proc onclick(event: Event, node: VNode) =
          openView(viewSystem)

      if observedJob(state.run):
        button(class = "statusbar-item statusbar-job", title = "Open durable job activity"):
          span(class = "statusbar-dot", `aria-hidden` = "true"):
            text ""
          text observationLabel(state.run.observationMode)
          proc onclick(event: Event, node: VNode) =
            openView(viewJobs)

    tdiv(class = "statusbar-group"):
      button(
        class = "statusbar-item statusbar-inspector",
        `aria-pressed` = cstring($state.inspectorOpen),
        title = "Run inspector (Ctrl/Cmd+Alt+I)"
      ):
        text "Run inspector"
        proc onclick(event: Event, node: VNode) =
          toggleInspector()
