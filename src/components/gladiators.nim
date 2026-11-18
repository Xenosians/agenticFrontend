## The gladiators: the agents at the bottom of the chat list, and the agents' room they open large.
## (Owner decisions of 18 November: the strip above the message box and the inspector tab are gone.)
##
## Each Janus agent is a pixel gladiator (`public/assets/gladiators/<agent>.png`: 8 state rows x 4
## frame columns of 32x40). The stylesheet picks the sheet by `data-agent` (the production CSP allows
## no inline style) and masks currentColor with it, so the art follows the theme; it scales only in
## whole-pixel steps. Display only: nothing here grants or changes anything.

include karax/prelude
import std/[options, strutils]
import karax/kdom
import ../app/[types, state, agent_presence, ludus, room3d, world, world3d]
import composer

const
  maxColumns = 4    ## desks per row at most; a smaller team gets one column per agent
  stepNames: array[1 .. roomSteps, string] = ["Routing", "Planning", "Running", "Writing"]

proc worldColumns(roster: seq[string]): int = max(1, min(maxColumns, roster.len))

var
  idleSince = 0.0           ## when the observed job (or the page) last changed
  lastJobKey = ""
  roomExpanded = false      ## the agents' world is open over the workspace
  worldLoaded = false       ## its first frame is drawn (the loading screen is gone)
  worldWalk: WorldWalk      ## the owner's gladiator, his walk and the open card
  worldRoster: seq[string]  ## the roster the floor was built for
  worldChatOpen = true      ## the docked chat is unfolded
  worldMenuOpen = false     ## the settings menu is open
  worldMotion = true        ## the world animates (off by default with reduced motion)
  worldTimer = 0            ## the walk's step timer

proc nowSeconds(): float {.importjs: "(Date.now() / 1000)".}
## After karax's own redraw (also a frame callback, queued after the click handler): two frames.
proc focusSoon(selector: cstring) {.importjs:
  "((s) => requestAnimationFrame(() => requestAnimationFrame(() => document.querySelector(s)?.focus())))(#)".}
proc viewportWidth(): int {.importjs: "(window.innerWidth)".}
proc viewportHeight(): int {.importjs: "(window.innerHeight)".}
proc everyMs(callback: proc(), milliseconds: int): int {.importjs: "setInterval(#, #)".}
proc stopEvery(id: int) {.importjs: "clearInterval(#)".}
proc eventKeyOf(event: Event): cstring {.importjs: "(#.key || '')".}
proc eventTargetIsField(event: Event): bool {.importjs:
  "(((t) => !!t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable))(#.target))".}
proc eventClientX(event: Event): float {.importjs: "(#.clientX)".}
proc eventClientY(event: Event): float {.importjs: "(#.clientY)".}
proc preventDefaultOf(event: Event) {.importjs: "#.preventDefault()".}

const
  worldHost = ".world .room3d-host"
  walkStepMs = 140          ## one tile per step while walking to a clicked place

proc idleSeconds(state: AppState): int =
  ## Seconds since the observed job last changed state, or since the page opened.
  let key = state.run.jobId & "|" & state.run.status & "|" & state.run.progressStage & "|" & state.run.agent &
    "|" & state.run.progressAgent
  let now = nowSeconds()
  if idleSince == 0.0 or key != lastJobKey:
    idleSince = now
    lastJobKey = key
  int(now - idleSince)

proc stateName(presence: AgentPresence): string =
  const names: array[AgentPresence, string] = ["sleeping", "walking", "thinking", "working", "training",
                                               "waiting", "celebrating", "hurt"]
  names[presence]

proc currentScene(state: AppState): seq[Gladiator] =
  ludusScene(ludusRoster(state.extensionCatalog), state.run, state.system, state.learningRuns,
             idleSeconds(state))

proc poseName(pose: RoomPose): string =
  const names: array[RoomPose, string] = ["idle", "typing", "pondering", "dozing", "waiting", "away", "cheering",
                                          "slumped"]
  names[pose]

proc screenName(screen: RoomScreen): string =
  const names: array[RoomScreen, string] = ["off", "on", "working", "training", "done", "error"]
  names[screen]

proc renderGladiator(gladiator: Gladiator): VNode =
  let title = gladiatorTitle(gladiator.agent) & ": " & stateName(gladiator.presence)
  result = buildHtml(span(class = cstring("gladiator gladiator-" & stateName(gladiator.presence)),
      `data-agent` = cstring(gladiator.agent), `data-state` = cstring(stateName(gladiator.presence)),
      `data-talking-to` = cstring(gladiator.talkingTo), title = cstring(title)))

