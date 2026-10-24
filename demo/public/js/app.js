// Sidekick AgentOps demo: alarm → 3D explanation → Scout evidence → Bolt work order → Gate approval → ROI → asset swap.
import { loadCrew, crew, swapCharacter } from "./crew.js";
import { loadData, turbineStats, ratioAt, scoutContext, boltContext, repairWindows, chillerStats, chillerScoutContext, chillerWindows, inr } from "./data.js";
import { Scene3D } from "./scene3d.js";
import { speak, prefetch, wait, chime, toggleMute, stopVoice } from "./voice.js";

const $ = (s) => document.querySelector(s);
const fillVars = (s, v) => s.replace(/\{(\w+)\}/g, (_, k) => v[k] ?? k);
const AUTO = new URLSearchParams(location.search).has("auto");
let D, S, scene, status = {}, role = "Operator", audit = [], waiter = null, swapReady = false, nowIdx = 0;
const report = {};

// ---------------------------------------------------------------- boot
init();
async function init() {
  await loadCrew();
  [D, status] = await Promise.all([loadData(), fetch("/api/status").then((r) => r.json()).catch(() => ({}))]);
  S = turbineStats(D);
  $("#mode").textContent = status.mode === "cached" ? "AI: cached (offline)" : status.key ? `AI: live · ${status.model}` : "AI: rules (no key)";
  $("#sources").innerHTML = `SCADA: ${D.fleet.source.dataset}. ${D.fleet.source.replay} Fault on ${D.fleet.fault.turbine} is injected for the demo.<br>Ops records: plant_ops.xlsx (synthetic). Forecast: Open-Meteo (${D.forecast.source}).`;
  buildTiles();
  scene = new Scene3D($("#gl"), $("#labels"), $("#leaders"));
  scene.faultSpark = (c) => spark(c, S.turbine.series.vib.slice(nowIdx - 72, nowIdx + 1), "#ffffff", true);
  setInterval(() => ($("#clock").textContent = new Date().toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" })), 1000);
  fetch("/api/audit/reset", { method: "POST" });
  bindKeys();
  $("#intro").addEventListener("click", start, { once: true });
  if (AUTO) setTimeout(() => $("#intro").click(), 800);
}

function bindKeys() {
  addEventListener("keydown", (e) => {
    const k = e.key.toLowerCase();
    if (k === " " || k === "enter" || k === "arrowright") { e.preventDefault(); if (waiter) waiter("next"); else if ($("#intro")) $("#intro").click(); }
    if (k === "s") switchRole();
    if (k === "a") $("#audit").classList.toggle("on");
    if (k === "h") $("#help").classList.toggle("on");
    if (k === "m") toast(toggleMute() ? "Voice muted" : "Voice on", true);
    if (k === "r") { stopVoice(); location.reload(); }
    if (k === "p") registerPasskey().then((ok) => toast(ok ? "Touch ID registered for Supervisor" : "Touch ID not available", ok));
    if (k === "l" && swapReady) swap();
  });
  $("#role").onclick = switchRole; $("#apRole").onclick = switchRole;
  addEventListener("dragover", (e) => { e.preventDefault(); document.body.classList.add("dragging"); });
  addEventListener("dragleave", (e) => { if (!e.relatedTarget) document.body.classList.remove("dragging"); });
  addEventListener("drop", async (e) => {
    e.preventDefault(); document.body.classList.remove("dragging");
    const f = e.dataTransfer.files[0]; if (!f || !swapReady) return;
    try { const def = JSON.parse(await f.text()); swap(def); } catch { toast("That isn't an asset file"); }
  });
}

// ---------------------------------------------------------------- dashboard
function buildTiles() {
  for (const t of D.fleet.turbines) {
    const el = document.createElement("div"); el.className = "tile"; el.id = "tile-" + t.id;
    el.innerHTML = `<div class="id"><span class="dot"></span>${t.id}<span class="model">${t.model}</span></div>
      <span class="badge">VIBRATION ALARM</span>
      <div class="kpis"><div class="kpi"><b data-k="power">–</b>kW</div><div class="kpi"><b data-k="wind">–</b>m/s</div><div class="kpi"><b data-k="oil">–</b>°C oil</div></div>
      <canvas></canvas><div class="lbl"><span>drive-train vibration · 72 h</span><span data-k="vib"></span></div>`;
    $("#fleet").appendChild(el);
  }
}

function renderFleet(i) {
  nowIdx = i;
  let p = 0, w = 0;
  for (const t of D.fleet.turbines) {
    const el = $("#tile-" + t.id), s = t.series;
    el.querySelector('[data-k=power]').textContent = Math.max(0, Math.round(s.power[i]));
    el.querySelector('[data-k=wind]').textContent = s.wind[i].toFixed(1);
    el.querySelector('[data-k=oil]').textContent = s.oil[i].toFixed(1);
    el.querySelector('[data-k=vib]').textContent = s.vib[i].toFixed(0) + " " + D.fleet.units.vib;
    spark(el.querySelector("canvas"), s.vib.slice(Math.max(0, i - 72), i + 1), el.classList.contains("alarm") ? "#ff5a4e" : "#7cf0c0");
    p += Math.max(0, s.power[i]); w += s.wind[i];
  }
  $("#farmPower").textContent = (p / 1000).toFixed(1);
  $("#farmWind").textContent = (w / D.fleet.turbines.length).toFixed(1);
  const when = new Date(Date.now() - (719 - i) * 3600e3);
  $("#replayNote").textContent = `SCADA replay · ${when.toLocaleDateString("en-GB", { day: "numeric", month: "short" })} ${when.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" })}`;
}

function spark(c, data, color, light = false) {
  const dpr = devicePixelRatio || 1, w = c.clientWidth || 190, h = c.clientHeight || 44;
  c.width = w * dpr; c.height = h * dpr; const g = c.getContext("2d"); g.scale(dpr, dpr);
  const max = Math.max(...data) * 1.05, min = Math.min(...data) * 0.9;
  g.beginPath();
  data.forEach((v, k) => { const x = (k / (data.length - 1)) * w, y = h - ((v - min) / (max - min || 1)) * (h - 4) - 2; k ? g.lineTo(x, y) : g.moveTo(x, y); });
  g.strokeStyle = color; g.lineWidth = 2; g.stroke();
  g.lineTo(w, h); g.lineTo(0, h); g.closePath();
  const grad = g.createLinearGradient(0, 0, 0, h); grad.addColorStop(0, color + (light ? "55" : "40")); grad.addColorStop(1, color + "00");
  g.fillStyle = grad; g.fill();
}

// Replays the last 30 hours; the alarm fires on the newest hour so every agent sees the same numbers.
async function replayToAlarm() {
  for (let i = 689; i <= 719; i++) { renderFleet(i); await wait(230); }
  return 719;
}

// ---------------------------------------------------------------- UI helpers
function stage(name) {
  const order = ["ingest", "decide", "act", "approve", "report"], at = order.indexOf(name);
  document.querySelectorAll(".stage").forEach((el) => {
    const k = order.indexOf(el.dataset.stage);
    el.classList.toggle("on", k === at); el.classList.toggle("done", k < at);
  });
}
function status_(who, text, active = true) {
  const m = document.querySelector(`.member[data-who=${who}]`);
  m.querySelector(".status").textContent = text; m.classList.toggle("active", active);
}
function toast(text, ok = false, ms = 3800) {
  const t = $("#toast"); t.textContent = text; t.classList.toggle("ok", ok); t.classList.add("on");
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("on"), ms);
}
const NAMES = { pip: "Pip · guide", scout: "Scout · investigate", bolt: "Bolt · act", gate: "Gate · govern" };
async function say(who, text, actions) {
  let av = $("#capWho");
  if (!av.classList.contains(who)) av = swapCharacter(av, who);
  $("#capName").textContent = NAMES[who]; $("#capText").textContent = text; $("#capActs").innerHTML = "";
  $("#caption").classList.add("on"); crew(who, "talk");
  await speak(who, text);
  crew(who, "idle");
  if (!actions) { await wait(250); return; }
  return new Promise((res) => {
    waiter = (v) => { waiter = null; $("#capActs").innerHTML = ""; res(v); };
    if (AUTO) setTimeout(() => waiter && waiter(actions[actions.length - 1][1]), 1500);
    actions.forEach(([label, value, cls]) => {
      const b = document.createElement("button"); b.className = "btn " + (cls || ""); b.textContent = label;
      b.onclick = () => waiter && waiter(value); $("#capActs").appendChild(b);
    });
  });
}
const hideCaption = () => $("#caption").classList.remove("on");
const pause = () => new Promise((res) => (waiter = (v) => { waiter = null; res(v); }));

async function agent(role, context, scenario = "turbine") {
  const t0 = performance.now();
  const r = await fetch("/api/agent", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ role, context, scenario }) });
  const j = await r.json(); if (j.error) throw new Error(j.error);
  j.wall = Math.round(performance.now() - t0); return j;
}
const srcBadge = (el, j) => { el.textContent = j.source === "live" ? `live · ${j.model} · ${(j.ms / 1000).toFixed(1)}s` : j.source === "cache" ? "cached answer" : "rules fallback"; el.classList.toggle("live", j.source === "live"); };

