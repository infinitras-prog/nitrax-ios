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
      st.textContent = 'html, body { background: transparent !important; overflow: hidden !important } '
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
        w.backgroundColor = .clear                      // 🎨 Hintergrund kommt aus SwiftUI (wählbar)
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.isUserInteractionEnabled = false
        w.load(URLRequest(url: url))
        fertig(w)
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}
}


/// 🎨 Hintergründe für den Videoanruf
enum VideoHintergrund {
    static let alle: [(String, String)] = [("nacht", "🌙 Nacht"), ("sonne", "🌅 Sonnenuntergang"), ("studio", "🎛 Studio"), ("aurora", "✨ Aurora")]

    @ViewBuilder
    static func ansicht(_ id: String) -> some View {
        switch id {
        case "sonne":
            LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.3), Color(red: 0.55, green: 0.2, blue: 0.45), Color(red: 0.12, green: 0.08, blue: 0.2)],
                           startPoint: .top, endPoint: .bottom)
        case "studio":
            RadialGradient(colors: [Color(red: 0.3, green: 0.32, blue: 0.38), Color(red: 0.08, green: 0.09, blue: 0.11)], center: .init(x: 0.5, y: 0.35),
                           startRadius: 10, endRadius: 600)
        case "aurora":
            ZStack {
                Color(red: 0.03, green: 0.04, blue: 0.08)
                LinearGradient(colors: [Color(red: 0.13, green: 0.83, blue: 0.93).opacity(0.45), .clear, Color(red: 0.55, green: 0.36, blue: 1).opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        default:
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.16), Color(red: 0.02, green: 0.02, blue: 0.05)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 🖼 Ergebnis aus der Bibliothek im Videoanruf zeigen
@MainActor
struct ZeigenAuswahl: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let gewaehlt: (Data, String) -> Void
    @State private var laedt: String?

    private var bilder: [Auftrag] {
        Array(studio.stand.auftraege.filter { $0.fertig && $0.bilderAnzahl > 0 }.sorted { ($0.finished ?? 0) > ($1.finished ?? 0) }.prefix(60))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                    ForEach(bilder) { a in
                        Button { Task { await holen(a) } } label: {
                            BibliothekKachel(a: a).overlay { if laedt == a.id { ProgressView() } }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
            .navigationTitle("Ihr etwas zeigen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }

    private func holen(_ a: Auftrag) async {
        guard let c = studio.client, let url = c.url("/api/img/file/\(a.id)/0") else { return }
        laedt = a.id
        defer { laedt = nil }
        var r = URLRequest(url: url)
        for (k, v) in c.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
        guard let (d, _) = try? await URLSession.shared.data(for: r), let b = UIImage(data: d) else { return }
        // kleiner rechnen (schneller beim Ansehen)
        let s = min(1, 1024 / max(b.size.width, b.size.height))
        let klein = UIGraphicsImageRenderer(size: CGSize(width: b.size.width * s, height: b.size.height * s)).image { _ in
            b.draw(in: CGRect(origin: .zero, size: CGSize(width: b.size.width * s, height: b.size.height * s)))
        }
        guard let jpeg = klein.jpegData(compressionQuality: 0.85) else { return }
        gewaehlt(jpeg, a.titel)
        dismiss()
    }
}
