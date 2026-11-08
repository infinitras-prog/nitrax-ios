"""Render-Kopie der iOS-Splash-Seite: feste Zufallsfolge, Zeit von außen (window.__render(t)), alle CSS-Übergänge/
-Animationen auf die Simulationszeit gezogen. Die Seite selbst bleibt unverändert."""
import os
HIER = os.path.dirname(os.path.abspath(__file__))
s = open(os.path.join(HIER, "splash_quelle.html"), encoding="utf-8").read()

kopf = """<script>
(function(){var a=20261108;Math.random=function(){a|=0;a=a+0x6D2B79F5|0;var t=Math.imul(a^a>>>15,1|a);
t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296}})();
window.__SIM=true;
</script>
<style>#fuss{bottom:46px!important}</style>
"""
s = s.replace("<style>", kopf + "<style>", 1)

alt_t = "const t=isNaN(FEST)?(now-T0)/1000:FEST;"
assert alt_t in s
s = s.replace(alt_t, "const t=window.__T;")
alt_raf = "  requestAnimationFrame(bild);\n}\nrequestAnimationFrame(bild);"
assert alt_raf in s
s = s.replace(alt_raf, """}
window.__render=function(t){
  window.__T=t; bild(0);
  document.getAnimations().forEach(function(a){
    if(a.__start==null)a.__start=t; a.pause(); a.currentTime=Math.max(0,(t-a.__start)*1000);
  });
};""")
# Haptik-/Fertig-Meldungen braucht der Render nicht
s = s.replace('setTimeout(function(){senden("fertig")}', 'if(!window.__SIM)setTimeout(function(){senden("fertig")}')
open(os.path.join(HIER, "splash_render.html"), "w", encoding="utf-8").write(s)
print("ok", len(s))