proc openRoom() =
  ## The agents' world opens over the workspace: a loading screen until its first frame is drawn.
  roomExpanded = true
  worldLoaded = not room3dSupported()  # without WebGL the 2D room is the world at once
  worldMenuOpen = false
  worldChatOpen = viewportWidth() > 720  # on a phone the chat starts folded
  worldMotion = not prefersReducedMotion()
  worldRoster = @[]
  focusSoon(".world .world-floor")

proc renderRoomPreview*(state: AppState): VNode =
  ## The agents at the bottom of the chat list (owner decision, 18 November): every agent as his
  ## pixel gladiator acting out his real state, and one line saying who is doing what. The whole
  ## block is one button that opens the agents' room large. Display only.
  let scene = currentScene(state)
  let caption = roomCaption(scene)
  result = buildHtml(button(class = "ludus-preview", `aria-label` = "Open the agents' world",
                            title = cstring(caption))):
    # Who is awake stands large (2x) in the middle; the sleepers lie small below him.
    span(class = "ludus-preview-awake", `aria-hidden` = "true"):
      for gladiator in scene:
        if gladiator.presence != apSleeping: renderGladiator(gladiator)
    span(class = "ludus-preview-asleep", `aria-hidden` = "true"):
      for gladiator in scene:
        if gladiator.presence == apSleeping: renderGladiator(gladiator)
    span(class = "ludus-preview-caption", `aria-live` = "polite"):
      text caption
    proc onclick(event: Event, node: VNode) = openRoom()

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

proc stopWalking() =
  if worldTimer != 0:
    stopEvery(worldTimer)
    worldTimer = 0

proc closeRoom() =
  stopWalking()
  roomExpanded = false
  worldMenuOpen = false
  hideRoom3d()
  redraw(kxi)
  focusSoon(".ludus-preview")

proc listenForEscape(onEscape: proc(): bool) {.importjs:
  "document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !e.defaultPrevented && #()) e.preventDefault(); }, true)".}

proc roomEscape(): bool =
  ## Escape closes the settings menu first, then the world, wherever focus is: the capture listener
  ## runs before the workspace's own Escape, which then leaves the event alone.
  if not roomExpanded: return false
  if worldMenuOpen:
    worldMenuOpen = false
    redraw(kxi)
    focusSoon(".world .world-settings-button")
    return true
  closeRoom()
  true

proc showOwner() =
  ## The owner's gladiator where he now stands (the 3D figure; the 2D marker follows the redraw).
  if room3dSupported():
    stepWorldOwner(worldHost, worldWalk.tile, worldWalk.walking, worldWalk.card)
  redraw(kxi)

proc walkTick() =
  if not worldWalk.advance():
    stopWalking()
  showOwner()

proc startWalk(goal: Tile) =
  stopWalking()
  worldWalk.goTo(goal)
  if not worldWalk.walking: return
  if not worldMotion:
    # Without motion the owner is simply there.
    while worldWalk.advance(): discard
    showOwner()
    return
  worldTimer = everyMs(walkTick, walkStepMs)

proc walkToDesk(agent: string) =
  for desk in worldWalk.floor.desks:
    if desk.agent == agent: startWalk(desk.tile)

proc deskLabel(seat: RoomSeat): string =
  gladiatorTitle(seat.agent) & ", " &
    (if seat.pose == rpAway: "at the " & gladiatorTitle(seat.visiting).toLowerAscii & "'s desk"
     else: presenceWord(seat.presence))

proc drawWorld3d(scene: seq[Gladiator]) =
  ## The world in 3D: the same seats as the room, on world.nim's floor, and the owner's gladiator.
  let seats = roomSeats(scene)
  var names: seq[string]
  for seat in seats: names.add deskLabel(seat)
  showWorld3d(worldHost, room3dSeats(seats), worldLabel(names, worldWalk.tile), worldColumns(worldRoster),
              worldWalk.tile,
              worldWalk.walking, worldMotion, worldWalk.card, proc() =
                if not worldLoaded:
                  worldLoaded = true
                  redraw(kxi))

proc stepFor(state: AppState, agent: string): string =
  ## What the agent is doing for the current request, in words.
  let doing = if state.run.progressAgent.len > 0: state.run.progressAgent else: state.run.agent
  if agent == hubAgent and (doing.len == 0 or doing == hubAgent):
    return "Handling the current request."
  if doing == agent: return "Working on the current request."
  if agent == hubAgent: return "Handed the current request to the " & gladiatorTitle(doing).toLowerAscii & "."
  "Not part of the current request."

