import std/[json, unittest]
import ../src/app/[types, learning, agent_presence, ludus]

proc catalog(owners: varargs[seq[string]]): JsonNode =
  result = %*{"capabilities": []}
  for index, names in owners:
    result["capabilities"].add %*{"id": "cap" & $index, "agent_names": names}

proc running(status: string, stage = "", agent = ""): RunState =
  RunState(active: true, jobId: "j1", status: status, progressStage: stage, agent: agent)

proc ready(): SystemState =
  SystemState(checked: true, backendConnected: true, aiReachable: true, aiHealthy: true, aiReady: true)

suite "the ludus roster: one gladiator per real agent":
  test "the hub leads, then every specialist that serves a capability, once, in name order":
    let roster = ludusRoster(catalog(@["proxmox-specialist"], @["jira-specialist", "proxmox-specialist"],
                                     @["networking-specialist"]))
    check roster == @["hub", "jira-specialist", "networking-specialist", "proxmox-specialist"]

  test "a missing or malformed catalog still has the hub, and nothing is invented":
    check ludusRoster(nil) == @["hub"]
    check ludusRoster(%*{"capabilities": "none"}) == @["hub"]
    check ludusRoster(%*{"capabilities": [{"id": "x", "agent_names": [1, "", nil]}]}) == @["hub"]
    # Names come from the server's catalog; anything that is not a plain agent name is ignored.
    check ludusRoster(catalog(@["<script>", "Proxmox Specialist", "proxmox-specialist"])) ==
      @["hub", "proxmox-specialist"]

  test "each gladiator has a plain name for people and keeps his agent's identifier":
    check gladiatorTitle("hub") == "Janus (hub)"
    check gladiatorTitle("proxmox-specialist") == "Proxmox specialist"
    check gladiatorTitle("service-desk-specialist") == "Service desk specialist"

suite "who does what in the ludus":
  let roster = @["hub", "networking-specialist", "proxmox-specialist"]

  test "with nothing running the hub walks and the specialists rest":
    let scene = ludusScene(roster, RunState(), ready(), @[], idleSeconds = 30)
    check scene[0].presence == apWalking
    check scene[1].presence == apSleeping and scene[2].presence == apSleeping

  test "while the hub routes a request he thinks; nobody else is involved yet":
    let scene = ludusScene(roster, running("processing", "routing"), ready(), @[], idleSeconds = 0)
    check scene[0].presence == apThinking
    check scene[0].talkingTo == ""
    check scene[2].presence == apSleeping

  test "once a specialist is named, the hub goes to him and he does the work":
    let scene = ludusScene(roster, running("processing", "executing", "proxmox-specialist"), ready(), @[],
                           idleSeconds = 0)
    check scene[0].talkingTo == "proxmox-specialist"
    check scene[2].presence == apWorking
    check scene[1].presence == apSleeping

  test "the named specialist waits at the gate for approval, then celebrates or is hurt":
    check ludusScene(roster, running("waiting_approval", agent = "proxmox-specialist"), ready(), @[],
                     idleSeconds = 0)[2].presence == apWaiting
    check ludusScene(roster, running("completed", agent = "proxmox-specialist"), ready(), @[],
                     idleSeconds = 1)[2].presence == apCelebrating
    check ludusScene(roster, running("failed", agent = "proxmox-specialist"), ready(), @[],
                     idleSeconds = 1)[2].presence == apHurt

  test "an agent not in the roster is never drawn: the hub carries the job alone":
    let scene = ludusScene(roster, running("processing", "executing", "unknown-specialist"), ready(), @[],
                           idleSeconds = 0)
    check scene.len == roster.len
    check scene[0].presence == apWorking and scene[0].talkingTo == ""

  test "a hub learning run trains the hub; a specialist run trains the specialists":
    let hubRun = LearningRun(id: "r1", state: "running", role: "hub")
    check ludusScene(roster, RunState(), ready(), @[hubRun], idleSeconds = 0)[0].presence == apTraining
    let specialistRun = LearningRun(id: "r2", state: "running", role: "specialist")
    let scene = ludusScene(roster, RunState(), ready(), @[specialistRun], idleSeconds = 0)
    check scene[0].presence == apWalking
    check scene[1].presence == apTraining and scene[2].presence == apTraining

  test "services down put everyone to sleep":
    for gladiator in ludusScene(roster, running("processing", "executing", "proxmox-specialist"),
                                SystemState(checked: true), @[], idleSeconds = 0):
      check gladiator.presence == apSleeping

