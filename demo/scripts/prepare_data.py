"""Build the demo data set.

Usage: python3 -I demo/scripts/prepare_data.py /path/to/extracted/kelmarsh

Reads the six Kelmarsh turbine CSVs (Zenodo record 5841834, CC BY 4.0), keeps
November 2016 at hourly resolution, injects a gearbox high-speed-shaft bearing
fault into turbine 4 and writes:
  public/data/fleet.json      real SCADA (plus the labelled injected fault)
  public/data/plant_ops.xlsx  maintenance log, parts, technicians, approval policy (synthetic)
  public/data/chiller.json    synthetic telemetry for the asset-swap scene
"""
import csv, glob, json, math, os, random, sys
from datetime import date, timedelta

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "public", "data")
SRC = sys.argv[1]
START, END = "2016-11-01", "2016-12-01"
COLS = {
    "wind": "Wind speed (m/s)",
    "power": "Power (kW)",
    "oil": "Gear oil temperature (°C)",
    "genb": "Generator bearing front temperature (°C)",
    "vib": "Drive train acceleration (mm/ss)",
    "rpm": "Gearbox speed (RPM)",
    "amb": "Nacelle ambient temperature (°C)",
}
FAULT_TURBINE, FAULT_DAYS = 4, 12
random.seed(7)


def read_turbine(n, start=START, end=END, src=None):
    path = glob.glob(os.path.join(src or SRC, f"Turbine_Data_Kelmarsh_{n}_*.csv"))[0]
    with open(path, encoding="utf-8") as f:
        header = None
        for line in f:
            if line.startswith("# Date and time"):
                header = next(csv.reader([line[2:]]))
                break
        idx = {k: header.index(v) for k, v in COLS.items()}
        hours = {}
        for row in csv.reader(f):
            ts = row[0]
            if not (start <= ts < end):
                continue
            h = ts[:13]
            bucket = hours.setdefault(h, {k: [] for k in COLS})
            for k, i in idx.items():
                if row[i] != "NaN":
                    bucket[k].append(float(row[i]))
    keys = sorted(hours)
    series = {k: [] for k in COLS}
    last = {k: 0.0 for k in COLS}
    for h in keys:
        for k in COLS:
            vals = hours[h][k]
            v = sum(vals) / len(vals) if vals else last[k]  # carry forward short gaps
            last[k] = v
            series[k].append(round(v, 2))
    return keys, series


def inject_fault(series):
    """Ramp drive-train vibration to ~3x and gear oil temperature by ~+7 °C over the last 12 days."""
    n = len(series["vib"])
    start = n - FAULT_DAYS * 24
    for i in range(start, n):
        p = (i - start) / (n - start)
        load = min(1.0, series["power"][i] / 2050) if series["power"][i] > 0 else 0.0
        series["vib"][i] = round(series["vib"][i] * (1 + 2.1 * p ** 1.6) + 4 * p * load + random.uniform(-0.3, 0.3), 2)
        series["oil"][i] = round(series["oil"][i] + 7.2 * p ** 1.3 * (0.6 + 0.4 * load), 2)
    return {"turbine": f"T-0{FAULT_TURBINE}", "signals": ["vib", "oil"], "from_hour": start,
            "note": "Synthetic gearbox high-speed-shaft bearing fault injected into real SCADA for the demo."}


