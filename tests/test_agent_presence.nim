import std/unittest
import ../src/app/[types, learning, agent_presence]

proc running(status: string, stage = ""): RunState =
  RunState(active: true, jobId: "j1", status: status, progressStage: stage)

proc ready(): SystemState =
  SystemState(checked: true, backendConnected: true, aiReachable: true, aiHealthy: true, aiReady: true)

proc learningRun(state: string): LearningRun =
  LearningRun(id: "run-1", state: state)

suite "the gladiator acts out what Janus is really doing":
  test "nothing happening: he walks around, and sleeps after a long quiet spell":
    check presenceState(RunState(), ready(), @[], idleSeconds = 30) == apWalking
    check presenceState(RunState(), ready(), @[], idleSeconds = 600) == apSleeping

  test "services that are down or unchecked put him to sleep, never to work":
    check presenceState(RunState(), SystemState(), @[], idleSeconds = 0) == apSleeping
    check presenceState(running("processing"), SystemState(checked: true), @[], idleSeconds = 0) == apSleeping

  test "choosing tools and planning is thinking; running tools and writing the answer is working":
    # The stages are the job socket's progress words (routing, planning, executing, synthesizing,
    # waiting_provider); before the first one arrives, a queued or submitted job is still being thought about.
    check presenceState(running("submitting"), ready(), @[], idleSeconds = 0) == apThinking
    check presenceState(running("pending"), ready(), @[], idleSeconds = 0) == apThinking
    check presenceState(running("processing"), ready(), @[], idleSeconds = 0) == apThinking
    check presenceState(running("processing", "routing"), ready(), @[], idleSeconds = 0) == apThinking
    check presenceState(running("processing", "planning"), ready(), @[], idleSeconds = 0) == apThinking
    check presenceState(running("processing", "waiting_provider"), ready(), @[], idleSeconds = 0) == apThinking
    check presenceState(running("processing", "executing"), ready(), @[], idleSeconds = 0) == apWorking
    check presenceState(running("processing", "synthesizing"), ready(), @[], idleSeconds = 0) == apWorking
    check presenceState(running("approving"), ready(), @[], idleSeconds = 0) == apWorking

  test "a proposal waiting for the owner makes him wait":
    check presenceState(running("waiting_approval"), ready(), @[], idleSeconds = 0) == apWaiting

  test "a finished job: celebrating on success, hurt on failure or an unknown outcome":
    check presenceState(running("completed"), ready(), @[], idleSeconds = 0) == apCelebrating
    for status in ["failed", "outcome_unknown", "reconciliation_required", "submission_unknown"]:
      check presenceState(running(status), ready(), @[], idleSeconds = 0) == apHurt
    # A cancelled or denied request is no injury: he goes back to walking.
    check presenceState(running("cancelled"), ready(), @[], idleSeconds = 0) == apWalking
    check presenceState(running("denied"), ready(), @[], idleSeconds = 0) == apWalking

  test "celebrating and hurt are moments, not moods":
    check presenceState(running("completed"), ready(), @[], idleSeconds = 20) == apWalking
    check presenceState(running("failed"), ready(), @[], idleSeconds = 20) == apWalking

  test "a learning (SFT) run trains him, unless a chat job needs him first":
    check presenceState(RunState(), ready(), @[learningRun("running")], idleSeconds = 900) == apTraining
    check presenceState(RunState(), ready(), @[learningRun("starting")], idleSeconds = 0) == apTraining
    check presenceState(RunState(), ready(), @[learningRun("completed")], idleSeconds = 30) == apWalking
    check presenceState(running("waiting_approval"), ready(), @[learningRun("running")], idleSeconds = 0) == apWaiting
    check presenceState(running("processing", "executing"), ready(), @[learningRun("running")],
                        idleSeconds = 0) == apWorking
    check presenceState(running("processing"), ready(), @[learningRun("running")], idleSeconds = 0) == apThinking

  test "each state has a plain caption for screen readers and the tooltip":
    check presenceCaption(apSleeping) == "Janus is asleep"
    check presenceCaption(apWalking) == "Janus is ready"
    check presenceCaption(apThinking) == "Janus is thinking"
    check presenceCaption(apWorking) == "Janus is working on your request"
    check presenceCaption(apTraining) == "Janus is training"
    check presenceCaption(apWaiting) == "Janus is waiting for your approval"
    check presenceCaption(apCelebrating) == "Janus finished the request"
    check presenceCaption(apHurt) == "Janus could not finish the request"

  test "the state's class names the animation the stylesheet plays":
    check presenceClass(apWorking) == "gladiator gladiator-working"
    check presenceClass(apSleeping) == "gladiator gladiator-sleeping"
