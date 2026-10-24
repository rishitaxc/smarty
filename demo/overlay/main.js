// Sidekick overlay: a transparent, click-through window over the whole screen that hangs from the notch.
// Run the demo server first (python3 -I demo/server.py), then: cd demo/overlay && npx electron .
const { app, BrowserWindow, globalShortcut, ipcMain, screen, desktopCapturer, systemPreferences, session, dialog } = require("electron");
const path = require("path");

const URL = process.env.SIDEKICK_URL || "http://localhost:8787/overlay.html";
let win;
// The overlay speaks without ever being clicked, so allow audio without a user gesture.
app.commandLine.appendSwitch("autoplay-policy", "no-user-gesture-required");

function create() {
  const d = screen.getPrimaryDisplay();
  win = new BrowserWindow({
    x: d.bounds.x, y: d.bounds.y, width: d.bounds.width, height: d.bounds.height,
    transparent: true, frame: false, hasShadow: false, resizable: false, movable: false,
    fullscreenable: false, skipTaskbar: true, enableLargerThanScreen: true, type: "panel",
    backgroundColor: "#00000000",
    webPreferences: { preload: path.join(__dirname, "preload.js"), backgroundThrottling: false },
  });
  win.setAlwaysOnTop(true, "screen-saver");
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  // Keep the overlay out of its own screenshots (set SIDEKICK_DEBUG=1 to see it in screen captures).
  if (!process.env.SIDEKICK_DEBUG) win.setContentProtection(true);
  win.webContents.on("console-message", (_e, level, msg, line, src) => console.log(`[page ${level}] ${msg} (${src}:${line})`));
  win.webContents.on("did-fail-load", (_e, code, desc) => console.log("load failed", code, desc));
  win.setIgnoreMouseEvents(true, { forward: true });
  win.loadURL(URL + `?top=${d.workArea.y - d.bounds.y}&scale=${d.scaleFactor}${process.env.SIDEKICK_DEBUG ? "&debug=1" : ""}`);
  win.showInactive();
  // macOS sometimes nudges a screen-sized panel when other apps activate; keep it pinned to the display.
  setInterval(() => {
    const want = screen.getPrimaryDisplay().bounds, got = win.getBounds();
    if (got.x !== want.x || got.y !== want.y || got.width !== want.width || got.height !== want.height) { console.log("re-pin", JSON.stringify(got)); win.setBounds(want); }
  }, 500);
}

app.whenReady().then(async () => {
  if (process.platform === "darwin") {
    app.dock?.hide();
    await systemPreferences.askForMediaAccess("microphone").catch(() => false);
  }
  session.defaultSession.setPermissionRequestHandler((_wc, perm, cb) => cb(["media", "microphone"].includes(perm)));
  create();
  const keys = { Space: "talk", V: "visualize", N: "next", S: "role", A: "audit", L: "swap", H: "hide", 0: "reset", Left: "back", Right: "forward", P: "pause" };
  for (const [k, action] of Object.entries(keys)) globalShortcut.register(`CommandOrControl+Shift+${k}`, () => win.webContents.send("shortcut", action));
  globalShortcut.register("CommandOrControl+Shift+Q", () => app.quit());
  // Local trigger for rehearsals: curl "localhost:8788/visualize" (localhost only).
  require("http").createServer((req, res) => {
    const action = (req.url || "/").slice(1).split("?")[0];
    if (Object.values(keys).includes(action)) win.webContents.send("shortcut", action);
    res.end(action === "bounds" ? JSON.stringify({ win: win.getBounds(), display: screen.getPrimaryDisplay().bounds, work: screen.getPrimaryDisplay().workArea }) : "ok " + action + "\n");
  }).listen(8788, "127.0.0.1");
});
app.on("will-quit", () => globalShortcut.unregisterAll());

ipcMain.handle("interactive", (_e, on) => win.setIgnoreMouseEvents(!on, { forward: true }));
// Fade instead of hide/show: re-showing a screen-sized panel lets macOS nudge it under the menu bar.
ipcMain.handle("show", (_e, on) => { win.setOpacity(on ? 1 : 0); win.setBounds(screen.getPrimaryDisplay().bounds); });

// Scroll the app under the overlay (needs Accessibility permission for System Events the first time).
const KEYS = { pagedown: 121, pageup: 116, home: 115, end: 119 };
// The app that was in front when the user asked (the one showing the sheet); keys always go there.
let target = null;
const osa = (script) => new Promise((res) => require("child_process").execFile("osascript", ["-e", script], (err, out) => res(err ? null : out.trim())));
ipcMain.handle("front", async () => (target = await osa('tell application "System Events" to get name of first process whose frontmost is true')));
ipcMain.handle("key", async (_e, name) => {
  const app = target && target.replace(/"/g, "");
  const script = app
    ? `tell application "System Events"\n if (name of first process whose frontmost is true) is not "${app}" then\n set frontmost of process "${app}" to true\n delay 0.3\n end if\n key code ${KEYS[name]}\nend tell`
    : `tell application "System Events" to key code ${KEYS[name]}`;
  const ok = await osa(script);
  if (ok === null) console.log("key failed:", name, app);
  return ok !== null;
});

ipcMain.handle("capture", async () => {
  const d = screen.getPrimaryDisplay();
  const size = { width: Math.round(d.bounds.width * d.scaleFactor), height: Math.round(d.bounds.height * d.scaleFactor) };
  const sources = await desktopCapturer.getSources({ types: ["screen"], thumbnailSize: size });
  const src = sources.find((s) => String(s.display_id) === String(d.id)) || sources[0];
  if (!src) throw new Error("No screen source. Allow Screen Recording for Electron in System Settings.");
  return { png: src.thumbnail.toPNG().toString("base64"), scale: d.scaleFactor };
});

ipcMain.handle("touchid", async (_e, reason) => {
  try {
    if (systemPreferences.canPromptTouchID()) { await systemPreferences.promptTouchID(reason); return true; }
  } catch { return false; }
  const r = await dialog.showMessageBox(win, { type: "question", buttons: ["Approve", "Cancel"], message: reason });
  return r.response === 0;
});