// ---------------------------------------------------------------- audit trail (SHA-256 hash chain)
async function sha(s) { const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)); return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join(""); }
async function log(actor, action, detail, kind = "") {
  const prev = audit.length ? audit[audit.length - 1].hash : "0".repeat(64);
  const entry = { ts: new Date().toISOString(), actor, action, detail, role, prev };
  entry.hash = await sha(prev + JSON.stringify({ ...entry, hash: undefined }));
  audit.push(entry);
  fetch("/api/audit", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(entry) });
  const row = document.createElement("div"); row.className = "arow " + kind;
  row.innerHTML = `<span>${new Date(entry.ts).toLocaleTimeString("en-GB")}</span><span class="a">${actor}</span><span>${action} · ${detail}</span><span class="h">#${entry.hash.slice(0, 16)} ← #${prev.slice(0, 16)}</span>`;
  $("#auditRows").appendChild(row); row.scrollIntoView({ block: "end", behavior: "smooth" });
  $("#chain").textContent = (await verifyChain()) ? `· chain verified ✓ ${audit.length}` : "· chain BROKEN";
}
async function verifyChain() {
  let prev = "0".repeat(64);
  for (const e of audit) { if (e.prev !== prev || e.hash !== await sha(prev + JSON.stringify({ ...e, hash: undefined }))) return false; prev = e.hash; }
  return true;
}

