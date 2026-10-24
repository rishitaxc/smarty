const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("sidekick", {
  capture: () => ipcRenderer.invoke("capture"),
  key: (name) => ipcRenderer.invoke("key", name),
  front: () => ipcRenderer.invoke("front"),
  interactive: (on) => ipcRenderer.invoke("interactive", on),
  touchId: (reason) => ipcRenderer.invoke("touchid", reason),
  onShortcut: (fn) => ipcRenderer.on("shortcut", (_e, action) => fn(action)),
});
