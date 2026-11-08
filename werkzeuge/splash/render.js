// Rendert splash_render.html Bild für Bild (60 fps, 393x852 pt @3x = 1179x2556 px) nach frames/NNNN.png
const { app, BrowserWindow } = require("electron");
const fs = require("fs"), path = require("path");
const FPS = 60, DAUER = +(process.env.DAUER || 5.5), W = 393, H = 852, F = 3;
const NUR = process.env.NUR ? process.env.NUR.split(",").map(Number) : null;   // Probebilder: NUR=0.5,2.8,5.4
app.commandLine.appendSwitch("force-device-scale-factor", String(F));
app.commandLine.appendSwitch("high-dpi-support", "1");
app.disableHardwareAcceleration();
app.whenReady().then(async () => {
  const w = new BrowserWindow({ width: W, height: H, show: false, useContentSize: true, frame: false, enableLargerThanScreen: true,
    webPreferences: { offscreen: true, backgroundThrottling: false } });
  w.webContents.setFrameRate(60); w.setContentSize(W, H);
  await w.loadFile(path.join(__dirname, "splash_render.html"));
  await new Promise(r => setTimeout(r, 800));
  const ziel = path.join(__dirname, NUR ? "probe" : "frames");
  fs.mkdirSync(ziel, { recursive: true });
  const zeiten = NUR || Array.from({ length: Math.round(DAUER * FPS) }, (_, i) => i / FPS);
  for (let i = 0; i < zeiten.length; i++) {
    await w.webContents.executeJavaScript(`window.__render(${zeiten[i]}); new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))`);
    w.webContents.invalidate();
    await new Promise(r => setTimeout(r, 30));
    const img = await w.webContents.capturePage();
    fs.writeFileSync(path.join(ziel, String(i).padStart(4, "0") + ".png"), img.toPNG());
    if (i % 60 === 0) console.log("Bild", i, "von", zeiten.length, img.getSize());
  }
  app.quit();
});
