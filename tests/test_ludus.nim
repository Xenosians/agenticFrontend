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

  test "with nothing running the hub walks and the specialists rest in the barracks":
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

  test "a hub learning run trains the hub; a specialist run trains the specialists' barracks":
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

suite "the ludus places each gladiator in the area his state belongs to":
  test "barracks for sleep, training yard, arena floor for work, the gate for approval":
    check ludusArea(apSleeping) == laBarracks
    check ludusArea(apTraining) == laYard
    check ludusArea(apWorking) == laArena
    check ludusArea(apThinking) == laArena
    check ludusArea(apWaiting) == laGate
    check ludusArea(apWalking) == laArena
    check ludusArea(apCelebrating) == laArena
    check ludusArea(apHurt) == laArena

suite "the hub speaks with the specialist he hands a request to":
  test "while handing over, the hub stands in the specialist's area; the others keep their own":
    let roster = @["hub", "networking-specialist", "proxmox-specialist"]
    let scene = ludusScene(roster, running("waiting_approval", agent = "proxmox-specialist"), ready(), @[],
                           idleSeconds = 0)
    check scene[0].talkingTo == "proxmox-specialist"
    check gladiatorArea(scene[0], scene) == laGate
    check gladiatorArea(scene[2], scene) == laGate
    check gladiatorArea(scene[1], scene) == laBarracks

  test "with no hand-off the hub stands where his own state belongs":
    let roster = @["hub", "proxmox-specialist"]
    let scene = ludusScene(roster, running("processing", "routing"), ready(), @[], idleSeconds = 0)
    check gladiatorArea(scene[0], scene) == laArena

suite "zoom steps keep the pixel art crisp":
  test "whole-pixel steps from 1x to 4x; fit picks the largest step that fits":
    check zoomIn(1) == 2 and zoomIn(4) == 4
    check zoomOut(3) == 2 and zoomOut(1) == 1
    check fitZoom(roomWidth = 320, roomHeight = 180, viewWidth = 700, viewHeight = 400) == 2
    check fitZoom(roomWidth = 320, roomHeight = 180, viewWidth = 300, viewHeight = 400) == 1
    check fitZoom(roomWidth = 320, roomHeight = 180, viewWidth = 5000, viewHeight = 5000) == 4
