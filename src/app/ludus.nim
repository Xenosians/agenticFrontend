## The ludus: one gladiator per real agent, each acting out what his agent is doing.
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
  LudusArea* = enum
    laBarracks, laYard, laArena, laGate

  Gladiator* = object
    agent*: string        ## the agent's identifier ("hub" or a specialist name)
    presence*: AgentPresence
    talkingTo*: string    ## the specialist the hub is handing the request to, if any

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

proc ludusArea*(presence: AgentPresence): LudusArea =
  case presence
  of apSleeping: laBarracks
  of apTraining: laYard
  of apWaiting: laGate
  of apWalking, apThinking, apWorking, apCelebrating, apHurt: laArena

proc gladiatorArea*(gladiator: Gladiator, scene: seq[Gladiator]): LudusArea =
  ## Where he stands: the area of his own state, except that the hub, while handing a request over,
  ## stands with that specialist so the two are seen talking.
  if gladiator.talkingTo.len > 0:
    for other in scene:
      if other.agent == gladiator.talkingTo: return ludusArea(other.presence)
  ludusArea(gladiator.presence)

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

proc zoomIn*(zoom: int): int = min(zoom + 1, maxZoom)
proc zoomOut*(zoom: int): int = max(zoom - 1, minZoom)

proc fitZoom*(roomWidth, roomHeight, viewWidth, viewHeight: int): int =
  ## The largest whole-pixel step at which the whole room fits the view.
  result = minZoom
  for zoom in minZoom .. maxZoom:
    if roomWidth * zoom <= viewWidth and roomHeight * zoom <= viewHeight:
      result = zoom
