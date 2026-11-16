## The ludus: one gladiator per real agent, each acting out what his agent is doing, at his own desk
## in the agents' room (F1b).
##
## The roster is the hub plus every specialist the server's capability catalog
## names; nothing is invented. Who works is decided only by state the app
## already holds: service health, the observed job (its status, progress word
## and the agent the server names) and the owner's learning runs. Display only:
## nothing here grants or changes anything.

import std/[algorithm, json, strutils]
import types
import learning
import agent_presence

type
  Gladiator* = object
    agent*: string        ## the agent's identifier ("hub" or a specialist name)
    presence*: AgentPresence
    talkingTo*: string    ## the specialist the hub is handing the request to, if any

  ## The agents' room (F1b): every agent at his own desk. A pose is what the seated agent does; his
  ## screen is dark while he dozes; the hub, visiting a specialist, leaves his own seat empty.
  RoomPose* = enum
    rpIdle, rpTyping, rpPondering, rpDozing, rpWaiting, rpAway, rpCheering, rpSlumped

  RoomScreen* = enum
    rsOff, rsOn, rsWorking, rsTraining, rsDone, rsError

  RoomSeat* = object
    agent*: string
    presence*: AgentPresence  ## the gladiator's state, for the words that name it
    pose*: RoomPose
    screen*: RoomScreen
    visiting*: string         ## the hub only: the specialist at whose desk he stands

  ## The room's top bar: the request's step (0 when none: queued, waiting on the provider, failed) of
  ## four (routing, planning, running, writing) and how many agents are busy, waiting for the owner's
  ## approval, training or hurt.
  RoomTopBar* = object
    step*, steps*: int
    busy*, waiting*, training*, failed*: int

const
  hubAgent* = "hub"
  minZoom* = 1
  maxZoom* = 4

proc plainAgentName(name: string): bool =
  ## Lower-case words joined by single hyphens, as the AI names its agents.
  if name.len == 0 or name.len > 64 or name[0] == '-' or name[^1] == '-' or "--" in name: return false
  for character in name:
    if character notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc ludusRoster*(catalog: JsonNode): seq[string] =
  ## The hub, then each specialist that serves a capability, once, in name order.
  var specialists: seq[string]
  if catalog != nil and catalog.kind == JObject and catalog.hasKey("capabilities") and
      catalog["capabilities"].kind == JArray:
    for item in catalog["capabilities"]:
      if item.kind != JObject or not item.hasKey("agent_names") or item["agent_names"].kind != JArray:
        continue
      for owner in item["agent_names"]:
        if owner.kind == JString and plainAgentName(owner.getStr) and owner.getStr != hubAgent and
            owner.getStr notin specialists:
          specialists.add owner.getStr
  specialists.sort()
  @[hubAgent] & specialists

proc gladiatorTitle*(agent: string): string =
  if agent == hubAgent: return "Janus (hub)"
  result = agent.replace("-", " ")
  if result.len > 0: result[0] = result[0].toUpperAscii

proc training(learningRuns: seq[LearningRun], role: string): bool =
  for learningRun in learningRuns:
    if learningRun.state in activeLearningRunStates and learningRun.role == role: return true

proc stepSpecialist(run: RunState, roster: seq[string]): tuple[agent: string, live: bool] =
  ## The specialist doing the current step. The agent the AI names live for this step wins (the hub
  ## routing or writing the answer means no specialist); a live name outside the roster is ignored.
  ## Without one, the agent the server's job record names decides.
  if not run.active: return ("", false)
  if run.progressAgent.len > 0 and run.progressAgent in roster:
    return ((if run.progressAgent == hubAgent: "" else: run.progressAgent), true)
  if run.agent != hubAgent and run.agent in roster: (run.agent, false) else: ("", false)

