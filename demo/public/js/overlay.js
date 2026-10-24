// Sidekick overlay: notch UI, screen capture → OCR → vision model → 2D chart + marks on the real cells → 3D → crew.
import { loadCrew, crew, swapCharacter } from "./crew.js";
import { loadData, turbineStats, scoutContext, boltContext, repairWindows, chillerStats, chillerScoutContext, chillerWindows, inr } from "./data.js";
import { Scene3D } from "./scene3d.js";
import { speak, prefetch, wait, chime, pause, resume, skip, recent, isPaused, untilResumed } from "./voice.js";

const $ = (s) => document.querySelector(s);
const P = new URLSearchParams(location.search);
const TOP = +(P.get("top") || 38);
document.documentElement.style.setProperty("--top", Math.max(32, TOP) + "px");
const fillVars = (s, v) => s.replace(/\{(\w+)\}/g, (_, k) => v[k] ?? k);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const W = () => innerWidth, H = () => innerHeight;
let D, S, scene, role = "Operator", audit = [], busy = false, last = null, waiter = null;

// In a normal browser (testing) there is no Electron bridge: use a screenshot file as the "screen".
const bridge = window.sidekick || {
  capture: async () => {
    const url = P.get("screen"); const b = await (await fetch(url)).blob();
    const img = await createImageBitmap(b);
    const png = await new Promise((r) => { const fr = new FileReader(); fr.onload = () => r(fr.result.split(",")[1]); fr.readAsDataURL(b); });
    return { png, scale: img.width / innerWidth };
  },
  interactive: async () => {}, touchId: async () => true, onShortcut: () => {},
};
if (!window.sidekick && P.get("screen")) Object.assign(document.body.style, { background: `url(${P.get("screen")}) top left / 100% auto no-repeat` });

init();
async function init() {
  await loadCrew();
  D = await loadData(); S = turbineStats(D);
  scene = new Scene3D($("#gl"), $("#labels"), $("#leaders"));
  scene.faultSpark = (c) => spark(c, S.turbine.series.vib.slice(-73), "#ffffff");
  notchIdle();
  addEventListener("mousemove", (e) => {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    const b = document.body.classList.contains("show3d") && scene.screenBox(), pad = 30;
    const onModel = !!b && e.clientX > b.x0 - pad && e.clientX < b.x1 + pad && e.clientY > b.y0 - pad && e.clientY < b.y1 + pad;
    $("#stage3d").classList.toggle("grab", onModel || dragging);
    bridge.interactive(onModel || dragging || !!(el && el.closest(".hit,.card,button")));
  });
  $("#notch").addEventListener("click", (e) => { if (!e.target.closest("button")) $("#notch").classList.toggle("open"); });
  $("#mic").onclick = () => talk();
  bridge.onShortcut((a) => ({ talk, visualize: () => visualize("Can you visualize it?"), next: () => waiter && waiter("yes"),
    role: switchRole, swap: () => swap(), reset: newProject, audit: () => {},
    back: back10, forward: fwd10, pause: togglePause }[a] || (() => {}))());
  $("#pBack").onclick = back10; $("#pFwd").onclick = fwd10; $("#pPlay").onclick = togglePause;
  $("#pGo").onclick = () => visualize("Can you visualize it?"); $("#pAsk").onclick = () => talk(); $("#pNew").onclick = newProject;
  $("#player").classList.add("on"); $("#dock").classList.add("on");   // the team is always on screen, even before the first run
  try { if (sessionStorage.getItem("fresh")) { sessionStorage.removeItem("fresh"); setTimeout(() => toast("Fresh start. Open the next sheet and tap Visualize (⌘⇧V).", true), 600); } } catch {}
  grab3d();
  addEventListener("keydown", (e) => { if (!window.sidekick && e.key === "v") visualize("Can you visualize it?"); if (e.key === "n" && waiter) waiter("yes"); if (e.key === "s") switchRole(); });
  barsLoop();
  if (P.has("auto")) setTimeout(() => visualize("Can you visualize it?"), 1200);
}

// ---------------------------------------------------------------- notch
const nMain = (html, state) => { $("#nMain").innerHTML = html; if (state) $("#nState").textContent = state; };
function notchIdle() {
  nMain(`<div class="big">Talk it through.<br>See it take shape.</div><div class="sub">Ask about anything on your screen.</div>`, "READY");
}
function notchCrew(active) {
  nMain(`<div class="crewrow">${["pip", "scout", "bolt", "gate"].map((w) => `<div class="m ${w === active ? "on" : ""}"><span data-crew="${w}"></span><span class="n">${w}</span></div>`).join("")}</div>`);
  import("./crew.js").then((m) => document.querySelectorAll("#nMain [data-crew]").forEach(m.mountInto));
}
let level = 0;
function barsLoop() {
  const bars = [...document.querySelectorAll("#bars i")];
  setInterval(() => bars.forEach((b, i) => (b.style.height = 4 + Math.max(0, level * 18 * (0.5 + Math.random() * 0.8) - i % 2) + "px")), 110);
}
function stage(name) {
  const order = ["ingest", "decide", "act", "approve", "report"], at = order.indexOf(name);
  document.querySelectorAll("#stages span").forEach((el) => { const k = order.indexOf(el.dataset.s); el.classList.toggle("on", k === at); el.classList.toggle("done", k < at); });
}
function toast(text, ok = false) { const t = $("#toast"); t.textContent = text; t.classList.toggle("ok", ok); t.classList.add("on"); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("on"), 3800); }