// ---------------------------------------------------------------- Touch ID via WebAuthn (platform authenticator)
const rnd = (n) => crypto.getRandomValues(new Uint8Array(n));
const b64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
async function registerPasskey() {
  try {
    const cred = await navigator.credentials.create({ publicKey: {
      challenge: rnd(32), rp: { name: "Sidekick demo", id: location.hostname },
      user: { id: rnd(16), name: "supervisor@northwind", displayName: "Maintenance supervisor" },
      pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
      authenticatorSelection: { authenticatorAttachment: "platform", userVerification: "required" }, timeout: 60000 } });
    localStorage.setItem("sidekick-cred", b64(cred.rawId)); return true;
  } catch { return false; }
}
async function biometric() {
  if (AUTO) return true;
  const id = (() => { try { return localStorage.getItem("sidekick-cred"); } catch { return null; } })();
  if (!id) return (await registerPasskey()) || confirm("Touch ID unavailable. Confirm as Maintenance supervisor?");
  try {
    await navigator.credentials.get({ publicKey: { challenge: rnd(32), allowCredentials: [{ type: "public-key", id: unb64(id) }], userVerification: "required", timeout: 60000 } });
    return true;
  } catch { return confirm("Touch ID unavailable. Confirm as Maintenance supervisor?"); }
}
function switchRole() {
  role = role === "Operator" ? "Maintenance supervisor" : "Operator";
  $("#role").innerHTML = `Role: <b>${role}</b>`; status_("gate", `Signed in: ${role}`, true);
  chime("pop"); if (waiter && waiter.role) waiter("role");
}

