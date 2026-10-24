// Transparent full-screen 3D overlay built from an asset definition (assets/*.json).
const T = window.THREE;
const ease = { outBack: (t) => 1 + 2.4 * (t - 1) ** 3 + 1.4 * (t - 1) ** 2, inOut: (t) => (t < .5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2) };
const fill = (s, vars) => (s || "").replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? k);

export class Scene3D {
  constructor(canvas, labelsEl, leadersEl) {
    this.canvas = canvas; this.labelsEl = labelsEl; this.leadersEl = leadersEl;
    this.renderer = new T.WebGLRenderer({ canvas, antialias: true, alpha: true });
    this.renderer.setPixelRatio(Math.min(2, devicePixelRatio));
    this.renderer.outputEncoding = T.sRGBEncoding;
    this.renderer.setClearColor(0x000000, 0);
    this.scene = new T.Scene();
    this.camera = new T.PerspectiveCamera(34, 1, 0.1, 200);
    this.scene.add(new T.HemisphereLight(0xffffff, 0x2a3644, 0.95));
    const key = new T.DirectionalLight(0xffffff, 0.85); key.position.set(6, 12, 8); this.scene.add(key);
    const rim = new T.DirectionalLight(0x9fd0ff, 0.35); rim.position.set(-8, 4, -6); this.scene.add(rim);
    this.tweens = []; this.parts = {}; this.labels = []; this.spin = false; this.turn = 0.0028;
    this.view = { offset: 0, zoom: 1 }; this.camPos = new T.Vector3(); this.camTarget = new T.Vector3();
    this.clock = performance.now();
    addEventListener("resize", () => this.resize()); this.resize();
    requestAnimationFrame((t) => this.loop(t));
  }

  resize() {
    const r = this.canvas.getBoundingClientRect();
    this.w = r.width; this.h = r.height;
    this.renderer.setSize(r.width, r.height, false);
    this.camera.aspect = r.width / r.height; this.applyView();
  }
  applyView() {
    const { offset, zoom } = this.view;
    this.camera.setViewOffset(this.w, this.h, offset * this.w, 0, this.w, this.h);
    this.camera.zoom = zoom; this.camera.updateProjectionMatrix();
  }

  // Direct manipulation: drag to orbit, wheel to zoom. Auto-turn pauses while the user is holding the model.
  drag(dx, dy) {
    if (!this.root) return;
    this.root.rotation.y += dx * 0.008;
    this.root.rotation.x = Math.max(-0.6, Math.min(0.6, this.root.rotation.x + dy * 0.006));
    this.held = performance.now();
  }
  zoomBy(delta) { this.view.zoom = Math.max(0.4, Math.min(3, this.view.zoom * Math.exp(-delta * 0.0015))); this.applyView(); this.held = performance.now(); }
  // Screen rectangle covering the visible model, for hit-testing the click-through overlay.
  screenBox() {
    if (!this.root) return null;
    const box = new T.Box3().setFromObject(this.root); if (box.isEmpty()) return null;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; const v = new T.Vector3();
    for (const x of [box.min.x, box.max.x]) for (const y of [box.min.y, box.max.y]) for (const z of [box.min.z, box.max.z]) {
      v.set(x, y, z).project(this.camera); const sx = (v.x + 1) / 2 * this.w, sy = (1 - v.y) / 2 * this.h;
      x0 = Math.min(x0, sx); y0 = Math.min(y0, sy); x1 = Math.max(x1, sx); y1 = Math.max(y1, sy);
    }
    return { x0, y0, x1, y1 };
  }

  tween(ms, fn, easing = ease.inOut) {
    return new Promise((res) => this.tweens.push({ t0: performance.now(), ms, fn, easing, res }));
  }

  clear() {
    if (this.root) this.scene.remove(this.root);
    this.labelsEl.innerHTML = ""; this.leadersEl.innerHTML = ""; this.labels = []; this.parts = {};
    this.spin = false; this.faultPart = null;
  }

  load(def, vars) {
    this.clear(); this.def = def; this.vars = vars;
    this.root = new T.Group(); this.scene.add(this.root);
    this.root.add(shadowDisc(def.scenario === "turbine" ? 3.2 : 3));
    this.rotor = new T.Group(); this.rotorPivot = null;
    for (const p of def.parts) {
      const mesh = new T.Mesh(geometry(p), new T.MeshStandardMaterial({ color: p.color, roughness: .55, metalness: .08, transparent: true }));
      if (p.rot) mesh.rotation.set(...p.rot);
      if (p.scale) mesh.userData.scale = new T.Vector3(...p.scale); else mesh.userData.scale = new T.Vector3(1, 1, 1);
      mesh.scale.setScalar(0.0001); mesh.visible = false;
      mesh.userData.def = p; mesh.userData.base = new T.Vector3(...p.pos);
      if (p.group === "rotor") {
        if (!this.rotorPivot) { this.rotorPivot = new T.Group(); this.rotorPivot.position.set(...p.pos); this.root.add(this.rotorPivot); }
        mesh.position.set(0, 0, 0); this.rotorPivot.add(mesh);
      } else { mesh.position.copy(mesh.userData.base); this.root.add(mesh); }
      this.parts[p.id] = mesh;
      if (p.label) this.labels.push(makeLabel(this.labelsEl, this.leadersEl, mesh, fill(p.label, vars)));
    }
    const c = def.camera;
    this.camPos.set(...c.pos); this.camTarget.set(...c.target);
    this.root.rotation.y = -0.5;
  }

