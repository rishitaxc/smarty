// Loads the demo data and builds the context each agent receives.
const mean = (a) => a.reduce((s, x) => s + x, 0) / Math.max(1, a.length);
const median = (a) => { const s = [...a].sort((x, y) => x - y); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const r1 = (x) => Math.round(x * 10) / 10;
export const inr = (x) => "₹" + Math.round(x).toLocaleString("en-IN");

export async function loadData() {
  const [fleet, manual, chiller, wbBuf] = await Promise.all([
    fetch("data/fleet.json").then((r) => r.json()),
    fetch("data/manual.md").then((r) => r.text()),
    fetch("data/chiller.json").then((r) => r.json()),
    fetch("data/plant_ops.xlsx").then((r) => r.arrayBuffer()),
  ]);
  const wb = XLSX.read(wbBuf, { type: "array" });
  const sheets = Object.fromEntries(wb.SheetNames.map((n) => [n, XLSX.utils.sheet_to_json(wb.Sheets[n])]));
  const forecast = await loadForecast(fleet.site);
  const D = { fleet, manual, chiller, sheets, forecast };
  D.curve = powerCurve(fleet);
  return D;
}

async function loadForecast(site) {
  const url = `https://api.open-meteo.com/v1/forecast?latitude=${site.lat}&longitude=${site.lon}&hourly=wind_speed_80m&wind_speed_unit=ms&forecast_days=7&timezone=Europe%2FLondon`;
  try {
    const ctl = new AbortController();
    setTimeout(() => ctl.abort(), 4000);
    const j = await (await fetch(url, { signal: ctl.signal })).json();
    if (!j.hourly) throw new Error("bad forecast");
    return { ...j.hourly, source: "live" };
  } catch {
    const j = await (await fetch("data/forecast_cache.json")).json();
    return { ...j.hourly, source: "cached" };
  }
}

// Empirical power curve from the real fleet data: median kW per 0.5 m/s bin.
function powerCurve(fleet) {
  const bins = {};
  for (const t of fleet.turbines) t.series.wind.forEach((w, i) => {
    const b = Math.round(w * 2) / 2; (bins[b] ||= []).push(Math.max(0, t.series.power[i]));
  });
  const pts = Object.entries(bins).filter(([, v]) => v.length > 8).map(([b, v]) => [+b, median(v)]).sort((a, b) => a[0] - b[0]);
  return (w) => {
    if (w <= pts[0][0]) return pts[0][1];
    for (let i = 1; i < pts.length; i++) if (w <= pts[i][0]) {
      const [x0, y0] = pts[i - 1], [x1, y1] = pts[i]; return y0 + ((w - x0) / (x1 - x0)) * (y1 - y0);
    }
    return pts[pts.length - 1][1];
  };
}

export function manualSections(text, ids) {
  return text.split(/\n(?=## )/).filter((s) => ids.some((id) => s.startsWith(`## ${id}`))).join("\n").trim();
}

// ---------------------------------------------------------------- turbine scenario
export function turbineStats(D, id = "T-04") {
  const ts = D.fleet.turbines, t = ts.find((x) => x.id === id), others = ts.filter((x) => x.id !== id);
  const n = t.series.vib.length, last48 = (s) => s.slice(n - 48), last10d = (s) => s.slice(n - 240);
  const daily = (s) => Array.from({ length: 30 }, (_, d) => r1(mean(s.slice(d * 24, d * 24 + 24))));
  const fleetDaily = (k) => Array.from({ length: 30 }, (_, d) => r1(median(others.map((o) => mean(o.series[k].slice(d * 24, d * 24 + 24))))));
  const vibLast = mean(last48(t.series.vib)), fleetVib = median(others.map((o) => mean(last48(o.series.vib))));
  const oilLast = mean(last10d(t.series.oil)), fleetOil = median(others.map((o) => mean(last10d(o.series.oil))));
  return {
    turbine: t, others,
    vib_first10d: r1(mean(t.series.vib.slice(0, 240))), vib_last48h: r1(vibLast), fleet_vib_last48h: r1(fleetVib),
    vib_ratio_to_fleet_last48h: r1(vibLast / fleetVib),
    oil_last10d: r1(oilLast), fleet_oil_last10d: r1(fleetOil), oil_delta: r1(oilLast - fleetOil),
    daily_vib: daily(t.series.vib), fleet_daily_vib: fleetDaily("vib"),
    daily_oil: daily(t.series.oil), fleet_daily_oil: fleetDaily("oil"), daily_wind: daily(t.series.wind),
    rpm_max: Math.round(Math.max(...t.series.rpm) / 10) * 10,
    avg_power_kw: Math.round(mean(t.series.power)),
  };
}

// Ratio of a turbine's trailing-48h vibration to the fleet median, at replay hour i.
export function ratioAt(D, id, i) {
  const ts = D.fleet.turbines, t = ts.find((x) => x.id === id), a = Math.max(0, i - 47);
  const m = (x) => mean(x.series.vib.slice(a, i + 1));
  return m(t) / median(ts.filter((x) => x.id !== id).map(m));
}

export function scoutContext(D, S, assetDef) {
  const t = S.turbine;
  return {
    task: "Investigate the vibration alarm on this turbine and diagnose the failing component.",
    asset: { id: t.id, model: t.model, rated_kw: t.rated_kw, hub_m: t.hub_m, rotor_m: t.rotor_m, fleet_size: D.fleet.turbines.length },
    units: D.fleet.units,
    signals: {
      vib_first10d: S.vib_first10d, vib_last48h: S.vib_last48h, fleet_vib_last48h: S.fleet_vib_last48h,
      vib_ratio_to_fleet_last48h: S.vib_ratio_to_fleet_last48h, oil_last10d: S.oil_last10d,
      fleet_oil_last10d: S.fleet_oil_last10d, oil_delta: S.oil_delta,
      daily_vib_30d: S.daily_vib, fleet_median_daily_vib_30d: S.fleet_daily_vib,
      daily_oil_30d: S.daily_oil, fleet_median_daily_oil_30d: S.fleet_daily_oil, daily_wind_30d: S.daily_wind,
    },
    maintenance_history: D.sheets.Maintenance.filter((r) => r.Turbine === t.id),
    maintenance_guide: manualSections(D.manual, ["4.1", "4.2", "4.4"]),
    candidate_components: assetDef.parts.filter((p) => p.group === "internal" && p.label).map((p) => p.label),
    _fault_component: assetDef.fault.component,
  };
}

// Candidate repair windows from the forecast: 6 h daytime windows with wind below 10 m/s, lowest lost energy first.
export function repairWindows(D, hours = 6) {
  const F = D.forecast, out = [], tariff = D.fleet.site.tariff_inr_kwh;
  for (let i = 24; i + hours <= F.time.length; i++) {
    const h = +F.time[i].slice(11, 13);
    if (h < 6 || h > 12) continue;
    const w = F.wind_speed_80m.slice(i, i + hours);
    if (Math.max(...w) >= 10) continue;
    const kwh = w.reduce((s, x) => s + D.curve(x), 0);
    out.push({ i, start: F.time[i], end: F.time[i + hours], max_wind_ms: r1(Math.max(...w)), mean_wind_ms: r1(mean(w)),
      energy_loss_kwh: Math.round(kwh), energy_loss_inr: Math.round(kwh * tariff), label: label(F.time[i], F.time[i + hours]) });
  }
  const best = {};
  for (const w of out.sort((a, b) => a.energy_loss_inr - b.energy_loss_inr)) best[w.start.slice(0, 10)] ||= w;
  return Object.values(best).sort((a, b) => a.energy_loss_inr - b.energy_loss_inr).slice(0, 3);
}

function label(a, b) {
  const d = new Date(a);
  return d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }) + ` ${a.slice(11, 16)}–${b.slice(11, 16)}`;
}

export function boltContext(D, scout, windows, scenario) {
  const today = new Date();
  const base = {
    task: "Draft the maintenance work order for this diagnosis.",
    today: today.toISOString().slice(0, 10), weekday: today.toLocaleDateString("en-GB", { weekday: "long" }),
    diagnosis: scout.diagnosis, recommended_action: scout.recommended_action,
    parts_inventory: D.sheets.Parts, technicians: D.sheets.Technicians,
    approval_policy: D.sheets["Approval policy"], candidate_windows: windows,
  };
  if (scenario === "chiller") return { ...base, asset: { id: "CH-2", site: "City Hospital plant room" },
    procedure: manualSections(D.manual, ["7.2"]), labour_hours: 3 };
  const cons = [["SEAL-HSS-KIT", 1], ["OIL-GB-320", 2], ["FLT-GB-OFF", 1]];
  const consumables_inr = cons.reduce((s, [sku, q]) => s + q * D.sheets.Parts.find((p) => p.SKU === sku)["Unit cost INR"], 0);
  return { ...base, asset: { id: "T-04", site: D.fleet.site.name }, procedure: manualSections(D.manual, ["4.3"]),
    labour_hours: 6, consumables: cons.map(([sku, q]) => ({ sku, qty: q })), consumables_inr,
    tariff_inr_per_kwh: D.fleet.site.tariff_inr_kwh };
}

// ---------------------------------------------------------------- chiller scenario
export function chillerStats(D) {
  const s = D.chiller.series, n = s.vib.length;
  const a = (k, sl) => r1(mean(s[k].slice(...sl)));
  return { flow_first10d: a("flow", [0, 240]), flow_last48h: a("flow", [n - 48]), vib_first10d: a("vib", [0, 240]),
    vib_last48h: a("vib", [n - 48]), seal_first10d: a("seal", [0, 240]), seal_last48h: a("seal", [n - 48]),
    seal_now: r1(s.seal[n - 1]) };
}

export function chillerScoutContext(D, C, assetDef) {
  return {
    task: "Investigate the alarm on this hospital chilled-water pump and diagnose the failing component.",
    asset: { id: "CH-2", type: "Chilled-water pump", site: "City Hospital plant room", note: "Synthetic telemetry for demo" },
    units: D.chiller.units, signals: C,
    maintenance_history: [], maintenance_guide: manualSections(D.manual, ["7.2"]),
    candidate_components: assetDef.parts.filter((p) => p.label).map((p) => p.label),
    _fault_component: assetDef.fault.component,
  };
}

export function chillerWindows() {
  const out = [];
  for (let d = 1; d <= 3; d++) {
    const s = new Date(); s.setDate(s.getDate() + d); s.setHours(23, 0, 0, 0);
    const e = new Date(s.getTime() + 3 * 3600e3);
    const iso = (x) => `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}-${String(x.getDate()).padStart(2, "0")}T${String(x.getHours()).padStart(2, "0")}:00`;
    out.push({ start: iso(s), end: iso(e),
      label: s.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }) + " 23:00–02:00",
      energy_loss_inr: 0, note: "Night, low cooling demand, standby pump CH-3 running" });
  }
  return out;
}
