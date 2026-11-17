/* The agents' room in 2.5D: monochrome voxel models and the scene layout (owner decision, 17 November).
 *
 * Pure data, no three.js: every model is a list of voxels [x, y, z, tone, part] inside model.size
 * (x right, y up, z toward the gladiator's front), built from original geometry (no third-party art).
 * scene() places every desk, stool and gladiator in room coordinates; the renderer (room3d.js) only
 * turns those voxels into lit cubes, so all placement is testable here. Each of the eight gladiator
 * states has its own silhouette, driven by the agent's real Janus state.
 *
 * The camera looks from +x, +y, +z. A desk's screen faces +x; its gladiator sits on the +x side
 * facing the screen, so the viewer sees the lit screen over his shoulder and nothing hides it.
 */
(function (root) {
  "use strict";

  // Monochrome only: the ink, three greys and the light tone.
  const TONES = ["#111111", "#3a3a3a", "#6b6b6b", "#a8a8a8", "#e8e8e8"];
  const [INK, DARK, MID, LIGHT, PALE] = TONES;
  const FRAMES = {sleeping: 2, walking: 4, thinking: 2, working: 2, training: 2, waiting: 1, celebrating: 2, hurt: 1};
  const STATES = Object.keys(FRAMES);
  const SCREENS = ["off", "on", "working", "training", "done", "error"];
  // Parts that give light rather than take it: a lit screen, thought dots, sleep marks.
  const UNLIT_PARTS = ["screen", "thought", "zed"];
  // A desk with its gladiator beside it is under 20 wide and 12 deep; the rest is aisle.
  const DESK_SPACING = 22;
  const BACK_AISLE = 10;
  const MARGIN = 2;
  // Desk-local places: the seated gladiator (turned to face the screen), the stool under him,
  // the stool tucked under the desk when he stands, and where a standing gladiator stands.
  const STATION = {seat: {x: 8, z: 2}, stool: {x: 10, z: 4}, tucked: {x: 2, z: 3}, stand: {x: 9, z: 2}};

  function builder(size) {
    const cells = new Map();
    const parts = new Set();
    // A voxel outside the model would be cut off; it is counted so tests catch a clipped pose.
    let dropped = 0;
    function put(x, y, z, tone, part) {
      if (x < 0 || y < 0 || z < 0 || x >= size[0] || y >= size[1] || z >= size[2]) { dropped++; return; }
      cells.set(`${x},${y},${z}`, [x, y, z, tone, part]);
      parts.add(part);
    }
    function box(x0, y0, z0, x1, y1, z1, tone, part) {
      for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) for (let z = z0; z <= z1; z++) put(x, y, z, tone, part);
    }
    return {put, box, done: () => ({size, voxels: [...cells.values()], parts: [...parts], dropped})};
  }

  // A gladiator is 9 wide, 18 tall, 7 deep. The pose decides where each part goes.
  const GLADIATOR_SIZE = [9, 18, 7];

  function basePose(state, frame) {
    const step = frame % 2;
    switch (state) {
      case "sleeping": return {seated: true, slump: 3, headTilt: 1, arms: "folded", breathe: step, zed: true};
      case "walking": return {seated: false, stride: [1, 0, -1, 0][frame % 4], arms: "swing"};
      case "thinking": return {seated: true, arms: "chin", dots: step + 2};
      case "working": return {seated: true, arms: "typing", typing: step};
      case "training": return {seated: false, arms: "thrust", thrust: step};
      case "celebrating": return {seated: false, arms: "raised", hop: step};
      case "hurt": return {seated: true, slump: 2, arms: "low", shieldDown: true};
      default: return {seated: false, arms: "rest"};
    }
  }

  function pose(state, frame, standing) {
    const chosen = basePose(state, frame);
    // A visitor stands at another desk: a seated pose keeps its arms but gets standing legs.
    if (standing && chosen.seated) return {...chosen, seated: false, slump: 0, headTilt: 0, zed: false};
    return chosen;
  }

  function gladiator(state, frame, hub, standing) {
    if (!STATES.includes(state)) state = "waiting";
    const p = pose(state, frame, Boolean(standing));
    const b = builder(GLADIATOR_SIZE);
    const lift = p.hop ? 1 : 0;
    if (p.seated) {
      // Thighs forward from the hips over the stool (its seat top is y 1), shins down to the floor.
      b.box(2, 0, 5, 3, 1, 6, DARK, "legs");
      b.box(5, 0, 5, 6, 1, 6, DARK, "legs");
      b.box(2, 2, 2, 6, 3, 6, MID, "legs");
    } else {
      const stride = p.stride || 0;
      b.box(2, lift, 2 + Math.max(0, stride), 3, 4 + lift, 3 + Math.max(0, stride), DARK, "legs");
      b.box(5, lift, 2 + Math.max(0, -stride), 6, 4 + lift, 3 + Math.max(0, -stride), DARK, "legs");
    }
    // Torso: a light tunic with a dark belt. A slump shortens it (the shoulders drop); it never
    // sinks into the thighs.
    const torsoBottom = p.seated ? 4 : 5 + lift;
    const torsoTop = torsoBottom + 4 - Math.min(p.slump || 0, 2);
    b.box(2, torsoBottom, 2, 6, torsoTop, 4, LIGHT, "torso");
    b.box(2, torsoBottom + 1, 2, 6, torsoBottom + 1, 4, INK, "torso");
    // Helmet with a dark visor slit across its front; a sleeping head drops forward onto his chest.
    const headBottom = torsoTop + 1 - (p.headTilt || 0);
    const headFront = 2 + (p.headTilt || 0);
    b.box(3, headBottom, headFront, 5, headBottom + 2, headFront + 2, PALE, "helmet");
    b.box(3, headBottom + 1, headFront + 2, 5, headBottom + 1, headFront + 2, INK, "helmet");
    if (hub) {
      // The hub's crest: a dark fan from brow to nape, trailing down the back.
      b.box(4, headBottom + 3, headFront - 1, 4, headBottom + 3, headFront + 2, INK, "plume");
      b.box(4, headBottom + 4, headFront, 4, headBottom + 4, headFront + 1, INK, "plume");
      b.put(4, headBottom + 2, headFront - 1, INK, "plume");
    }
    // The shield on one arm, the gladius in the other hand; both follow the arms.
    const shoulder = torsoTop;
    const shieldY = p.shieldDown ? torsoBottom : shoulder - 3;
    b.box(0, shieldY, 2, 1, shieldY + 3, 4, MID, "shield");
    b.put(0, shieldY + 1, 5, INK, "shield");
    switch (p.arms) {
      case "typing":
        // Forearms out to the keyboard; the hands lift and fall between frames.
        b.box(7, shoulder - 1, 3, 7, shoulder - 1, 6, LIGHT, "arms");
        b.box(3, shoulder - 1, 5, 6, shoulder - 1 + p.typing, 6, LIGHT, "arms");
        b.box(8, 2, 1, 8, 4, 1, PALE, "gladius");
        break;
      case "chin":
        // Elbow raised, the hand at his chin.
        b.box(7, shoulder - 1, 3, 7, headBottom, 4, LIGHT, "arms");
        b.box(6, headBottom, 5, 7, headBottom, 5, LIGHT, "arms");
        b.box(8, shoulder - 3, 1, 8, shoulder, 1, PALE, "gladius");
        // Thought dots rise beside his head on the viewer's side; the last one is a bubble.
        b.put(7, headBottom + 3, 1, PALE, "thought");
        if (p.dots >= 2) b.put(8, headBottom + 4, 1, PALE, "thought");
        if (p.dots >= 3) b.box(7, headBottom + 5, 0, 8, headBottom + 6, 1, PALE, "thought");
        break;
      case "raised":
        b.box(7, shoulder, 3, 7, shoulder + 3, 3, LIGHT, "arms");
        b.box(7, shoulder + 4, 3, 7, Math.min(GLADIATOR_SIZE[1] - 1, shoulder + 8), 3, PALE, "gladius");
        break;
      case "thrust":
        b.box(7, shoulder - 1, 3, 7, shoulder - 1, 4 + p.thrust, LIGHT, "arms");
        b.box(7, shoulder - 1, 5 + p.thrust, 7, shoulder - 1, Math.min(GLADIATOR_SIZE[2] - 1, 6 + p.thrust), PALE, "gladius");
        break;
      case "swing":
        b.box(7, shoulder - 3, 3, 7, shoulder - 1, 3, LIGHT, "arms");
        b.box(8, shoulder - 6, 3 + (p.stride > 0 ? 1 : 0), 8, shoulder - 3, 3 + (p.stride > 0 ? 1 : 0), PALE, "gladius");
        break;
      case "folded":
        // Arms folded on the chest; the gladius rests across his lap.
        b.box(3, torsoBottom + 2, 5, 5, torsoBottom + 2 + p.breathe, 5, LIGHT, "arms");
        b.box(2, 4, 6, 6, 4, 6, PALE, "gladius");
        break;
      case "low":
        // Arms hanging; the gladius has dropped to the floor.
        b.box(7, torsoBottom, 3, 7, shoulder - 1, 3, LIGHT, "arms");
        b.box(7, 0, 5, 8, 0, 6, PALE, "gladius");
        break;
      default:
        b.box(7, shoulder - 3, 3, 7, shoulder - 1, 3, LIGHT, "arms");
        b.box(8, shoulder - 7, 3, 8, shoulder - 3, 3, PALE, "gladius");
    }
    if (p.zed) {
      // A sleep mark, a Z, rising beside him on the viewer's side as he breathes. Its diagonal runs
      // from top right to bottom left as seen once he has turned to his screen.
      const y = headBottom + 5 + p.breathe;
      b.box(5, y + 3, 1, 8, y + 3, 1, PALE, "zed");
      b.put(6, y + 2, 1, PALE, "zed");
      b.put(7, y + 1, 1, PALE, "zed");
      b.box(5, y, 1, 8, y, 1, PALE, "zed");
    }
    const model = b.done();
    model.seated = Boolean(p.seated);
    return model;
  }

  // A desk seen from the camera's corner: the monitor stands at the back (low x) with its screen
  // facing +x, toward the seated gladiator and the camera. Knee space under the top takes a
  // tucked stool.
  const DESK_SIZE = [8, 13, 12];

  function desk(screen) {
    if (!SCREENS.includes(screen)) screen = "on";
    const b = builder(DESK_SIZE);
    b.box(0, 6, 0, 7, 6, 11, MID, "top");
    b.box(0, 0, 0, 7, 5, 1, DARK, "legs");
    b.box(0, 0, 9, 7, 5, 11, DARK, "drawers");
    b.box(7, 2, 10, 7, 2, 10, LIGHT, "drawers");
    b.box(7, 4, 10, 7, 4, 10, LIGHT, "drawers");
    b.box(1, 7, 5, 1, 7, 6, DARK, "monitor");
    b.box(1, 8, 2, 1, 12, 9, INK, "monitor");
    const face = {off: DARK, on: PALE, working: PALE, training: LIGHT, done: PALE, error: MID}[screen];
    b.box(2, 9, 3, 2, 11, 8, face, "screen");
    // Each state draws its own mark on the lit screen, in ink: lines of text, a rising curve,
    // a check, a cross.
    const mark = (y, z) => b.put(2, y, z, INK, "screen");
    if (screen === "working") { mark(11, 4); mark(11, 5); mark(11, 6); mark(10, 4); mark(10, 5); mark(9, 4); mark(9, 6); }
    if (screen === "training") { mark(9, 3); mark(9, 4); mark(10, 5); mark(10, 6); mark(11, 7); mark(11, 8); }
    if (screen === "done") { mark(10, 4); mark(9, 5); mark(10, 6); mark(11, 7); }
    if (screen === "error") { mark(9, 4); mark(11, 4); mark(10, 5); mark(9, 6); mark(11, 6); }
    // The keyboard lies at the desk's front edge, under a seated gladiator's hands.
    b.box(6, 7, 4, 7, 7, 7, LIGHT, "keyboard");
    return b.done();
  }

  function stool() {
    // A light seat on four dark legs; a seated gladiator's thighs rest on it.
    const b = builder([5, 2, 5]);
    b.box(0, 1, 0, 4, 1, 4, LIGHT, "seat");
    for (const [x, z] of [[0, 0], [4, 0], [0, 4], [4, 4]]) b.put(x, 0, z, DARK, "leg");
    return b.done();
  }

  // A quarter turn so a gladiator faces -x (his screen): his front goes to low x, his sword side
  // to +z, toward the viewer.
  function turnToScreen(model) {
    const [sx, sy, sz] = model.size;
    return {...model, size: [sz, sy, sx],
            voxels: model.voxels.map(([x, y, z, tone, part]) => [sz - 1 - z, y, x, tone, part])};
  }

  /* One desk per agent in roster order, on rows of `columns` desks (desk units of DESK_SPACING).
   * A hub on a hand-off leaves his stool and stands behind the specialist's desk. */
  function layout(seats, columns) {
    const width = Math.max(1, columns);
    // A back aisle and a side margin, so a visitor behind the first row stays inside the walls.
    const desks = seats.map((seat, index) => {
      const column = index % width, row = Math.floor(index / width);
      return {agent: seat.agent, state: seat.state, screen: seat.screen, column, row,
              x: MARGIN + column * DESK_SPACING, z: BACK_AISLE + row * DESK_SPACING, occupied: !seat.visiting};
    });
    let visitor = null;
    for (const seat of seats) {
      if (!seat.visiting) continue;
      const target = desks.find(item => item.agent === seat.visiting);
      // Behind the desk (farther from the camera), so he never hides the specialist or the screen.
      if (target) visitor = {agent: seat.agent, atDesk: target.agent, state: seat.state, standing: true,
                             x: target.x - 1, z: target.z - 8};
    }
    const rows = Math.max(1, Math.ceil(seats.length / width));
    return {desks, visitor, floor: {width: MARGIN + width * DESK_SPACING, depth: BACK_AISLE + rows * DESK_SPACING}};
  }

  function placed(model, x, z, object) {
    return {...object, voxels: model.voxels.map(([vx, vy, vz, tone, part]) => [vx + x, vy, vz + z, tone, part])};
  }

  /* Every object in room coordinates for one moment: desks and stools (furniture) and gladiators.
   * `frame` is a frame number, or a function giving the frame number for a state (so each state
   * keeps its own pace). The renderer draws exactly these voxels. */
  function scene(roomLayout, frame) {
    const frameOf = typeof frame === "function" ? frame : () => frame;
    const objects = [];
    for (const item of roomLayout.desks) {
      objects.push(placed(desk(item.screen), item.x, item.z, {kind: "desk", agent: item.agent}));
      const tick = frameOf(item.state);
      const figure = item.occupied ? gladiator(item.state, tick % (FRAMES[item.state] || 1), item.agent === "hub")
                                   : null;
      if (figure && figure.seated) {
        objects.push(placed(stool(), item.x + STATION.stool.x, item.z + STATION.stool.z, {kind: "stool", agent: item.agent}));
        objects.push(placed(turnToScreen(figure), item.x + STATION.seat.x, item.z + STATION.seat.z,
                            {kind: "gladiator", agent: item.agent, state: item.state}));
      } else {
        // Standing (or away): the stool is tucked under the desk; a walker paces beside it.
        objects.push(placed(stool(), item.x + STATION.tucked.x, item.z + STATION.tucked.z, {kind: "stool", agent: item.agent}));
        if (figure) {
          const pace = item.state === "walking" ? [0, 1, 2, 1][tick % 4] : 0;
          objects.push(placed(figure, item.x + STATION.stand.x + pace, item.z + STATION.stand.z,
                              {kind: "gladiator", agent: item.agent, state: item.state}));
        }
      }
    }
    const visitor = roomLayout.visitor;
    if (visitor) {
      const tick = frameOf(visitor.state);
      objects.push(placed(gladiator(visitor.state, tick % (FRAMES[visitor.state] || 1), true, true), visitor.x, visitor.z,
                          {kind: "gladiator", agent: visitor.agent, state: visitor.state, visiting: visitor.atDesk}));
    }
    return objects;
  }

  const api = {TONES, FRAMES, DESK_SPACING, STATES, SCREENS, STATION, UNLIT_PARTS,
               gladiator, desk, stool, layout, scene, turnToScreen};
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.AgenticRoomModels = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
