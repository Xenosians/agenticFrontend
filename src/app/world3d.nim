## The world's 3D drawing (owner decisions of 18 November): the agents' room renderer
## (public/js/room3d.js) in world mode, on the floor tiles of world.nim, with the owner's own
## gladiator. Nim keeps every piece of state; this module only hands it to the renderer.

import std/[json, strutils]
import room3d, world

proc worldOwnerJson*(tile: Tile, walking: bool, open = ""): string =
  ## Where the owner stands, whether he walks, and whose card is open (that desk is marked).
  $(%*{"tile": {"x": tile.x, "y": tile.y}, "walking": walking, "open": open})

proc mountWorld3d(selector, seats, label, owner: cstring, columns: int, animate: bool,
                  onLoaded: proc()) {.importjs: """
((selector, seats, label, owner, columns, animate, onLoaded) => requestAnimationFrame(() => {
  const host = document.querySelector(selector);
  if (!host || !globalThis.AgenticRoom3D) return;
  const parsed = JSON.parse(seats);
  globalThis.__room3dSeats = parsed;
  if (!host.__room3d) {
    const dark = document.documentElement.dataset.theme !== "light";
    host.__room3d = globalThis.AgenticRoom3D.create(host, {dark, world: true});
    globalThis.__room3dHosts = [...(globalThis.__room3dHosts || []).filter(h => h.isConnected), host];
  }
  host.__room3d.update(parsed, columns, label, JSON.parse(owner));
  host.__room3d.animate(animate);
  // The first drawn frame ends the loading screen.
  if (!host.__worldLoaded) { host.__worldLoaded = true; onLoaded(); }
}))(#, #, #, #, #, #, #)""".}

proc moveWorldOwner(selector, owner: cstring) {.importjs: """
((selector, owner) => { const host = document.querySelector(selector);
  if (host && host.__room3d) host.__room3d.moveOwner(JSON.parse(owner)); })(#, #)""".}

proc animateWorld3d(selector: cstring, on: bool) {.importjs: """
((selector, on) => { const host = document.querySelector(selector);
  if (host && host.__room3d) host.__room3d.animate(on); })(#, #)""".}

proc worldTileAt(selector: cstring, x, y: float): JsonNode =
  ## The floor tile under a point of the drawn world, or nil off the floor.
  proc pick(selector: cstring, x, y: float): cstring {.importjs: """
((selector, x, y) => { const host = document.querySelector(selector);
  if (!host || !host.__room3d) return ""; const tile = host.__room3d.tileAtPoint(x, y);
  return tile ? JSON.stringify(tile) : ""; })(#, #, #)""".}
  let found = $pick(selector, x, y)
  if found.len > 0: parseJson(found) else: nil

proc showWorld3d*(selector: string, seats: seq[Room3dSeat], label: string, columns: int, owner: Tile,
                  walking, animate: bool, open: string, onLoaded: proc()) =
  mountWorld3d(cstring(selector), cstring(room3dJson(seats)), cstring(label),
               cstring(worldOwnerJson(owner, walking, open)), columns, animate, onLoaded)

proc stepWorldOwner*(selector: string, owner: Tile, walking: bool, open: string) =
  moveWorldOwner(cstring(selector), cstring(worldOwnerJson(owner, walking, open)))

proc setWorldMotion*(selector: string, on: bool) =
  animateWorld3d(cstring(selector), on)

proc pickWorldTile*(selector: string, x, y: float): tuple[found: bool, tile: Tile] =
  let node = worldTileAt(cstring(selector), x, y)
  if node.isNil or node.kind != JObject: return (false, (x: 0, y: 0))
  (true, (x: node["x"].getInt, y: node["y"].getInt))

proc worldLabel*(names: seq[string], owner: Tile): string =
  "Agents' world: " & names.join("; ") & "; you are on tile " & $owner.x & ", " & $owner.y