// ---------------------------------------------------------------- buddy (character + speech bubble that moves around the screen)
const NAMES = { pip: "Pip", scout: "Scout", bolt: "Bolt", gate: "Gate" };
const mate = (who) => document.querySelector(`.mate[data-who=${who}]`);
// Live activity in the collapsed notch: who is working (left wing) and what they're doing (right wing).
function activity(who, text) {
  const n = $("#notch");
  if (!who) { n.classList.remove("live"); $("#nWho").textContent = ""; $("#nAct").textContent = ""; return; }
  let f = $("#nFace"); if (!f.classList.contains(who)) swapCharacter(f, who);
  $("#nWho").textContent = NAMES[who]; $("#nAct").textContent = text; n.classList.add("live");
  if ($("#nMain")) nMain(`<div class="think"><div class="spin"></div>${esc(NAMES[who])}: ${esc(text)}</div>`, NAMES[who].toUpperCase());
}
function status(who, text, active = true) {
  if (active && text) activity(who, text);
  $("#dock").classList.add("on");
  const m = mate(who), st = m.querySelector(".st");
  st.textContent = text || ""; st.classList.toggle("on", !!text); m.classList.toggle("active", active);
}
// A visible message passing from one teammate to another.
async function handoff(from, to, text) {
  const a = mate(from).getBoundingClientRect(), b = mate(to).getBoundingClientRect();
  const el = document.createElement("div"); el.className = "handoff"; el.textContent = `${NAMES[from]} → ${NAMES[to]}: ${text}`.slice(0, 90);
  Object.assign(el.style, { left: a.left - 40 + "px", top: a.top - 30 + "px" }); document.body.appendChild(el);
  await wait(50); Object.assign(el.style, { left: Math.min(b.left - 40, W() - 520) + "px", top: b.top - 60 + "px" });
  chime("pop"); setTimeout(() => { el.style.opacity = 0; setTimeout(() => el.remove(), 400); }, 1500);
  await wait(350);
}
let dragging = false;
function grab3d() {
  const st = $("#stage3d"); let lx = 0, ly = 0;
  st.addEventListener("pointerdown", (e) => { dragging = true; lx = e.clientX; ly = e.clientY; st.classList.add("dragging"); st.setPointerCapture(e.pointerId); });
  st.addEventListener("pointermove", (e) => { if (!dragging) return; scene.drag(e.clientX - lx, e.clientY - ly); lx = e.clientX; ly = e.clientY; });
  st.addEventListener("pointerup", () => { dragging = false; st.classList.remove("dragging"); });
  st.addEventListener("wheel", (e) => { e.preventDefault(); scene.zoomBy(e.deltaY); }, { passive: false });
}
function setPaused(on) {
  if (on) { pause(); scene.paused = true; $("#pPlay").textContent = "▶"; }
  else { resume(); scene.paused = false; $("#pPlay").textContent = "❚❚"; }
}
function togglePause() { setPaused(!isPaused()); }
// Start over on a different sheet: a clean reload drops every running step, voice and model.
function newProject() {
  skip(); try { sessionStorage.setItem("fresh", "1"); } catch {}
  location.reload();
}
let replaying = false;
async function back10() {
  if (replaying) return; replaying = true;
  const lines = recent(10); skip();
  toast("↺ Replaying the last 10 seconds", true);
  for (const l of lines) await say(l.who, l.text, { record: false });
  replaying = false;
}
function fwd10() { skip(); toast("Skipped ahead", true); }
async function say(who, text, opts = {}) {
  if (!opts.force) await untilResumed();
  $("#player").classList.add("on"); $("#pNow").textContent = `${NAMES[who]}: ${text}`;
  const m = mate(who), bub = m.querySelector(".say");
  bub.querySelector("span").textContent = text; bub.classList.add("on"); $("#dock").classList.add("on");
  activity(who, "speaking…");
  crew(who, "talk"); level = 0.8;
  await speak(who, text, opts);
  crew(who, "idle"); level = 0; bub.classList.remove("on"); await wait(120);
}
// ---------------------------------------------------------------- voice in
let stayPaused = false;
async function talk() {
  if (listening) return;
  const held = !isPaused() && (busy || !!last);   // asking mid-run pauses the story until you've been answered
  if (held) setPaused(true);
  try { await talkInner(); } finally { if (held && !stayPaused) setPaused(false); stayPaused = false; }
}
async function talkInner() {
  chime("pop"); $("#notch").classList.add("open"); $("#mic").classList.add("on"); $("#micT1").textContent = "Listening…";
  nMain(`<div class="listen"><div class="bars" style="width:40px">${"<i></i>".repeat(5)}</div>I'm listening…</div>`, "LISTENING");
  let text = "";
  try { text = await record(); } catch (e) { toast("Mic: " + e.message); }
  $("#mic").classList.remove("on"); $("#micT1").textContent = "Talk to Sidekick";
  if (!text) { nMain(`<div class="sub">Didn't catch that. Press ⌘⇧Space and try again.</div>`, "READY"); setTimeout(() => $("#notch").classList.remove("open"), 1800); return; }
  nMain(`<div class="q">You said</div><div class="big" style="font-size:20px">“${esc(text)}”</div>`, "GOT IT");
  setTimeout(() => $("#notch").classList.remove("open"), 1600);
  if (waiter) { handleAnswer(text); return; }
  if (busy || last) return await followUp(text);
  if (/visuali|chart|graph|plot|draw|show|what.?s wrong|problem|look at/i.test(text)) return visualize(text);
  chat(text);
}
let listening = false;
function handleAnswer(t) {
  if (/supervisor|switch/i.test(t)) { setRole("Maintenance supervisor"); return waiter && waiter("yes"); }
  if (waiter && /approve|yes|yeah|go ahead|confirm|do it|sure|show/i.test(t)) return waiter("yes");
  if (waiter && /\b(no|not now|stop|cancel)\b/i.test(t)) return waiter("no");
}
// Keep listening for a spoken answer while a question is open.
async function listenWhile(open) {
  while (open()) {
    let t = "";
    try { t = await record(7000, open); } catch { return; }
    if (t && open()) { toast(`You: “${t}”`, true); handleAnswer(t); }
    await wait(200);
  }
}
async function followUp(text) {
  activity("pip", "Thinking about your feedback…");
  const ctx = last ? { screen: last.v.headline, problem: last.v.problem.summary, visual: last.d.title, rows_read: last.rows, busy } : {};
  const j = await post("/api/chat", { utterance: text, shot: last?.o.shot || "", context: ctx });
  if (!j.output) return toast(j.error || "Couldn't answer");
  await act(j.output.action, j.output.focus, j.output.answer, text);
}
// Turn spoken feedback into something actually happening on screen.
async function act(action, focus, answer, text) {
  log("Pip", "Feedback", `“${text}” → ${action}`);
  const F = { force: true };
  const quick = { pause: () => (stayPaused = true), resume: () => {}, back: back10, forward: fwd10, switch_role: () => setRole("Maintenance supervisor") };
  if (quick[action]) { if (answer) await say("pip", answer, F); return quick[action](); }
  if (action === "approve") { if (waiter) return waiter("yes"); return say("pip", "There's nothing waiting for approval yet.", F); }
  if (answer) await say("pip", answer, F);
  if (action === "visualize" && !busy) { setTimeout(() => visualize(text), 0); return; }
  if (!last) return;
  if (action === "redraw_bar" || action === "redraw_line") { redraw(action === "redraw_bar" ? "bar" : "line"); return; }
  if (action === "explain_again") { reteach(focus || text); return; }
  if (action === "show_3d" && !document.body.classList.contains("show3d")) {
    last.d.visual_3d.asset === "generate" ? buildGenerated(last.build3dP) : deepDive(last.d.visual_3d.asset);
  }
}
async function redraw(type) {
  if (!last?.merged) return;
  $("#marks").innerHTML = ""; document.body.classList.remove("show3d");
  const d = { ...last.d, chart: { ...last.d.chart, type } };
  const box = boardPlace(last.tb); crew("bolt", "work"); status("bolt", type === "bar" ? "Redrawing as bars" : "Redrawing as lines");
  const steps = type === "bar" ? drawBars(box, last.merged, last.v, d) : drawChart(box, { table: last.merged }, last.v, d);
  for (const st of steps) await st();
  crew("bolt", "happy"); status("bolt", "Redrawn ✓", false);
}
async function reteach(focus) {
  crew("bolt", "work"); status("bolt", "Re-drawing the lesson, simpler…");
  const tr = await post("/api/teach", { scout: last.v, utterance: `Explain it again more simply, step by step. Focus: ${focus}` });
  if (!tr.output?.beats?.length) return toast(tr.error || "Lesson failed");
  tr.output.beats.forEach((b) => prefetch("pip", b.say));
  document.body.classList.remove("show3d"); lessonPlace();
  const beats = drawLesson(null, tr.output);
  for (let i = 0; i < tr.output.beats.length; i++) await Promise.all([beats[i](), say("pip", tr.output.beats[i].say)]);
  crew("bolt", "happy"); status("bolt", "Lesson ✓", false);
}
// Bar view: average of the last 7 days per unit, peers' average as a dashed line.
function drawBars(box, merged, v, d) {
  $("#bTitle").textContent = d.title; $("#bCap").textContent = `${d.chart.y_label} · last 7 days, average per unit`;
  const svg = $("#bSvg"), vw = 1000, vh = 400; svg.setAttribute("viewBox", `0 0 ${vw} ${vh}`); svg.innerHTML = "";
  const cols = merged.columns, rows = merged.rows.slice(-7), hi = d.chart.highlight_series || v.problem.series;
  const avg = cols.map((c) => { const xs = rows.map((r) => r.cells[c]?.v).filter((x) => x != null); return xs.reduce((a, b) => a + b, 0) / Math.max(1, xs.length); });
  const max = Math.max(...avg) * 1.15, L = 70, R = vw - 40, T = 30, B = vh - 50, bw = (R - L) / cols.length;
  const peers = avg.filter((_, i) => cols[i] !== hi), peer = peers.reduce((a, b) => a + b, 0) / Math.max(1, peers.length);
  const Y = (x) => B - (x / max) * (B - T);
  return [async () => {
    svg.insertAdjacentHTML("beforeend", `<path class="draw" stroke="#1c232c" stroke-width="2.5" d="${rough([[L, T], [L, B], [R, B]], 2)}"/>`);
    await animatePath(svg.lastElementChild, 500);
    for (const [i, c] of cols.entries()) {
      const x = L + i * bw + bw * 0.2, w = bw * 0.6, y = Y(avg[i]), red = c === hi;
      svg.insertAdjacentHTML("beforeend", `<path class="draw" stroke="${red ? "#e5484d" : "#8ea4bd"}" stroke-width="3" fill="${red ? "#e5484d" : "#8ea4bd"}" fill-opacity="${red ? .35 : .2}" d="${rough([[x, B], [x, y], [x + w, y], [x + w, B]], 1.5)}"/><text x="${x + w / 2}" y="${B + 26}" text-anchor="middle" font-size="17" fill="#4b5563">${esc(c)}</text><text x="${x + w / 2}" y="${y - 10}" text-anchor="middle" font-size="17" font-weight="700" fill="${red ? "#b3261e" : "#4b5563"}">${+avg[i].toFixed(avg[i] < 20 ? 2 : 0)}</text>`);
      await animatePath(svg.querySelectorAll("path.draw")[svg.querySelectorAll("path.draw").length - 1], 380); chime("pop");
    }
  }, async () => {
    svg.insertAdjacentHTML("beforeend", `<path class="draw" stroke="#7c3aed" stroke-width="2.5" stroke-dasharray="8 7" d="M${L} ${Y(peer)} L${R} ${Y(peer)}"/><text x="${R}" y="${Y(peer) - 8}" text-anchor="end" font-size="19" font-weight="700" fill="#7c3aed">peers avg ${+peer.toFixed(peer < 20 ? 2 : 0)} · ${hi} ×${(avg[cols.indexOf(hi)] / peer).toFixed(1)}</text>`);
    await animatePath(svg.querySelectorAll("path.draw")[svg.querySelectorAll("path.draw").length - 1], 500);
  }];
}
async function record(maxMs = 9000, isOpen = null) {
  listening = true; activity("pip", "Listening…");
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const rec = new MediaRecorder(stream, { mimeType: "audio/webm" }), chunks = [];
  rec.ondataavailable = (e) => chunks.push(e.data);
  const ctx = new AudioContext(), an = ctx.createAnalyser(); ctx.createMediaStreamSource(stream).connect(an);
  const buf = new Uint8Array(an.fftSize); let spoke = false, quietSince = performance.now(); const t0 = performance.now();
  rec.start(100);
  await new Promise((res) => {
    const tick = () => {
      an.getByteTimeDomainData(buf); const rms = Math.sqrt(buf.reduce((s, v) => s + ((v - 128) / 128) ** 2, 0) / buf.length);
      level = Math.min(1, rms * 8);
      if (rms > 0.03) { spoke = true; quietSince = performance.now(); }
      const now = performance.now();
      if ((spoke && now - quietSince > 1100) || now - t0 > maxMs || (isOpen && !isOpen())) return res();
      requestAnimationFrame(tick);
    }; tick();
  });
  await new Promise((r) => { rec.onstop = r; rec.stop(); });
  stream.getTracks().forEach((t) => t.stop()); ctx.close(); level = 0; listening = false;
  if (!spoke || (isOpen && !isOpen())) return "";
  nMain(`<div class="think"><div class="spin"></div>Turning your words into a question…</div>`, "TRANSCRIBING");
  const r = await fetch("/api/transcribe", { method: "POST", body: new Blob(chunks, { type: "audio/webm" }) });
  const t = ((await r.json()).text || "").trim();
  // silence or room noise can come back as a stray word in another script; ignore it
  return /[a-z]{2}/i.test(t) && t.replace(/[^a-z]/gi, "").length >= 2 ? t : "";
}
async function chat(text) {
  nMain(`<div class="q">“${esc(text)}”</div><div class="think"><div class="spin"></div>Looking at your screen…</div>`, "THINKING");
  const shot = await captureAndOcr(false);
  const j = await (await fetch("/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ utterance: text, shot: shot.shot }) })).json();
  if (j.error) return toast(j.error);
  nMain(`<div class="q">“${esc(text)}”</div><div class="sub" style="font-size:14px;color:#fff">${esc(j.output.answer)}</div>`, "ANSWER");
  await say("pip", j.output.answer);
  if (j.output.wants_visual) visualize(text);
}

// ---------------------------------------------------------------- see the screen
async function captureAndOcr(showScan = true, flash = true) {
  // In debug builds the overlay is visible to screen capture, so hide it for the shot.
  if (P.has("debug")) { document.body.style.opacity = 0; await wait(140); }
  const cap = await bridge.capture().finally(() => (document.body.style.opacity = 1));
  if (showScan && flash) { $("#flash").classList.remove("go"); void $("#flash").offsetWidth; $("#flash").classList.add("go"); chime("pop"); }
  const r = await (await fetch("/api/ocr", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ image: cap.png }) })).json();
  r.scale = cap.scale;
  if (showScan && !flash) chime("pop");
  r.box = (id) => { const it = r.items[id]; return it && { x: it.x / cap.scale, y: it.y / cap.scale, w: it.w / cap.scale, h: it.h / cap.scale }; };
  if (showScan) {
    $("#scan").innerHTML = "";
    $("#sweep").classList.remove("go"); void $("#sweep").offsetWidth; $("#sweep").classList.add("go");
    const scan = $("#scan"); scan.innerHTML = "";
    r.items.forEach((it, i) => { const b = document.createElement("b"); const bx = r.box(i);
      Object.assign(b.style, { left: bx.x - 3 + "px", top: bx.y - 2 + "px", width: bx.w + 6 + "px", height: bx.h + 4 + "px", animationDelay: (bx.y / H()) * 1.2 + "s" }); scan.appendChild(b); });
  }
  return r;
}

