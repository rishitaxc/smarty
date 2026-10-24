// Character voices: OpenAI Marin via the local server (cached), with playback controls.
// Browser speech synthesis is only a last resort if the voice service can't be reached.
const PITCH = { pip: 1.3, scout: 1.05, bolt: 0.9, gate: 0.75 };
const cache = new Map();
const RATE = 1.15;   // a touch quicker than natural pace; pitch is preserved
let muted = false, current = null, paused = false, skipping = false;
const history = [];          // { who, text, ms } for every finished line, newest last
const waiters = [];          // resolves when playback resumes

export const toggleMute = () => (muted = !muted);
export const isPaused = () => paused;

export function prefetch(who, text) {
  const k = who + "|" + text;
  if (!cache.has(k)) cache.set(k, fetch("/api/tts", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ who, text }) })
    .then((r) => (r.ok ? r.blob() : null)).catch(() => null));
  return cache.get(k);
}

export function untilResumed() { return paused ? new Promise((r) => waiters.push(r)) : Promise.resolve(); }
export function pause() { paused = true; current?.pause(); if ("speechSynthesis" in window) speechSynthesis.pause(); }
export function resume() {
  paused = false; current?.play().catch(() => {}); if ("speechSynthesis" in window) speechSynthesis.resume();
  waiters.splice(0).forEach((r) => r());
}
// Jump to the end of the current line.
export function skip() { skipping = true; if (current) { current.currentTime = current.duration || 0; current.dispatchEvent(new Event("ended")); } if ("speechSynthesis" in window) speechSynthesis.cancel(); }
// Lines finished within the last `seconds` of speech, oldest first (for "back 10 s").
export function recent(seconds) {
  const out = []; let t = 0;
  for (let i = history.length - 1; i >= 0 && t < seconds * 1000; i--) { out.unshift(history[i]); t += history[i].ms; }
  return out;
}

// force: speak even while the main story is paused (answers to a question asked mid-run).
export async function speak(who, text, { record = true, force = false } = {}) {
  if (!force) await untilResumed();
  const prev = current;
  skipping = false;
  const t0 = performance.now();
  if (muted) await wait(900 + text.length * 45);
  else {
    const blob = await Promise.race([prefetch(who, text), wait(15000).then(() => null)]);
    if (blob) {
      const audio = new Audio(URL.createObjectURL(blob)); current = audio; audio.playbackRate = RATE;
      try {
        await audio.play();
        await new Promise((res) => { audio.onended = res; audio.onerror = res; setTimeout(res, 45000); });
      } catch { await synth(who, text); }
      current = force ? prev : null;
    } else await synth(who, text);
  }
  if (record) history.push({ who, text, ms: Math.max(1500, performance.now() - t0) });
  if (!force) await untilResumed();
}

function synth(who, text) {
  return new Promise((res) => {
    if (!("speechSynthesis" in window)) return wait(1200 + text.length * 50).then(res);
    const u = new SpeechSynthesisUtterance(text);
    const voices = speechSynthesis.getVoices().filter((v) => v.lang.startsWith("en"));
    const pick = { pip: /Samantha|Karen|Moira/, scout: /Tessa|Serena|Fiona/, bolt: /Daniel|Rishi|Alex/, gate: /Fred|Daniel|Aaron/ }[who] || /Samantha/;
    u.voice = voices.find((v) => pick.test(v.name)) || voices[0] || null;
    u.pitch = PITCH[who] || 1; u.rate = 1.04;
    u.onend = res; u.onerror = res; setTimeout(res, 2500 + text.length * 80);
    speechSynthesis.speak(u);
  });
}

export function stopVoice() { if (current) current.pause(); if ("speechSynthesis" in window) speechSynthesis.cancel(); }
export const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// Short UI sounds made with WebAudio (no files needed).
let ctx;
export function chime(kind) {
  try {
    ctx ||= new AudioContext();
    const notes = { alarm: [[880, 0], [660, .18], [880, .36], [660, .54]], ok: [[660, 0], [990, .12]], deny: [[220, 0], [180, .16]], pop: [[1200, 0]] }[kind];
    for (const [f, t] of notes) {
      const o = ctx.createOscillator(), g = ctx.createGain();
      o.type = kind === "deny" ? "square" : "sine"; o.frequency.value = f;
      g.gain.setValueAtTime(0.0001, ctx.currentTime + t);
      g.gain.exponentialRampToValueAtTime(kind === "pop" ? 0.05 : 0.12, ctx.currentTime + t + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + t + 0.16);
      o.connect(g).connect(ctx.destination); o.start(ctx.currentTime + t); o.stop(ctx.currentTime + t + 0.2);
    }
  } catch { /* audio is optional */ }
}
