"""Sidekick AgentOps demo server (Python standard library only).

  python3 -I demo/server.py [--port 8787] [--mode auto|live|cached]

auto   : call the model; on failure use the cached answer, then the rule-based answer.
live   : call the model, never use the cache.
cached : use cached answers only (offline stage mode); rules if nothing is cached.

The OpenAI key comes from OPENAI_API_KEY or from the Side app's Keychain item
(service dev.side.notch.openai). It never leaves this process.
"""
import argparse, base64, hashlib, json, os, re, ssl, subprocess, sys, tempfile, time, urllib.error, urllib.request, uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
# python.org builds ship without root certificates; use the macOS bundle.
TLS = ssl.create_default_context(cafile="/etc/ssl/cert.pem") if os.path.exists("/etc/ssl/cert.pem") else ssl.create_default_context()
PUBLIC = os.path.join(HERE, "public")
CACHE = os.path.join(HERE, "cache")
MODEL = os.environ.get("SIDEKICK_MODEL", "gpt-6.1-sol")
FAST_MODEL = os.environ.get("SIDEKICK_FAST_MODEL", "gpt-5.4-mini")
TTS_MODEL = "gpt-4o-mini-tts"
STT_MODEL = os.environ.get("SIDEKICK_STT", "gpt-4o-mini-transcribe")
OCR_BIN = os.path.join(HERE, "ocr", "ocr")
# Every character speaks with OpenAI's Marin voice; the instructions give each one its personality.
VOICES = {
    "pip": ("marin", "Warm, friendly and clear, like a favourite teacher explaining something exciting. Natural, conversational pace with light smiles; no rushing, no sing-song."),
    "scout": ("marin", "Calm, curious and precise, like a thoughtful investigator sharing a finding. Even pace, slightly lower energy."),
    "bolt": ("marin", "Upbeat and confident, like an eager engineer who just built something. Natural pace, crisp."),
    "gate": ("marin", "Calm, firm and kind, like a polite security officer. Measured pace, clear pauses."),
}


def api_key():
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    env_file = os.path.join(HERE, ".env")  # gitignored; one line: OPENAI_API_KEY=sk-...
    if not key and os.path.exists(env_file):
        for line in open(env_file):
            if line.strip().startswith("OPENAI_API_KEY="):
                key = line.split("=", 1)[1].strip().strip('"').strip("'")
    if key or os.environ.get("SIDEKICK_NO_KEYCHAIN"):
        return key
    try:
        print("Reading the OpenAI key from Keychain (click Always Allow if macOS asks)…", flush=True)
        out = subprocess.run(["security", "find-generic-password", "-s", "dev.side.notch.openai", "-w"],
                             capture_output=True, text=True, timeout=90)
        return out.stdout.strip()
    except Exception:
        return ""


KEY = api_key()

# ---------------------------------------------------------------- prompts and schemas
S = lambda **props: {"type": "object", "additionalProperties": False, "properties": props, "required": list(props)}
STR, INT, NUM = {"type": "string"}, {"type": "integer"}, {"type": "number"}
ARR = lambda item: {"type": "array", "items": item}

