## The gladiators: a strip above the message box and the Ludus room in the Run Inspector.
##
## Each Janus agent is a pixel gladiator (`public/assets/gladiators/<agent>.png`: 8 state rows x 4
## frame columns of 32x40). The stylesheet picks the sheet by `data-agent` (the production CSP allows
## no inline style) and masks currentColor with it, so the art follows the theme; it scales only in
## whole-pixel steps. Display only: nothing here grants or changes anything.

include karax/prelude
import std/strutils
import ../app/[types, agent_presence, ludus]

const
  roomWidth* = 320  ## the Ludus room in art pixels (zoom 1)
  roomHeight* = 120

var
  idleSince = 0.0           ## when the observed job (or the page) last changed
  lastJobKey = ""
  ludusZoomLevel = 0        ## 0 until the room is first measured, then 1..4
  ludusFocus = ""           ## the agent whose details are shown in the room

proc nowSeconds(): float {.importjs: "(Date.now() / 1000)".}

proc idleSeconds(state: AppState): int =
  ## Seconds since the observed job last changed state, or since the page opened.
  let key = state.run.jobId & "|" & state.run.status & "|" & state.run.progressStage & "|" & state.run.agent &
    "|" & state.run.progressAgent
  let now = nowSeconds()
  if idleSince == 0.0 or key != lastJobKey:
    idleSince = now
    lastJobKey = key
  int(now - idleSince)

proc presenceWord(presence: AgentPresence): string =
  const words: array[AgentPresence, string] = ["asleep", "walking about", "thinking", "working",
                                               "training", "waiting for your approval", "celebrating",
                                               "hurt"]
  words[presence]

proc stateName(presence: AgentPresence): string =
  const names: array[AgentPresence, string] = ["sleeping", "walking", "thinking", "working", "training",
                                               "waiting", "celebrating", "hurt"]
  names[presence]

proc renderGladiator(gladiator: Gladiator, interactive = false): VNode =
  ## One gladiator per call, so a room gladiator's handler keeps its own agent (a loop variable
  ## captured by several handlers would be shared in JavaScript).
  let title = gladiatorTitle(gladiator.agent) & ": " & stateName(gladiator.presence)
  if interactive:
    result = buildHtml(button(class = cstring("gladiator gladiator-" & stateName(gladiator.presence)),
        `data-agent` = cstring(gladiator.agent), `data-state` = cstring(stateName(gladiator.presence)),
        `data-talking-to` = cstring(gladiator.talkingTo), title = cstring(title),
        `aria-label` = cstring(gladiatorTitle(gladiator.agent) & ", " & presenceWord(gladiator.presence)))):
      proc onclick(event: Event, node: VNode) =
        ludusFocus = gladiator.agent
  else:
    result = buildHtml(span(class = cstring("gladiator gladiator-" & stateName(gladiator.presence)),
        `data-agent` = cstring(gladiator.agent), `data-state` = cstring(stateName(gladiator.presence)),
        `data-talking-to` = cstring(gladiator.talkingTo), title = cstring(title)))

proc currentScene(state: AppState): seq[Gladiator] =
  ludusScene(ludusRoster(state.extensionCatalog), state.run, state.system, state.learningRuns,
             idleSeconds(state))

proc renderGladiatorStrip*(state: AppState): VNode =
  ## The hub, plus the specialist he is handing the current request to. One sentence names it for
  ## screen readers; the art itself is decoration.
  let scene = currentScene(state)
  var shown: seq[Gladiator]
  for gladiator in scene:
    if gladiator.agent == hubAgent or (scene[0].talkingTo.len > 0 and gladiator.agent == scene[0].talkingTo) or
        (gladiator.presence notin {apSleeping, apWalking} and gladiator.agent != hubAgent and
         state.run.active and gladiator.agent == state.run.agent):
      shown.add gladiator
  let caption = presenceCaption(presenceState(state.run, state.system, state.learningRuns,
                                              idleSeconds(state)))
  result = buildHtml(tdiv(class = "gladiator-strip", role = "img", `aria-label` = "Janus agents")):
    tdiv(class = "gladiator-track"):
      for gladiator in shown:
        renderGladiator(gladiator)
    span(class = "visually-hidden", `aria-live` = "polite"):
      text caption

proc renderLudus*(state: AppState): VNode =
  ## Every agent's gladiator in one room, by area: barracks, training yard, arena floor, the gate.
  let scene = currentScene(state)
  if ludusZoomLevel == 0: ludusZoomLevel = 2
  var areas: array[LudusArea, seq[Gladiator]]
  for gladiator in scene:
    areas[gladiatorArea(gladiator, scene)].add gladiator
  const areaNames: array[LudusArea, string] = ["Barracks", "Training yard", "Arena", "Gate"]
  result = buildHtml(section(class = "ludus", `aria-label` = "Ludus")):
    tdiv(class = "ludus-toolbar"):
      button(class = "ludus-zoom-button", `aria-label` = "Zoom out", title = "Zoom out",
             disabled = ludusZoomLevel <= minZoom):
        text "−"
        proc onclick(event: Event, node: VNode) = ludusZoomLevel = zoomOut(ludusZoomLevel)
      span(class = "ludus-zoom-level", `data-zoom` = cstring($ludusZoomLevel)):
        text $ludusZoomLevel & "×"
      button(class = "ludus-zoom-button", `aria-label` = "Zoom in", title = "Zoom in",
             disabled = ludusZoomLevel >= maxZoom):
        text "+"
        proc onclick(event: Event, node: VNode) = ludusZoomLevel = zoomIn(ludusZoomLevel)
    tdiv(class = "ludus-viewport"):
      tdiv(class = cstring("ludus-room zoom-" & $ludusZoomLevel)):
        for area in LudusArea:
          tdiv(class = cstring("ludus-area ludus-area-" & ($area)[2 .. ^1].toLowerAscii),
               `data-area` = cstring(areaNames[area])):
            span(class = "ludus-area-name"): text areaNames[area]
            tdiv(class = "ludus-area-floor"):
              for gladiator in areas[area]:
                renderGladiator(gladiator, interactive = true)
    if ludusFocus.len > 0:
      for gladiator in scene:
        if gladiator.agent == ludusFocus:
          tdiv(class = "ludus-focus", role = "status"):
            strong: text gladiatorTitle(gladiator.agent)
            span:
              text " is " & presenceWord(gladiator.presence)
              if gladiator.talkingTo.len > 0:
                text ", handing the request to the " & gladiatorTitle(gladiator.talkingTo).toLowerAscii
              text "."