  async showStep(step) {
    const ids = step.parts;
    ids.forEach((id, k) => {
      const m = this.parts[id]; m.visible = true;
      setTimeout(() => {
        const target = m.userData.scale.clone();
        m.material.emissive = new T.Color(0xffffff);
        this.tween(700, (t) => { m.scale.copy(target).multiplyScalar(Math.max(0.0001, t)); m.material.emissiveIntensity = (1 - t) * 0.7; }, ease.outBack);
        const l = this.labels.find((x) => x.mesh === m); if (l) setTimeout(() => l.el.classList.add("on"), 450);
      }, k * 140);
    });
    if (step.spin) this.spin = true;
    if (step.camera === "focus") this.focus();
    if (step.explode) setTimeout(() => this.explode(), ids.length * 140 + 300);
    if (step.fault) setTimeout(() => this.setFault(), ids.length * 140 + 500);
  }

  async explode() {
    const moves = Object.values(this.parts).filter((m) => m.userData.def.explode);
    const from = moves.map((m) => m.position.clone());
    await this.tween(1300, (t) => moves.forEach((m, i) => {
      const e = m.userData.def.explode; m.position.set(from[i].x + e[0] * t, from[i].y + e[1] * t, from[i].z + e[2] * t);
      if (m.userData.def.group === "shell") { m.material.opacity = 1 - 0.86 * t; m.material.depthWrite = t < .5; }
    }));
    this.labels.filter((l) => l.mesh.userData.def.group === "shell").forEach((l) => l.el.classList.remove("on"));
  }

  setFault() {
    const id = this.def.fault.part, m = this.parts[id]; this.faultPart = m;
    m.material.color.set(0xff6a5e); m.material.emissive = new T.Color(0xff2a1a);
    const halo = new T.Sprite(new T.SpriteMaterial({ map: glowTexture(), color: 0xff5a4e, transparent: true, depthWrite: false, blending: T.AdditiveBlending }));
    halo.scale.setScalar(1.6); m.add(halo); this.halo = halo;
    const light = new T.PointLight(0xff4a3a, 1.1, 2.2); m.add(light);
    const l = this.labels.find((x) => x.mesh === m);
    if (l) { l.el.classList.add("fault", "on"); l.el.innerHTML = `<span>${fill(this.def.fault.label, this.vars)}</span>`; l.fault = true;
      if (this.faultSpark) { const c = document.createElement("canvas"); l.el.appendChild(c); this.faultSpark(c); } }
    // Declutter: keep only the fault label once it has been introduced.
    setTimeout(() => this.labels.forEach((x) => { if (!x.fault) x.el.classList.remove("on"); }), 2600);
  }

  focus() {
    const c = this.def.camera, p0 = this.camPos.clone(), t0 = this.camTarget.clone();
    const p1 = new T.Vector3(...c.focusPos), t1 = new T.Vector3(...c.focusTarget);
    this.turn = 0.0014;
    return this.tween(1800, (t) => { this.camPos.lerpVectors(p0, p1, t); this.camTarget.lerpVectors(t0, t1, t); });
  }

  layout(offset, zoom = 1, ms = 1100) {
    const o0 = this.view.offset, z0 = this.view.zoom;
    return this.tween(ms, (t) => { this.view.offset = o0 + (offset - o0) * t; this.view.zoom = z0 + (zoom - z0) * t; this.applyView(); });
  }

  loop(now) {
    const dt = this.paused ? 0 : Math.min(50, now - this.clock); this.clock = now;
    this.tweens = this.tweens.filter((tw) => {
      const t = Math.min(1, (now - tw.t0) / tw.ms); tw.fn(tw.easing(t));
      if (t >= 1) { tw.res(); return false; } return true;
    });
    if (this.root) {
      if (!this.held || now - this.held > 2500) this.root.rotation.y += this.turn * dt / 16;
      if (this.spin && this.rotorPivot) this.rotorPivot.rotation.z += 0.022 * dt / 16;
      if (this.faultPart) {
        const k = (Math.sin(now / 260) + 1) / 2;
        this.faultPart.material.emissiveIntensity = 0.5 + 0.9 * k;
        if (this.halo) this.halo.material.opacity = 0.45 + 0.5 * k;
      }
    }
    this.camera.position.copy(this.camPos); this.camera.lookAt(this.camTarget);
    this.renderer.render(this.scene, this.camera);
    this.placeLabels();
    requestAnimationFrame((t) => this.loop(t));
  }

