// exe のウィンドウ：dist/index.html（vite build の結果）を開く。F11 で全画面を切り替える
const { app, BrowserWindow } = require("electron");
const path = require("node:path");

function create() {
  const win = new BrowserWindow({
    width: 1280,
    height: 720,
    backgroundColor: "#000000",
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  win.loadFile(path.join(__dirname, "..", "dist", "index.html"));
  win.webContents.on("before-input-event", (_event, input) => {
    if (input.type === "keyDown" && input.key === "F11") win.setFullScreen(!win.isFullScreen());
  });
}

app.whenReady().then(create);
app.on("window-all-closed", () => app.quit());