function tableBox(o) {
  if (o.table.rows.length < 5) return null;
  const ids = [...Object.values(o.table.header_ids || {}), ...o.table.rows.flatMap((r) => [r.id, ...Object.values(r.cells).map((c) => c.id)])].filter((i) => i >= 0);
  if (!ids.length) return null;
  const bs = ids.map(o.box).filter(Boolean);
  const x = Math.min(...bs.map((b) => b.x)), y = Math.min(...bs.map((b) => b.y));
  return { x, y, r: Math.max(...bs.map((b) => b.x + b.w)), b: Math.max(...bs.map((b) => b.y + b.h)) };
}

async function visualize(utterance) {
  if (busy) return; busy = true;
  clearStage();
  $("#notch").classList.add("open"); stage("ingest");
  nMain(`<div class="q">“${esc(utterance)}”</div><div class="think"><div class="spin"></div>Team is looking at your screen…</div>`, "SEEING");
  ["pip", "scout", "bolt", "gate"].forEach((w) => status(w, "", false));
  $("#notch").classList.remove("open");
  await say("pip", "Sure! Team, let's take a look.");

  const app = await bridge.front?.();   // remember which app holds the sheet, so scrolling goes there
  if (app) status("gate", `Looking at ${app}`);
  // Gate: capture + rules-based privacy check before any model sees it
  status("gate", "Capturing screen…"); crew("gate", "work");
  let o;
  try { o = await captureAndOcr(true); }
  catch (e) {
    crew("gate", "deny"); status("gate", "Can't see the screen", false);
    toast(/Screen Recording|screen source/i.test(e.message) ? "I can't see the screen. Unlock it, or allow Screen Recording for Electron." : `Capture failed: ${e.message}`);
    await say("gate", "I can't see your screen right now. Check Screen Recording permission, then try again.");
    activity(null); busy = false; return;
  }
  crew("gate", o.redacted ? "deny" : "approve");
  status("gate", o.redacted ? `Redacted ${o.redacted} personal item${o.redacted > 1 ? "s" : ""} · image withheld` : `Checked ${o.items.length} text boxes · no personal data`);
  log("Gate", "Privacy check", `${o.items.length} OCR boxes, ${o.redacted} redacted`, o.redacted ? "deny" : "ok");
  const tb = tableBox(o);
  if (tb) drawRect(tb);
  await handoff("gate", "scout", o.redacted ? "redacted text only" : "screen is clear");
  crew("gate", "idle"); status("gate", o.redacted ? "Redacted" : "Clear ✓", false);

  // Scout spots a spreadsheet name on screen; Gate allows a read-only open; the file flies to Scout.
  const fileItem = o.items.find((it) => /[\w\- .()]+\.(xlsx|csv)\b/i.test(it.t));
  let file = null;
  if (fileItem) {
    const name = fileItem.t.match(/[\w\-.()]+\.(xlsx|csv)/i)[0];
    status("gate", `File access: ${name} · read-only`); crew("gate", "work");
    const f = await post("/api/file", { name });
    crew("gate", f.found ? "approve" : "idle");
    if (f.found) {
      log("Gate", "File access", `read-only ${f.path}`, "ok");
      status("gate", "Read-only access ✓", false);
      file = f; await flyFile(fileItem, o, name, f);
      status("scout", `Opened ${Object.keys(f.sheets).length} sheets · ${f.rows.toLocaleString("en-IN")} rows`);
    }
  }
  // Scout: scrolls through everything, then the vision model reads it
  stage("decide"); crew("scout", "work");
  const t0 = performance.now();
  const firstSheet = file && Object.values(file.sheets)[0], fromFile = !!(firstSheet && firstSheet.rows.length >= 5);
  let pages = [o], merged;
  if (fromFile) merged = { columns: firstSheet.columns, header_ids: {}, rows: firstSheet.rows.map((r) => ({ ...r, page: 0 })) };
  else {
    // No file: Scout has to read every page off the screen.
    const scrolling = tb ? say("scout", "Let me scroll through all of it.") : null;
    pages = await scrollRead(o); await scrolling;
    merged = pages.length > 1 ? mergeTables(pages) : o.table;
    if (pages.length > 1) log("Scout", "Scrolled", `${pages.length} pages · ${merged.rows.length} rows`);
  }
  const cols = merged.columns.length, rows = merged.rows.length;
  status("scout", tb ? `Read ${rows} rows × ${cols} columns · thinking…` : "Reading your screen…");
  const plain = { columns: merged.columns, rows: merged.rows.map((r) => ({ label: r.label, cells: Object.fromEntries(Object.entries(r.cells).map(([k, c]) => [k, { v: c.v, id: c.id ?? -1 }])) })), header_ids: o.table.header_ids || {} };
  // Every row of every sheet, compact: { sheet: { columns, rows: [[label, v1, v2, ...], ...] } }
  const fileSummary = file ? Object.fromEntries(Object.entries(file.sheets).map(([k, sh]) => [k, { columns: sh.columns, rows: sh.rows.map((r) => [r.label, ...sh.columns.map((c) => r.cells[c]?.v ?? null)]) }])) : {};
  const seeP = post("/api/see", { shot: o.shot, table: plain, utterance, units: "", ocr_text: o.items.map((i) => i.t), file: file ? { path: file.path, sheets: fileSummary } : {} });
  // With the file in hand, Scout skims the sheet on screen while the model is already thinking.
  if (fromFile && tb) {
    const sk = say("scout", "Skimming the whole sheet while I think.");
    const n = await skim(Math.ceil(rows / Math.max(8, o.table.rows.length - 3))); await sk;
    log("Scout", "Scrolled", `${n} pages · ${rows} rows × ${cols} columns`);
  }
  if (file) status("scout", `Cross-checking ${Object.keys(file.sheets).length} sheets · ${file.rows.toLocaleString("en-IN")} rows…`);
  const sr = await seeP;
  if (sr.error) { toast(sr.error); busy = false; return; }
  const v = sr.output;
  status("scout", `Found it · ${((performance.now() - t0) / 1000).toFixed(0)} s`, false); crew("scout", "happy");
  log("Scout", "Read screen", `${v.kind}: ${v.headline.slice(0, 80)}`);
  $("#scan").innerHTML = "";
  await say("scout", v.headline);
  crew("scout", "idle");
  const boltP = post("/api/draw", { scout: v, columns: o.table.columns, rows });
  const teachP = post("/api/teach", { scout: v, utterance });   // the whiteboard lesson, prepared in parallel
  await handoff("scout", "bolt", v.handoff);

  // Bolt: designs the visual (fast model)
  stage("act"); crew("bolt", "work"); status("bolt", "Designing the visual…");
  const br = await boltP;
  if (br.error) { toast(br.error); busy = false; return; }
  const d = br.output;
  d.narration.forEach((t) => prefetch("pip", t));
  // Bolt drafts the work order in the background so it's ready the moment the 3D tour ends.
  const wo = d.visual_3d.asset === "generate" && v.diagnosis?.component ? draftWO(v) : null;
  teachP.then((t) => t.output?.beats?.forEach((b) => prefetch("pip", b.say)));
  status("bolt", d.mode === "chart" ? "Drawing a chart" : "Drawing a diagram");
  // Bolt starts building the 3D model now, so it's ready when the 2D explanation ends.
  const build3dP = d.visual_3d.asset === "generate"
    ? post("/api/build3d", { subject: d.visual_3d.subject, context: `${v.headline} ${v.problem.summary}` }) : null;
  log("Bolt", "Designed visual", `${d.mode}: ${d.title}`);
  last = { o, v, d, tb, rows: merged.rows.length, merged, build3dP, wo, perPage: o.table.rows.length || 30 };
  await handoff("bolt", "pip", `${d.mode} ready: ${d.title}`);
  crew("bolt", "idle");

  // Pip explains while the board draws itself in the upper area
  const box = boardPlace(tb);
  const hasSeries = (merged.rows.length >= 5) || (v.data?.series?.length && v.data.labels.length >= 3);
  const steps = d.mode === "chart" && hasSeries ? (d.chart.type === "bar" ? drawBars(box, merged, v, d) : drawChart(box, { table: merged }, v, d)) : drawDiagram(box, d);
  for (let i = 0; i < d.narration.length; i++) {
    status("pip", `Explaining ${i + 1}/${d.narration.length}`);
    await Promise.all([steps[Math.min(i, steps.length - 1)](), say("pip", d.narration[i])]);
  }
  for (let i = d.narration.length; i < steps.length; i++) await steps[i]();
  status("pip", "", false);
  if (tb) {
    const m = pages.length > 1 || fromFile ? await markProblem(v, merged, steps.peak, last.perPage) : await markCells(o, v, steps.peak);
    if (m) await say("scout", v.problem.summary.split(/(?<=\.)\s/)[0]);
  }
  // Whiteboard lesson: Bolt draws the mechanism behind the numbers while Pip teaches it.
  status("bolt", "Preparing the lesson…"); crew("bolt", "work");
  const tr = await teachP;
  if (tr.output?.beats?.length) {
    log("Bolt", "Lesson", `${tr.output.title} · ${tr.output.beats.length} beats`);
    const lb = lessonPlace();
    $("#marks").querySelectorAll("text").forEach((t) => (t.style.opacity = 0.25));
    const beats = drawLesson(lb, tr.output);
    for (let i = 0; i < tr.output.beats.length; i++) {
      status("bolt", `Drawing ${i + 1}/${tr.output.beats.length}`);
      await Promise.all([beats[i](), say("pip", tr.output.beats[i].say)]);
    }
    crew("bolt", "happy");
  }
  status("bolt", "Done ✓", false);
  busy = false;
  // Bolt goes straight from the 2D visual to building it in 3D.
  crew("bolt", "work"); status("bolt", "Building 3D model…");
  await say("bolt", d.visual_3d.asset === "generate" ? `Now let me build the ${d.visual_3d.subject} in 3D.` : "Now let me build it in 3D, so you can see what's breaking inside.");
  if (d.visual_3d.asset === "generate") return buildGenerated(build3dP);
  deepDive(d.visual_3d.asset);
}
// Scout scrolls through the whole sheet, reading every page, then returns to the top.
async function scrollRead(first) {
  const pages = [first];
  if (first.table.rows.length < 5 || !bridge.key) return pages;
  for (let p = 1; p < 16; p++) {
    status("scout", `Scrolling · reading page ${p + 1}`);
    await bridge.key("pagedown"); await wait(420);
    let o = await captureAndOcr(true, false);
    const same = (x) => !x.table.rows.length || x.table.rows.at(-1)?.label === pages.at(-1).table.rows.at(-1)?.label;
    if (same(o) && p === 1) { await bridge.key("pagedown"); await wait(500); o = await captureAndOcr(true, false); } // focus may have been elsewhere
    if (same(o)) break;
    pages.push(o);
  }
  status("scout", "Back to the top");
  await bridge.key("home"); await wait(450);
  return pages;
}
// Quick visual skim (no OCR): Scout already has the numbers from the file.
async function skim(pagesToGo) {
  if (!bridge.key) return 1;
  const n = Math.min(20, Math.max(1, pagesToGo));
  for (let p = 1; p < n; p++) { status("scout", `Skimming · page ${p + 1} of ${n}`); await bridge.key("pagedown"); await wait(230); }
  await wait(300); await bridge.key("home"); await wait(300);
  return n;
}
function mergeTables(pages) {
  const seen = new Map();
  pages.forEach((o, pi) => o.table.rows.forEach((r) => {
    if (!seen.has(r.label)) seen.set(r.label, { label: r.label, page: pi, cells: Object.fromEntries(Object.entries(r.cells).map(([k, c]) => [k, { v: c.v }])) });
  }));
  return { columns: pages[0].table.columns, rows: [...seen.values()], header_ids: {} };
}
// Scroll to the page where the problem is, read it again for exact positions, and circle it.
async function markProblem(v, merged, peakFn, perPage = 30) {
  const series = v.problem.series, labels = merged.rows.map((r) => r.label);
  let a = labels.indexOf(v.problem.start_label), b = labels.indexOf(v.problem.end_label);
  if (a < 0) a = Math.max(0, labels.length - 10); if (b < 0) b = labels.length - 1;
  const lo = Math.min(a, b), hi = Math.max(a, b), want = new Set(labels.slice(lo, hi + 1));
  status("scout", "Scrolling to the problem…");
  if (hi >= labels.length - perPage + 2) await bridge.key("end");
  else for (let k = 0; k < Math.floor(lo / Math.max(8, perPage - 3)); k++) { await bridge.key("pagedown"); await wait(200); }
  await wait(450);
  let o2 = await captureAndOcr(false);
  // nudge a page either way if the rows aren't on screen yet
  for (let t = 0; t < 3; t++) {
    const seen = o2.table.rows.map((r) => labels.indexOf(r.label)).filter((i) => i >= 0);
    if (!seen.length) break;
    const sLo = Math.min(...seen), sHi = Math.max(...seen);
    if (sHi < hi && sLo < lo) await bridge.key("pagedown"); else if (sLo > lo && sHi > hi) await bridge.key("pageup"); else break;
    await wait(400); o2 = await captureAndOcr(false);
  }
  const head = o2.table.header_ids?.[series];
  const ids = [head, ...o2.table.rows.filter((r) => want.has(r.label) && r.cells[series]).map((r) => r.cells[series].id)].filter((i) => i != null && i >= 0);
  const m = await markCells(o2, { ...v, highlight_ids: ids }, peakFn);
  status("scout", m ? `Circled ${series}` : "Found it");
  return m;
}
async function flyFile(item, o, name, f) {
  const b = o.box(item.id), sc = mate("scout").getBoundingClientRect();
  const chip = document.createElement("div"); chip.className = "filechip glow";
  chip.innerHTML = `<div class="ic">XLSX</div><div><b>${esc(name)}</b><span>${Object.keys(f.sheets).length} sheets · ${f.rows.toLocaleString("en-IN")} rows · read-only</span></div>`;
  Object.assign(chip.style, { left: b.x + "px", top: b.y + b.h + 6 + "px" }); document.body.appendChild(chip);
  chime("pop"); await wait(900);
  Object.assign(chip.style, { left: sc.left - 140 + "px", top: sc.top - 70 + "px", transform: "scale(.85)" });
  await wait(1150); chip.classList.remove("glow"); crew("scout", "happy");
  await say("scout", `Found the file itself. Reading all ${Object.keys(f.sheets).length} sheets, exact numbers.`);
  chip.style.opacity = 0; setTimeout(() => chip.remove(), 500);
}
const post = (url, body) => fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }).then((r) => r.json());

