## The gladiators: a strip above the message box and the Ludus room in the Run Inspector.
##
## Each Janus agent is a pixel gladiator (`public/assets/gladiators/<agent>.png`: 8 state rows x 4
## frame columns of 32x40). The stylesheet picks the sheet by `data-agent` (the production CSP allows
## no inline style) and masks currentColor with it, so the art follows the theme; it scales only in
## whole-pixel steps. Display only: nothing here grants or changes anything.

include karax/prelude
import std/strutils
import ../app/[types, agent_presence, ludus, room3d]

const
  roomWidth = 334   ## the expanded room in art pixels (zoom 1): four workstations of 80, margins, walls
  roomHeight = 70   ## the back wall and the floor's margins; each row of desks adds rowHeight
  rowHeight = 46
  roomColumns = 4
  stepNames: array[1 .. roomSteps, string] = ["Routing", "Planning", "Running", "Writing"]

var
  idleSince = 0.0           ## when the observed job (or the page) last changed
  lastJobKey = ""
  ludusZoomLevel = 0        ## 0 until the room is first measured, then 1..4
  ludusFocus = ""           ## the agent whose details are shown in the room
  roomExpanded = false      ## the room is open large over the conversation

proc nowSeconds(): float {.importjs: "(Date.now() / 1000)".}
## After karax's own redraw (also a frame callback, queued after the click handler): two frames.
proc focusSoon(selector: cstring) {.importjs:
  "((s) => requestAnimationFrame(() => requestAnimationFrame(() => document.querySelector(s)?.focus())))(#)".}
proc viewportWidth(): int {.importjs: "(window.innerWidth)".}
proc viewportHeight(): int {.importjs: "(window.innerHeight)".}

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

proc renderGladiator(gladiator: Gladiator): VNode =
  let title = gladiatorTitle(gladiator.agent) & ": " & stateName(gladiator.presence)
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

proc poseName(pose: RoomPose): string =
  const names: array[RoomPose, string] = ["idle", "typing", "pondering", "dozing", "waiting", "away", "cheering",
                                          "slumped"]
  names[pose]

proc screenName(screen: RoomScreen): string =
  const names: array[RoomScreen, string] = ["off", "on", "working", "training", "done", "error"]
  names[screen]

proc renderDesk(seat: RoomSeat, visitor: RoomSeat, hasVisitor: bool): VNode =
  ## One workstation: the agent on his stool (or the empty stool), his desk and screen, his emblem on
  ## the drawer, and the hub standing beside it when he has come to hand over a request. Choosing a
  ## desk shows who works there and what he is doing. One desk per call, so each handler keeps its
  ## own agent (a loop variable captured by several handlers would be shared in JavaScript).
  let label = gladiatorTitle(seat.agent) & ", " &
    (if seat.pose == rpAway: "at the " & gladiatorTitle(seat.visiting).toLowerAscii & "'s desk"
     else: presenceWord(seat.presence))
  result = buildHtml(button(class = "room-desk", `data-agent` = cstring(seat.agent),
                            `data-pose` = cstring(poseName(seat.pose)), `data-screen` = cstring(screenName(seat.screen)),
                            `aria-label` = cstring(label), title = cstring(label))):
    span(class = "room-desk-furniture")
    span(class = "room-emblem", `data-agent` = cstring(seat.agent))
    span(class = cstring("room-seat room-pose-" & poseName(seat.pose)), `data-agent` = cstring(seat.agent))
    if hasVisitor:
      span(class = cstring("room-visitor room-visitor-" & stateName(visitor.presence)),
           `data-agent` = cstring(visitor.agent))
    proc onclick(event: Event, node: VNode) =
      ludusFocus = seat.agent

proc renderRoom(state: AppState, scene: seq[Gladiator], zoom: int, labelled: bool): VNode =
  ## The agents' room: the back wall, then every agent's desk in roster order, four to a row.
  let seats = roomSeats(scene)
  result = buildHtml(tdiv(class = cstring("agents-room zoom-" & $zoom), role = "group",
                          `aria-label` = (if labelled: cstring"Agents' room" else: cstring"Agents"))):
    tdiv(class = "room-wall", `aria-hidden` = "true")
    tdiv(class = "room-floor"):
      for seat in seats:
        var visitor: RoomSeat
        var hasVisitor = false
        for other in seats:
          if other.visiting.len > 0 and other.visiting == seat.agent:
            visitor = other
            hasVisitor = true
        renderDesk(seat, visitor, hasVisitor)

proc requestTitle(state: AppState): string =
  ## The current request is named by its chat, as in the conversation header.
  for chat in state.chats:
    if chat.chatId == state.currentChatId: return chat.title

