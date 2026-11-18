import std/[options, unittest]
import ../src/app/world

## The virtual world's floor (owner decision, 18 November): desks on a grid of tiles in the
## same order and columns as the agents' room; the owner's own gladiator walks the aisles.
## Display state only: nothing here is sent to the server.

suite "the world's floor":
  test "every agent has one desk tile, in roster order, four to a row":
    let floor = worldFloor(@["hub", "networking-specialist", "proxmox-specialist"], columns = 4)
    check floor.desks.len == 3
    check floor.desks[0].agent == "hub"
    check floor.desks[0].tile == (x: 1, y: 1)
    check floor.desks[1].tile == (x: 4, y: 1)
    check floor.desks[2].tile == (x: 7, y: 1)
    check floor.width == 12 and floor.height == 4
    let wide = worldFloor(@["hub", "a", "b", "c", "d"], columns = 4)
    check wide.desks[4].tile == (x: 1, y: 4)
    check wide.height == 7

  test "the owner starts in the front aisle, on a free tile":
    let floor = worldFloor(@["hub", "proxmox-specialist"], columns = 4)
    let start = ownerStart(floor)
    check start.y == floor.height - 1
    check not blocked(floor, start)

  test "the owner walks one tile per step and never through a desk or a wall":
    let floor = worldFloor(@["hub", "proxmox-specialist"], columns = 4)
    let start = ownerStart(floor)
    check step(floor, start, wdUp) == (x: start.x, y: start.y - 1)
    check step(floor, (x: 0, y: 0), wdLeft) == (x: 0, y: 0)
    check step(floor, (x: 0, y: 0), wdUp) == (x: 0, y: 0)
    check step(floor, (x: floor.width - 1, y: 0), wdRight) == (x: floor.width - 1, y: 0)
    # The tile in front of a desk is free; the desk itself is not.
    check step(floor, (x: 1, y: 2), wdUp) == (x: 1, y: 2)

  test "standing next to a desk faces its agent; elsewhere nobody":
    let floor = worldFloor(@["hub", "proxmox-specialist"], columns = 4)
    check facing(floor, (x: 1, y: 2)) == "hub"
    check facing(floor, (x: 0, y: 1)) == "hub"
    check facing(floor, (x: 5, y: 1)) == "proxmox-specialist"
    check facing(floor, (x: 2, y: 3)) == ""

  test "a click on the floor walks a shortest free path there, around desks":
    let floor = worldFloor(@["hub", "proxmox-specialist"], columns = 4)
    let path = walkTo(floor, (x: 1, y: 3), (x: 1, y: 0))
    check path.len > 0
    check path[^1] == (x: 1, y: 0)
    for tile in path:
      check not blocked(floor, tile)
    var previous = (x: 1, y: 3)
    for tile in path:
      check abs(tile.x - previous.x) + abs(tile.y - previous.y) == 1
      previous = tile
    # Around the desk at (1, 1): the straight line is blocked, so the path is longer than 3.
    check path.len > 3
    # A desk tile itself is never a destination: the walk ends beside it, facing its agent.
    let toDesk = walkTo(floor, (x: 1, y: 3), (x: 4, y: 1))
    check toDesk.len > 0 and facing(floor, toDesk[^1]) == "proxmox-specialist"
    check not blocked(floor, toDesk[^1])
    # Outside the floor: no walk.
    check walkTo(floor, (x: 1, y: 3), (x: 50, y: 50)).len == 0

suite "the world page's state":
  test "a key moves the owner one tile; arrows and WASD both work, other keys do nothing":
    check worldKeyDirection("ArrowUp") == some(wdUp)
    check worldKeyDirection("w") == some(wdUp)
    check worldKeyDirection("A") == some(wdLeft)
    check worldKeyDirection("ArrowRight") == some(wdRight)
    check worldKeyDirection("s") == some(wdDown)
    check worldKeyDirection("Enter").isNone
    check worldKeyDirection("x").isNone

  test "walking up to a desk opens that agent's card; moving away closes it":
    var walk = newWorldWalk(worldFloor(@["hub", "proxmox-specialist"], columns = 4))
    check walk.tile == ownerStart(walk.floor)
    check walk.card == ""
    # From the front aisle up the column left of the hub's desk, then right to face him.
    walk.goTo((x: 0, y: 1))
    while walk.advance(): discard
    check walk.tile == (x: 0, y: 1)
    check walk.card == "hub"
    walk.press(wdDown)
    check walk.tile == (x: 0, y: 2)
    check walk.card == ""

  test "clicking a desk walks there one tile per step and opens the card on arrival":
    var walk = newWorldWalk(worldFloor(@["hub", "proxmox-specialist"], columns = 4))
    walk.goTo((x: 4, y: 1))
    check walk.walking
    check walk.card == ""
    var steps = 0
    while walk.advance(): inc steps
    check steps > 1
    check not walk.walking
    check walk.card == "proxmox-specialist"
    check not blocked(walk.floor, walk.tile)

  test "a key press stops a walk in progress; a blocked press leaves the owner where he is":
    var walk = newWorldWalk(worldFloor(@["hub"], columns = 4))
    walk.goTo((x: 0, y: 0))
    discard walk.advance()
    let before = walk.tile
    walk.press(wdUp)
    check not walk.walking
    check walk.tile == step(walk.floor, before, wdUp)
    # Against the left wall another press leaves him where he is.
    for _ in 0 ..< walk.floor.width: walk.press(wdLeft)
    let atWall = walk.tile
    check atWall.x == 0 or blocked(walk.floor, (x: atWall.x - 1, y: atWall.y))
    walk.press(wdLeft)
    check walk.tile == atWall

  test "choosing an agent opens his card without moving; the floor follows a new roster":
    var walk = newWorldWalk(worldFloor(@["hub", "proxmox-specialist"], columns = 4))
    let start = walk.tile
    walk.choose("proxmox-specialist")
    check walk.card == "proxmox-specialist" and walk.tile == start
    walk.reseat(worldFloor(@["hub", "networking-specialist", "proxmox-specialist"], columns = 4))
    check walk.floor.desks.len == 3
    check not blocked(walk.floor, walk.tile)
    walk.choose("nobody")
    check walk.card == ""