function clearStage() {
  $("#marks").innerHTML = ""; $("#scan").innerHTML = ""; $("#board").classList.remove("on"); $("#cards").innerHTML = "";
  $("#roi").classList.remove("on"); $("#finale").classList.remove("on"); document.body.classList.remove("show3d");
}

function drawRect(tb) {
  $("#marks").insertAdjacentHTML("beforeend", `<rect id="tbRect" x="${tb.x - 8}" y="${tb.y - 8}" width="${tb.r - tb.x + 16}" height="${tb.b - tb.y + 16}" rx="10" fill="rgba(124,240,192,.06)" stroke="#7cf0c0" stroke-width="2" stroke-dasharray="6 6"/>`);
}

// Always in the upper part of the screen, fully visible; beside the table when there is one.
function boardPlace(tb) {
  const top = TOP + 64, maxH = Math.min(460, H() * 0.48);
  let x, w;
  if (tb && W() - tb.r - 50 >= 520) { x = tb.r + 30; w = Math.min(860, W() - x - 24); }
  else if (tb && tb.x - 50 >= 520) { w = Math.min(860, tb.x - 50); x = tb.x - 30 - w; }
  else { w = Math.min(900, W() - 48); x = (W() - w) / 2; }
  const b = $("#board"); Object.assign(b.style, { left: x + "px", top: top + "px", width: w + "px", height: maxH + "px" });
  b.classList.add("on");
  return { x, y: top, w, h: maxH };
}

function drawDiagram(box, d) {
  $("#bTitle").textContent = d.title; $("#bCap").textContent = "Bolt's diagram · from what Scout read on your screen";
  const svg = $("#bSvg"), vw = 1000, vh = 400; svg.setAttribute("viewBox", `0 0 ${vw} ${vh}`); svg.innerHTML = "";
  const nodes = d.diagram.nodes.slice(0, 6), n = nodes.length, pos = {};
  const cols = n <= 3 ? n : Math.ceil(n / 2), rowsN = n <= 3 ? 1 : 2;
  nodes.forEach((nd, i) => { const r = Math.floor(i / cols), c = i % cols; pos[nd.id] = { x: 90 + c * ((vw - 180) / Math.max(1, cols - 1 || 1)) * (cols > 1 ? 1 : 0) + (cols === 1 ? (vw - 180) / 2 : 0), y: rowsN === 1 ? vh / 2 : 110 + r * 180 }; });
  const colors = ["#c5e8b0", "#cdb4e6", "#fdb27e", "#a9d3f5", "#ffe08a", "#f7b8c4"];
  const steps = [];
  nodes.forEach((nd, i) => steps.push(async () => {
    const p = pos[nd.id], w = Math.max(150, Math.min(230, nd.label.length * 13 + 40));
    svg.insertAdjacentHTML("beforeend", `<g class="node" style="opacity:0;transition:opacity .4s"><path class="draw" stroke="#1c232c" stroke-width="2.5" fill="${colors[i % 6]}" d="${rough([[p.x - w / 2, p.y - 32], [p.x + w / 2, p.y - 32], [p.x + w / 2, p.y + 32], [p.x - w / 2, p.y + 32], [p.x - w / 2, p.y - 32]], 3)}"/><text x="${p.x}" y="${p.y + 7}" text-anchor="middle" font-size="21" font-weight="700">${esc(nd.label)}</text></g>`);
    const g = svg.lastElementChild; requestAnimationFrame(() => (g.style.opacity = 1)); chime("pop"); await wait(380);
  }));
  steps.push(async () => {
    for (const e of d.diagram.edges) {
      const a = pos[e.source], b = pos[e.target]; if (!a || !b) continue;
      const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2 - 40;
      svg.insertAdjacentHTML("beforeend", `<path class="draw" stroke="#e5484d" stroke-width="3" d="M${a.x} ${a.y + (b.y > a.y ? 34 : b.y < a.y ? -34 : 0)} Q ${mx} ${my} ${b.x + (b.x > a.x ? -80 : b.x < a.x ? 80 : 0)} ${b.y}"/><text x="${mx}" y="${my + 6}" text-anchor="middle" font-size="16" fill="#b3261e">${esc(e.label)}</text>`);
      await animatePath(svg.querySelectorAll("path.draw")[svg.querySelectorAll("path.draw").length - 1], 450);
    }
  });
  // spread node reveals across the narration lines
  const grouped = [async () => { for (const f of steps.slice(0, Math.ceil(n / 2))) await f(); }, async () => { for (const f of steps.slice(Math.ceil(n / 2), n)) await f(); }, steps[n]];
  grouped.peak = () => ({ x: box.x + box.w / 2, y: box.y + box.h });
  return grouped;
}

// Hand-drawn style path through points.
const rough = (pts, j = 1.2) => pts.map(([x, y], i) => `${i ? "L" : "M"}${(x + (Math.random() - .5) * j).toFixed(1)} ${(y + (Math.random() - .5) * j).toFixed(1)}`).join(" ");
function animatePath(p, ms) { const L = p.getTotalLength(); p.style.strokeDasharray = L; p.style.strokeDashoffset = L; p.getBoundingClientRect(); p.style.transition = `stroke-dashoffset ${ms}ms ease-in-out`; p.style.strokeDashoffset = 0; return wait(ms); }