proc renderTopBar(state: AppState, scene: seq[Gladiator]): VNode =
  ## Like a studio game's header: the request (its chat), its step, and four counters.
  let bar = roomTopBar(scene, state.run)
  let title = requestTitle(state)
  let stepText = if bar.step == 0: "No request in progress" else: "Step " & $bar.step & " of " & $bar.steps &
    ": " & stepNames[bar.step]
  result = buildHtml(tdiv(class = "room-topbar")):
    tdiv(class = "room-request"):
      span(class = "room-title"): text(if state.run.active and title.len > 0: title elif state.run.active:
                                       "Current request" else: "No request")
      tdiv(class = "room-step", role = "progressbar", `aria-label` = "Request progress",
           `aria-valuemin` = "0", `aria-valuemax` = cstring($bar.steps), `aria-valuenow` = cstring($bar.step),
           `aria-valuetext` = cstring(stepText), `data-step` = cstring($bar.step)):
        for step in 1 .. bar.steps:
          span(class = (if step <= bar.step: cstring"room-step-cell done" else: cstring"room-step-cell"),
               title = cstring(stepNames[step]))
      span(class = "room-step-name"): text stepText
    tdiv(class = "room-counters"):
      for (key, label, count) in [("busy", "Busy", bar.busy), ("waiting", "Waiting for you", bar.waiting),
                                  ("training", "Training", bar.training), ("failed", "Failed", bar.failed)]:
        span(class = "room-counter", `data-counter` = cstring(key), `data-count` = cstring($count),
             title = cstring(label)):
          span(class = "room-counter-value"): text $count
          span(class = "room-counter-label"): text label

proc closeRoom() =
  roomExpanded = false
  hideRoom3d()
  redraw(kxi)
  focusSoon(".ludus .room-expand")

proc listenForEscape(onEscape: proc(): bool) {.importjs:
  "document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !e.defaultPrevented && #()) e.preventDefault(); }, true)".}

proc roomEscape(): bool =
  ## Escape closes the open room wherever focus is (it may still be on the expand button): the capture
  ## listener runs before the workspace's own Escape, which then leaves the event alone.
  if not roomExpanded: return false
  closeRoom()
  true

proc drawRoom3d(scene: seq[Gladiator]) =
  ## The expanded room in 2.5D: the same seats as the 2D room, and a label naming every agent's state.
  let seats = roomSeats(scene)
  var names: seq[string]
  for seat in seats:
    names.add gladiatorTitle(seat.agent) & ", " &
      (if seat.pose == rpAway: "at the " & gladiatorTitle(seat.visiting).toLowerAscii & "'s desk"
       else: presenceWord(seat.presence))
  showRoom3d(".room-overlay .room3d-host", room3dSeats(seats), room3dLabel(names), roomColumns)

var escapeInstalled = false

proc renderLudus*(state: AppState): VNode =
  ## Every agent at his own desk in one room (F1b), with the request's progress above it.
  if not escapeInstalled:
    escapeInstalled = true
    listenForEscape(roomEscape)
  let scene = currentScene(state)
  if ludusZoomLevel == 0: ludusZoomLevel = 1
  result = buildHtml(section(class = "ludus", `aria-label` = "Ludus")):
    renderTopBar(state, scene)
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
      button(class = "ludus-zoom-button room-expand", `aria-label` = "Expand the agents' room",
             title = "Expand the agents' room"):
        text "⤢"
        proc onclick(event: Event, node: VNode) =
          roomExpanded = true
          focusSoon(".room-overlay .room-close")
    tdiv(class = "ludus-viewport"):
      renderRoom(state, scene, ludusZoomLevel, labelled = not roomExpanded)
    if roomExpanded:
      tdiv(class = "room-overlay"):
        tdiv(class = "room-dialog", role = "dialog", `aria-modal` = "true", `aria-label` = "Agents' room"):
          tdiv(class = "room-dialog-header"):
            strong: text "Agents' room"
            button(class = "ludus-zoom-button room-close", `aria-label` = "Close the agents' room",
                   title = "Close (Esc)"):
              text "×"
              proc onclick(event: Event, node: VNode) = closeRoom()
          renderTopBar(state, scene)
          # With WebGL the room is drawn in 2.5D behind the desks, which stay as the accessible,
          # clickable layer; without it (or with no 3D script) the 2D room shows as before.
          let drawn3d = room3dSupported()
          tdiv(class = (if drawn3d: cstring"room-dialog-body room3d-on" else: cstring"room-dialog-body")):
            if drawn3d:
              tdiv(class = "room3d-host", `aria-hidden` = "false")
            renderRoom(state, scene, fitZoom(roomWidth, roomHeight + rowHeight * ((scene.len + roomColumns - 1) div
                                                                                  roomColumns),
                                             viewportWidth() - 64, viewportHeight() - 190), labelled = true)
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
  if roomExpanded and room3dSupported():
    drawRoom3d(scene)
