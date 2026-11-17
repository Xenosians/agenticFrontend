## The agents' room in 2.5D (owner decision, 17 November): the expanded room is drawn by three.js
## (public/js/room3d.js) from the same seats the 2D room shows. This module turns the app's seats
## into the plain data the renderer draws and mounts or removes it; Nim keeps the state.

import std/[json, jsffi, strutils]
import ludus, agent_presence

type Room3dSeat* = object
  agent*, state*, screen*, visiting*: string

proc presenceState*(presence: AgentPresence): string =
  ## The renderer's state word for each of the eight gladiator states.
  const words: array[AgentPresence, string] = ["sleeping", "walking", "thinking", "working", "training",
                                               "waiting", "celebrating", "hurt"]
  words[presence]

proc screenWord*(screen: RoomScreen): string =
  const words: array[RoomScreen, string] = ["off", "on", "working", "training", "done", "error"]
  words[screen]

proc room3dSeats*(seats: seq[RoomSeat]): seq[Room3dSeat] =
  ## One drawn seat per room seat, same order and states; nothing is added.
  for seat in seats:
    result.add Room3dSeat(agent: seat.agent, state: presenceState(seat.presence),
                          screen: screenWord(seat.screen), visiting: seat.visiting)

proc room3dJson*(seats: seq[Room3dSeat]): string =
  var rows = newJArray()
  for seat in seats:
    rows.add %*{"agent": seat.agent, "state": seat.state, "screen": seat.screen, "visiting": seat.visiting}
  $rows

proc room3dLabel*(names: seq[string]): string =
  ## What the canvas says to screen readers: every agent and what he is doing.
  "Agents' room: " & names.join("; ")

proc room3dSupported*(): bool {.importjs: "(globalThis.AgenticRoom3D ? globalThis.AgenticRoom3D.supported() : false)".}

# Karax puts the view in the page after the view proc returns, so both run on the next frame.
# The renderer belongs to its host element; a host Karax removed takes its renderer with it.
proc mountRoom3d(selector, seats, label: cstring, columns: int, animate: bool) {.importjs: """
((selector, seats, label, columns, animate) => requestAnimationFrame(() => {
  const host = document.querySelector(selector);
  if (!host || !globalThis.AgenticRoom3D) return;
  const parsed = JSON.parse(seats);
  globalThis.__room3dSeats = parsed;
  for (const stale of globalThis.__room3dHosts || []) {
    if (stale !== host && stale.__room3d && !stale.isConnected) { stale.__room3d.destroy(); stale.__room3d = null; }
  }
  if (!host.__room3d) {
    // The page's resolved theme (dark, light or the system's), as the stylesheet applies it.
    const dark = document.documentElement.dataset.theme !== "light";
    host.__room3d = globalThis.AgenticRoom3D.create(host, {dark});
    globalThis.__room3dHosts = [...(globalThis.__room3dHosts || []).filter(h => h.isConnected), host];
  }
  host.__room3d.update(parsed, columns, label);
  host.__room3d.animate(animate);
}))(#, #, #, #, #)""".}

proc unmountRoom3d() {.importjs: """
(() => requestAnimationFrame(() => {
  for (const host of globalThis.__room3dHosts || []) {
    if (host.__room3d) { host.__room3d.destroy(); host.__room3d = null; }
  }
  globalThis.__room3dHosts = [];
}))()""".}

proc prefersReducedMotion*(): bool {.importjs: "(globalThis.matchMedia ? globalThis.matchMedia('(prefers-reduced-motion: reduce)').matches : false)".}

proc showRoom3d*(selector: string, seats: seq[Room3dSeat], label: string, columns: int) =
  ## Draws (or redraws) the 3D room in the element; animation stops when the user prefers less motion.
  mountRoom3d(cstring(selector), cstring(room3dJson(seats)), cstring(label), columns,
              not prefersReducedMotion())

proc hideRoom3d*() =
  ## Stops and removes every 3D room renderer (the room was closed or turned off).
  unmountRoom3d()