function drawChart(box, o, v, d) {
  $("#bTitle").textContent = d.title; $("#bCap").textContent = `${d.chart.y_label} · Bolt's chart from what Scout read on your screen`;
  const svg = $("#bSvg"), vw = 1000, vh = 400; svg.setAttribute("viewBox", `0 0 ${vw} ${vh}`); svg.innerHTML = "";
  let labels = o.table.rows.map((r) => r.label), series = o.table.columns.map((c) => ({ name: c, values: o.table.rows.map((r) => r.cells[c]?.v ?? null) }));
  if (!labels.length && v.data.series.length) { labels = v.data.labels; series = v.data.series; }
  const all = series.flatMap((s) => s.values).filter((x) => x != null), max = Math.max(...all) * 1.1, min = 0;
  const L = 60, R = vw - 90, T = 20, B = vh - 40;
  const X = (i) => L + (i / Math.max(1, labels.length - 1)) * (R - L), Y = (val) => B - ((val - min) / (max - min)) * (B - T);
  const g = (html) => svg.insertAdjacentHTML("beforeend", html);
  g(`<path class="draw" stroke="#1c232c" stroke-width="2.5" d="${rough([[L, T], [L, B], [R, B]], 2)}"/>`);
  for (let k = 0; k <= 4; k++) { const val = Math.round((max / 4) * k); g(`<text x="${L - 10}" y="${Y(val) + 5}" text-anchor="end" font-size="16" fill="#6b7280">${val}</text>`); }
  const every = Math.max(1, Math.ceil(labels.length / 8));
  labels.forEach((lb, i) => { if (i % every === 0 || i === labels.length - 1) g(`<text x="${X(i)}" y="${B + 26}" text-anchor="middle" font-size="16" fill="#6b7280">${esc(lb)}</text>`); });
  const hi = d.chart.highlight_series || v.problem.series;
  const palette = ["#8ea4bd", "#a6b6c7", "#9db2a8", "#b8a9c9", "#c2b49b"];
  const line = (s, color, wdt) => {
    const pts = s.values.map((val, i) => val == null ? null : [X(i), Y(val)]).filter(Boolean);
    const long = pts.length > 60;
    g(`<path class="draw" data-s="${esc(s.name)}" stroke="${color}" stroke-width="${long ? wdt * 0.6 : wdt}" stroke-opacity="${long && wdt < 4 ? 0.7 : 1}" d="${rough(pts, long ? 0.2 : 1.6)}"/>`);
    const end = pts[pts.length - 1]; g(`<text x="${end[0] + 8}" y="${end[1] + 5}" font-size="17" fill="${color}" font-weight="700" opacity="0" class="lbl" data-s="${esc(s.name)}">${esc(s.name)}</text>`);
    return pts;
  };
  const greys = series.filter((s) => s.name !== hi); greys.forEach((s, i) => line(s, palette[i % palette.length], 2.6));
  const hs = series.find((s) => s.name === hi); const hpts = hs ? line(hs, "#e5484d", 5) : [];
  const paths = [...svg.querySelectorAll("path.draw")]; paths.forEach((p) => (p.style.opacity = 0));
  const show = (sel) => svg.querySelectorAll(sel).forEach((t) => (t.style.transition = "opacity .4s", t.style.opacity = 1));
  // peak of the highlighted series (in screen coordinates for the arrow later)
  const peak = hpts.reduce((a, p) => (p[1] < a[1] ? p : a), hpts[0] || [R, T]);
  const toScreen = ([x, y]) => { const r = svg.getBoundingClientRect(), sx = r.width / vw, sy = r.height / vh, s = Math.min(sx, sy);
    const ox = r.left + (r.width - vw * s) / 2, oy = r.top + (r.height - vh * s) / 2; return { x: ox + x * s, y: oy + y * s }; };
  const api = {
    grey: async () => { paths.slice(0, 1).forEach((p) => (p.style.opacity = 1)); await animatePath(paths[0], 600);
      await Promise.all(paths.slice(1, -1).map((p) => { p.style.opacity = 1; return animatePath(p, 1600); })); show(`.lbl:not([data-s="${hi}"])`); },
    red: async () => { const p = paths[paths.length - 1]; p.style.opacity = 1; await animatePath(p, 1900); show(`.lbl[data-s="${hi}"]`); chime("pop"); },
    note: async () => {
      // label sits left of and below the peak, clear of the band label along the top edge
      const [px, py] = peak, ex = Math.max(L + 300, px - 46), ty = Math.min(B - 40, Math.max(py + 70, T + 120));
      g(`<path class="draw note" stroke="#e5484d" stroke-width="3" d="M${ex + 6} ${ty - 8} Q ${px - 10} ${ty - 10} ${px - 4} ${py + 18}"/>`);
      g(`<text x="${ex}" y="${ty}" text-anchor="end" font-size="21" fill="#b3261e" font-weight="700">${esc((d.chart.annotation || "").slice(0, 46))}</text>`);
      g(`<circle cx="${px}" cy="${py}" r="16" fill="none" stroke="#e5484d" stroke-width="3" class="draw note"/>`);
      for (const n of svg.querySelectorAll(".note")) await animatePath(n, 450);
    },
    peak: () => toScreen(peak),
  };
  // Bolt's whiteboard annotations, each drawn while Pip says the line it belongs to.
  const idx = (lb) => { const i = labels.indexOf(lb); return i < 0 ? null : i; };
  const valAt = (name, i) => { const sr = series.find((x) => x.name === name) || hs; return sr?.values[i] ?? null; };
  const annotate = async (a) => {
    const i0 = idx(a.from_label), i1 = idx(a.to_label);
    const ink = "#7c3aed", txt = (x, y, anchor = "middle") => g(`<text class="ann" x="${x}" y="${y}" text-anchor="${anchor}" font-size="19" font-weight="700" fill="${ink}" opacity="0">${esc(a.text)}</text>`);
    if (a.kind === "band" && i0 != null) {
      const x0 = X(i0), x1 = X(i1 ?? labels.length - 1);
      g(`<rect class="ann" x="${Math.min(x0, x1)}" y="${T}" width="${Math.abs(x1 - x0) || 8}" height="${B - T}" fill="${ink}" fill-opacity=".08" opacity="0"/>`);
      g(`<path class="draw ann-l" stroke="${ink}" stroke-width="2.5" d="${rough([[Math.min(x0, x1), B + 6], [Math.max(x0, x1), B + 6]], 1)}"/>`);
      txt((x0 + x1) / 2, T + 18);
    } else if (a.kind === "hline" && a.value) {
      g(`<path class="draw ann-l" stroke="${ink}" stroke-width="2.5" stroke-dasharray="8 7" d="M${L} ${Y(a.value)} L${R} ${Y(a.value)}"/>`);
      txt(R - 4, Y(a.value) - 8, "end");
    } else if ((a.kind === "circle" || a.kind === "arrow" || a.kind === "label") && i0 != null) {
      const v0 = a.kind === "label" && a.value ? a.value : valAt(a.series, i0); if (v0 == null) return;
      const px = X(i0), py = Y(v0);
      if (a.kind === "circle") { g(`<path class="draw ann-l" stroke="${ink}" stroke-width="3" d="${roughEllipse(px, py, 22, 18)}"/>`); txt(px, py - 30); }
      else if (a.kind === "arrow") {
        const tx = Math.max(L + 80, Math.min(R - 80, px - 140)), ty = Math.max(T + 30, py - 90);
        g(`<path class="draw ann-l" stroke="${ink}" stroke-width="3" d="M${tx + 40} ${ty + 8} Q ${(tx + px) / 2} ${ty - 20} ${px - 6} ${py - 8}"/><path class="draw ann-l" stroke="${ink}" stroke-width="3" d="M${px - 20} ${py - 16} L${px - 6} ${py - 8} L${px - 20} ${py}"/>`);
        txt(tx, ty, "end");
      } else txt(px, py - 14);
    } else return;
    for (const p of [...svg.querySelectorAll("path.ann-l")].filter((p) => !p.dataset.done)) { p.dataset.done = 1; await animatePath(p, 420); }
    svg.querySelectorAll(".ann").forEach((el) => { el.style.transition = "opacity .35s"; el.style.opacity = 1; });
    chime("pop"); await wait(150);
  };
  const anns = (d.annotations || []).filter((a) => a.kind);
  const withAnns = (base, line) => async () => { await base(); for (const a of anns.filter((x) => x.line === line)) await annotate(a); };
  const steps = [withAnns(api.grey, 0), withAnns(api.red, 1), withAnns(api.note, 2)];
  steps.push(async () => { for (const a of anns.filter((x) => x.line > 2)) await annotate(a); });
  steps.peak = api.peak; return steps;
}