suite "the hub speaks with the specialist he hands a request to":
  test "while handing over, the hub is with the specialist; the others keep to themselves":
    let roster = @["hub", "networking-specialist", "proxmox-specialist"]
    let scene = ludusScene(roster, running("waiting_approval", agent = "proxmox-specialist"), ready(), @[],
                           idleSeconds = 0)
    check scene[0].talkingTo == "proxmox-specialist"
    check scene[1].talkingTo == "" and scene[2].talkingTo == ""

  test "with no hand-off the hub keeps to his own desk":
    let roster = @["hub", "proxmox-specialist"]
    let scene = ludusScene(roster, running("processing", "routing"), ready(), @[], idleSeconds = 0)
    check scene[0].talkingTo == ""

suite "the live hand-off: the agent the AI names while it works":
  let roster = @["hub", "networking-specialist", "proxmox-specialist"]

  proc live(stage, agent: string, status = "processing", named = ""): RunState =
    result = running(status, stage, named)
    result.progressAgent = agent

  test "while the specialist plans his call, the hub stands with him and both think":
    let scene = ludusScene(roster, live("planning", "proxmox-specialist"), ready(), @[], idleSeconds = 0)
    check scene[0].talkingTo == "proxmox-specialist"
    check scene[0].presence == apThinking and scene[2].presence == apThinking
    check scene[1].presence == apSleeping

  test "while the specialist's tool runs he works and the hub watches with him":
    let scene = ludusScene(roster, live("executing", "proxmox-specialist"), ready(), @[], idleSeconds = 0)
    check scene[2].presence == apWorking
    check scene[0].talkingTo == "proxmox-specialist" and scene[0].presence == apThinking

  test "when the hub writes the answer he works alone, even after a specialist was named":
    for named in ["", "proxmox-specialist"]:
      let scene = ludusScene(roster, live("synthesizing", "hub", named = named), ready(), @[], idleSeconds = 0)
      check scene[0].presence == apWorking and scene[0].talkingTo == ""
      check scene[2].presence == apSleeping

  test "a live name outside the roster is ignored; the hub carries the step":
    let scene = ludusScene(roster, live("planning", "made-up-specialist"), ready(), @[], idleSeconds = 0)
    check scene[0].talkingTo == "" and scene[0].presence == apThinking
    for gladiator in scene[1 .. ^1]:
      check gladiator.presence == apSleeping

  test "without a live name the server's named agent decides, as before":
    let scene = ludusScene(roster, live("", "", status = "waiting_approval", named = "proxmox-specialist"), ready(),
                           @[], idleSeconds = 0)
    check scene[0].talkingTo == "proxmox-specialist" and scene[2].presence == apWaiting

suite "zoom steps keep the pixel art crisp":
  test "the large room takes the largest whole-pixel step (1x to 4x) that fits the window":
    check fitZoom(roomWidth = 320, roomHeight = 180, viewWidth = 700, viewHeight = 400) == 2
    check fitZoom(roomWidth = 320, roomHeight = 180, viewWidth = 300, viewHeight = 400) == 1
    check fitZoom(roomWidth = 320, roomHeight = 180, viewWidth = 5000, viewHeight = 5000) == 4