proc ludusScene*(roster: seq[string], run: RunState, system: SystemState, learningRuns: seq[LearningRun],
                 idleSeconds: int): seq[Gladiator] =
  ## One gladiator per roster entry, in roster order.
  let jobPresence = presenceState(run, system, @[], idleSeconds)
  let (specialist, live) = stepSpecialist(run, roster)
  for agent in roster:
    var gladiator = Gladiator(agent: agent, presence: apSleeping)
    if not (system.checked and system.backendConnected and system.aiReady):
      result.add gladiator
      continue
    if agent == hubAgent:
      if specialist.len > 0 and jobPresence notin {apWalking, apSleeping}:
        # The hub has handed the request over: he stands with that specialist.
        gladiator.presence = if jobPresence in {apWorking, apWaiting}: apThinking else: jobPresence
        gladiator.talkingTo = specialist
      elif jobPresence notin {apWalking, apSleeping}:
        gladiator.presence = jobPresence
      elif training(learningRuns, "hub"):
        gladiator.presence = apTraining
      else:
        gladiator.presence = jobPresence
    elif agent == specialist and (jobPresence notin {apWalking, apSleeping, apThinking} or
                                  live and jobPresence == apThinking):
      # A specialist named live also thinks while he plans his call.
      gladiator.presence = jobPresence
    elif training(learningRuns, "specialist"):
      gladiator.presence = apTraining
    result.add gladiator

proc roomPose(presence: AgentPresence): RoomPose =
  case presence
  of apSleeping: rpDozing
  of apWalking: rpIdle
  of apThinking: rpPondering
  of apWorking, apTraining: rpTyping
  of apWaiting: rpWaiting
  of apCelebrating: rpCheering
  of apHurt: rpSlumped

proc roomScreen(presence: AgentPresence): RoomScreen =
  case presence
  of apSleeping: rsOff
  of apWorking: rsWorking
  of apTraining: rsTraining
  of apCelebrating: rsDone
  of apHurt: rsError
  of apWalking, apThinking, apWaiting: rsOn

proc roomSeats*(scene: seq[Gladiator]): seq[RoomSeat] =
  ## One desk per gladiator, in scene (roster) order. Only the scene decides; nothing is added.
  for gladiator in scene:
    var seat = RoomSeat(agent: gladiator.agent, presence: gladiator.presence, pose: roomPose(gladiator.presence),
                        screen: roomScreen(gladiator.presence))
    if gladiator.talkingTo.len > 0:
      seat.pose = rpAway
      seat.screen = rsOn
      seat.visiting = gladiator.talkingTo
    result.add seat

const roomSteps* = 4

proc roomStep(run: RunState): int =
  ## Which of the four steps the request is on; 0 when it is on none (or failed). Waiting for the
  ## owner's approval holds it at running; a finished request fills the bar.
  if not run.active: return 0
  case run.status
  of "completed": return roomSteps
  of "waiting_approval", "approving", "rejecting": return 3
  else: discard
  case run.progressStage
  of "routing": 1
  of "planning": 2
  of "executing": 3
  of "synthesizing": 4
  else: 0

proc roomTopBar*(scene: seq[Gladiator], run: RunState): RoomTopBar =
  result = RoomTopBar(step: roomStep(run), steps: roomSteps)
  for gladiator in scene:
    case gladiator.presence
    of apThinking, apWorking: inc result.busy
    of apWaiting: inc result.waiting
    of apTraining: inc result.training
    of apHurt: inc result.failed
    else: discard

proc zoomIn*(zoom: int): int = min(zoom + 1, maxZoom)
proc zoomOut*(zoom: int): int = max(zoom - 1, minZoom)

proc fitZoom*(roomWidth, roomHeight, viewWidth, viewHeight: int): int =
  ## The largest whole-pixel step at which the whole room fits the view (the expanded room).
  result = minZoom
  for zoom in minZoom .. maxZoom:
    if roomWidth * zoom <= viewWidth and roomHeight * zoom <= viewHeight:
      result = zoom