// A bigger board for the lesson, still in the upper part of the screen.
function lessonPlace() {
  const w = Math.min(1100, W() - 48), h = Math.min(640, H() - TOP - 230), x = (W() - w) / 2, y = TOP + 50;
  const b = $("#board"); Object.assign(b.style, { left: x + "px", top: y + "px", width: w + "px", height: h + "px" }); b.classList.add("on");
  return { x, y, w, h };
}
const INK = { ink: "#1c232c", red: "#e5484d", blue: "#2f7cf6", green: "#1d8a5a", purple: "#7c3aed", orange: "#e8590c" };
function drawLesson(box, lesson) {
  $("#bTitle").textContent = lesson.title; $("#bCap").textContent = "Bolt's whiteboard · built from Scout's findings";
  const svg = $("#bSvg"); svg.setAttribute("viewBox", "0 0 1000 560"); svg.innerHTML = "";
  const add = (html) => { svg.insertAdjacentHTML("beforeend", html); return svg.lastElementChild; };
  const pair = (p) => { const out = []; for (let i = 0; i + 1 < p.length; i += 2) out.push([p[i], p[i + 1]]); return out; };
  const item = async (it) => {
    const c = INK[it.color] || INK.ink, pts = pair(it.pts || []);
    const fill = it.fill ? `fill="${c}" fill-opacity=".18"` : 'fill="none"';
    let el;
    switch (it.kind) {
      case "text": {
        if (!pts[0]) return;
        el = add(`<text x="${pts[0][0]}" y="${pts[0][1]}" font-size="${Math.max(14, Math.min(40, it.size || 22))}" fill="${c}" font-weight="700"></text>`);
        for (const ch of it.text) { el.textContent += ch; await wait(18); }
        return;
      }
      case "circle": if (!pts[0]) return; el = add(`<path class="draw" stroke="${c}" stroke-width="3" ${fill} d="${roughEllipse(pts[0][0], pts[0][1], it.r || 20, it.r || 20)}"/>`); break;
      case "ellipse": if (!pts[0]) return; el = add(`<path class="draw" stroke="${c}" stroke-width="3" ${fill} d="${roughEllipse(pts[0][0], pts[0][1], it.w || 30, it.h || 20)}"/>`); break;
      case "rect": { if (!pts[0]) return; const [x, y] = pts[0], w = it.w || 60, h = it.h || 40;
        el = add(`<path class="draw" stroke="${c}" stroke-width="3" ${fill} d="${rough([[x, y], [x + w, y], [x + w, y + h], [x, y + h], [x, y]], 2)}"/>`); break; }
      case "curve": if (pts.length < 3) return; el = add(`<path class="draw" stroke="${c}" stroke-width="3" fill="none" d="M${pts[0]} Q ${pts[1]} ${pts[2]}"/>`); break;
      default: { if (pts.length < 2) return; el = add(`<path class="draw" stroke="${c}" stroke-width="3" fill="none" d="${rough(pts, 1.4)}"/>`);
        if (it.kind === "arrow") { const [a, b] = pts.slice(-2), ang = Math.atan2(b[1] - a[1], b[0] - a[0]), k = 14;
          const h1 = [b[0] - k * Math.cos(ang - .45), b[1] - k * Math.sin(ang - .45)], h2 = [b[0] - k * Math.cos(ang + .45), b[1] - k * Math.sin(ang + .45)];
          await animatePath(el, 380); el = add(`<path class="draw" stroke="${c}" stroke-width="3" fill="none" d="M${h1} L${b} L${h2}"/>`); } }
    }
    await animatePath(el, it.kind === "polyline" ? 700 : 420);
  };
  return lesson.beats.map((beat) => async () => { for (const it of beat.items) await item(it); chime("pop"); });
}

function roughEllipse(cx, cy, rx, ry) {
  const pts = []; const turns = 1.12, start = Math.random() * Math.PI;
  for (let a = 0; a <= Math.PI * 2 * turns; a += 0.12) { const k = 1 + (Math.random() - .5) * 0.04 + (a > Math.PI * 2 ? 0.06 : 0); pts.push([cx + Math.cos(a + start) * rx * k, cy + Math.sin(a + start) * ry * k]); }
  return rough(pts, 0.8);
}
async function markCells(o, v, peakFn) {
  const ids = (v.highlight_ids || []).filter((i) => i >= 0 && o.items[i]);
  if (!ids.length) return null;
  const svg = $("#marks"); $("#tbRect")?.remove();
  const head = o.table.header_ids?.[v.problem.series], hb = head >= 0 ? o.box(head) : null;
  const cells = ids.filter((i) => i !== head).map(o.box);
  const add = (html) => { svg.insertAdjacentHTML("beforeend", html); return svg.lastElementChild; };
  if (hb) { const p = add(`<path class="ink" d="${roughEllipse(hb.x + hb.w / 2, hb.y + hb.h / 2, hb.w / 2 + 16, hb.h / 2 + 10)}"/>`); chime("pop"); await animatePath(p, 550); }
  let m = null;
  if (cells.length) {
    const x = Math.min(...cells.map((b) => b.x)) - 12, y = Math.min(...cells.map((b) => b.y)) - 8;
    const r = Math.max(...cells.map((b) => b.x + b.w)) + 12, b = Math.max(...cells.map((c) => c.y + c.h)) + 8;
    m = { x, y, w: r - x, h: b - y };
    const p = add(`<path class="ink" d="${roughEllipse(x + m.w / 2, y + m.h / 2, m.w / 2 + 10, m.h / 2 + 12)}"/>`); chime("pop"); await animatePath(p, 800);
    const t = add(`<text x="${r + 22}" y="${y + m.h / 2}" >${esc(v.problem.series)} ↑ ×${v.problem.ratio_to_others}</text>`); t.style.opacity = 0; t.style.transition = "opacity .4s"; requestAnimationFrame(() => (t.style.opacity = 1));
    // arrow from the chart's peak to the circled cells
    const pk = peakFn(), ex = r + 14, ey = y + m.h / 2;
    const a = add(`<path class="ink" d="M${pk.x} ${pk.y} C ${pk.x - 120} ${pk.y + 160}, ${ex + 160} ${ey - 60}, ${ex + 8} ${ey}"/>`); await animatePath(a, 700);
    // the link has made its point; fade it so it doesn't cut across what comes next
    setTimeout(() => { a.style.transition = "opacity .6s"; a.style.opacity = 0; setTimeout(() => a.remove(), 700); }, 3500);
  }
  return m;
}

// ---------------------------------------------------------------- generated 3D (any subject)
function assetFromBolt(g) {
  const parts = g.parts.map((p) => ({ id: p.id, label: p.label || null, shape: p.shape, args: p.args, pos: p.pos.slice(0, 3),
    rot: p.rot?.length === 3 ? p.rot : undefined, color: /^#[0-9a-f]{6}$/i.test(p.color) ? p.color : "#cfd8e2",
    group: p.group === "none" ? undefined : p.group, explode: p.explode?.some((x) => x) ? p.explode : undefined }));
  // frame the camera on the model's bounding box
  const ext = (p) => Math.max(...p.args.slice(0, 3).map(Math.abs), 0.3);
  const lo = [0, 1, 2].map((k) => Math.min(...parts.map((p) => p.pos[k] - ext(p)))), hi = [0, 1, 2].map((k) => Math.max(...parts.map((p) => p.pos[k] + ext(p))));
  const c = lo.map((v, k) => (v + hi[k]) / 2), r = Math.max(...hi.map((v, k) => v - lo[k])) / 2;
  const ids = new Set(parts.map((p) => p.id));
  const steps = g.steps.map((st) => ({ parts: st.parts.filter((id) => ids.has(id)), say: st.say, explode: st.explode }));
  const placed = new Set(steps.flatMap((st) => st.parts)); const rest = parts.filter((p) => !placed.has(p.id)).map((p) => p.id);
  if (rest.length) steps[steps.length - 1].parts.push(...rest);
  const fault = g.fault.part && ids.has(g.fault.part) ? { part: g.fault.part, label: g.fault.label || g.fault.part, component: g.fault.label } : null;
  if (fault) { const st = steps.find((s) => s.parts.includes(fault.part)) || steps[steps.length - 1]; st.fault = true; if (!st.parts.includes(fault.part)) st.parts.push(fault.part); }
  steps[steps.length - 1].camera = "focus";
  return { id: "gen", scenario: "generated", title: g.title, parts, steps, fault: fault || { part: "", label: "" },
    camera: { pos: [c[0] + r * 2.4, c[1] + r * 1.3, c[2] + r * 2.7], target: c, focusPos: [c[0] + r * 1.7, c[1] + r * 0.9, c[2] + r * 1.9], focusTarget: c } };
}
async function buildGenerated(build3dP) {
  busy = true; crew("bolt", "work"); status("bolt", "Shaping parts…");
  const r = await build3dP;
  if (!r || r.error) { toast(r?.error || "3D build failed"); busy = false; return; }
  const def = assetFromBolt(r.output);
  log("Bolt", "Built 3D", `${def.title}: ${def.parts.length} parts [${r.source} ${(r.ms / 1000).toFixed(0)}s]`);
  $("#board").classList.remove("on"); $("#marks").innerHTML = "";
  const left = last?.tb ? last.tb.r + 20 : 0, cx = (left + W()) / 2;
  scene.turn = 0.0028; scene.load(def, {}); scene.view.offset = (W() / 2 - cx) / W(); scene.view.zoom = 1; scene.applyView();
  document.body.classList.add("show3d");
  for (const [i, st] of def.steps.entries()) {
    status("bolt", `Building 3D · ${i + 1}/${def.steps.length}`);
    scene.showStep(st); await say("pip", st.say); await wait(st.explode ? 700 : 120);
  }
  crew("bolt", "happy"); status("bolt", "3D built ✓", false);
  await say("bolt", `That's the ${def.title}. ${def.parts.length} parts, built live. Drag it to look around.`);
  if (last?.v?.diagnosis?.component) await genericAction(last.v);
  activity(null); busy = false;
}
// Any engineering case: Bolt drafts the work order from Scout's diagnosis, Gate approves, Bolt executes.
// Next three weekday night shifts (most crews don't work weekends).
function shiftWindows() {
  const days = []; for (let dd = 1; days.length < 3 && dd < 10; dd++) { const x = new Date(); x.setDate(x.getDate() + dd); if (x.getDay() % 6) days.push(dd); }
  return days.map((dd) => {
    const s = new Date(); s.setDate(s.getDate() + dd); s.setHours(22, 0, 0, 0); const e = new Date(s.getTime() + 4 * 3600e3);
    const iso = (x) => `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}-${String(x.getDate()).padStart(2, "0")}T${String(x.getHours()).padStart(2, "0")}:00`;
    return { start: iso(s), end: iso(e), label: s.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }) + " 22:00–02:00", energy_loss_inr: 0, note: "Night shift, lowest load" };
  });
}
function draftWO(v) {
  const windows = shiftWindows();
  const ctx = { task: "Draft the maintenance work order for this diagnosis.", today: new Date().toISOString().slice(0, 10),
    weekday: new Date().toLocaleDateString("en-GB", { weekday: "long" }), diagnosis: v.diagnosis, recommended_action: v.problem.summary,
    parts_inventory: D.sheets.Parts, technicians: D.sheets.Technicians, approval_policy: D.sheets["Approval policy"], candidate_windows: windows,
    asset: { id: v.problem.series, what: v.what_i_see }, labour_hours: 4 };
  return { windows, p: agent("bolt", ctx, "screen") };
}
async function genericAction(v) {
  stage("act"); crew("bolt", "work"); status("bolt", "Drafting the work order…");
  const pre = last?.v === v && last.wo ? last.wo : draftWO(v), windows = pre.windows;
  const bolt = await pre.p;
  if (bolt.error || !bolt.output) return toast(bolt.error || "Bolt failed");
  const wo = bolt.output.work_order;
  log("Bolt", "Drafted WO-2491", `${wo.asset} · ${wo.part_sku} · ${inr(wo.total_cost_inr)}`);
  await workOrderCard(bolt, windows, false);
  await say("bolt", bolt.output.spoken);
  crew("bolt", "idle");
  stage("approve"); await approval(wo);
  stage("report"); status("pip", "", false);
  await say("pip", "All done. Diagnosed, explained, approved and booked. Ask me anything about it.");
}

