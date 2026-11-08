# Splash-Video neu erzeugen (Windows-PC)
1. `python vorbereiten.py` (Render-Kopie mit fester Zufallsfolge und Zeit von außen)
2. `<electron.exe> render.js` -> frames/0000-0329.png (393x852 @3x, 60 fps)
3. `ffmpeg -framerate 60 -i frames/%04d.png -vf crop=1178:2556:0:0 -c:v libx265 -preset slow -crf 20 -pix_fmt yuv420p -tag:v hvc1 -movflags +faststart ../../NitraX/Splash/splash.mp4`
4. Letztes Bild als `NitraX/Splash/splash_ende.jpg` (Bewegung reduzieren).
frames/ nicht einchecken.