suite "the agents' room: every agent at his own desk, like a small studio":
  let roster = @["hub", "networking-specialist", "proxmox-specialist"]

  proc live(stage, agent: string, status = "processing", named = ""): RunState =
    result = running(status, stage, named)
    result.progressAgent = agent

  proc seatOf(room: seq[RoomSeat], agent: string): RoomSeat =
    for seat in room:
      if seat.agent == agent: return seat

  test "each agent has one desk in roster order, the hub's first; idle desks are dark":
    let room = roomSeats(ludusScene(roster, RunState(), ready(), @[], idleSeconds = 30))
    check room.len == 3
    check room[0].agent == "hub" and room[1].agent == "networking-specialist"
    # The hub is ready at his desk; the specialists doze with their screens off.
    check room[0].pose == rpIdle and room[0].screen == rsOn
    check room[1].pose == rpDozing and room[1].screen == rsOff
    check room[2].pose == rpDozing and room[2].screen == rsOff
    check room[0].visiting == ""

  test "while the hub routes he thinks at his own desk; nobody else stirs":
    let room = roomSeats(ludusScene(roster, live("routing", "hub"), ready(), @[], idleSeconds = 0))
    check room[0].pose == rpPondering and room[0].screen == rsOn
    check room[0].visiting == ""
    check seatOf(room, "proxmox-specialist").pose == rpDozing

  test "the hub walks to the specialist's desk and stands with him while he plans, then types":
    var room = roomSeats(ludusScene(roster, live("planning", "proxmox-specialist"), ready(), @[],
                                    idleSeconds = 0))
    # The hub's seat is empty: he is at the proxmox specialist's desk.
    check room[0].pose == rpAway and room[0].visiting == "proxmox-specialist"
    check seatOf(room, "proxmox-specialist").pose == rpPondering
    room = roomSeats(ludusScene(roster, live("executing", "proxmox-specialist"), ready(), @[], idleSeconds = 0))
    check seatOf(room, "proxmox-specialist").pose == rpTyping
    check seatOf(room, "proxmox-specialist").screen == rsWorking
    check room[0].visiting == "proxmox-specialist"
    check seatOf(room, "networking-specialist").pose == rpDozing

  test "approval and the finish: the specialist waits; the hub celebrates with him, then goes back":
    let waiting = roomSeats(ludusScene(roster, running("waiting_approval", agent = "proxmox-specialist"),
                                       ready(), @[], idleSeconds = 0))
    check seatOf(waiting, "proxmox-specialist").pose == rpWaiting
    check waiting[0].visiting == "proxmox-specialist"
    let done = roomSeats(ludusScene(roster, running("completed", agent = "proxmox-specialist"), ready(), @[],
                                    idleSeconds = 1))
    check done[0].visiting == "proxmox-specialist" and done[0].presence == apCelebrating
    # Once the moment has passed the hub is back at his own desk.
    let later = roomSeats(ludusScene(roster, running("completed", agent = "proxmox-specialist"), ready(), @[],
                                     idleSeconds = momentSeconds))
    check later[0].visiting == "" and later[0].pose == rpIdle
    let writing = roomSeats(ludusScene(roster, live("synthesizing", "hub", named = "proxmox-specialist"),
                                       ready(), @[], idleSeconds = 0))
    check writing[0].pose == rpTyping and writing[0].screen == rsWorking and writing[0].visiting == ""

  test "the finish shows on the desk: a cheer and a check mark, or a slump and a cross":
    let done = roomSeats(ludusScene(roster, running("completed", agent = "proxmox-specialist"), ready(), @[],
                                    idleSeconds = 1))
    check seatOf(done, "proxmox-specialist").pose == rpCheering
    check seatOf(done, "proxmox-specialist").screen == rsDone
    let failed = roomSeats(ludusScene(roster, running("failed", agent = "proxmox-specialist"), ready(), @[],
                                      idleSeconds = 1))
    check seatOf(failed, "proxmox-specialist").pose == rpSlumped
    check seatOf(failed, "proxmox-specialist").screen == rsError

  test "training, services down: training agents work on a learning curve, an outage darkens every desk":
    let training = roomSeats(ludusScene(roster, RunState(), ready(),
                                        @[LearningRun(id: "r", state: "running", role: "specialist")],
                                        idleSeconds = 0))
    check training[1].pose == rpTyping and training[2].pose == rpTyping
    check training[1].screen == rsTraining
    for seat in roomSeats(ludusScene(roster, live("executing", "proxmox-specialist"), SystemState(checked: true),
                                     @[], idleSeconds = 0)):
      check seat.pose == rpDozing and seat.screen == rsOff and seat.visiting == ""

