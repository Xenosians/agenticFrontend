## The gladiator's state: what Janus is really doing, as one of eight animations.
##
## Only state the app already holds decides it: service health, the observed
## chat job (its durable status and the job socket's progress word) and the
## owner's learning runs. A finished job is a moment (celebrating or hurt) that
## lasts until the next quiet spell; a long quiet spell puts him to sleep.

import types
import learning

type
  AgentPresence* = enum
    apSleeping, apWalking, apThinking, apWorking, apTraining, apWaiting, apCelebrating, apHurt

const
  ## Seconds without any activity before the gladiator lies down.
  sleepAfterSeconds* = 300
  ## Seconds a finished job's moment (celebrating or hurt) lasts.
  momentSeconds* = 12
  thinkingStages = ["routing", "planning", "waiting_provider"]
  hurtStatuses = ["failed", "outcome_unknown", "reconciliation_required", "submission_unknown"]
  ## Every status in which Janus is still doing something for the observed job.
  busyStatuses = ["submitting", "restoring", "pending", "processing", "approving", "rejecting"]

proc presenceState*(run: RunState, system: SystemState, learningRuns: seq[LearningRun],
                    idleSeconds: int): AgentPresence =
  ## idleSeconds: time since the observed job last changed (or since the page opened).
  if not (system.checked and system.backendConnected and system.aiReady):
    return apSleeping
  if run.active:
    if run.status == "waiting_approval":
      return apWaiting
    if run.status in busyStatuses:
      if run.status in ["approving", "rejecting"] or run.progressStage notin thinkingStages and
          run.progressStage.len > 0:
        return apWorking
      return apThinking
  for learningRun in learningRuns:
    if learningRun.state in activeLearningRunStates:
      return apTraining
  if run.active and idleSeconds < momentSeconds:
    if run.status == "completed":
      return apCelebrating
    if run.status in hurtStatuses:
      return apHurt
  if idleSeconds >= sleepAfterSeconds:
    return apSleeping
  apWalking

proc presenceCaption*(presence: AgentPresence): string =
  case presence
  of apSleeping: "Janus is asleep"
  of apWalking: "Janus is ready"
  of apThinking: "Janus is thinking"
  of apWorking: "Janus is working on your request"
  of apTraining: "Janus is training"
  of apWaiting: "Janus is waiting for your approval"
  of apCelebrating: "Janus finished the request"
  of apHurt: "Janus could not finish the request"

proc presenceClass*(presence: AgentPresence): string =
  const names: array[AgentPresence, string] = ["sleeping", "walking", "thinking", "working", "training",
                                               "waiting", "celebrating", "hurt"]
  "gladiator gladiator-" & names[presence]