// ---------------------------------------------------------------- the story
async function start() {
  $("#intro").remove(); chime("pop");
  stage("ingest"); status_("pip", "Watching 6 turbines");
  log("Ingest", "SCADA stream", `${D.fleet.turbines.length} turbines, hourly, ${D.fleet.source.dataset.split(",")[0]}`);
  const alarmIdx = await replayToAlarm();
  const ratio = ratioAt(D, "T-04", alarmIdx).toFixed(1);
  $("#tile-T-04").classList.add("alarm"); renderFleet(alarmIdx); chime("alarm");
  crew("pip", "alert"); status_("pip", "Alarm on T-04");
  log("Ingest", "ALARM", `T-04 drive-train vibration ${ratio}× fleet median (48 h)`, "deny");

  const def = await (await fetch("assets/turbine.json")).json();
  def.parts.find((p) => p.id === "blade1").label = null;
  def.parts.find((p) => p.id === "hub").label = "Rotor · {rotor_m} m";
  const vars = { hub_m: S.turbine.hub_m, rotor_m: S.turbine.rotor_m, rated_mw: "2", rpm_max: S.rpm_max.toLocaleString("en-GB"), ratio };
  def.steps.forEach((st) => prefetch("pip", fillVars(st.say, vars)));
  // Scout starts now so the model's latency hides behind the 3D build.
  const scoutP = agent("scout", scoutContext(D, S, def));
  const windows = repairWindows(D);

  await wait(400);
  await say("pip", `Turbine four's drive-train vibration just hit ${ratio} times the rest of the fleet. Want me to look?`, [["Show me", "go", "go"]]);
  hideCaption();

  // --- 3D explanation
  stage("decide"); crew("pip", "idle");
  status_("scout", "Reading 30 days of SCADA…"); crew("scout", "work");
  document.body.classList.add("dim", "show3d"); $("#title3d").textContent = def.title;
  scene.load(def, vars); scene.layout(0, 1, 10);
  for (const st of def.steps) {
    scene.showStep(st);
    await say("pip", fillVars(st.say, vars));
    await wait(st.explode ? 1400 : 300);
  }
  await wait(1200); hideCaption();

  // --- Scout's evidence
  scene.layout(0.2, 0.92);
  $("#evidence").classList.add("on");
  let scout;
  try { scout = await scoutP; } catch (e) { toast("Scout failed: " + e.message); return; }
  report.scout = scout.output; srcBadge($("#scoutSrc"), scout);
  prefetch("scout", scout.output.headline);
  const boltP = agent("bolt", boltContext(D, scout.output, windows, "turbine"));
  status_("scout", "Found the cause", true);
  log("Scout", "Diagnosis", `${scout.output.diagnosis.component}, ${scout.output.diagnosis.days_to_failure} d, conf ${scout.output.diagnosis.confidence} [${scout.source}]`);
  await renderEvidence(scout.output, "turbine");
  crew("scout", "happy");
  await say("scout", scout.output.headline);
  crew("scout", "idle"); status_("scout", `${scout.output.diagnosis.days_to_failure} days to failure`, false);
  await say("pip", "Bolt, can you line up the repair?");
  hideCaption();

  // --- Bolt drafts the work order
  stage("act"); $("#evidence").classList.remove("on");
  scene.layout(0.27, 0.72);
  $("#cmms").classList.add("on"); status_("bolt", "Drafting work order…"); crew("bolt", "work");
  drawWind(windows, null);
  let bolt;
  try { bolt = await boltP; } catch (e) { toast("Bolt failed: " + e.message); return; }
  report.bolt = bolt.output; srcBadge($("#boltSrc"), bolt); prefetch("bolt", bolt.output.spoken);
  const wo = bolt.output.work_order;
  const pipP = agent("pip", { scout: scout.output, bolt: bolt.output, outcome: "approved by supervisor" });
  await fillWorkOrder(wo, windows);
  crew("bolt", "happy"); status_("bolt", "Draft ready · waiting for approval", true);
  log("Bolt", "Drafted WO-2491", `${wo.part_sku}, ${wo.window_start} → ${wo.window_end}, ${inr(wo.total_cost_inr)}`);
  await say("bolt", bolt.output.spoken);
  crew("bolt", "idle"); hideCaption();

  // --- Gate: approval
  stage("approve"); $("#audit").classList.add("on");
  const policy = D.sheets["Approval policy"];
  $("#apWO").textContent = `WO-2491 · ${wo.title} · ${wo.asset}`;
  $("#apAmt").textContent = inr(wo.total_cost_inr);
  $("#apWhy").textContent = `${wo.window_start.replace("T", " ")} → ${wo.window_end.slice(11)} · lost energy ${inr(wo.energy_loss_inr)}`;
  $("#apPolicy").textContent = "Policy (plant_ops.xlsx): " + policy.map((p) => `${p.Role}: ${p["Can approve work orders"] === "Yes" ? "up to " + inr(p["Limit INR"]) : "cannot approve"}`).join(" · ");
  $("#approval").classList.add("on"); status_("gate", `Checking policy · ${role}`, true);
  await approvalLoop(wo, policy);

  // --- Report + ROI
  stage("report"); $("#approval").classList.remove("on");
  $("#submit").textContent = "✓ Submitted"; $("#submit").classList.add("ready"); $("#woId").textContent = "WO-2491 · APPROVED";
  await wait(1200);
  $("#cmms").classList.remove("on"); $("#audit").classList.remove("on");
  document.body.classList.remove("show3d");
  let pip; try { pip = (await pipP).output; } catch { pip = { lines: [], report_summary: "" }; }
  report.pip = pip;
  const roi = await drawROI(wo, windows);
  report.roi = roi; report.audit = audit; report.sources = D.fleet.source; report.generatedAt = new Date().toISOString();
  try { localStorage.setItem("sidekick-report", JSON.stringify(report)); } catch { /* report page will say no data */ }
  log("Pip", "Report", `Saved ≈ ${inr(roi.saved)} vs unplanned failure`, "ok");
  for (const line of pip.lines || []) await say("pip", line);
  swapReady = true;
  const choice = await say("pip", "I've written it all up. And this crew isn't just for turbines.", [["Open report", "report", "ghost"], ["Try another asset", "swap", "go"]]);
  if (choice === "report") { window.open("report.html", "_blank"); await say("pip", "Want to see another asset?", [["Try another asset", "swap", "go"]]); }
  swap();
}