suite "the room's top bar: the request, its step and four counters":
  let roster = @["hub", "networking-specialist", "proxmox-specialist"]

  test "with nothing running there is no step and every counter is zero, the dozing ones excepted":
    let bar = roomTopBar(ludusScene(roster, RunState(), ready(), @[], idleSeconds = 30), RunState())
    check bar.step == 0 and bar.steps == 4
    check bar.busy == 0 and bar.waiting == 0 and bar.training == 0 and bar.failed == 0

  test "the step follows the job: routing 1, planning 2, running 3, writing 4 of 4":
    for (stage, step) in [("routing", 1), ("planning", 2), ("executing", 3), ("synthesizing", 4)]:
      let run = running("processing", stage, "proxmox-specialist")
      check roomTopBar(ludusScene(roster, run, ready(), @[], idleSeconds = 0), run).step == step
    let queued = running("pending")
    check roomTopBar(ludusScene(roster, queued, ready(), @[], idleSeconds = 0), queued).step == 0
    # Waiting on the provider keeps the step it was on: nothing more is claimed.
    let provider = running("processing", "waiting_provider")
    check roomTopBar(ludusScene(roster, provider, ready(), @[], idleSeconds = 0), provider).step == 0

  test "approval holds the step at running; the finish fills the bar; a failure empties it":
    let waiting = running("waiting_approval", agent = "proxmox-specialist")
    var bar = roomTopBar(ludusScene(roster, waiting, ready(), @[], idleSeconds = 0), waiting)
    check bar.step == 3 and bar.waiting == 1
    let done = running("completed", agent = "proxmox-specialist")
    check roomTopBar(ludusScene(roster, done, ready(), @[], idleSeconds = 1), done).step == 4
    # A failure hurts the specialist and the hub with him: the counter counts what the room shows.
    let failed = running("failed", agent = "proxmox-specialist")
    bar = roomTopBar(ludusScene(roster, failed, ready(), @[], idleSeconds = 1), failed)
    check bar.failed == 2 and bar.step == 0

  test "busy counts agents thinking or working; training counts those in a learning run":
    let run = running("processing", "executing", "proxmox-specialist")
    let bar = roomTopBar(ludusScene(roster, run, ready(), @[], idleSeconds = 0), run)
    check bar.busy == 2  # the specialist works; the hub thinks with him
    let training = roomTopBar(ludusScene(roster, RunState(), ready(),
                                         @[LearningRun(id: "r", state: "running", role: "specialist")],
                                         idleSeconds = 0), RunState())
    check training.training == 2 and training.busy == 0