// ---------------------------------------------------------------- 3D + crew
async function deepDive(asset = "turbine") {
  if (asset === "chiller_pump") return swap();
  busy = true;
  const def = await (await fetch("assets/turbine.json")).json();
  def.parts.find((p) => p.id === "blade1").label = null; def.parts.find((p) => p.id === "hub").label = "Rotor · {rotor_m} m";
  const vars = { hub_m: S.turbine.hub_m, rotor_m: S.turbine.rotor_m, rated_mw: "2", rpm_max: S.rpm_max.toLocaleString("en-GB"), ratio: S.vib_ratio_to_fleet_last48h };
  def.steps.forEach((st) => prefetch("pip", fillVars(st.say, vars)));
  const scoutP = agent("scout", scoutContext(D, S, def)); const windows = repairWindows(D);
  $("#board").classList.remove("on"); $("#notch").classList.remove("open"); $("#marks").innerHTML = "";
  // put the model in the free space between the table and the card column
  const left = last?.tb ? last.tb.r + 20 : 0, right = W() - 460, cx = (left + right) / 2;
  scene.load(def, vars); scene.view.offset = (W() / 2 - cx) / W(); scene.view.zoom = 0.85; scene.applyView();
  document.body.classList.add("show3d"); stage("decide");
  crew("scout", "work");
  crew("bolt", "work");
  for (const [i, st] of def.steps.entries()) {
    status("bolt", `Building 3D · ${i + 1}/${def.steps.length}`);
    scene.showStep(st); await say("pip", fillVars(st.say, vars)); await wait(st.explode ? 1300 : 250);
  }
  crew("bolt", "happy"); status("bolt", "3D built ✓", false); status("scout", "Pulling 30 days of SCADA…"); crew("scout", "work");

  // Scout
  const scout = await scoutP; if (scout.error) return toast(scout.error);
  const boltP = agent("bolt", boltContext(D, scout.output, windows, "turbine"));
  log("Scout", "Diagnosis", `${scout.output.diagnosis.component}, ${scout.output.diagnosis.days_to_failure} d`);
  await evidenceCards(scout);
  await say("scout", scout.output.headline, { x: W() - 900, y: TOP + 140 });
  crew("scout", "idle");

  // Bolt
  stage("act"); crew("bolt", "work");
  const bolt = await boltP; if (bolt.error) return toast(bolt.error);
  const wo = bolt.output.work_order;
  const pipP = agent("pip", { scout: scout.output, bolt: bolt.output, outcome: "approved by supervisor" });
  await workOrderCard(bolt, windows);
  log("Bolt", "Drafted WO-2491", `${wo.part_sku} · ${inr(wo.total_cost_inr)}`);
  await say("bolt", bolt.output.spoken, { x: W() - 900, y: H() - 260 });
  crew("bolt", "idle");

  // Gate
  stage("approve"); await approval(wo);

  // Report
  stage("report"); document.body.classList.remove("show3d"); $("#cards").innerHTML = ""; $("#marks").innerHTML = "";
  const roi = await drawROI(wo, windows);
  const pip = await pipP.then((r) => r.output).catch(() => ({ lines: [] }));
  for (const line of pip.lines || []) await say("pip", line, { x: W() / 2 - 260, y: H() - 150 });
  try { localStorage.setItem("sidekick-report", JSON.stringify({ scout: scout.output, bolt: bolt.output, pip, roi, audit, sources: D.fleet.source, generatedAt: new Date().toISOString() })); } catch {}
  busy = false;
  await say("pip", "And this crew isn't only for turbines. Press command shift L for a hospital pump.");
}

async function agent(role, context, scenario = "turbine") {
  const r = await fetch("/api/agent", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ role, context, scenario }) });
  return r.json();
}
function card(html, cls = "") { const c = document.createElement("div"); c.className = "card " + cls; c.innerHTML = html; $("#cards").appendChild(c); requestAnimationFrame(() => requestAnimationFrame(() => c.classList.add("on"))); return c; }

async function evidenceCards(scout) {
  $("#cards").innerHTML = "";
  card(`<div class="hd"><span data-crew="scout"></span><div><div class="k">Scout · investigate</div><h4>Evidence</h4></div><span class="src">${scout.source} · ${(scout.ms / 1000).toFixed(1)}s</span></div>`);
  document.querySelectorAll("#cards [data-crew]").forEach((el) => import("./crew.js").then((m) => m.mountInto(el)));
  for (const e of scout.output.evidence.slice(0, 3)) { const c = card(`<div class="k">${esc(e.kind)}</div><h4>${esc(e.title)}</h4><p>${esc(e.detail)}</p>`); c.title = e.source; chime("pop"); await wait(800); }
  const d = scout.output.diagnosis, days = d.days_to_failure > 0 ? d.days_to_failure : "watch";
  card(`<div class="k" style="color:var(--hot)">Diagnosis · ${Math.round(d.confidence * 100)}%</div><div class="row"><div><h4>${esc(d.component)}</h4><p>${esc(d.failure_mode)}</p></div><div style="margin-left:auto;text-align:right"><div class="num">${days}</div><div class="k">${d.days_to_failure > 0 ? "days left" : "status"}</div></div></div>`, "diag");
  chime("alarm"); await wait(600);
}

async function workOrderCard(bolt, windows, wind = true) {
  $("#cards").innerHTML = ""; const wo = bolt.output.work_order;
  const winLabel = (windows.find((w) => w.start === wo.window_start) || {}).label || wo.window_start.replace("T", " ");
  const c = card(`<div class="hd"><span data-crew="bolt"></span><div><div class="k">Bolt · work order draft</div><h4>${esc(wo.title)}</h4></div><span class="src">${bolt.source}</span></div>
    <div class="wo">${[["Asset", wo.asset], ["Part", `${wo.part_sku} × ${wo.quantity}`], ["Crew", wo.technicians.join(", ")], ["Window", winLabel], [wind ? "Lost energy" : "Downtime cost", inr(wo.energy_loss_inr)]].map(([k, v]) => `<span>${k}</span><span>${esc(v)}</span>`).join("")}</div>
    ${wind ? `<canvas id="windC"></canvas><div class="k">Hub-height wind · next 7 days · Open-Meteo ${D.forecast.source}</div>` : ""}
    <div class="total"><span class="lock">🔒 needs approval</span><b>${inr(wo.total_cost_inr)}</b></div>`);
  c.querySelectorAll("[data-crew]").forEach((el) => import("./crew.js").then((m) => m.mountInto(el)));
  for (const s of c.querySelectorAll(".wo span")) { s.classList.add("on"); await wait(140); }
  if (wind) { await wait(300); windChart($("#windC"), windows, wo.window_start); }
}

function windChart(c, windows, chosen) {
  const dpr = devicePixelRatio || 1, w = c.clientWidth, h = c.clientHeight; c.width = w * dpr; c.height = h * dpr;
  const g = c.getContext("2d"); g.scale(dpr, dpr); const ws = D.forecast.wind_speed_80m, max = Math.max(12, ...ws);
  const X = (i) => (i / (ws.length - 1)) * w, Y = (v) => h - 4 - (v / max) * (h - 8);
  for (const win of windows) { g.fillStyle = win.start === chosen ? "rgba(124,240,192,.35)" : "rgba(255,191,71,.18)"; g.fillRect(X(win.i), 0, X(win.i + 6) - X(win.i), h); }
  g.setLineDash([4, 4]); g.strokeStyle = "rgba(255,90,78,.7)"; g.beginPath(); g.moveTo(0, Y(10)); g.lineTo(w, Y(10)); g.stroke(); g.setLineDash([]);
  g.beginPath(); ws.forEach((v, i) => (i ? g.lineTo(X(i), Y(v)) : g.moveTo(X(i), Y(v)))); g.strokeStyle = "#5aa8ff"; g.lineWidth = 2; g.stroke();
}