async function approvalLoop(wo, policy) {
  const limitOf = (r) => policy.find((p) => p.Role.toLowerCase().startsWith(r.toLowerCase().split(" ")[0])) || policy[0];
  for (;;) {
    await say("pip", role === "Operator" ? "This needs a human. Go ahead and approve it." : "Supervisor signed in. Approve when ready.");
    await new Promise((res) => { $("#apGo").onclick = res; waiter = res; if (AUTO) setTimeout(res, 1500); });
    waiter = null; hideCaption();
    const p = limitOf(role), canApprove = p["Can approve work orders"] === "Yes" && wo.total_cost_inr <= p["Limit INR"];
    if (!canApprove) {
      crew("gate", "deny"); chime("deny");
      toast(`✋ ${role}s can't approve work orders above ${inr(p["Limit INR"])}. Escalating to Maintenance supervisor.`);
      await log("Gate", "DENIED", `${role} attempted approval of ${inr(wo.total_cost_inr)} (limit ${inr(p["Limit INR"])})`, "deny");
      status_("gate", "Blocked · needs supervisor", true);
      await say("gate", "Sorry, operators can't approve this one. It needs a maintenance supervisor.");
      crew("gate", "idle");
      if (role === "Operator") {
        await new Promise((res) => { waiter = res; waiter.role = true; if (AUTO) setTimeout(switchRole, 1500); });
        waiter = null;
      }
      continue;
    }
    status_("gate", "Waiting for Touch ID…", true); crew("gate", "alert");
    const ok = await biometric();
    if (!ok) { crew("gate", "deny"); toast("Biometric check failed"); continue; }
    crew("gate", "approve"); chime("ok");
    toast(`✓ Approved by ${role} · Touch ID`, true);
    await log("Gate", "APPROVED", `WO-2491 ${inr(wo.total_cost_inr)} · biometric ✓ · ${role}`, "ok");
    status_("gate", "Approved and logged", true);
    await say("gate", "Approved, and it's on the record.");
    crew("gate", "idle");
    return;
  }
}

// ---------------------------------------------------------------- evidence cards
async function renderEvidence(out, scenario, host = $("#cards")) {
  host.innerHTML = "";
  for (const e of out.evidence) {
    const c = document.createElement("div"); c.className = "card";
    c.innerHTML = `<div class="k">${e.id} · ${e.kind}</div><h4>${esc(e.title)}</h4><p>${esc(e.detail)}</p><div class="cite">↳ ${esc(e.source)}</div>`;
    host.appendChild(c);
    if (e.kind === "trend" || e.kind === "fleet") { const cv = document.createElement("canvas"); c.insertBefore(cv, c.querySelector(".cite")); }
    await wait(60); c.classList.add("on"); chime("pop");
    const cv = c.querySelector("canvas");
    if (cv) e.kind === "fleet" && scenario === "turbine" ? fleetBars(cv) : trendChart(cv, scenario);
    await wait(1100);
  }
  const d = out.diagnosis, c = document.createElement("div"); c.className = "card diag";
  const pct = Math.round(d.confidence * 100), circ = 2 * Math.PI * 30;
  c.innerHTML = `<div class="k" style="color:var(--hot)">Diagnosis</div>
    <div class="diagrow"><svg class="ring" viewBox="0 0 74 74"><circle cx="37" cy="37" r="30" fill="none" stroke="#2a3542" stroke-width="7"/>
      <circle cx="37" cy="37" r="30" fill="none" stroke="#ff5a4e" stroke-width="7" stroke-linecap="round" stroke-dasharray="${circ}" stroke-dashoffset="${circ}" transform="rotate(-90 37 37)" style="transition:stroke-dashoffset 1.4s"/>
      <text x="37" y="42" text-anchor="middle" fill="#fff" font-size="16" font-weight="800">${pct}%</text></svg>
      <div><h4 style="margin:0">${esc(d.component)}</h4><p>${esc(d.failure_mode)}</p></div>
      <div style="margin-left:auto;text-align:right"><div class="big">${d.days_to_failure}</div><div class="unit">days to failure</div></div></div>
    <p style="margin-top:8px">${esc(d.reasoning)}</p>`;
  host.appendChild(c); await wait(60); c.classList.add("on"); chime("alarm");
  setTimeout(() => (c.querySelector("circle:nth-of-type(2)").style.strokeDashoffset = circ * (1 - d.confidence)), 100);
  c.scrollIntoView({ behavior: "smooth", block: "end" });
}
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