suite "the room preview in the chat list says who is doing what":
  let roster = @["hub", "networking-specialist", "proxmox-specialist"]

  test "one line names the busiest agents first, counts the sleepers, and says when all sleep":
    check roomCaption(ludusScene(roster, RunState(), ready(), @[], idleSeconds = 30)) ==
      "Janus (hub) is walking about; the other 2 are asleep."
    let asleep = ludusScene(roster, RunState(), SystemState(), @[], idleSeconds = 30)
    check roomCaption(asleep) == "Everyone is asleep."
    let run = running("processing", "executing", "proxmox-specialist")
    check roomCaption(ludusScene(roster, run, ready(), @[], idleSeconds = 0)) ==
      "Proxmox specialist is working; Janus (hub) is thinking; the other one is asleep."
    let waiting = running("waiting_approval", agent = "proxmox-specialist")
    check roomCaption(ludusScene(roster, waiting, ready(), @[], idleSeconds = 0)) ==
      "Proxmox specialist is waiting for your approval; Janus (hub) is thinking; the other one is asleep."
    # With nobody asleep the line names everyone and adds nothing.
    check roomCaption(ludusScene(@["hub"], RunState(), ready(), @[], idleSeconds = 30)) ==
      "Janus (hub) is walking about."

  test "the slim row's one line fits beside its sprites: who and what for one, the busiest state for more":
    # The full sentence stays the row's tooltip and spoken text; the row shows a line that fits in full
    # instead of cutting the sentence mid-word (owner decision, 26 November: a slim, readable row).
    check roomRowLine(ludusScene(roster, RunState(), ready(), @[], idleSeconds = 30)) == "Janus is walking"
    check roomRowLine(ludusScene(roster, RunState(), SystemState(), @[], idleSeconds = 30)) == "All asleep"
    let run = running("processing", "executing", "proxmox-specialist")
    let busy = ludusScene(roster, run, ready(), @[], idleSeconds = 0)
    check roomRowLine(busy) == "Working"
    # The busiest agent is drawn first, so the line describes the first sprite.
    var order: seq[string]
    for gladiator in busiestFirst(busy): order.add gladiator.agent
    check order == @["proxmox-specialist", "hub"]
    let waiting = running("waiting_approval", agent = "proxmox-specialist")
    check roomRowLine(ludusScene(roster, waiting, ready(), @[], idleSeconds = 0)) == "Needs you"
    check roomRowLine(ludusScene(@["hub", "proxmox-specialist"], waiting, ready(), @[], idleSeconds = 0)) ==
      "Needs you"
    # Short enough: each state's word, and one agent with the longest name a roster has.
    for presence in AgentPresence:
      if presence != apSleeping:
        check shortPresenceWord(presence).len <= 10
    check roomRowLine(@[Gladiator(agent: "networking-specialist", presence: apWaiting)]) == "Networking needs you"
    # A longer name than the row has room for gives the state alone.
    check roomRowLine(@[Gladiator(agent: "infrastructure-specialist", presence: apWorking)]) == "Working"
    check roomRowSprites == 2

suite "each agent's recent steps (world decision 3: a card shows what he did)":
  proc step(stage, agent: string, status = "processing"): RunState =
    RunState(active: true, jobId: "j1", status: status, progressStage: stage, progressAgent: agent)

  test "each new stage is recorded once for the agent doing it, in order, with plain words":
    var log: StepLog
    log.note(step("routing", "hub"))
    log.note(step("routing", "hub"))
    log.note(step("planning", "proxmox-specialist"))
    log.note(step("executing", "proxmox-specialist"))
    log.note(step("synthesizing", "hub"))
    check log.recent("hub") == @["Chose who handles the request", "Wrote the answer"]
    check log.recent("proxmox-specialist") == @["Planned the action", "Ran the tool"]
    check log.recent("networking-specialist").len == 0

  test "the outcome is recorded once for the agent that did the work":
    var log: StepLog
    log.note(step("executing", "proxmox-specialist"))
    var waiting = step("", "", "waiting_approval")
    waiting.agent = "proxmox-specialist"
    log.note(waiting)
    log.note(waiting)
    var done = step("", "", "completed")
    done.agent = "proxmox-specialist"
    log.note(done)
    check log.recent("proxmox-specialist") == @["Ran the tool", "Asked for your approval", "Finished the request"]
    var failed = step("", "", "failed")
    failed.jobId = "j2"
    failed.agent = "hub"
    log.note(failed)
    check log.recent("hub") == @["The request failed"]

  test "a new request starts the agents' steps over; only the last few are kept":
    var log: StepLog
    log.note(step("routing", "hub"))
    var next = step("routing", "hub")
    next.jobId = "j2"
    log.note(next)
    check log.recent("hub") == @["Chose who handles the request"]
    # One long request (a plan with several tool calls) keeps only the newest steps.
    for index in 0 ..< 12:
      var job = step(if index mod 2 == 0: "planning" else: "executing", "proxmox-specialist")
      job.jobId = "j3"
      log.note(job)
    check log.recent("proxmox-specialist").len == maxRecentSteps
    check log.recent("proxmox-specialist")[^1] == "Ran the tool"

  test "an agent the AI does not name, or no request at all, records nothing":
    var log: StepLog
    log.note(RunState())
    log.note(step("routing", "Not A Name"))
    log.note(step("thinking-hard", "hub"))
    check log.recent("hub").len == 0
    check log.recent("Not A Name").len == 0
