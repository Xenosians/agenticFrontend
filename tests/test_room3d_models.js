"use strict";
// The agents' room in 2.5D (owner decision, 17 November): an isometric voxel room drawn with three.js.
// These tests cover the pure part: the voxel models and the scene layout, which decide what is drawn
// for each agent's real state. Rendering itself needs WebGL and is checked in the browser suite.
const {test} = require("node:test");
const assert = require("node:assert/strict");
const room = require("../public/js/room3d_models.js");

const STATES = ["sleeping", "walking", "thinking", "working", "training", "waiting", "celebrating", "hurt"];
const SCREENS = ["off", "on", "working", "training", "done", "error"];

function voxelsOf(model) {
  return model.voxels.map(([x, y, z, tone]) => `${x},${y},${z},${tone}`);
}

test("every voxel uses one of the monochrome tones and sits inside its model's bounds", () => {
  const models = [room.desk("on"), room.stool(), ...STATES.map(state => room.gladiator(state, 0, false))];
  for (const model of models) {
    assert.ok(model.voxels.length > 0);
    for (const [x, y, z, tone] of model.voxels) {
      assert.ok(Number.isInteger(x) && Number.isInteger(y) && Number.isInteger(z));
      assert.ok(x >= 0 && x < model.size[0] && y >= 0 && y < model.size[1] && z >= 0 && z < model.size[2],
                `voxel ${x},${y},${z} outside ${model.size}`);
      assert.ok(room.TONES.includes(tone), `tone ${tone} is not monochrome`);
    }
    // No two voxels share a cell: a duplicate would z-fight.
    assert.equal(new Set(model.voxels.map(([x, y, z]) => `${x},${y},${z}`)).size, model.voxels.length);
  }
  for (const tone of room.TONES) assert.match(tone, /^#([0-9a-f])\1\1$|^#([0-9a-f]{2})\2\2$/);
});

test("each of the eight states has its own silhouette, and animated states change between frames", () => {
  const silhouettes = new Set(STATES.map(state => voxelsOf(room.gladiator(state, 0, false)).join(";")));
  assert.equal(silhouettes.size, STATES.length);
  for (const state of ["walking", "working", "thinking", "celebrating"]) {
    assert.ok(room.FRAMES[state] >= 2, `${state} must animate`);
    assert.notDeepEqual(voxelsOf(room.gladiator(state, 0, false)), voxelsOf(room.gladiator(state, 1, false)));
  }
  for (const state of STATES) assert.ok(Number.isInteger(room.FRAMES[state]) && room.FRAMES[state] >= 1);
});

test("the hub is told apart by his plume, and every gladiator carries the shield and gladius", () => {
  const hub = room.gladiator("waiting", 0, true);
  const specialist = room.gladiator("waiting", 0, false);
  assert.ok(hub.voxels.length > specialist.voxels.length);
  assert.ok(hub.parts.includes("plume") && !specialist.parts.includes("plume"));
  for (const model of [hub, specialist]) {
    for (const part of ["helmet", "shield", "gladius"]) assert.ok(model.parts.includes(part), part);
  }
});

test("no pose is cut off at its model's edge: every part it places is drawn", () => {
  for (const state of STATES) {
    for (let frame = 0; frame < room.FRAMES[state]; frame++) {
      for (const hub of [false, true]) {
        const model = room.gladiator(state, frame, hub);
        assert.equal(model.dropped, 0, `${state} frame ${frame} hub ${hub} lost voxels`);
        for (const part of ["legs", "torso", "helmet", "shield", "gladius"]) {
          assert.ok(model.parts.includes(part), `${state} frame ${frame} has no ${part}`);
        }
      }
    }
  }
  for (const screen of SCREENS) assert.equal(room.desk(screen).dropped, 0);
});

test("a seated working gladiator is lower than a standing one, so he sits on his stool", () => {
  // Posture is the body's height; floating marks (thought dots, sleep Z's) do not count.
  const top = model => Math.max(...model.voxels.filter(([, , , , part]) => part !== "zed" && part !== "thought")
    .map(([, y]) => y));
  assert.ok(top(room.gladiator("working", 0, false)) < top(room.gladiator("waiting", 0, false)));
  assert.ok(top(room.gladiator("sleeping", 0, false)) < top(room.gladiator("working", 0, false)));
  assert.ok(top(room.gladiator("hurt", 0, false)) < top(room.gladiator("working", 0, false)));
});

test("each screen state lights the monitor differently, and off is darker than on", () => {
  const screens = SCREENS.map(screen => room.desk(screen));
  assert.equal(new Set(screens.map(model => voxelsOf(model).join(";"))).size, SCREENS.length);
  const brightness = model => model.voxels.filter(([, , , , part]) => part === "screen")
    .reduce((sum, [, , , tone]) => sum + parseInt(tone.slice(1, 3), 16), 0);
  assert.ok(brightness(room.desk("off")) < brightness(room.desk("on")));
});

test("the layout seats every agent at his own desk in roster order, the hub first, on an isometric grid", () => {
  const seats = [
    {agent: "hub", state: "waiting", screen: "on", visiting: ""},
    {agent: "proxmox-specialist", state: "working", screen: "working", visiting: ""},
    {agent: "networking-specialist", state: "sleeping", screen: "off", visiting: ""},
    {agent: "ticket-specialist", state: "hurt", screen: "error", visiting: ""},
    {agent: "access-specialist", state: "celebrating", screen: "done", visiting: ""},
  ];
  const layout = room.layout(seats, 4);
  assert.deepEqual(layout.desks.map(desk => desk.agent), seats.map(seat => seat.agent));
  assert.deepEqual(layout.desks.slice(0, 5).map(desk => [desk.column, desk.row]),
                   [[0, 0], [1, 0], [2, 0], [3, 0], [0, 1]]);
  // Desks never overlap.
  const cells = layout.desks.map(desk => `${desk.x},${desk.z}`);
  assert.equal(new Set(cells).size, cells.length);
  assert.ok(layout.floor.width >= Math.max(...layout.desks.map(desk => desk.x)) + room.DESK_SPACING);
});

test("on a hand-off the hub stands at the specialist's desk, and his own stool is empty", () => {
  const seats = [
    {agent: "hub", state: "walking", screen: "on", visiting: "proxmox-specialist"},
    {agent: "proxmox-specialist", state: "thinking", screen: "on", visiting: ""},
  ];
  const layout = room.layout(seats, 4);
  const hub = layout.desks[0], specialist = layout.desks[1];
  assert.equal(hub.occupied, false);
  assert.equal(layout.visitor.agent, "hub");
  assert.equal(layout.visitor.atDesk, "proxmox-specialist");
  assert.ok(Math.abs(layout.visitor.x - specialist.x) < room.DESK_SPACING);
  assert.notEqual(layout.visitor.x, hub.x);
  // He stands (never seated in mid-air) behind the desk, farther from the camera than the screen,
  // and still on the floor, inside the back wall.
  assert.equal(layout.visitor.standing, true);
  assert.ok(layout.visitor.z < specialist.z);
  assert.ok(layout.visitor.z >= 0 && layout.visitor.x >= 0);
});

test("a visitor in a seated state is drawn standing, keeping that state's own marks", () => {
  const body = model => Math.max(...model.voxels.filter(([, , , , part]) => part !== "zed" && part !== "thought")
    .map(([, y]) => y));
  const standing = room.gladiator("thinking", 0, true, true);
  assert.equal(body(standing), body(room.gladiator("waiting", 0, true)));
  assert.ok(standing.parts.includes("thought"));
  assert.equal(standing.dropped, 0);
});

test("the screen faces the seat: a lit screen's face is on the side where its gladiator sits", () => {
  const model = room.desk("working");
  const monitor = model.voxels.filter(([, , , , part]) => part === "monitor" || part === "screen");
  const screenX = Math.max(...model.voxels.filter(([, , , , part]) => part === "screen").map(([x]) => x));
  assert.equal(screenX, Math.max(...monitor.map(([x]) => x)));
  assert.ok(room.STATION.seat.x > screenX);
});

function cellsOf(object) {
  return object.voxels.map(([x, y, z]) => `${x},${y},${z}`);
}

function fullRoom(visiting) {
  // Every state at a desk, the hub on a hand-off when asked, on the dialog's four columns.
  const seats = [{agent: "hub", state: visiting ? "walking" : "thinking", screen: "on",
                  visiting: visiting ? "agent-working" : ""}];
  for (const state of STATES) seats.push({agent: `agent-${state}`, state, screen: "on", visiting: ""});
  return room.layout(seats, 4);
}

test("in every frame, nothing in the room shares a cell with anything else, and all of it is on the floor", () => {
  for (const visiting of [false, true]) {
    const layout = fullRoom(visiting);
    for (let frame = 0; frame < 4; frame++) {
      const owner = new Map();
      for (const [index, object] of room.scene(layout, frame).entries()) {
        for (const cell of cellsOf(object)) {
          assert.ok(!owner.has(cell), `${object.kind} of ${object.agent} overlaps ${owner.get(cell)} at ${cell}` +
                                      ` (frame ${frame}, hand-off ${visiting})`);
          owner.set(cell, `${object.kind} of ${object.agent}#${index}`);
        }
        for (const [x, y, z] of object.voxels) {
          assert.ok(x >= 0 && z >= 0 && y >= 0 && x < layout.floor.width && z < layout.floor.depth,
                    `${object.kind} of ${object.agent} leaves the floor at ${x},${y},${z}`);
        }
      }
    }
  }
});

test("a seated gladiator sits on his stool and a working one's hands reach the keyboard", () => {
  const layout = fullRoom(false);
  const objects = room.scene(layout, 0);
  const of = (kind, agent) => objects.find(object => object.kind === kind && object.agent === agent);
  for (const state of ["sleeping", "thinking", "working", "hurt"]) {
    const body = of("gladiator", `agent-${state}`), seat = of("stool", `agent-${state}`);
    const seatTop = new Set(seat.voxels.filter(([, y]) => y === 1).map(([x, , z]) => `${x},${z}`));
    // Some of his thighs rest right on the seat (one voxel above it).
    assert.ok(body.voxels.some(([x, y, z, , part]) => part === "legs" && y === 2 && seatTop.has(`${x},${z}`)), state);
  }
  const typist = of("gladiator", "agent-working"), deskOf = of("desk", "agent-working");
  const keys = deskOf.voxels.filter(([, , , , part]) => part === "keyboard");
  const hands = typist.voxels.filter(([, , , , part]) => part === "arms");
  const touching = hands.some(([hx, hy, hz]) => keys.some(([kx, ky, kz]) =>
    Math.abs(hx - kx) + Math.abs(hy - ky) + Math.abs(hz - kz) === 1));
  assert.ok(touching, "the typing hands must touch the keyboard");
});

test("standing gladiators tuck their stool under the desk, and a seated one's stool shows behind him", () => {
  const objects = room.scene(fullRoom(false), 0);
  const of = (kind, agent) => objects.find(object => object.kind === kind && object.agent === agent);
  const top = object => Math.max(...object.voxels.map(([, y]) => y));
  for (const state of ["walking", "training", "waiting", "celebrating"]) {
    const desk = of("desk", `agent-${state}`), seat = of("stool", `agent-${state}`);
    const minX = Math.min(...desk.voxels.map(([x]) => x)), maxX = Math.max(...desk.voxels.map(([x]) => x));
    assert.ok(seat.voxels.every(([x]) => x >= minX && x <= maxX), `${state}: stool not tucked`);
    assert.ok(top(seat) < 6);
  }
  const body = of("gladiator", "agent-working"), seat = of("stool", "agent-working");
  // The seat reaches past his back (toward the viewer), so it can be seen.
  assert.ok(Math.max(...seat.voxels.map(([x]) => x)) > Math.max(...body.voxels.filter(([, y]) => y <= 2).map(([x]) => x)));
});

test("the hub's crest, thought dots and sleep marks are on the viewer's side once he turns to his screen", () => {
  const objects = room.scene(fullRoom(false), 1);
  const of = agent => objects.find(object => object.kind === "gladiator" && object.agent === agent);
  for (const [agent, part] of [["agent-thinking", "thought"], ["agent-sleeping", "zed"]]) {
    const body = of(agent);
    const marks = body.voxels.filter(([, , , , p]) => p === part);
    const head = body.voxels.filter(([, , , , p]) => p === "helmet");
    assert.ok(marks.length >= 3, `${agent} shows ${part}`);
    // Viewer's side: toward +x and +z from the middle of his head, and above it.
    const middle = axis => head.reduce((sum, voxel) => sum + voxel[axis], 0) / head.length;
    assert.ok(marks.every(voxel => voxel[1] > Math.max(...head.map(([, y]) => y))));
    assert.ok(marks.reduce((sum, voxel) => sum + voxel[0] + voxel[2], 0) / marks.length >= middle(0) + middle(2));
  }
  assert.ok(objects.find(object => object.agent === "hub" && object.kind === "gladiator").voxels
    .some(([, , , , part]) => part === "plume"));
});

test("unknown states and screens fall back to quiet ones instead of failing", () => {
  assert.deepEqual(voxelsOf(room.gladiator("dancing", 0, false)), voxelsOf(room.gladiator("waiting", 0, false)));
  assert.deepEqual(voxelsOf(room.desk("rainbow")), voxelsOf(room.desk("on")));
  assert.deepEqual(room.layout([], 4).desks, []);
});
