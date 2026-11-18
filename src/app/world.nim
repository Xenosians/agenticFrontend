## The virtual world's floor (owner decision, 18 November): every agent's desk on a grid of tiles,
## in the same order and columns as the agents' room, and the aisles the owner's own gladiator
## walks. Pure display state: nothing here is sent to the server or changes any agent.

import std/[deques, tables]

type
  Tile* = tuple[x, y: int]

  WorldDirection* = enum
    wdUp, wdDown, wdLeft, wdRight

  WorldDesk* = object
    agent*: string
    tile*: Tile

  WorldFloor* = object
    width*, height*: int
    desks*: seq[WorldDesk]

const
  deskPitch = 3   ## a desk tile, then two aisle tiles, across and down
  margin = 1      ## a free aisle along the left and back walls

proc worldFloor*(roster: seq[string], columns: int): WorldFloor =
  ## One desk tile per agent in roster order, `columns` to a row, with aisles around each desk
  ## and a wider front aisle where the owner starts.
  let perRow = max(1, columns)
  for index, agent in roster:
    result.desks.add WorldDesk(agent: agent, tile: (x: margin + (index mod perRow) * deskPitch,
                                                    y: margin + (index div perRow) * deskPitch))
  let rows = max(1, (roster.len + perRow - 1) div perRow)
  # One free tile left of the first desk and right of the last; two between desks.
  result.width = margin + (perRow - 1) * deskPitch + 1 + margin
  result.height = margin + rows * deskPitch

proc inside(floor: WorldFloor, tile: Tile): bool =
  tile.x >= 0 and tile.y >= 0 and tile.x < floor.width and tile.y < floor.height

proc deskAt(floor: WorldFloor, tile: Tile): string =
  for desk in floor.desks:
    if desk.tile == tile: return desk.agent

proc blocked*(floor: WorldFloor, tile: Tile): bool =
  ## Walls and desks block; every other tile is aisle.
  not floor.inside(tile) or floor.deskAt(tile).len > 0

proc ownerStart*(floor: WorldFloor): Tile =
  ## The middle of the front aisle, nearest the viewer.
  (x: floor.width div 2, y: floor.height - 1)

proc moved(tile: Tile, direction: WorldDirection): Tile =
  case direction
  of wdUp: (x: tile.x, y: tile.y - 1)
  of wdDown: (x: tile.x, y: tile.y + 1)
  of wdLeft: (x: tile.x - 1, y: tile.y)
  of wdRight: (x: tile.x + 1, y: tile.y)

proc step*(floor: WorldFloor, tile: Tile, direction: WorldDirection): Tile =
  ## One tile in the direction, or the same tile when a desk or wall is in the way.
  let next = moved(tile, direction)
  if floor.blocked(next): tile else: next

proc facing*(floor: WorldFloor, tile: Tile): string =
  ## The agent whose desk is next to the tile (up, left, right or down), or "".
  for direction in WorldDirection:
    let agent = floor.deskAt(moved(tile, direction))
    if agent.len > 0: return agent

proc walkTo*(floor: WorldFloor, start, goal: Tile): seq[Tile] =
  ## The shortest path of free tiles from start to goal (start excluded), one tile per step.
  ## A desk as the goal means "go to that agent": the walk ends on the nearest free tile beside it.
  ## No path, or a goal outside the floor: an empty walk.
  if not floor.inside(goal) or floor.blocked(start): return @[]
  let deskAgent = floor.deskAt(goal)
  proc arrived(tile: Tile): bool =
    if deskAgent.len > 0: floor.deskAt(tile).len == 0 and floor.facing(tile) == deskAgent and
                          abs(tile.x - goal.x) + abs(tile.y - goal.y) == 1
    else: tile == goal
  if arrived(start): return @[]
  var came = initTable[Tile, Tile]()
  var queue = initDeque[Tile]()
  queue.addLast start
  came[start] = start
  while queue.len > 0:
    let tile = queue.popFirst
    for direction in WorldDirection:
      let next = moved(tile, direction)
      if floor.blocked(next) or came.hasKey(next): continue
      came[next] = tile
      if arrived(next):
        var path = @[next]
        var back = tile
        while back != start:
          path.insert(back, 0)
          back = came[back]
        return path
      queue.addLast next