ROLES = {
    "scout": {
        "instructions": (
            "You are Scout, the investigation agent in an asset-maintenance crew. You receive telemetry summaries, "
            "the fleet comparison, maintenance history and maintenance-guide excerpts for one asset. Diagnose the most "
            "likely failing component. Every claim must be backed by an evidence item that cites the exact source "
            "(signal name and numbers, work order ID, or guide section). Give 3 to 4 evidence items. Estimate days to "
            "failure using the guide's thresholds. Be calibrated; never invent data that is not in the input. "
            "'headline' is one short spoken sentence (max 22 words) a friendly character says aloud."),
        "schema": S(
            headline=STR,
            evidence=ARR(S(id=STR, kind={"type": "string", "enum": ["trend", "fleet", "record", "manual"]},
                           title=STR, detail=STR, source=STR)),
            diagnosis=S(component=STR, failure_mode=STR, days_to_failure=INT, confidence=NUM, reasoning=STR),
            recommended_action=STR),
    },
    "bolt": {
        "instructions": (
            "You are Bolt, the action agent. Draft one maintenance work order from the diagnosis. Choose the part from "
            "the inventory (prefer in-stock), choose qualified technicians available on the window's weekday, and choose "
            "the candidate window with the lowest lost energy that the technicians can staff. Cost = parts + labour "
            "(hours x rate per technician) + consumables listed in the guide. Use only numbers from the input. You "
            "cannot approve or submit; set needs_approval true. 'spoken' is one short sentence (max 24 words) a "
            "friendly character says aloud, mentioning the window and the cost in rupees."),
        "schema": S(
            work_order=S(title=STR, asset=STR, component=STR, priority={"type": "string", "enum": ["P1", "P2", "P3"]},
                         part_sku=STR, part_name=STR, quantity=INT, technicians=ARR(STR), window_start=STR,
                         window_end=STR, labour_hours=NUM, cost_breakdown=ARR(S(item=STR, inr=INT)),
                         total_cost_inr=INT, energy_loss_inr=INT, justification=STR),
            plan_steps=ARR(STR), needs_approval={"type": "boolean"}, spoken=STR),
    },
    "see": {
        "instructions": (
            "You are Scout, the investigator in a small agent team on the user's screen. You get a screenshot and, when "
            "found, a table rebuilt from OCR (cell ids refer to OCR boxes). Describe what is on screen, decide whether it "
            "holds numeric data, and find the single most important insight or problem. If there is a real table, pick "
            "OCR ids to circle: the key column header plus the cells that show the problem (max 12). 'opened_file' holds "
            "every row of every sheet in the workbook: use all of it and cross-check sheets (e.g. vibration against oil "
            "temperature and power) before deciding. If there is no real "
            "table, leave highlight_ids empty and, if the image shows numbers, read them into 'data'. Never invent "
            "columns. 'handoff' is one short sentence you say to Bolt about what to draw. 'diagnosis' names the physical "
            "component most likely at fault (e.g. 'M-05 spindle bearing'), the failure mode, a calibrated days-to-failure "
            "estimate (integer, 0 if unknown) and confidence 0-1."),
        "schema": S(
            kind={"type": "string", "enum": ["table", "chart", "text", "diagram", "code", "other"]},
            what_i_see=STR, headline=STR,
            problem=S(series=STR, start_label=STR, end_label=STR, summary=STR, ratio_to_others=NUM),
            highlight_ids=ARR(INT), data=S(labels=ARR(STR), series=ARR(S(name=STR, values=ARR(NUM)))),
            key_points=ARR(STR), handoff=STR,
            diagnosis=S(component=STR, failure_mode=STR, days_to_failure=INT, confidence=NUM, reasoning=STR)),
    },
    "draw": {
        "instructions": (
            "You are Bolt, the builder in a small agent team. Scout has read the user's screen. Design the best visual "
            "explanation. Use mode 'chart' when there is numeric series data, otherwise 'diagram': 3 to 6 nodes with short "
            "labels (max 4 words) and edges that explain how the ideas connect. 'narration' is 3 short spoken lines "
            "(max 16 words each) for Pip to say while it draws. For charts, add 3 to 6 'annotations' that explain the chart like a "
            "teacher drawing on a whiteboard, each tied to the narration line (0-based 'line') it illustrates: 'band' shades "
            "from_label..to_label (e.g. a normal period or the fault window), 'hline' is a dashed level at 'value' (e.g. the "
            "peer average), 'circle'/'arrow' point at 'series' on from_label, 'label' writes text at from_label. Use x labels "
            "exactly as they appear in the data; text max 5 words; unused fields as '' or 0. You ALWAYS follow the 2D visual with a 3D PROTOTYPE of the "
            "physical machine or object the data comes from (never a 3D chart, graph or bar model of the numbers): 'turbine' for wind turbines, "
            "otherwise 'generate' and name the exact object in 'subject', including the failing part (for abstract topics, pick the most concrete object)."),
        "model": "fast",
        "schema": S(
            mode={"type": "string", "enum": ["chart", "diagram"]},
            title=STR,
            chart=S(type={"type": "string", "enum": ["line", "bar"]}, y_label=STR, highlight_series=STR, annotation=STR),
            diagram=S(nodes=ARR(S(id=STR, label=STR, detail=STR)), edges=ARR(S(source=STR, target=STR, label=STR))),
            narration=ARR(STR),
            annotations=ARR(S(kind={"type": "string", "enum": ["band", "hline", "circle", "arrow", "label"]}, text=STR,
                              series=STR, from_label=STR, to_label=STR, value=NUM, line=INT)),
            visual_3d=S(asset={"type": "string", "enum": ["turbine", "generate"]}, subject=STR, why=STR)),
    },
    "teach": {
        "instructions": (
            "You are Bolt, a brilliant teacher drawing on a whiteboard (canvas 1000 x 560, origin top-left) while Pip "
            "speaks. Scout has found something on the user's screen. Teach the user WHY it happens, not just what the "
            "chart shows: draw the physical mechanism (e.g. a labelled cross-section of the failing part, how the fault "
            "creates the signal), write the key calculation with the real numbers from Scout's findings, connect "
            "related signals (cause -> effect arrows), and end with what it means and what to do. 4 or 5 beats; each beat "
            "has one spoken line (max 22 words) and 3 to 9 drawing items that build on earlier beats (keep earlier "
            "items' space free; plan the layout across the whole canvas, left-to-right / top-to-bottom). Items: "
            "line/arrow/polyline/curve use pts as a flat list [x1,y1,x2,y2,...] (curve: start, control, end); circle "
            "uses pts [cx,cy] and r; ellipse pts [cx,cy] with w,h as radii; rect pts [x,y] with w,h; text pts [x,y] "
            "(baseline-left) with text (max 7 words) and size 16-34. Colours: ink, red, blue, green, purple, orange. "
            "fill true only for small highlights. Make it clear, labelled and beautiful, like a great lecture sketch."),
        "schema": S(
            title=STR,
            beats=ARR(S(say=STR, items=ARR(S(
                kind={"type": "string", "enum": ["line", "arrow", "polyline", "curve", "circle", "ellipse", "rect", "text"]},
                pts=ARR(NUM), r=NUM, w=NUM, h=NUM, text=STR, size=NUM,
                color={"type": "string", "enum": ["ink", "red", "blue", "green", "purple", "orange"]}, fill={"type": "boolean"}))))),
    },
    "build3d": {
        "instructions": (
            "You are Bolt, building a 3D PROTOTYPE of a real physical object (never a chart, graph or data plot) from primitive shapes that will assemble itself on screen while Pip "
            "explains it. Units are metres-ish; keep the whole model within about 6 units, standing on y=0. Shapes and "
            "args: box [w,h,d]; cyl [radiusTop,radiusBottom,height] (axis is Y; rotate x=1.5708 to lie along Z, z=1.5708 "
            "along X); sphere [r]; cone [r,h]; torus [radius,tube] (ring in the XY plane). rot is radians [x,y,z]. Use "
            "10 to 22 parts, real recognisable structure, pleasant distinct colours (hex). Give important parts a short "
            "label (max 3 words), others label ''. group: 'shell' for outer covers that should fade when opened, "
            "'internal' for inner parts, 'none' otherwise; explode is the offset [x,y,z] used when the model opens "
            "(0,0,0 if it stays). 3 to 5 steps, each lists part ids and one short spoken line (max 16 words). If the "
            "context mentions a problem, set fault.part to the part where it happens, else fault.part ''."),
        "schema": S(
            title=STR,
            parts=ARR(S(id=STR, label=STR, shape={"type": "string", "enum": ["box", "cyl", "sphere", "cone", "torus"]},
                        args=ARR(NUM), pos=ARR(NUM), rot=ARR(NUM), color=STR,
                        group={"type": "string", "enum": ["shell", "internal", "none"]}, explode=ARR(NUM))),
            steps=ARR(S(parts=ARR(STR), say=STR, explode={"type": "boolean"})),
            fault=S(part=STR, label=STR)),
    },
    "chat": {
        "instructions": (
            "You are Pip, a friendly on-screen guide. The user just spoke while the team is working on their screen. "
            "Answer in at most 2 short spoken sentences, using what the team found. If the user asks for something to "
            "happen, set 'action': redraw_bar / redraw_line (change the chart type), explain_again (re-teach the lesson "
            "more simply), show_3d (build the 3D model now), approve, switch_role, pause, resume, back (replay the last "
            "10 seconds), forward, visualize (start reading the screen), or none. Put any extra detail the user asked "
            "for in 'focus' (e.g. which signal to explain), else ''."),
        "schema": S(answer=STR, action={"type": "string", "enum": ["none", "redraw_bar", "redraw_line", "explain_again", "show_3d",
                                                                  "approve", "switch_role", "pause", "resume", "back", "forward", "visualize"]},
                    focus=STR),
    },
    "pip": {
        "instructions": (
            "You are Pip, the guide. Turn the crew's results into a short, friendly explanation for the person on "
            "screen. 'lines' are 2 short spoken sentences (max 20 words each). 'report_summary' is a 3-sentence "
            "plain-English summary for the maintenance report. Use only facts in the input."),
        "schema": S(lines=ARR(STR), report_summary=STR),
    },
}