const SUP = "Maintenance supervisor";
function setRole(r) {
  role = r; chime("pop"); toast(`Signed in as ${role}`, true);
  const el = $("#roleName"); if (el) el.textContent = role;
}
function switchRole() {
  setRole(role === "Operator" ? SUP : "Operator");
  if (waiter && role === SUP) waiter("yes");
}
// Gate's approval: one button. If your role can't sign, Gate says why and the same button becomes "sign in as supervisor".
async function approval(wo) {
  const policy = D.sheets["Approval policy"];
  const pol = (r) => policy.find((x) => x.Role.toLowerCase().startsWith(r.toLowerCase().split(" ")[0])) || policy[0];
  const can = (r) => { const p = pol(r); return p["Can approve work orders"] === "Yes" && wo.total_cost_inr <= p["Limit INR"]; };
  const opLimit = pol("Operator")["Limit INR"], supLimit = pol(SUP)["Limit INR"];
  const c = card(`<div class="hd"><span data-crew="gate"></span><div><div class="k">Gate · rules, not AI</div><h4>Needs approval · ${inr(wo.total_cost_inr)}</h4></div></div>
    <div class="who"><span>Signed in as</span><b id="roleName">${role}</b></div>
    <p class="why" id="apWhy">Operators sign up to ${inr(opLimit)}. Supervisors up to ${inr(supLimit)}, with Touch ID.</p>
    <div class="acts"><button id="apGo">Approve</button></div>
    <div class="k" style="margin-top:10px">Audit trail · hash-chained</div><div id="auditRows"></div>`, "ap");
  c.querySelectorAll("[data-crew]").forEach((el) => import("./crew.js").then((m) => m.mountInto(el)));
  audit.forEach(renderAudit);
  const press = async () => {
    let open = true;
    await new Promise((res) => { $("#apGo").onclick = res; waiter = res; if (P.has("auto")) setTimeout(res, 1500); listenWhile(() => open); });
    open = false; waiter = null;
  };
  await say("pip", "This needs a human sign-off. Tap Approve.");
  for (;;) {
    await press();
    if (!can(role)) {
      crew("gate", "deny"); chime("deny");
      await log("Gate", "DENIED", `${role} · ${inr(wo.total_cost_inr)} > ${inr(pol(role)["Limit INR"])}`, "deny");
      $("#apWhy").innerHTML = `<b style="color:var(--hot)">✋ ${esc(role)}s can't sign ${inr(wo.total_cost_inr)}.</b> A supervisor has to.`;
      $("#apGo").textContent = "Sign in as supervisor · Touch ID";
      await say("gate", `Over the ${inr(pol(role)["Limit INR"])} limit. A supervisor has to sign this.`);
      crew("gate", "idle");
      await say("pip", "Tap the button to sign in as supervisor.");
      await press();
      if (role !== SUP) setRole(SUP);
    }
    crew("gate", "alert"); $("#apGo").textContent = "Waiting for Touch ID…";
    const ok = await bridge.touchId(`approve work order WO-2491 for ${inr(wo.total_cost_inr)}`);
    if (!ok) { crew("gate", "deny"); toast("Touch ID failed. Tap to try again."); $("#apGo").textContent = "Approve · Touch ID"; continue; }
    crew("gate", "approve"); chime("ok");
    await log("Gate", "APPROVED", `WO-2491 · ${inr(wo.total_cost_inr)} · Touch ID`, "ok");
    // collapse the approval card so Bolt's receipt has room on screen
    c.querySelector(".acts")?.remove(); $("#apWhy").remove();
    c.querySelector("h4").textContent = `Approved ✓ · ${inr(wo.total_cost_inr)} · Touch ID`; c.classList.add("done");
    document.querySelectorAll("#cards .lock").forEach((l) => (l.textContent = `✓ approved by ${role}`));
    await say("gate", "Approved, and it's on the record.");
    crew("gate", "idle");
    await executeWorkOrder(wo, audit[audit.length - 1].hash);
    return;
  }
}

// After approval, Bolt actually carries it out: the work order is written into the plant's workbook and the part reserved.
async function executeWorkOrder(wo, approvalHash) {
  stage("act"); crew("bolt", "work"); status("bolt", "Booking WO-2491…");
  const r = await post("/api/execute", { work_order: wo, approval: approvalHash, id: "WO-2491" });
  if (!r.done) { crew("bolt", "deny"); toast(`Not executed: ${r.reason || r.error}`); return; }
  await log("Bolt", "EXECUTED", `WO-2491 written to ${r.file} · part ${wo.part_sku} on hand ${r.part_on_hand}`, "ok");
  const [id, date, asset, comp, type, finding, techs] = r.row;
  const c = card(`<div class="hd"><span data-crew="bolt"></span><div><div class="k">Bolt · done ✓</div><h4>WO-2491 booked</h4></div><span class="src">approval #${esc(r.approval)}</span></div>
    <div class="wo">${[["Written to", r.file + " › Maintenance"], ["Asset", `${asset} · ${comp}`], ["When", finding.split(" · ")[1] || date], ["Crew", techs], ["Status", type], ["Part reserved", `${wo.part_sku} · ${r.part_on_hand} left in store`]].map(([k, v]) => `<span>${k}</span><span>${esc(v)}</span>`).join("")}</div>`, "");
  c.style.borderColor = "rgba(124,240,192,.6)";
  c.querySelectorAll("[data-crew]").forEach((el) => import("./crew.js").then((m) => m.mountInto(el)));
  for (const sp of c.querySelectorAll(".wo span")) { sp.classList.add("on"); await wait(120); }
  crew("bolt", "happy"); chime("ok"); status("bolt", "WO-2491 booked ✓", false);
  await say("bolt", `Done. It's booked for ${(finding.split(" · ")[1] || date).replace(/^\d{4}-\d{2}-\d{2} /, "")}, with ${techs}, and the bearing is reserved.`);
  crew("bolt", "idle");
}

async function sha(s) { const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)); return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join(""); }
async function log(actor, action, detail, kind = "") {
  const prev = audit.length ? audit[audit.length - 1].hash : "0".repeat(64);
  const e = { ts: new Date().toISOString(), actor, action, detail, role, prev, kind }; e.hash = await sha(prev + JSON.stringify({ ...e, hash: undefined }));
  audit.push(e); fetch("/api/audit", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(e) }); renderAudit(e);
}
function renderAudit(e) {
  const host = $("#auditRows"); if (!host) return;
  host.insertAdjacentHTML("beforeend", `<div class="arow ${e.kind}"><span>${new Date(e.ts).toLocaleTimeString("en-GB")}</span><span class="a">${esc(e.actor)}</span><span>${esc(e.action)} · ${esc(e.detail)}</span><span class="h">#${e.hash.slice(0, 18)} ← #${e.prev.slice(0, 12)}</span></div>`);
  host.scrollTop = host.scrollHeight;
}

function spark(c, data, color) {
  const dpr = devicePixelRatio || 1, w = c.clientWidth || 190, h = c.clientHeight || 44; c.width = w * dpr; c.height = h * dpr;
  const g = c.getContext("2d"); g.scale(dpr, dpr); const max = Math.max(...data), min = Math.min(...data);
  g.beginPath(); data.forEach((v, k) => { const x = (k / (data.length - 1)) * w, y = h - ((v - min) / (max - min || 1)) * (h - 4) - 2; k ? g.lineTo(x, y) : g.moveTo(x, y); });
  g.strokeStyle = color; g.lineWidth = 2; g.stroke();
}

async function drawROI(wo, windows) {
  const avgKw = S.avg_power_kw, tariff = D.fleet.site.tariff_inr_kwh, days = 42;
  const unplanned = avgKw * 24 * days * tariff, planned = wo.energy_loss_inr + wo.total_cost_inr, saved = unplanned - planned;
  const winLabel = (windows.find((w) => w.start === wo.window_start) || {}).label || wo.window_start;
  const svg = $("#roiSvg"); $("#roi").classList.add("on");
  svg.innerHTML = `<text x="40" y="58" font-size="38" font-weight="700">One bearing. Two futures.</text>
    <text x="40" y="140" font-size="22" fill="#b3261e">If it fails in service</text><path class="draw" stroke="#e5484d" stroke-width="34" d="M40 180 C 300 176, 600 184, 960 179"/>
    <text x="40" y="236" font-size="18" fill="#4b5563">~6 weeks offline waiting for a crane and a gearbox (guide §4.4)</text>
    <text x="960" y="236" font-size="26" font-weight="700" text-anchor="end" fill="#b3261e" class="num" data-v="${unplanned}">₹0</text>
    <text x="40" y="300" font-size="22" fill="#1d6b45">Fixed on ${esc(winLabel)}</text><path class="draw" stroke="#30a46c" stroke-width="34" d="M40 340 C 44 338, 52 342, 60 340"/>
    <text x="40" y="396" font-size="18" fill="#4b5563">6 hours in the calmest window · part in stock · approved</text>
    <text x="960" y="396" font-size="26" font-weight="700" text-anchor="end" fill="#1d6b45" class="num" data-v="${planned}">₹0</text>
    <text x="40" y="478" font-size="30" font-weight="700">Saved ≈ <tspan class="num" data-v="${saved}" fill="#1d6b45">₹0</tspan></text>
    <text x="1000" y="532" font-size="13" text-anchor="end" fill="#6b7280">Lost energy at ${inr(tariff)}/kWh × T-04's real 30-day average output (${avgKw} kW). Excludes gearbox exchange.</text>`;
  for (const p of svg.querySelectorAll(".draw")) await animatePath(p, 1100);
  const nums = [...svg.querySelectorAll(".num")], t0 = performance.now();
  await new Promise((res) => (function f(now) { const p = Math.min(1, (now - t0) / 1500), e = 1 - (1 - p) ** 3; nums.forEach((n) => (n.textContent = inr(+n.dataset.v * e))); p < 1 ? requestAnimationFrame(f) : res(); })(t0));
  chime("ok"); return { unplanned, planned, saved, days, avgKw, tariff };
}

async function swap() {
  if (busy) return; busy = true; $("#roi").classList.remove("on"); $("#cards").innerHTML = "";
  const def = await (await fetch("assets/chiller_pump.json")).json(), C = chillerStats(D), vars = { seal_now: C.seal_now };
  stage("decide"); scene.turn = 0.0028; scene.load(def, vars); scene.view.offset = 0.12; scene.view.zoom = 1; scene.applyView();
  document.body.classList.add("show3d");
  const chain = (async () => { const sc = await agent("scout", chillerScoutContext(D, C, def), "chiller"); const bo = await agent("bolt", boltContext(D, sc.output, chillerWindows(), "chiller"), "chiller"); return [sc, bo]; })();
  for (const st of def.steps) { scene.showStep(st); await say("pip", fillVars(st.say, vars), { x: W() * 0.2, y: H() - 170 }); await wait(st.explode ? 1300 : 250); }
  const [sc, bo] = await chain; const wo = bo.output.work_order;
  card(`<div class="k" style="color:var(--hot)">Scout · ${sc.source}</div><h4>${esc(sc.output.diagnosis.component)} · ${sc.output.diagnosis.days_to_failure} days</h4><p>${esc(sc.output.headline)}</p>`, "diag");
  card(`<div class="k" style="color:var(--bolt)">Bolt · ${bo.source}</div><h4>${esc(wo.title)}</h4><p>${esc(wo.technicians.join(", "))} · ${esc(wo.window_start.replace("T", " "))} · ${inr(wo.total_cost_inr)}</p><div class="cite">→ Gate: needs approval</div>`);
  await say("scout", sc.output.headline, { x: W() - 960, y: TOP + 140 });
  $("#finale").classList.add("on"); chime("ok"); ["pip", "scout", "bolt", "gate"].forEach((w) => crew(w, "happy"));
  await say("pip", "Same crew, new machine. All it took was a new asset file.", { x: W() / 2 - 260, y: H() - 260 });
  busy = false;
}