def build_fleet():
    static = list(csv.DictReader(open(os.path.join(SRC, "static.csv"), encoding="utf-8-sig")))
    turbines, fault = [], None
    for n in range(1, 7):
        keys, s = read_turbine(n)
        if n == FAULT_TURBINE:
            fault = inject_fault(s)
        st = static[n - 1]
        turbines.append({"id": f"T-0{n}", "rated_kw": int(st["Rated power (kW)"]), "hub_m": float(st["Hub Height (m)"]),
                         "rotor_m": float(st["Rotor Diameter (m)"]), "model": f'{st["Manufacturer"]} {st["Model"]}', "series": s})
        print(f"T-0{n}: {len(keys)} hours")
    lat = sum(float(r["Latitude"]) for r in static) / 6
    lon = sum(float(r["Longitude"]) for r in static) / 6
    fleet = {
        "site": {"name": "Northwind Ridge", "lat": round(lat, 4), "lon": round(lon, 4), "tariff_inr_kwh": 4.0},
        "source": {"dataset": "Kelmarsh wind farm SCADA, Nov 2016 (Plumley, Zenodo 5841834, CC BY 4.0)",
                   "url": "https://zenodo.org/records/5841834", "resolution": "hourly means of 10-minute data",
                   "replay": "Timestamps are shifted so the 30-day window ends now."},
        "fault": fault, "units": {k: v[v.rfind("(") + 1:-1] for k, v in COLS.items()}, "turbines": turbines,
    }
    json.dump(fleet, open(os.path.join(OUT, "fleet.json"), "w"), separators=(",", ":"))


def sheet(wb, title, header, rows):
    ws = wb.create_sheet(title)
    ws.append(header)
    for c in ws[1]:
        c.font = Font(bold=True, color="FFFFFF")
        c.fill = PatternFill("solid", fgColor="1F2A36")
    for r in rows:
        ws.append(r)
    for col in ws.columns:
        ws.column_dimensions[col[0].column_letter].width = max(12, min(60, max(len(str(c.value or "")) for c in col) + 2))


def build_workbook():
    today = date(2026, 10, 24)
    d = lambda days: (today - timedelta(days=days)).isoformat()
    wb = Workbook()
    wb.remove(wb.active)
    sheet(wb, "Maintenance", ["WO", "Date", "Turbine", "Component", "Type", "Finding", "Technician", "Hours", "Cost INR"], [
        ["WO-2291", d(412), "T-04", "Gearbox", "Inspection", "Oil sample normal, particle count 4", "A. Rao", 3, 9500],
        ["WO-2318", d(355), "T-02", "Pitch system", "Corrective", "Blade B pitch motor replaced", "S. Iyer", 7, 142000],
        ["WO-2344", d(301), "T-04", "Gearbox", "Preventive", "Oil change, filters replaced", "A. Rao", 5, 61000],
        ["WO-2360", d(266), "T-06", "Yaw", "Preventive", "Yaw brake pads replaced", "M. Khan", 6, 48000],
        ["WO-2387", d(214), "T-01", "Generator", "Inspection", "Bearing grease top-up", "S. Iyer", 2, 6500],
        ["WO-2402", d(187), "T-04", "Gearbox", "Inspection", "HSS bearing: slight noise noted on run-up, no action", "M. Khan", 2, 7000],
        ["WO-2415", d(150), "T-03", "Converter", "Corrective", "IGBT module fault, module swapped", "R. Das", 9, 210000],
        ["WO-2433", d(118), "T-05", "Gearbox", "Preventive", "Oil change, endoscope OK", "A. Rao", 5, 61000],
        ["WO-2451", d(77), "T-04", "Gearbox", "Inspection", "Oil sample: particle count 11 (up from 4). Re-sample in 90 days", "R. Das", 2, 9500],
        ["WO-2466", d(41), "T-02", "Blades", "Inspection", "Leading edge erosion, minor", "S. Iyer", 4, 22000],
        ["WO-2478", d(12), "T-06", "Hydraulics", "Corrective", "Accumulator recharged", "M. Khan", 3, 18000],
    ])
    sheet(wb, "Parts", ["SKU", "Description", "Fits", "On hand", "Location", "Unit cost INR", "Lead time days"], [
        ["BRG-HSS-NU2326", "Gearbox high-speed shaft bearing, cylindrical roller", "MM92 gearbox", 2, "Site store, bay 3", 68000, 21],
        ["BRG-IMS-32248", "Gearbox intermediate shaft bearing, tapered roller", "MM92 gearbox", 1, "Central depot", 94000, 35],
        ["SEAL-HSS-KIT", "HSS seal and O-ring kit", "MM92 gearbox", 6, "Site store, bay 3", 5400, 7],
        ["OIL-GB-320", "Gear oil ISO VG 320, 20 L", "MM92 gearbox", 14, "Site store, bay 1", 3300, 5],
        ["FLT-GB-OFF", "Offline oil filter element", "MM92 gearbox", 9, "Site store, bay 1", 2800, 5],
        ["GEN-BRG-6330", "Generator drive-end bearing", "MM92 generator", 1, "Central depot", 52000, 28],
        ["BRG-MAIN-240", "Main shaft bearing, spherical roller", "MM92 drivetrain", 0, "OEM", 1450000, 120],
        ["SEAL-CHP-45", "Mechanical seal kit, chilled-water pump", "CH-2 pump", 3, "Hospital plant room store", 18500, 10],
    ])
    sheet(wb, "Technicians", ["Name", "Role", "Gearbox certified", "Climb certified", "Available", "Rate INR/h"], [
        ["A. Rao", "Senior technician", "Yes", "Yes", "Mon-Fri", 1800],
        ["R. Das", "Technician", "Yes", "Yes", "Tue-Sat", 1500],
        ["M. Khan", "Technician", "No", "Yes", "Mon-Fri", 1400],
        ["S. Iyer", "Technician", "Yes", "Yes", "Wed-Sun", 1500],
        ["P. Nair", "HVAC technician", "No", "No", "Mon-Sun", 1300],
    ])
    sheet(wb, "Approval policy", ["Role", "Can approve work orders", "Limit INR", "Notes"], [
        ["Operator", "No", 50000, "Can raise and draft work orders; escalates above limit"],
        ["Maintenance supervisor", "Yes", 500000, "Requires biometric confirmation"],
        ["Site manager", "Yes", 5000000, "Required for crane mobilisation"],
    ])
    sheet(wb, "README", ["Note"], [["Synthetic operations records for the Sidekick AgentOps'26 demo. Not real company data."]])
    wb.save(os.path.join(OUT, "plant_ops.xlsx"))