proc renderCard(state: AppState, scene: seq[Gladiator]): VNode =
  ## The open agent's card: who he is, what he is doing, and the way to ask Janus.
  var gladiator: Gladiator
  for candidate in scene:
    if candidate.agent == worldWalk.card: gladiator = candidate
  let title = gladiatorTitle(gladiator.agent)
  result = buildHtml(section(class = "world-card", `aria-label` = cstring(title), role = "region",
                             `aria-live` = "polite")):
    tdiv(class = "world-card-heading"):
      strong: text title
      button(class = "world-card-close", `aria-label` = "Close the card", title = "Close"):
        text "×"
        proc onclick(event: Event, node: VNode) =
          worldWalk.card = ""
          focusSoon(".world .world-floor")
    p(class = "world-card-state"):
      text title & " is " & presenceWord(gladiator.presence)
      if gladiator.talkingTo.len > 0:
        text ", handing the request to the " & gladiatorTitle(gladiator.talkingTo).toLowerAscii
      text "."
    # The bar above already says when there is no request; the card speaks only to a running one.
    if state.run.active:
      p(class = "world-card-step"): text stepFor(state, gladiator.agent)
      # What he did in this request, step by step (world decision 3).
      let steps = agentSteps.recent(gladiator.agent)
      if steps.len == 0:
        p(class = "world-card-steps-empty"): text "No steps in this request yet."
      else:
        ol(class = "world-card-steps", `aria-label` = "Recent steps"):
          for words in steps:
            li: text words
    p(class = "world-card-note"): text "Janus decides which agent handles each request."
    button(class = "secondary-action world-card-ask"):
      text "Ask Janus"
      proc onclick(event: Event, node: VNode) =
        worldChatOpen = true
        focusSoon("#worldMessageInput")

proc renderDockedChat(state: AppState): VNode =
  ## The current chat in a corner of the world: its last messages and a message box that sends
  ## exactly as the chat view's does.
  if not worldChatOpen:
    return buildHtml(button(class = "secondary-action world-chat-show", `aria-label` = "Show chat")):
      text "Chat"
      proc onclick(event: Event, node: VNode) =
        worldChatOpen = true
        focusSoon("#worldMessageInput")
  let busy = backendJobBusy(state)
  result = buildHtml(aside(class = "world-chat", `aria-label` = "Chat")):
    tdiv(class = "world-chat-heading"):
      strong: text(block:
        var title = "Chat"
        for chat in state.chats:
          if chat.chatId == state.currentChatId and chat.title.len > 0: title = chat.title
        title)
      button(class = "world-chat-hide", `aria-label` = "Hide chat", title = "Hide chat"):
        text "–"
        proc onclick(event: Event, node: VNode) =
          worldChatOpen = false
          focusSoon(".world .world-chat-show")
    ol(class = "world-chat-messages", `aria-label` = "Recent messages"):
      let first = max(0, state.messages.len - 6)
      for index in first ..< state.messages.len:
        let message = state.messages[index]
        li(class = (if message.role == mrUser: cstring"world-message mine" else: cstring"world-message")):
          text message.content
    tdiv(class = "world-chat-composer"):
      textarea(id = "worldMessageInput", class = "world-chat-input", rows = "2",
               `aria-label` = "Message Janus", placeholder = "Message Janus…",
               value = cstring(state.composerDraft)):
        proc oninput(event: Event, node: VNode) = setComposerDraft(state, $node.value)
        proc onkeydown(event: Event, node: VNode) =
          setComposerDraft(state, $node.value)
          if eventKeyOf(event) == "Enter" and not cast[KeyboardEvent](event).shiftKey:
            preventDefaultOf(event)
            submitDraft(state)
      let canSend = not busy and state.composerDraft.strip.len > 0
      button(class = (if canSend: cstring"send-button active world-chat-send" else: cstring"send-button world-chat-send"),
             `aria-label` = "Send message", disabled = not canSend):
        text "↑"
        proc onclick(event: Event, node: VNode) = submitDraft(state)

proc renderSettings(): VNode =
  result = buildHtml(tdiv(class = "world-settings")):
    button(class = "world-settings-button", `aria-label` = "World settings", `aria-haspopup` = "menu",
           `aria-expanded` = (if worldMenuOpen: cstring"true" else: cstring"false"), title = "Settings"):
      text "⚙"
      proc onclick(event: Event, node: VNode) =
        worldMenuOpen = not worldMenuOpen
        if worldMenuOpen: focusSoon(".world .world-menu [role=menuitem]")
    if worldMenuOpen:
      tdiv(class = "world-menu", role = "menu", `aria-label` = "World settings"):
        button(role = "menuitem", class = "world-menu-item"):
          text "Back to chat"
          proc onclick(event: Event, node: VNode) = closeRoom()
        button(role = "menuitemcheckbox", class = "world-menu-item",
               `aria-checked` = (if worldMotion: cstring"true" else: cstring"false")):
          text "Motion"
          proc onclick(event: Event, node: VNode) =
            worldMotion = not worldMotion
            if room3dSupported(): setWorldMotion(worldHost, worldMotion)