function setup(c) {
  const dpr = devicePixelRatio || 1, w = c.clientWidth, h = c.clientHeight;
  c.width = w * dpr; c.height = h * dpr; const g = c.getContext("2d"); g.scale(dpr, dpr); return [g, w, h];
}
function trendChart(c, scenario) {
  const [g, w, h] = setup(c);
  const a = scenario === "turbine" ? S.daily_vib : daily(D.chiller.series.seal), b = scenario === "turbine" ? S.fleet_daily_vib : null;
  const all = a.concat(b || []), max = Math.max(...all) * 1.08, min = Math.min(...all) * 0.9;
  const X = (k) => 6 + (k / (a.length - 1)) * (w - 12), Y = (v) => h - 14 - ((v - min) / (max - min)) * (h - 22);
  let t0 = performance.now();
  (function frame(now) {
    const p = Math.min(1, (now - t0) / 1200), n = Math.max(2, Math.floor(p * a.length));
    g.clearRect(0, 0, w, h);
    g.font = "10px ui-monospace,Menlo"; g.fillStyle = "#56657a";
    g.fillText(scenario === "turbine" ? "30 days · T-04 (red) vs fleet median (grey)" : "30 days · seal chamber °C", 6, h - 2);
    const line = (arr, col, lw) => { g.beginPath(); arr.slice(0, n).forEach((v, k) => (k ? g.lineTo(X(k), Y(v)) : g.moveTo(X(k), Y(v)))); g.strokeStyle = col; g.lineWidth = lw; g.stroke(); };
    if (b) line(b, "#6b7a8c", 2);
    line(a, "#ff5a4e", 2.6);
    if (p < 1) requestAnimationFrame(frame);
  })(t0);
}
const daily = (s) => Array.from({ length: Math.floor(s.length / 24) }, (_, d) => s.slice(d * 24, d * 24 + 24).reduce((x, y) => x + y, 0) / 24);
function fleetBars(c) {
  const [g, w, h] = setup(c), ts = D.fleet.turbines, n = ts[0].series.vib.length;
  const vals = ts.map((t) => t.series.vib.slice(n - 48).reduce((a, b) => a + b, 0) / 48), max = Math.max(...vals) * 1.1;
  const bw = (w - 20) / ts.length; let t0 = performance.now();
  (function frame(now) {
    const p = Math.min(1, (now - t0) / 900); g.clearRect(0, 0, w, h);
    ts.forEach((t, k) => {
      const bh = (vals[k] / max) * (h - 24) * p, x = 10 + k * bw + bw * 0.18;
      g.fillStyle = t.id === "T-04" ? "#ff5a4e" : "#3b4a5c"; g.fillRect(x, h - 14 - bh, bw * 0.64, bh);
      g.fillStyle = "#8796a8"; g.font = "10px ui-monospace,Menlo"; g.fillText(t.id, x, h - 2);
    });
    if (p < 1) requestAnimationFrame(frame);
  })(t0);
}