def build_chiller():
    n, rows = 720, {"flow": [], "vib": [], "seal": []}
    for i in range(n):
        p = max(0.0, (i - (n - 240)) / 240)
        rows["flow"].append(round(118 + 6 * math.sin(i / 12) - 9 * p + random.uniform(-1, 1), 1))
        rows["vib"].append(round(2.1 + 0.2 * math.sin(i / 7) + 2.4 * p ** 1.5 + random.uniform(-0.1, 0.1), 2))
        rows["seal"].append(round(41 + 2 * math.sin(i / 24) + 11 * p ** 1.4 + random.uniform(-0.4, 0.4), 1))
    json.dump({"asset": "CH-2 chilled water pump, City Hospital plant room", "synthetic": True,
               "units": {"flow": "m3/h", "vib": "mm/s", "seal": "degC"}, "series": rows},
              open(os.path.join(OUT, "chiller.json"), "w"), separators=(",", ":"))


def build_screen_sheet():
    """The workbook a person has open on screen: daily means per turbine, last 30 days, dates ending today."""
    fleet = json.load(open(os.path.join(OUT, "fleet.json")))
    today = date(2026, 10, 24)
    wb = Workbook()
    wb.remove(wb.active)
    for title, key, digits in [("Drive-train vibration", "vib", 0), ("Gear oil temp", "oil", 1)]:
        ws = wb.create_sheet(title)
        ws.append(["Date"] + [t["id"] for t in fleet["turbines"]])
        for c in ws[1]:
            c.font = Font(bold=True)
        for d in range(30):
            day = today - timedelta(days=29 - d)
            vals = [round(sum(t["series"][key][d * 24:(d + 1) * 24]) / 24, digits) for t in fleet["turbines"]]
            ws.append([day.strftime("%d %b")] + [int(v) if digits == 0 else v for v in vals])
        for row in ws.iter_rows():
            for c in row:
                c.font = Font(name="Arial", size=10, bold=c.row == 1)
        ws.freeze_panes = "B2"
        ws.sheet_view.zoomScale = 90
        ws.column_dimensions["A"].width = 10
        for col in "BCDEFG":
            ws.column_dimensions[col].width = 9
    wb.save(os.path.join(ROOT, "Northwind_Ridge_daily_SCADA.xlsx"))


