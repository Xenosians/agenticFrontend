import std/unittest
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