proc ownerLabel(): string =
  "You, on tile " & $worldWalk.tile.x & ", " & $worldWalk.tile.y &
    (if worldWalk.card.len > 0: ", beside the " & gladiatorTitle(worldWalk.card).toLowerAscii & "'s desk" else: "")

proc renderFloor(state: AppState, scene: seq[Gladiator], drawn3d: bool): VNode =
  ## The walkable floor: one button per desk (the accessible layer over the drawing), and the owner.
  ## Arrow keys or WASD move the owner; a click on the drawn floor walks him there.
  let seats = roomSeats(scene)
  let floor = worldWalk.floor
  result = buildHtml(tdiv(class = cstring("world-floor columns-" & $floor.width & " rows-" & $floor.height),
                          tabindex = "0", role = "application",
                          `aria-label` = "The agents' floor. Arrow keys or W, A, S, D move you; click a desk to see an agent.",
                          `data-columns` = cstring($floor.width), `data-rows` = cstring($floor.height))):
    for seat in seats:
      var tile: Tile
      for desk in floor.desks:
        if desk.agent == seat.agent: tile = desk.tile
      button(class = "world-desk", `data-agent` = cstring(seat.agent), `data-tile` = cstring($tile.x & "," & $tile.y),
             `data-x` = cstring($tile.x), `data-y` = cstring($tile.y), `aria-label` = cstring(deskLabel(seat)),
             title = cstring(deskLabel(seat)), `data-hub` = (if seat.agent == hubAgent: cstring"true" else: cstring"false"),
             `data-open` = (if worldWalk.card == seat.agent: cstring"true" else: cstring"false")):
        span(class = "world-desk-name"): text gladiatorTitle(seat.agent)
        span(class = "world-desk-state", `aria-hidden` = "true"):
          text (if seat.pose == rpAway: "visiting" else: presenceWord(seat.presence))
        proc onclick(event: Event, node: VNode) = worldWalk.choose($node.getAttr("data-agent"))
        proc ondblclick(event: Event, node: VNode) = walkToDesk($node.getAttr("data-agent"))
    span(class = "world-owner", role = "img", `aria-label` = cstring(ownerLabel()),
         `data-tile` = cstring($worldWalk.tile.x & "," & $worldWalk.tile.y),
         `data-x` = cstring($worldWalk.tile.x), `data-y` = cstring($worldWalk.tile.y),
         `data-walking` = (if worldWalk.walking: cstring"true" else: cstring"false")):
      text "You"
    proc onkeydown(event: Event, node: VNode) =
      if eventTargetIsField(event): return
      let direction = worldKeyDirection($eventKeyOf(event))
      if direction.isSome:
        preventDefaultOf(event)
        stopWalking()
        worldWalk.press(direction.get)
        showOwner()
    proc onclick(event: Event, node: VNode) =
      if not drawn3d: return
      let picked = pickWorldTile(worldHost, eventClientX(event), eventClientY(event))
      if picked.found: startWalk(picked.tile)

var escapeInstalled = false

proc renderRoomOverlay*(state: AppState): VNode =
  ## The agents' world over the workspace, opened from the agents in the chat list.
  if not escapeInstalled:
    escapeInstalled = true
    listenForEscape(roomEscape)
  if not roomExpanded:
    return buildHtml(tdiv(class = "room-overlay-closed", hidden = true))
  let scene = currentScene(state)
  var roster: seq[string]
  for gladiator in scene: roster.add gladiator.agent
  if roster != worldRoster:
    # A new roster (or the first open) lays the floor out again.
    if worldRoster.len == 0: worldWalk = newWorldWalk(worldFloor(roster, worldColumns(roster)))
    else: worldWalk.reseat(worldFloor(roster, worldColumns(roster)))
    worldRoster = roster
  let drawn3d = room3dSupported()
  result = buildHtml(tdiv(class = "world", role = "dialog", `aria-modal` = "true", `aria-label` = "Agents' world")):
    tdiv(class = (if drawn3d: cstring"world-stage room3d-on" else: cstring"world-stage")):
      if drawn3d:
        tdiv(class = "room3d-host", `aria-hidden` = "false")
      renderFloor(state, scene, drawn3d)
    if not worldLoaded:
      tdiv(class = "world-loading", role = "status"):
        span: text "Entering the Ludus…"
    renderTopBar(state, scene)
    renderSettings()
    if worldWalk.card.len > 0:
      renderCard(state, scene)
    renderDockedChat(state)
  if drawn3d:
    drawWorld3d(scene)