  placeLabels() {
    if (!this.labels.length || !this.root) return;
    const center = new T.Vector3(); this.root.getWorldPosition(center);
    const cs = center.clone().project(this.camera);
    const cx = (cs.x + 1) / 2 * this.w;
    const v = new T.Vector3();
    for (const l of this.labels) {
      if (!l.mesh.visible) continue;
      l.mesh.getWorldPosition(v); v.project(this.camera);
      const x = (v.x + 1) / 2 * this.w, y = (1 - v.y) / 2 * this.h;
      const side = x >= cx ? 1 : -1, dx = (l.fault ? 150 : 95) * side, dy = l.fault ? -90 : -46;
      const lx = x + dx, ly = y + dy;
      l.el.style.left = lx + "px"; l.el.style.top = ly + "px";
      l.line.setAttribute("x1", x); l.line.setAttribute("y1", y); l.line.setAttribute("x2", lx); l.line.setAttribute("y2", ly);
      l.dot.setAttribute("cx", x); l.dot.setAttribute("cy", y);
      const on = l.el.classList.contains("on");
      l.line.style.opacity = on ? 0.85 : 0; l.dot.style.opacity = on ? 1 : 0;
      l.line.setAttribute("stroke", l.fault ? "#ff5a4e" : "#ffffff"); l.dot.setAttribute("fill", l.fault ? "#ff5a4e" : "#ffffff");
    }
  }
}

function geometry(p) {
  const a = p.args;
  switch (p.shape) {
    case "cyl": return new T.CylinderGeometry(a[0], a[1], a[2], 40);
    case "sphere": return new T.SphereGeometry(a[0], 40, 24);
    case "torus": return new T.TorusGeometry(a[0], a[1], 18, 48);
    case "cone": return new T.ConeGeometry(a[0], a[1], 40);
    case "blade": {
      const [len, w, th] = a, g = new T.BoxGeometry(w, len, th, 1, 12, 1);
      g.translate(0, len / 2 + 0.35, 0);
      const pos = g.attributes.position;
      for (let i = 0; i < pos.count; i++) {
        const t = Math.max(0, (pos.getY(i) - 0.35) / len);
        pos.setX(i, pos.getX(i) * (1 - 0.72 * t) + (pos.getX(i) > 0 ? 0.08 : 0) * (1 - t));
        pos.setZ(i, pos.getZ(i) * (1 - 0.55 * t));
      }
      g.computeVertexNormals(); return g;
    }
    default: return new T.BoxGeometry(...a);
  }
}

function makeLabel(labelsEl, leadersEl, mesh, text) {
  const el = document.createElement("div"); el.className = "plabel"; el.textContent = text; labelsEl.appendChild(el);
  const ns = "http://www.w3.org/2000/svg";
  const line = document.createElementNS(ns, "line"); line.setAttribute("stroke-width", "1.5"); line.style.transition = "opacity .5s"; line.style.opacity = 0;
  const dot = document.createElementNS(ns, "circle"); dot.setAttribute("r", "3.5"); dot.style.transition = "opacity .5s"; dot.style.opacity = 0;
  leadersEl.append(line, dot);
  return { el, line, dot, mesh };
}

let glowTex;
function glowTexture() {
  if (glowTex) return glowTex;
  const c = document.createElement("canvas"); c.width = c.height = 128; const g = c.getContext("2d");
  const r = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  r.addColorStop(0, "rgba(255,255,255,1)"); r.addColorStop(.3, "rgba(255,140,120,.6)"); r.addColorStop(1, "rgba(255,90,78,0)");
  g.fillStyle = r; g.fillRect(0, 0, 128, 128); return (glowTex = new T.CanvasTexture(c));
}

function shadowDisc(r) {
  const c = document.createElement("canvas"); c.width = c.height = 128; const g = c.getContext("2d");
  const grad = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  grad.addColorStop(0, "rgba(0,0,0,.55)"); grad.addColorStop(1, "rgba(0,0,0,0)");
  g.fillStyle = grad; g.fillRect(0, 0, 128, 128);
  const m = new T.Mesh(new T.PlaneGeometry(r * 2, r * 2), new T.MeshBasicMaterial({ map: new T.CanvasTexture(c), transparent: true, depthWrite: false }));
  m.rotation.x = -Math.PI / 2; m.position.y = 0.01; return m;
}