def call_model(role, context, image_path=None):
    spec = ROLES[role]
    content = [{"type": "input_text", "text": json.dumps({k: v for k, v in context.items() if not k.startswith("_")})}]
    if image_path:
        content.append({"type": "input_image", "image_url": "data:image/png;base64," + base64.b64encode(open(image_path, "rb").read()).decode()})
    body = {
        "model": FAST_MODEL if spec.get("model") == "fast" else MODEL, "instructions": spec["instructions"], "store": False,
        "reasoning": {"effort": "low"},
        "input": [{"role": "user", "content": content}],
        "text": {"format": {"type": "json_schema", "name": role, "strict": True, "schema": spec["schema"]}},
        "max_output_tokens": 6000,
    }
    req = urllib.request.Request("https://api.openai.com/v1/responses", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60, context=TLS) as r:
        result = json.load(r)
    for item in result.get("output", []):
        for part in item.get("content", []) or []:
            if part.get("type") == "output_text":
                return json.loads(part["text"])
    raise RuntimeError("no output_text in response")


# ---------------------------------------------------------------- rule-based fallback
def rules(role, c):
    """Deterministic answers computed from the same context, used only when the model and cache are unavailable."""
    if role == "scout":
        s = c["signals"]
        if "seal_last48h" in s:
            return {"headline": f"Seal chamber is at {s['seal_now']} degrees and flow is falling. It's the mechanical seal.",
                    "evidence": [{"id": "E1", "kind": "trend", "title": "Seal temperature rising", "detail": f"{s['seal_first10d']} to {s['seal_last48h']} °C", "source": "Pump telemetry: seal chamber temperature"},
                                 {"id": "E2", "kind": "trend", "title": "Vibration up, flow down", "detail": f"Vibration {s['vib_first10d']} to {s['vib_last48h']} mm/s; flow {s['flow_first10d']} to {s['flow_last48h']} m3/h", "source": "Pump telemetry"},
                                 {"id": "E3", "kind": "manual", "title": "Guide threshold met", "detail": "Seal above 50 °C and vibration above 4.5 mm/s indicates seal failure.", "source": "Maintenance guide §7.2"}],
                    "diagnosis": {"component": c.get("_fault_component", "Pump mechanical seal"), "failure_mode": "Seal face wear", "days_to_failure": 5, "confidence": 0.85, "reasoning": "Both guide thresholds are exceeded and flow is falling."},
                    "recommended_action": "Replace the mechanical seal on a night window with the standby pump running."}
        ratio = s["vib_ratio_to_fleet_last48h"]
        days = max(3, int(round(14 - 4 * (ratio - 2)))) if ratio > 2 else 30
        recs = [r for r in c["maintenance_history"] if "particle" in str(r).lower() or "HSS" in str(r)]
        ev = [
            {"id": "E1", "kind": "trend", "title": "Drive-train vibration rising",
             "detail": f"{s['vib_first10d']} to {s['vib_last48h']} {c['units']['vib']} over 30 days", "source": "SCADA: Drive train acceleration"},
            {"id": "E2", "kind": "fleet", "title": f"{ratio}x the fleet",
             "detail": f"Fleet median {s['fleet_vib_last48h']}; gear oil +{s['oil_delta']} °C vs fleet", "source": "SCADA: fleet comparison"},
        ]
        if recs:
            r = recs[-1]
            ev.append({"id": "E3", "kind": "record", "title": f"{r.get('WO')} history", "detail": str(r.get("Finding")), "source": f"plant_ops.xlsx / Maintenance / {r.get('WO')}"})
        ev.append({"id": "E4", "kind": "manual", "title": "Guide threshold met", "detail": "Vibration above 2x baseline with oil temperature rise above 5 °C indicates advanced bearing wear.", "source": "Maintenance guide §4.2"})
        comp = c.get("_fault_component", "the bearing")
        return {"headline": f"Vibration is {ratio} times the fleet and the oil is running hot. It's the {comp.lower()}.",
                "evidence": ev,
                "diagnosis": {"component": comp, "failure_mode": "Rolling-element wear", "days_to_failure": days,
                              "confidence": 0.8, "reasoning": "Vibration and oil temperature both exceed the guide thresholds and the earlier inspection noted rising wear indicators."},
                "recommended_action": "Replace the bearing in the lowest-wind window within 14 days."}
    if role == "bolt":
        parts, windows = c["parts_inventory"], c["candidate_windows"]
        pump = "pump" in c["diagnosis"]["component"].lower()
        part = next((p for p in parts if p.get("On hand", 0) and c["diagnosis"]["component"].split()[0].lower() in str(p).lower()), parts[0])
        w = min(windows, key=lambda x: x["energy_loss_inr"])
        techs = [t for t in c["technicians"] if ("HVAC" in t["Role"] if pump else t.get("Gearbox certified") == "Yes")][: 1 if pump else 2]
        hours = c.get("labour_hours", 6)
        labour = sum(int(t["Rate INR/h"]) * hours for t in techs)
        cons = c.get("consumables_inr", 0)
        total = int(part["Unit cost INR"]) + labour + cons
        return {"work_order": {"title": f"Replace {c['diagnosis']['component'].lower()}", "asset": c["asset"]["id"],
                               "component": c["diagnosis"]["component"], "priority": "P1", "part_sku": part["SKU"],
                               "part_name": part["Description"], "quantity": 1, "technicians": [t["Name"] for t in techs],
                               "window_start": w["start"], "window_end": w["end"], "labour_hours": hours,
                               "cost_breakdown": [{"item": part["Description"], "inr": int(part["Unit cost INR"])},
                                                  {"item": f"Labour {len(techs)} x {hours} h", "inr": labour},
                                                  {"item": "Seal kit, oil, filter", "inr": cons}],
                               "total_cost_inr": total, "energy_loss_inr": int(w["energy_loss_inr"]),
                               "justification": "Lowest-wind window with certified technicians available; part in stock."},
                "plan_steps": ["Reserve part", "Assign technicians", "Book low-wind window", "Request approval"],
                "needs_approval": True,
                "spoken": f"Booked the calmest window, {w['label']}. Total about {total:,} rupees. I just need a supervisor to approve."}
    if role == "see":
        cols, rows = c["table"]["columns"], c["table"]["rows"]
        if not rows:
            return {"headline": "I can see the sheet, but I couldn't read the table clearly.", "what_i_see": "", "chart": {"type": "line", "title": "", "y_label": "", "highlight_series": "", "annotation": ""},
                    "problem": {"series": "", "start_label": "", "end_label": "", "summary": "", "ratio_to_others": 1}, "highlight_ids": [], "narration": [],
                    "data": {"labels": [], "series": []}, "visual_3d": {"asset": "none", "why": ""}}
        last = rows[-5:]
        def avg(col, rs): vals = [r["cells"][col]["v"] for r in rs if col in r["cells"]]; return sum(vals) / max(1, len(vals))
        worst = max(cols, key=lambda k: avg(k, last) / max(1e-6, avg(k, rows[:10])))
        others = sorted(avg(k, last) for k in cols if k != worst)
        ratio = round(avg(worst, last) / max(1e-6, others[len(others) // 2]), 1)
        start = next((i for i, r in enumerate(rows) if worst in r["cells"] and r["cells"][worst]["v"] > 1.6 * (sum(avg(k, [r]) for k in cols if k != worst) / (len(cols) - 1))), len(rows) - 8)
        ids = [c["table"]["header_ids"][worst]] + [r["cells"][worst]["id"] for r in rows[start:] if worst in r["cells"]][-10:]
        return {"headline": f"{worst} is the odd one out. It's running about {ratio} times the others.",
                "what_i_see": f"A daily table for {', '.join(cols)}.",
                "chart": {"type": "line", "title": c.get("sheet_title") or "Daily values", "y_label": c.get("units", ""), "highlight_series": worst, "annotation": f"{worst} ×{ratio}"},
                "problem": {"series": worst, "start_label": rows[start]["label"], "end_label": rows[-1]["label"], "summary": f"{worst} climbs from {rows[start]['label']} while the others stay flat.", "ratio_to_others": ratio},
                "highlight_ids": ids,
                "narration": [f"Each line is one turbine, over the last {len(rows)} days.", f"Most of them move together with the wind.", f"But {worst} breaks away from {rows[start]['label']} and keeps climbing."],
                "data": {"labels": [], "series": []}, "visual_3d": {"asset": "turbine" if worst.startswith("T-") else "none", "why": "Turbine vibration data"}}
    if role == "chat":
        return {"answer": "I can see your screen. Ask me to visualize it and I'll draw it for you.", "wants_visual": True}
    if role == "pip":
        wo = c["bolt"]["work_order"]
        return {"lines": [f"We caught it about {c['scout']['diagnosis']['days_to_failure']} days early.",
                          f"Fixing it now costs {wo['total_cost_inr']:,} rupees instead of weeks offline."],
                "report_summary": f"{c['scout']['headline']} A work order was drafted for {wo['window_start']} and approved by a supervisor. Planned repair avoids an unplanned outage."}
    raise ValueError(role)


# ---------------------------------------------------------------- OCR table reconstruction
PII = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+|\+?\d[\d\s-]{9,}\d|\b(?:\d[ -]?){13,19}\b")
HEADER = re.compile(r"^[A-Z]{1,3}-?[0-9O]{1,3}$")
NUM = re.compile(r"^-?[0-9][0-9,]*\.?[0-9]*$")
DATE = re.compile(r"^\d{1,2} [A-Z][a-z]{2}$")


def fill_skipped_columns(image, items):
    """Vision OCR occasionally drops a whole narrow column. If the header row has a gap where a column should be,
    re-read just that vertical strip and merge what it finds."""
    heads = sorted((it for it in items if HEADER.match(it["t"].replace(" ", ""))), key=lambda it: it["x"])
    if len(heads) < 3:
        return items
    xs = [h["x"] + h["w"] / 2 for h in heads]
    gaps = [b - a for a, b in zip(xs, xs[1:])]
    step = sorted(gaps)[len(gaps) // 2]
    extra, fast = [], None
    for (a, b), g in zip(zip(heads, heads[1:]), gaps):
        if g > step * 1.6:
            x0, x1 = a["x"] + a["w"] + 4, b["x"] - 4
            y0 = max(0, min(h["y"] for h in heads) - 10)
            if fast is None:  # the "fast" recogniser reads columns the accurate one sometimes skips
                out = subprocess.run([OCR_BIN, image], capture_output=True, timeout=20, env={**os.environ, "OCR_FAST": "1"}).stdout
                try:
                    fast = json.loads(out)["items"]
                except Exception:
                    fast = []
            extra += [it for it in fast if x0 <= it["x"] + it["w"] / 2 <= x1 and it["y"] >= y0 - 2]
    return items + extra


def fill_sparse_columns(image, items, table):
    """If a rebuilt column is missing many cells, add the fast recogniser's boxes for that column (no duplicates)."""
    rows, cols = table["rows"], table["columns"]
    if len(rows) < 5:
        return 0
    sparse = [c for c in cols if sum(c in r["cells"] for r in rows) < len(rows)]
    hid = table.get("header_ids", {})
    if not sparse or not all(hid.get(c, -1) >= 0 for c in sparse):
        return 0
    out = subprocess.run([OCR_BIN, image], capture_output=True, timeout=20, env={**os.environ, "OCR_FAST": "1"}).stdout
    try:
        fast = json.loads(out)["items"]
    except Exception:
        return 0
    xs = sorted(items[hid[c]]["x"] + items[hid[c]]["w"] / 2 for c in cols if hid.get(c, -1) >= 0)
    step = min(b - a for a, b in zip(xs, xs[1:])) if len(xs) > 1 else 120
    cx = lambda it: it["x"] + it["w"] / 2
    added = 0
    for c in sparse:
        h = items[hid[c]]
        for it in fast:
            if abs(cx(it) - cx(h)) < step * 0.45 and it["y"] > h["y"] + h["h"] and NUM.match(it["t"].replace(",", "")):
                if not any(abs(cx(e) - cx(it)) < 12 and abs(e["y"] - it["y"]) < 10 for e in items):
                    items.append(it)
                    added += 1
    return added


def synthetic_headers(items):
    """No header row visible: make one column per x-cluster of numbers to the right of the date column."""
    dates = [it for it in items if DATE.match(it["t"])]
    if len(dates) < 3:
        return []
    top, right_of = min(d["y"] for d in dates), max(d["x"] + d["w"] for d in dates)
    xs = sorted(it["x"] + it["w"] / 2 for it in items if NUM.match(it["t"].replace(",", "")) and it["x"] > right_of and it["y"] >= top - 5)
    clusters = []
    for x in xs:
        if clusters and x - clusters[-1][-1] < 40:
            clusters[-1].append(x)
        else:
            clusters.append([x])
    clusters = [c for c in clusters if len(c) >= 3]
    h = max(d["h"] for d in dates)
    return [{"t": f"COL{k + 1}", "x": sum(c) / len(c) - 10, "w": 20, "y": top - 2 * h, "h": h, "id": -1 - k} for k, c in enumerate(clusters)]


def rebuild_table(items):
    """Group OCR boxes into a table: header tokens like T-04 define columns, date tokens define rows."""
    heads = [it for it in items if HEADER.match(it["t"].replace(" ", ""))]
    if len(heads) < 2:
        heads = synthetic_headers(items)
    if len(heads) < 2:
        return {"columns": [], "rows": [], "header_ids": {}}
    # keep the largest group of headers sharing a baseline
    heads.sort(key=lambda it: it["y"])
    groups = []
    for it in heads:
        if groups and abs(groups[-1][0]["y"] - it["y"]) < it["h"]:
            groups[-1].append(it)
        else:
            groups.append([it])
    heads = max(groups, key=len)
    cx = lambda it: it["x"] + it["w"] / 2
    cy = lambda it: it["y"] + it["h"] / 2
    heads.sort(key=cx)
    name = lambda it: it["t"].replace(" ", "").replace("O", "0").replace("T0", "T-0") if "-" not in it["t"] else it["t"].replace("O", "0")
    cols = [h["t"] if h["t"].startswith("COL") else name(h) for h in heads]
    spacing = min(cx(b) - cx(a) for a, b in zip(heads, heads[1:])) if len(heads) > 1 else 80
    header_y = max(h["y"] + h["h"] for h in heads)
    left, right = cx(heads[0]) - spacing * 2.2, cx(heads[-1]) + spacing * 0.7
    dates = sorted([it for it in items if DATE.match(it["t"]) and it["y"] > header_y and left <= cx(it) <= cx(heads[0])], key=cy)
    rows = [{"label": d["t"], "y": cy(d), "id": d["id"], "cells": {}} for d in dates]
    for it in items:
        t = it["t"].replace(",", "")
        if it["y"] <= header_y or not NUM.match(t) or not (left <= cx(it) <= right) or not rows:
            continue
        k = min(range(len(heads)), key=lambda j: abs(cx(heads[j]) - cx(it)))
        if abs(cx(heads[k]) - cx(it)) > spacing * 0.6:
            continue
        r = min(rows, key=lambda row: abs(row["y"] - cy(it)))
        if abs(r["y"] - cy(it)) > it["h"]:
            continue
        r["cells"][cols[k]] = {"v": float(t), "id": it["id"]}
    rows = [r for r in rows if len(r["cells"]) >= max(2, len(cols) // 2)]
    return {"columns": cols, "rows": rows, "header_ids": {c: h["id"] for c, h in zip(cols, heads)}}


# ---------------------------------------------------------------- HTTP
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=PUBLIC, **k)

    def log_message(self, fmt, *args):
        if "/api/" in str(args[0] if args else ""):
            sys.stderr.write("%s\n" % (fmt % args))

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def send_json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        if self.path == "/api/status":
            return self.send_json({"mode": MODE, "model": MODEL, "key": bool(KEY)})
        if self.path == "/api/audit":
            path = os.path.join(CACHE, "audit.jsonl")
            rows = [json.loads(l) for l in open(path)] if os.path.exists(path) else []
            return self.send_json(rows)
        return super().do_GET()

    def do_POST(self):
        try:
            if self.path == "/api/agent":
                return self.agent(self.body())
            if self.path == "/api/tts":
                return self.tts(self.body())
            if self.path == "/api/ocr":
                return self.ocr(self.body())
            if self.path == "/api/see":
                return self.see(self.body())
            if self.path == "/api/build3d":
                b = self.body()
                return self.run_role("build3d", {"subject": b["subject"], "context": b.get("context", "")}, "screen")
            if self.path == "/api/execute":
                return self.execute(self.body())
            if self.path == "/api/file":
                return self.open_file(self.body())
            if self.path == "/api/teach":
                b = self.body()
                return self.run_role("teach", {"scout": b["scout"], "question": b.get("utterance", "")}, "screen")
            if self.path == "/api/draw":
                return self.draw(self.body())
            if self.path == "/api/chat":
                return self.chat(self.body())
            if self.path == "/api/transcribe":
                return self.transcribe()
            if self.path == "/api/audit":
                with open(os.path.join(CACHE, "audit.jsonl"), "a") as f:
                    f.write(json.dumps(self.body()) + "\n")
                return self.send_json({"ok": True})
            if self.path == "/api/audit/reset":
                open(os.path.join(CACHE, "audit.jsonl"), "w").close()
                return self.send_json({"ok": True})
        except Exception as e:  # never leak the key in an error
            return self.send_json({"error": str(e).replace(KEY, "[redacted]") if KEY else str(e)}, 500)
        self.send_error(404)

    def agent(self, req):
        role, context, scenario = req["role"], req["context"], req.get("scenario", "turbine")
        cache_path = os.path.join(CACHE, f"agent-{scenario}-{role}.json")
        t0 = time.time()
        if MODE != "cached" and KEY:
            try:
                out = call_model(role, context)
                json.dump(out, open(cache_path, "w"), indent=1)
                return self.send_json({"output": out, "source": "live", "model": MODEL, "ms": int((time.time() - t0) * 1000)})
            except Exception as e:
                sys.stderr.write(f"[{role}] live call failed: {str(e)[:200]}\n")
                if MODE == "live":
                    raise
        if MODE == "live":
            raise RuntimeError("No OpenAI key. Put OPENAI_API_KEY in demo/.env")
        if os.path.exists(cache_path):
            return self.send_json({"output": json.load(open(cache_path)), "source": "cache", "model": MODEL, "ms": 0})
        return self.send_json({"output": rules(role, context), "source": "rules", "model": "rules", "ms": 0})

    # ------------------------------------------------ screen understanding
    def ocr(self, req):
        """Save the screenshot, run Apple Vision OCR and rebuild the visible table. Returns a shot id for /api/see."""
        shot = uuid.uuid4().hex[:10]
        raw = os.path.join(CACHE, "shots", shot + ".png")
        os.makedirs(os.path.dirname(raw), exist_ok=True)
        open(raw, "wb").write(base64.b64decode(req["image"].split(",")[-1]))
        t0 = time.time()
        ocr = json.loads(subprocess.run([OCR_BIN, raw], capture_output=True, timeout=30).stdout or b'{"items":[]}')
        ocr["items"] = fill_skipped_columns(raw, ocr["items"])
        for i, it in enumerate(ocr["items"]):
            it["id"] = i
        # Gate (rules, not AI): redact personal data before anything reaches a model.
        redacted = 0
        for it in ocr["items"]:
            clean = PII.sub("[redacted]", it["t"])
            if clean != it["t"]:
                it["t"], redacted = clean, redacted + 1
        table = rebuild_table(ocr["items"])
        added = fill_sparse_columns(raw, ocr["items"], table)
        if added:
            for i, it in enumerate(ocr["items"]):
                it["id"] = i
            table = rebuild_table(ocr["items"])
        if table["rows"] and len(table["rows"]) < 5:
            table = {"columns": [], "rows": [], "header_ids": {}}
        small = os.path.join(CACHE, "shots", shot + "-small.png")
        subprocess.run(["sips", "-Z", "1600", raw, "--out", small], capture_output=True)
        json.dump({"redacted": redacted}, open(os.path.join(CACHE, "shots", shot + ".json"), "w"))
        return self.send_json({"shot": shot, "width": ocr.get("width"), "height": ocr.get("height"), "items": ocr["items"], "redacted": redacted,
                               "table": table, "ms": int((time.time() - t0) * 1000)})

    def see(self, req):
        shot = re.sub(r"[^0-9a-f]", "", req["shot"])
        image = os.path.join(CACHE, "shots", shot + "-small.png")
        meta = os.path.join(CACHE, "shots", shot + ".json")
        if os.path.exists(meta) and json.load(open(meta)).get("redacted"):
            image = None  # Gate found personal data: the model only gets the redacted OCR text
        context = {"user_request": req.get("utterance", "Can you visualize it?"), "table": req["table"],
                   "sheet_title": req["table"].get("title", ""), "units": req.get("units", ""),
                   "ocr_text": [it_t for it_t in req.get("ocr_text", [])][:200],
                   "opened_file": req.get("file", {})}
        return self.run_role("see", context, "screen", image)

    def draw(self, req):
        context = {"scout": req["scout"], "table_columns": req.get("columns", []), "rows": req.get("rows", 0),
                   "assets_available": ["turbine (hand-built wind turbine drivetrain)", "generate (Bolt builds any other object live)"]}
        return self.run_role("draw", context, "screen")

    def chat(self, req):
        shot = re.sub(r"[^0-9a-f]", "", req.get("shot", ""))
        image = os.path.join(CACHE, "shots", shot + "-small.png") if shot else None
        return self.run_role("chat", {"question": req["utterance"], "what_the_team_found": req.get("context", {})}, "screen",
                             image if image and os.path.exists(image) else None)

    def run_role(self, role, context, scenario, image=None):
        cache_path = os.path.join(CACHE, f"agent-{scenario}-{role}.json")
        t0 = time.time()
        if MODE != "cached" and KEY:
            try:
                out = call_model(role, context, image)
                json.dump(out, open(cache_path, "w"), indent=1)
                return self.send_json({"output": out, "source": "live", "model": MODEL, "ms": int((time.time() - t0) * 1000)})
            except Exception as e:
                sys.stderr.write(f"[{role}] live call failed: {str(e)[:300]}\n")
                if MODE == "live":
                    raise
        if MODE == "live":
            raise RuntimeError("No OpenAI key. Put OPENAI_API_KEY in demo/.env")
        if role != "see" and os.path.exists(cache_path):
            return self.send_json({"output": json.load(open(cache_path)), "source": "cache", "model": MODEL, "ms": 0})
        return self.send_json({"output": rules(role, context), "source": "rules", "model": "rules", "ms": 0})

    def execute(self, req):
        """Carry out an approved work order: write it into plant_ops.xlsx and reserve the part.
        Refuses unless the audit log holds an APPROVED entry with the given hash (Gate is enforced here too)."""
        audit_path = os.path.join(CACHE, "audit.jsonl")
        entries = [json.loads(l) for l in open(audit_path)] if os.path.exists(audit_path) else []
        ok = next((e for e in entries if e.get("hash") == req.get("approval") and e.get("action") == "APPROVED"), None)
        if not ok:
            return self.send_json({"done": False, "reason": "No matching approval in the audit log"}, 403)
        wo = req["work_order"]
        from openpyxl import load_workbook
        book = os.path.join(PUBLIC, "data", "plant_ops.xlsx")
        wb = load_workbook(book)
        ms, ps = wb["Maintenance"], wb["Parts"]
        wo_id = req.get("id", "WO-2491")
        if not any(r[0].value == wo_id for r in ms.iter_rows(min_row=2)):
            ms.append([wo_id, wo["window_start"][:10], wo["asset"], wo["component"], "Corrective · scheduled",
                       f"{wo['title']} · {wo['window_start'].replace('T', ' ')}-{wo['window_end'][11:16]} · approved by {ok.get('role')}",
                       ", ".join(wo["technicians"]), wo["labour_hours"], wo["total_cost_inr"]])
            for r in ps.iter_rows(min_row=2):
                if r[0].value == wo["part_sku"] and isinstance(r[3].value, int) and r[3].value > 0:
                    r[3].value -= wo.get("quantity", 1)
        wb.save(book)
        # read back what is now in the file, as the receipt
        wb = load_workbook(book, read_only=True)
        row = next(r for r in wb["Maintenance"].iter_rows(values_only=True) if r[0] == wo_id)
        part = next((r for r in wb["Parts"].iter_rows(values_only=True) if r[0] == wo["part_sku"]), None)
        return self.send_json({"done": True, "file": "data/plant_ops.xlsx", "row": [str(v) for v in row],
                               "part_on_hand": part[3] if part else None, "approval": ok["hash"][:16]})

    def open_file(self, req):
        """Gate-approved, read-only open of a spreadsheet the user has on screen, from a few allowed folders."""
        name = os.path.basename(req.get("name", "")).strip()
        if not re.fullmatch(r"[\w\- .()]+\.(xlsx|csv)", name, re.I):
            return self.send_json({"found": False, "reason": "not a spreadsheet name"})
        home = os.path.expanduser("~")
        roots = [HERE, os.path.join(home, "Desktop"), os.path.join(home, "Downloads"), os.path.join(home, "Documents")]
        path = None
        for root in roots:
            for dirpath, dirnames, files in os.walk(root):
                dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in ("node_modules", "cache")]
                if dirpath.count(os.sep) - root.count(os.sep) > 3:
                    dirnames[:] = []
                if name in files:
                    path = os.path.join(dirpath, name)
                    break
            if path:
                break
        if not path:
            return self.send_json({"found": False, "reason": "not in allowed folders"})
        from openpyxl import load_workbook  # only needed here
        wb = load_workbook(path, read_only=True, data_only=True)
        sheets = {}
        for ws in wb.worksheets:
            rows = [r for r in ws.iter_rows(values_only=True) if any(v is not None for v in r)]
            if not rows:
                continue
            cols = [str(c) for c in rows[0][1:]]
            sheets[ws.title] = {"columns": cols, "rows": [{"label": str(r[0]), "cells": {c: {"v": r[i + 1]} for i, c in enumerate(cols) if isinstance(r[i + 1], (int, float))}} for r in rows[1:]]}
        rel = path.replace(home, "~")
        return self.send_json({"found": True, "path": rel, "sheets": sheets,
                               "rows": sum(len(v["rows"]) for v in sheets.values())})

    def transcribe(self):
        n = int(self.headers.get("Content-Length", 0))
        audio = self.rfile.read(n)
        if not KEY:
            return self.send_json({"text": "Can you visualize it?", "source": "no key"})
        boundary = uuid.uuid4().hex
        parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{STT_MODEL}\r\n'.encode(),
                 f'--{boundary}\r\nContent-Disposition: form-data; name="language"\r\n\r\nen\r\n'.encode(),
                 f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="speech.webm"\r\nContent-Type: audio/webm\r\n\r\n'.encode(),
                 audio, f"\r\n--{boundary}--\r\n".encode()]
        r = urllib.request.Request("https://api.openai.com/v1/audio/transcriptions", data=b"".join(parts),
                                   headers={"Authorization": f"Bearer {KEY}", "Content-Type": f"multipart/form-data; boundary={boundary}"})
        with urllib.request.urlopen(r, timeout=40, context=TLS) as resp:
            return self.send_json({"text": json.load(resp).get("text", ""), "source": "live"})

    def tts(self, req):
        who, text = req.get("who", "pip"), req["text"][:600]
        voice, style = VOICES.get(who, VOICES["pip"])
        name = hashlib.sha1(f"{who}|{text}".encode()).hexdigest()[:16] + ".mp3"
        path = os.path.join(CACHE, "tts", name)
        if not os.path.exists(path):
            if MODE == "cached" or not KEY:
                return self.send_json({"error": "not cached"}, 404)
            body = {"model": TTS_MODEL, "voice": voice, "input": text, "instructions": style, "response_format": "mp3"}
            r = urllib.request.Request("https://api.openai.com/v1/audio/speech", data=json.dumps(body).encode(),
                                       headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
            with urllib.request.urlopen(r, timeout=40, context=TLS) as resp:
                audio = resp.read()
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "wb").write(audio)
        data = open(path, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--mode", choices=["auto", "live", "cached"], default=os.environ.get("SIDEKICK_MODE", "live"))
    a = ap.parse_args()
    MODE = a.mode
    os.makedirs(os.path.join(CACHE, "tts"), exist_ok=True)
    print(f"Sidekick demo on http://localhost:{a.port}  mode={MODE} model={MODEL} key={'yes' if KEY else 'no'}")
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