def build_sheet_page_data():
    """A full year of real daily SCADA for the on-screen sheet (Kelmarsh 2017 when available), T-04 fault in the last 12 days."""
    year_dir = os.path.join(SRC, "y2017")
    full = os.path.isdir(year_dir) and glob.glob(os.path.join(year_dir, "Turbine_Data_*"))
    start, end, days = ("2017-01-01", "2018-01-01", 365) if full else ("2016-10-01", "2016-12-01", 61)
    cols = {}
    for n in range(1, 7):
        keys, s = read_turbine(n, start, end, year_dir if full else None)
        days = min(days, len(keys) // 24)
        daily = {k: [sum(s[k][d * 24:(d + 1) * 24]) / 24 for d in range(days)] for k in ("vib", "oil", "power")}
        if n == FAULT_TURBINE:
            for d in range(days - 12, days):
                p = (d - (days - 12)) / 11
                daily["vib"][d] = daily["vib"][d] * (1 + 2.1 * p ** 1.6)
                daily["oil"][d] = daily["oil"][d] + 7.2 * p ** 1.3
        cols[f"T-0{n}"] = daily
    today = date(2026, 10, 24)
    labels = [(today - timedelta(days=days - 1 - d)).strftime("%d %b") for d in range(days)]
    out = {"labels": labels, "turbines": list(cols),
           "vib": {t: [round(v) for v in cols[t]["vib"]] for t in cols},
           "oil": {t: [round(v, 1) for v in cols[t]["oil"]] for t in cols},
           "power": {t: [round(v) for v in cols[t]["power"]] for t in cols},
           "source": f"Kelmarsh wind farm SCADA {start[:4]} (Zenodo 5841834, CC BY 4.0), {days} daily means; T-04 fault injected; dates shifted to end today."}
    json.dump(out, open(os.path.join(OUT, "sheet_daily.json"), "w"), separators=(",", ":"))
    # The same year as a real workbook, named like the file shown on screen.
    wb = Workbook()
    wb.remove(wb.active)
    for title, key in [("Drive-train vibration", "vib"), ("Gear oil temp", "oil"), ("Power", "power")]:
        ws = wb.create_sheet(title)
        ws.append(["Date"] + out["turbines"])
        for i, lb in enumerate(labels):
            ws.append([lb] + [out[key][t][i] for t in out["turbines"]])
        for row in ws.iter_rows():
            for c in row:
                c.font = Font(name="Arial", size=10, bold=c.row == 1)
        ws.freeze_panes = "B2"
    wb.save(os.path.join(ROOT, "Northwind_Ridge_SCADA_daily.xlsx"))


CASES = {
    # key: (file name, domain, unit ids, [(sheet, key, unit, base, noise, fault_add, decimals)], faulty unit, fault days, synthetic note)
    "cnc": ("Line3_CNC_spindles_daily.xlsx", "Manufacturing · machining line 3", [f"M-0{i}" for i in range(1, 7)],
            [("Spindle vibration (mm/s)", "vib", 2.1, 0.35, 5.2, 2), ("Spindle temp (°C)", "temp", 38, 1.6, 11, 1), ("Load (%)", "load", 64, 7, 0, 0)], "M-05", 16),
    "transformer": ("Substation_TX_DGA_daily.xlsx", "Energy · 132 kV substation", [f"TX-0{i}" for i in range(1, 7)],
            [("Hydrogen H2 (ppm)", "h2", 42, 6, 260, 0), ("Top-oil temp (°C)", "oil", 58, 3, 9, 1), ("Load (MVA)", "load", 31, 5, 0, 0)], "TX-03", 20),
    "pump": ("Pump_station_daily.xlsx", "Utilities · raw-water pump station", [f"P-0{i}" for i in range(1, 7)],
            [("Discharge pressure (bar)", "pres", 6.2, 0.18, -1.6, 2), ("Motor current (A)", "amp", 118, 4, 19, 0), ("Pump vibration (mm/s)", "vib", 2.4, 0.3, 4.1, 2)], "P-02", 14),
}


def build_cases():
    """Synthetic but realistic engineering datasets (365 days) for testing beyond the turbine. Clearly labelled synthetic."""
    for key, (fname, domain, units, sheets, bad, fdays) in CASES.items():
        rnd = random.Random(sum(map(ord, key)))
        today, days = date(2026, 10, 24), 365
        labels = [(today - timedelta(days=days - 1 - d)).strftime("%d %b") for d in range(days)]
        out = {"labels": labels, "turbines": units, "file": fname, "domain": domain, "tabs": [],
               "source": f"Synthetic test data for {domain} (not real plant data); {bad} develops a fault in the last {fdays} days."}
        wb = Workbook(); wb.remove(wb.active)
        season = [math.sin(2 * math.pi * d / 365) for d in range(days)]
        weekly = [1 if (today - timedelta(days=days - 1 - d)).weekday() < 5 else 0.7 for d in range(days)]
        for title, k, base, noise, add, dec in sheets:
            out["tabs"].append({"k": k, "title": title})
            out[k] = {}
            for u in units:
                off = rnd.uniform(-0.06, 0.06) * base
                vals = []
                for d in range(days):
                    v = base + off + noise * rnd.gauss(0, 1) + 0.04 * base * season[d]
                    if k in ("load", "amp"):
                        v *= weekly[d]
                    if u == bad and d >= days - fdays:
                        p = (d - (days - fdays)) / (fdays - 1)
                        v += add * p ** 1.5
                    vals.append(round(v, dec) if dec else round(v))
                out[k][u] = vals
            ws = wb.create_sheet(title.split(" (")[0][:31])
            ws.append(["Date"] + units)
            for i, lb in enumerate(labels):
                ws.append([lb] + [out[k][u][i] for u in units])
            for row in ws.iter_rows():
                for c in row:
                    c.font = Font(name="Arial", size=10, bold=c.row == 1)
        wb.save(os.path.join(ROOT, fname))
        json.dump(out, open(os.path.join(OUT, f"sheet_{key}.json"), "w"), separators=(",", ":"))


def extend_ops_records():
    """Parts and people for the other engineering cases, so Bolt can draft real work orders for them."""
    from openpyxl import load_workbook
    path = os.path.join(OUT, "plant_ops.xlsx")
    wb = load_workbook(path)
    ps, ts = wb["Parts"], wb["Technicians"]
    for row in [["SPN-BRG-7014", "Spindle bearing set, angular contact (M-series CNC)", "CNC spindle", 3, "Line 3 crib", 46000, 14],
                ["SPN-BAL-SVC", "Spindle balancing and alignment service kit", "CNC spindle", 5, "Line 3 crib", 6500, 3],
                ["TX-DGA-SVC", "Transformer oil sampling, DGA and partial-discharge survey", "132 kV transformer", 4, "Substation store", 38000, 2],
                ["TX-OIL-FLT", "Online oil filtration / degassing hire (5 days)", "132 kV transformer", 1, "Contractor", 165000, 7],
                ["PMP-IMP-250", "Pump impeller, 250 mm, duplex steel", "Raw-water pump", 2, "Pump station store", 72000, 21],
                ["PMP-SUC-STR", "Suction strainer clean and inspection kit", "Raw-water pump", 6, "Pump station store", 4200, 2]]:
        ps.append(row)
    for row in [["K. Mehta", "CNC maintenance technician", "No", "No", "Mon-Sat", 1400],
                ["V. Nair", "HV electrician (authorised person)", "No", "No", "Mon-Fri", 2100],
                ["J. Thomas", "Mechanical fitter, pumps", "No", "No", "Mon-Sun", 1350]]:
        ts.append(row)
    wb.save(path)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build_fleet()
    build_workbook()
    build_chiller()
    build_screen_sheet()
    build_sheet_page_data()
    build_cases()
    extend_ops_records()
    print("wrote", sorted(os.listdir(OUT)))