// ---------------------------------------------------------------- CMMS form + wind chart
function drawWind(windows, chosen) {
  const c = $("#windChart"), [g, w, h] = setup(c), F = D.forecast, ws = F.wind_speed_80m;
  $("#windSrc").textContent = F.source === "live" ? "live" : "cached";
  const max = Math.max(12, ...ws) * 1.05, X = (i) => (i / (ws.length - 1)) * w, Y = (v) => h - 16 - (v / max) * (h - 22);
  g.clearRect(0, 0, w, h);
  for (const win of windows) {
    const pick = chosen && win.start === chosen; g.fillStyle = pick ? "rgba(29,138,90,.28)" : "rgba(255,191,71,.25)";
    g.fillRect(X(win.i), 0, X(win.i + 6) - X(win.i), h - 16);
    if (pick) { g.fillStyle = "#1d8a5a"; g.font = "bold 11px -apple-system"; g.fillText("Bolt's pick", X(win.i) + 2, 12); }
  }
  g.setLineDash([4, 4]); g.strokeStyle = "#e0897f"; g.beginPath(); g.moveTo(0, Y(10)); g.lineTo(w, Y(10)); g.stroke(); g.setLineDash([]);
  g.fillStyle = "#c0645a"; g.font = "10px ui-monospace,Menlo"; g.fillText("10 m/s work limit", w - 100, Y(10) - 4);
  g.beginPath(); ws.forEach((v, i) => (i ? g.lineTo(X(i), Y(v)) : g.moveTo(X(i), Y(v)))); g.strokeStyle = "#2f7cf6"; g.lineWidth = 2; g.stroke();
  g.fillStyle = "#64748b";
  for (let i = 0; i < ws.length; i += 24) g.fillText(new Date(F.time[i]).toLocaleDateString("en-GB", { weekday: "short", day: "numeric" }), X(i) + 2, h - 3);
}

async function flyTo(el) {
  const r = el.getBoundingClientRect(), cur = $("#cursor");
  cur.classList.add("on"); cur.style.transform = `translate(${r.left + 18}px, ${r.top + r.height / 2}px)`;
  await wait(780);
}
async function typeInto(el, text) {
  el.classList.add("focus"); el.textContent = "";
  for (const ch of text) { el.textContent += ch; await wait(text.length > 40 ? 9 : 22); }
  el.classList.remove("focus"); el.classList.add("done");
}
async function fillWorkOrder(wo, windows) {
  const cmms = $("#cmms"), F = (k) => cmms.querySelector(`[data-f=${k}]`);
  const winLabel = (windows.find((w) => w.start === wo.window_start) || {}).label || `${wo.window_start} → ${wo.window_end}`;
  const fields = [["title", wo.title], ["asset", `${wo.asset} · ${wo.component}`], ["priority", wo.priority], ["part", `${wo.part_sku} · ${wo.part_name} × ${wo.quantity}`], ["techs", wo.technicians.join(", ")], ["window", winLabel]];
  for (const [k, v] of fields) {
    await flyTo(F(k)); await typeInto(F(k), v);
    if (k === "window") { await flyTo($("#windChart")); drawWind(windows, wo.window_start); chime("pop"); await wait(700); }
  }
  const tb = $("#costs"); tb.innerHTML = ""; await flyTo(tb);
  for (const r of wo.cost_breakdown) { tb.insertAdjacentHTML("beforeend", `<tr><td>${esc(r.item)}</td><td>${inr(r.inr)}</td></tr>`); chime("pop"); await wait(350); }
  tb.insertAdjacentHTML("beforeend", `<tr class="total"><td>Total</td><td>${inr(wo.total_cost_inr)}</td></tr>`);
  await flyTo($("#submit")); $("#cnote").textContent = wo.justification;
  await wait(600); $("#cursor").classList.remove("on");
}

