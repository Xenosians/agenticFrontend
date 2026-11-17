/* The agents' room in 2.5D, drawn with three.js (owner decision, 17 November).
 *
 * A fixed isometric camera looks at a monochrome voxel room: one desk per agent with his
 * gladiator at it. room3d_models.js decides every voxel from the agents' real Janus state; this
 * file only draws them, lit by one key light with real shadows. The Nim app owns the state and
 * calls update() whenever it changes. Without WebGL the app keeps the 2D room (supported() is
 * false); when the user prefers reduced motion the room is drawn still (animate(false)).
 */
(function (root) {
  "use strict";

  const models = root.AgenticRoomModels;
  // How long each state holds a frame, in milliseconds: a typist is quick, a sleeper slow.
  const FRAME_MS = {sleeping: 900, walking: 180, thinking: 700, working: 240, training: 380, waiting: 1000,
                    celebrating: 320, hurt: 1000};
  const THEMES = {
    dark: {floor: "#5a5a5a", wall: "#707070", ambient: 0.55, key: 2.3},
    light: {floor: "#c4c4c4", wall: "#9a9a9a", ambient: 0.75, key: 1.7},
  };

  function supported() {
    try {
      const canvas = document.createElement("canvas");
      return Boolean(root.THREE && models && (canvas.getContext("webgl2") || canvas.getContext("webgl")));
    } catch (error) {
      return false;
    }
  }

  function create(host, options) {
    const THREE = root.THREE;
    const theme = THEMES[options && options.dark === false ? "light" : "dark"];
    const renderer = new THREE.WebGLRenderer({antialias: true, alpha: true, preserveDrawingBuffer: true});
    renderer.setPixelRatio(Math.min(2, root.devicePixelRatio || 1));
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFShadowMap;
    renderer.domElement.className = "room3d-canvas";
    renderer.domElement.setAttribute("role", "img");
    host.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, -1000, 1000);
    scene.add(new THREE.AmbientLight(0xffffff, theme.ambient));
    // The key light comes from behind the left wall, so shadows fall toward the viewer's right.
    const sun = new THREE.DirectionalLight(0xffffff, theme.key);
    sun.castShadow = true;
    sun.shadow.mapSize.set(2048, 2048);
    sun.shadow.bias = -0.0004;
    sun.shadow.normalBias = 0.02;
    scene.add(sun);
    scene.add(sun.target);

    const cube = new THREE.BoxGeometry(1, 1, 1);
    const materials = new Map();
    function material(tone, unlit) {
      // A lit screen, thought dots and sleep marks give light: they keep their tone in shadow.
      const key = (unlit ? "u" : "l") + tone;
      if (!materials.has(key)) {
        materials.set(key, unlit ? new THREE.MeshBasicMaterial({color: tone})
                                 : new THREE.MeshLambertMaterial({color: tone}));
      }
      return materials.get(key);
    }

    const furniture = new THREE.Group();
    const figures = new THREE.Group();
    scene.add(furniture);
    scene.add(figures);
    const matrix = new THREE.Matrix4();

    function addVoxels(group, objects) {
      // One instanced mesh per tone and lighting across all objects: a few draw calls per frame.
      const batches = new Map();
      for (const object of objects) {
        for (const voxel of object.voxels) {
          const unlit = models.UNLIT_PARTS.includes(voxel[4]) && voxel[3] !== "#3a3a3a";
          const key = (unlit ? "u" : "l") + voxel[3];
          if (!batches.has(key)) batches.set(key, {tone: voxel[3], unlit, voxels: []});
          batches.get(key).voxels.push(voxel);
        }
      }
      for (const batch of batches.values()) {
        const mesh = new THREE.InstancedMesh(cube, material(batch.tone, batch.unlit), batch.voxels.length);
        batch.voxels.forEach(([x, y, z], index) => {
          matrix.makeTranslation(x + 0.5, y + 0.5, z + 0.5);
          mesh.setMatrixAt(index, matrix);
        });
        mesh.castShadow = !batch.unlit;
        mesh.receiveShadow = !batch.unlit;
        group.add(mesh);
      }
    }

    function clear(group) {
      for (const child of [...group.children]) {
        if (child.isInstancedMesh) child.dispose();
        else if (child.geometry) child.geometry.dispose();
        group.remove(child);
      }
    }

    let layout = models.layout([], 4);
    let started = 0;
    let shown = "";
    let running = false;
    let raf = 0;

    // Each state keeps its own pace: its frame number is the time since the room opened over its
    // frame length.
    const frameAt = time => state => Math.floor(Math.max(0, time - started) / (FRAME_MS[state] || 1000));

    function drawFurniture() {
      clear(furniture);
      const width = layout.floor.width, depth = layout.floor.depth;
      const floorMaterial = new THREE.MeshLambertMaterial({color: theme.floor});
      const floor = new THREE.Mesh(new THREE.PlaneGeometry(width, depth), floorMaterial);
      floor.rotation.x = -Math.PI / 2;
      floor.position.set(width / 2, 0, depth / 2);
      floor.receiveShadow = true;
      furniture.add(floor);
      // Two walls (back and left) close the room on the sides away from the camera.
      const wallMaterial = new THREE.MeshLambertMaterial({color: theme.wall});
      const back = new THREE.Mesh(new THREE.BoxGeometry(width + 1, 18, 1), wallMaterial);
      back.position.set(width / 2 - 0.5, 9, -0.5);
      const left = new THREE.Mesh(new THREE.BoxGeometry(1, 18, depth), wallMaterial);
      left.position.set(-0.5, 9, depth / 2);
      for (const wall of [back, left]) { wall.receiveShadow = true; furniture.add(wall); }
      addVoxels(furniture, models.scene(layout, 0).filter(object => object.kind !== "gladiator"));
    }

    function drawFigures(time) {
      const objects = models.scene(layout, frameAt(time)).filter(object => object.kind === "gladiator");
      // Redraw only when a pose changed: most frames, nothing moves.
      const signature = objects.map(object => object.voxels.map(voxel => voxel.slice(0, 3).join(",")).join(";"))
        .join("|");
      if (signature === shown && figures.children.length) return false;
      shown = signature;
      clear(figures);
      addVoxels(figures, objects);
      return true;
    }

    function fitCamera() {
      const width = layout.floor.width, depth = layout.floor.depth;
      const centre = new THREE.Vector3(width / 2, 6, depth / 2);
      // The classic isometric view: 45 degrees around, about 35 degrees down.
      camera.position.set(centre.x + 200, centre.y + 163, centre.z + 200);
      camera.lookAt(centre);
      camera.updateMatrixWorld();
      // Fit the room's corners (floor and wall tops) to the canvas with a small margin.
      const corners = [];
      for (const x of [0, width]) for (const y of [0, 20]) for (const z of [0, depth]) corners.push(new THREE.Vector3(x, y, z));
      let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
      for (const corner of corners) {
        corner.applyMatrix4(camera.matrixWorldInverse);
        minX = Math.min(minX, corner.x); maxX = Math.max(maxX, corner.x);
        minY = Math.min(minY, corner.y); maxY = Math.max(maxY, corner.y);
      }
      const aspect = Math.max(1, host.clientWidth) / Math.max(1, host.clientHeight);
      let halfWidth = (maxX - minX) / 2 * 1.04, halfHeight = (maxY - minY) / 2 * 1.04;
      if (halfWidth / halfHeight > aspect) halfHeight = halfWidth / aspect; else halfWidth = halfHeight * aspect;
      const middleX = (minX + maxX) / 2, middleY = (minY + maxY) / 2;
      camera.left = middleX - halfWidth;
      camera.right = middleX + halfWidth;
      camera.top = middleY + halfHeight;
      camera.bottom = middleY - halfHeight;
      camera.updateProjectionMatrix();
      sun.target.position.copy(centre);
      sun.position.set(centre.x - 90, centre.y + 150, centre.z + 25);
      const reach = Math.max(width, depth);
      Object.assign(sun.shadow.camera, {left: -reach, right: reach, top: reach, bottom: -reach, near: 1, far: 600});
      sun.shadow.camera.updateProjectionMatrix();
    }

    function render() {
      renderer.render(scene, camera);
    }

    const now = () => (root.performance ? root.performance.now() : 0);

    function redraw() {
      renderer.setSize(Math.max(1, host.clientWidth), Math.max(1, host.clientHeight), false);
      fitCamera();
      drawFurniture();
      shown = "";
      drawFigures(now());
      render();
    }

    function tick(time) {
      if (!running) return;
      raf = root.requestAnimationFrame(tick);
      if (drawFigures(time)) render();
    }

    const observer = typeof root.ResizeObserver === "function" ? new root.ResizeObserver(() => redraw()) : null;
    if (observer) observer.observe(host);

    return {
      update(seats, columns, label) {
        layout = models.layout(Array.isArray(seats) ? seats : [], columns || 4);
        renderer.domElement.setAttribute("aria-label", label || "The agents' room");
        if (!started) started = now();
        redraw();
      },
      animate(on) {
        if (on && !running) {
          running = true;
          raf = root.requestAnimationFrame(tick);
        } else if (!on && running) {
          running = false;
          root.cancelAnimationFrame(raf);
        }
      },
      destroy() {
        running = false;
        root.cancelAnimationFrame(raf);
        if (observer) observer.disconnect();
        clear(furniture);
        clear(figures);
        cube.dispose();
        for (const value of materials.values()) value.dispose();
        renderer.dispose();
        renderer.domElement.remove();
      },
    };
  }

  root.AgenticRoom3D = {supported, create};
})(typeof globalThis !== "undefined" ? globalThis : this);
