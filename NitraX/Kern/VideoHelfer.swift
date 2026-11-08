import SwiftUI
import WebKit

/// 🖼 Porträt des Helfers (für den Anrufkreis): die App fotografiert den Kopf der 3D-Figur, sobald sie im Helfer-Tab bereit ist.
enum HelferPortrait {
    static let schluessel = "helfer_portrait"

    static var bild: UIImage? {
        guard let d = Gemeinsam.defaults.data(forKey: schluessel) else { return nil }
        return UIImage(data: d)
    }

    /// JS: Kopf-Schnappschuss als data-URL (Größe der Bühne danach wiederherstellen). Keine Backslashes im Swift-Text!
    static let skript = """
    (function(){ try {
      var f = window.nxHandyHelfer && window.nxHandyHelfer.figur && window.nxHandyHelfer.figur();
      if (!f || !f.schnappschuss || !f.vrm) return '';
      var el = f.ziel, w = el.clientWidth, h = el.clientHeight;
      var u = f.schnappschuss(384, 384, 'kopf');
      f.renderer.setSize(w, h, false); f.kamera.aspect = w / h; f.kamera.updateProjectionMatrix(); f.kameraSetzen();
      return u;
    } catch (e) { return '' } })()
    """

    @MainActor
    static func holen(aus web: WKWebView?) {
        web?.evaluateJavaScript(skript) { erg, _ in
            guard let s = erg as? String, let komma = s.firstIndex(of: ","), s.hasPrefix("data:image"),
                  let d = Data(base64Encoded: String(s[s.index(after: komma)...])), UIImage(data: d) != nil else { return }
            Gemeinsam.defaults.set(d, forKey: schluessel)
        }
    }
}

/// 📹 Der Helfer im Videoanruf: dieselbe 3D-Figur wie im Helfer-Tab, aber als »Bildschirm« ohne Bedienelemente und stumm –
/// die Stimme spielt die App (Telefonat), die Figur bewegt nur den Mund dazu (aussenPegel) und zeigt Gefühle.
struct VideoHelferWeb: UIViewRepresentable {
    let url: URL
    let fertig: (WKWebView) -> Void

    static let skript = """
    (function(){
      if (window.__nxVideo) return; window.__nxVideo = true;
      var st = document.createElement('style');
      st.textContent = 'html, body { background: #07080f !important; overflow: hidden !important } '
        + '* { visibility: hidden !important } '
        + '.nxvid-buehne, .nxvid-buehne * { visibility: visible !important }';
      (document.head || document.documentElement).appendChild(st);
      function figur() { try { return window.nxHandyHelfer && window.nxHandyHelfer.figur && window.nxHandyHelfer.figur() } catch (e) { return null } }
      var n = 0;
      (function auf() {
        n++;
        var c = document.querySelector('.nxhh canvas');
        if (c) {
          var p = c.parentElement;
          p.classList.add('nxvid-buehne');
          p.style.cssText += ';position:fixed !important;left:0 !important;top:0 !important;width:100vw !important;height:100vh !important;z-index:99999 !important;margin:0 !important';
          var f = figur(); if (f && f.zustandSetzen) f.zustandSetzen('hoeren');
          return;
        }
        if (window.nxHandyHelfer && !document.querySelector('.nxhh')) { try { window.nxHandyHelfer.oeffnen() } catch (e) {} }
        if (n < 200) setTimeout(auf, 100);
      })();
      window.nxVideo = {
        pegel: function (v) { var f = figur(); if (f && f.aussenPegel) f.aussenPegel(v) },
        zustand: function (z) { var f = figur(); if (f && f.zustandSetzen) f.zustandSetzen(z) },
        gefuehl: function (g) { var f = figur(); if (f && f.gefuehl) f.gefuehl(g, 5) }
      };
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let k = WKWebViewConfiguration()
        k.allowsInlineMediaPlayback = true
        k.mediaTypesRequiringUserActionForPlayback = .all            // die Seite selbst bleibt stumm
        let inhalt = WKUserContentController()
        inhalt.addUserScript(WKUserScript(source: Self.skript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        k.userContentController = inhalt
        let w = WKWebView(frame: .zero, configuration: k)
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1)
        w.scrollView.isScrollEnabled = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.isUserInteractionEnabled = false
        w.load(URLRequest(url: url))
        fertig(w)
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}
}