// ---------------------------------------------------------------- ROI sketch board
async function drawROI(wo, windows) {
  const avgKw = S.avg_power_kw, tariff = D.fleet.site.tariff_inr_kwh, days = 42;
  const unplanned = avgKw * 24 * days * tariff, planned = wo.energy_loss_inr + wo.total_cost_inr, saved = unplanned - planned;
  const winLabel = (windows.find((w) => w.start === wo.window_start) || {}).label || wo.window_start;
  const svg = $("#roiSvg"); $("#roi").classList.add("on");
  svg.innerHTML = `
    <text x="40" y="58" font-size="38" font-weight="700">One bearing. Two futures.</text>
    <text x="40" y="140" font-size="22" fill="#b3261e">If it fails in service</text>
    <path class="draw" stroke="#e5484d" stroke-width="34" d="M40 180 C 300 176, 600 184, 960 179"/>
    <text x="40" y="236" font-size="18" fill="#4b5563">~6 weeks offline waiting for a crane and a gearbox (guide §4.4)</text>
    <text x="960" y="236" font-size="26" font-weight="700" text-anchor="end" fill="#b3261e" class="num" data-v="${unplanned}">₹0</text>
    <text x="40" y="300" font-size="22" fill="#1d6b45">Fixed on ${esc(winLabel)}</text>
    <path class="draw" stroke="#30a46c" stroke-width="34" d="M40 340 C 44 338, 52 342, 60 340"/>
    <text x="40" y="396" font-size="18" fill="#4b5563">6 hours in the calmest window · part in stock · approved</text>
    <text x="960" y="396" font-size="26" font-weight="700" text-anchor="end" fill="#1d6b45" class="num" data-v="${planned}">₹0</text>
    <text x="40" y="478" font-size="30" font-weight="700">Saved ≈ <tspan class="num" data-v="${saved}" fill="#1d6b45">₹0</tspan></text>
    <path class="draw" stroke="#1c232c" stroke-width="3" d="M30 440 C 200 422, 470 426, 530 450 C 570 470, 480 508, 270 506 C 100 504, 20 488, 30 452"/>
    <text x="1000" y="532" font-size="13" text-anchor="end" fill="#6b7280">Lost energy at ${inr(tariff)}/kWh × T-04's real 30-day average output (${avgKw} kW). Excludes gearbox exchange, so the real gap is larger.</text>`;
  for (const p of svg.querySelectorAll(".draw")) {
    const L = p.getTotalLength(); p.style.strokeDasharray = L; p.style.strokeDashoffset = L;
    p.getBoundingClientRect(); p.style.transition = "stroke-dashoffset 1.3s ease-in-out"; p.style.strokeDashoffset = 0;
    await wait(650);
  }
  const nums = [...svg.querySelectorAll(".num")], t0 = performance.now();
  await new Promise((res) => (function frame(now) {
    const p = Math.min(1, (now - t0) / 1600), e = 1 - (1 - p) ** 3;
    nums.forEach((n) => (n.textContent = inr(+n.dataset.v * e)));
    p < 1 ? requestAnimationFrame(frame) : res();
  })(t0));
  chime("ok");
  return { unplanned: Math.round(unplanned), planned: Math.round(planned), saved: Math.round(saved), days, avgKw, tariff };
}

// ---------------------------------------------------------------- reusability: swap the asset
async function swap(defIn) {
  if (!swapReady) return; swapReady = false; hideCaption();
  $("#roi").classList.remove("on"); $("#mini").innerHTML = "";
  const def = defIn || (await (await fetch("assets/chiller_pump.json")).json());
  const C = chillerStats(D), vars = { seal_now: C.seal_now };
  stage("decide"); log("Ingest", "Asset loaded", `${def.id} · ${def.title}`);
  document.body.classList.add("dim", "show3d"); $("#title3d").textContent = def.title;
  scene.turn = 0.0028; scene.load(def, vars); scene.view.offset = 0; scene.view.zoom = 1; scene.applyView();
  def.steps.forEach((st) => prefetch("pip", fillVars(st.say, vars)));
  const chain = (async () => {
    const sc = await agent("scout", chillerScoutContext(D, C, def), "chiller");
    const bo = await agent("bolt", boltContext(D, sc.output, chillerWindows(), "chiller"), "chiller");
    return [sc, bo];
  })();
  crew("scout", "work"); crew("bolt", "work"); status_("scout", "Reading pump telemetry…"); status_("bolt", "Waiting for diagnosis…");
  for (const st of def.steps) { scene.showStep(st); await say("pip", fillVars(st.say, vars)); await wait(st.explode ? 1300 : 300); }
  hideCaption(); scene.layout(0.2, 0.92);
  const [sc, bo] = await chain;
  const wo = bo.output.work_order;
  crew("scout", "idle"); crew("bolt", "idle");
  status_("scout", sc.output.diagnosis.component, false); status_("bolt", `Draft ${inr(wo.total_cost_inr)}`, false);
  const mini = $("#mini");
  mini.innerHTML = `<div class="card on diag"><div class="k" style="color:var(--hot)">Scout · ${sc.source}</div><h4>${esc(sc.output.diagnosis.component)} · ${sc.output.diagnosis.days_to_failure} days</h4><p>${esc(sc.output.headline)}</p></div>
    <div class="card on"><div class="k" style="color:var(--bolt)">Bolt · ${bo.source}</div><h4>${esc(wo.title)}</h4><p>${esc(wo.technicians.join(", "))} · ${esc(wo.window_start.replace("T", " "))} · ${inr(wo.total_cost_inr)}</p><div class="cite">→ Gate: needs approval</div></div>`;
  stage("approve"); log("Bolt", "Drafted", `${wo.asset} ${wo.part_sku} ${inr(wo.total_cost_inr)}`);
  await say("scout", sc.output.headline);
  $("#finale").classList.add("on"); chime("ok");
  crew("pip", "happy"); crew("scout", "happy"); crew("bolt", "happy"); crew("gate", "happy");
  await say("pip", "Same crew, new machine. All it took was a new asset file.");
  hideCaption();
}
