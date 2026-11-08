import SwiftUI
import WebKit
import AVFoundation

/// 🧍 Der 3D-Helfer - Figur, Touch-Gesten, Gespräch, Spiele, Listen, Wecker (die Helfer-Ansicht des PCs, eingebettet).
/// Das Mikrofon macht die App selbst: in Webansichten sperrt iOS es ohne HTTPS - so geht Sprechen auch im WLAN.
@MainActor
struct HelferAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    @State private var neuLaden = UUID()
    @State private var meldung: Int?
    @StateObject private var bruecke = HelferBruecke()
    @State private var kamera = false
    @State private var fotoFrage = false

    var body: some View {
        ZStack {
            Hintergrund()
            if let url = adresse, let c = studio.client {
                HelferWeb(url: url, client: c, bruecke: bruecke).id(neuLaden).ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Nicht verbunden", systemImage: "wifi.exclamationmark")
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                // 📷 Foto für den Helfer: er schaut es sich an und antwortet (Frontkamera = »Wie sehe ich aus?«)
                Button { kamera = true } label: {
                    Image(systemName: "camera.fill").padding(10).background(.ultraThinMaterial, in: Circle())
                }
                Button { meldung = nil; neuLaden = UUID() } label: {
                    Image(systemName: "arrow.clockwise").padding(10).background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.trailing, 12).padding(.top, 4)
            .opacity(0.85)
        }
        .fullScreenCover(isPresented: $kamera) {
            KameraAufnahme { d in Task { await fotoSenden(d) } }.ignoresSafeArea()
        }
        .onAppear { meldungUebernehmen() }
        .onChange(of: navigation.helferMeldung) { _, _ in meldungUebernehmen() }
    }

    private var adresse: URL? {
        guard let v = studio.verbindung, let basis = studio.client?.aktuelleBasis ?? v.reihenfolge.first else { return nil }
        let k = v.schluessel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v.schluessel
        return URL(string: basis + "/?k=" + k + "#helfer" + (meldung.map { "&m=\($0)" } ?? ""))
    }

    private func fotoSenden(_ daten: Data) async {
        guard let c = studio.client else { return }
        let jpeg = UIImage(data: daten).flatMap { bild -> Data? in
            // ~1280 px reichen dem Helfer und gehen schnell durchs WLAN
            let s = min(1, 1280 / max(bild.size.width, bild.size.height))
            let g = CGSize(width: bild.size.width * s, height: bild.size.height * s)
            return UIGraphicsImageRenderer(size: g).image { _ in bild.draw(in: CGRect(origin: .zero, size: g)) }.jpegData(compressionQuality: 0.85)
        } ?? daten
        do {
            let r = try await c.hochladen("/api/chat/upload", daten: jpeg, dateiname: "helfer-foto.jpg", typ: "image/jpeg")
            if let n = r["name"]?.text { bruecke.bild(n) }
        } catch { studio.meldung = error.localizedDescription }
    }

    /// Mitteilung angetippt: Helfer neu öffnen, er sagt dir die Meldung
    private func meldungUebernehmen() {
        guard let m = navigation.helferMeldung else { return }
        navigation.helferMeldung = nil
        meldung = m
        neuLaden = UUID()
    }
}

/// Verbindung SwiftUI <-> Helfer-Seite (Foto senden, Text einspielen)
@MainActor
final class HelferBruecke: ObservableObject {
    weak var web: WKWebView?

    func bild(_ name: String, frage: String = "📷 Schau mal – was siehst du auf dem Foto?") {
        let n = (try? String(data: JSONEncoder().encode(name), encoding: .utf8)) ?? nil
        let f = (try? String(data: JSONEncoder().encode(frage), encoding: .utf8)) ?? nil
        guard let n, let f else { return }
        web?.evaluateJavaScript("window.nxIOSBild && window.nxIOSBild(\(n), \(f))", completionHandler: nil)
    }
}

struct HelferWeb: UIViewRepresentable {
    let url: URL
    let client: NXClient
    let bruecke: HelferBruecke

    /// Verbindet die Helfer-Seite mit dem nativen Mikrofon: 🎤 der Seite -> App nimmt auf -> PC erkennt -> Text an den Helfer
    static let bruecke = """
    (function(){
      if (window.__nxIOS) return; window.__nxIOS = true;
      var st = document.createElement('style');
      st.textContent = '.nxhh [data-a="push"], .nxhh [data-a="zu"] { display: none !important }';
      (document.head || document.documentElement).appendChild(st);
      function binden() {
        var b = document.querySelector('.nxhh [data-a="mikro"]');
        if (!b || b.__nx) return;
        var n = b.cloneNode(true); n.__nx = true; b.replaceWith(n);
        n.addEventListener('click', function (e) {
          e.preventDefault();
          window.webkit.messageHandlers.nxMikro.postMessage(n.classList.contains('an') ? 'stopp' : 'start');
        });
      }
      new MutationObserver(binden).observe(document.documentElement, {childList: true, subtree: true});
      binden();
      window.nxIOSZustand = function (an, t) {
        var b = document.querySelector('.nxhh [data-a="mikro"]'); if (b) b.classList.toggle('an', !!an);
        var z = document.querySelector('.nxhh-zust'); if (z && typeof t === 'string') z.textContent = t;
      };
      window.nxIOSText = function (t) {
        var i = document.querySelector('.nxhh-unten input'), s = document.querySelector('.nxhh [data-a="senden"]');
        if (i && s && t) { i.value = t; s.click(); }
      };
      // 📷 Foto aus der App: hängt an die nächste Frage an den Helfer (der Helfer schickt seine Fragen per fetch)
      window.__nxBilder = [];
      var altFetch = window.fetch;
      window.fetch = function (u, o) {
        try {
          if (typeof u === 'string' && u.indexOf('/api/chats/') >= 0 && u.slice(-7) === '/senden' && window.__nxBilder.length && o && typeof o.body === 'string') {
            var b = JSON.parse(o.body); b.bilder = (b.bilder || []).concat(window.__nxBilder); window.__nxBilder = [];
            o = Object.assign({}, o, {body: JSON.stringify(b)});
          }
        } catch (e) {}
        return altFetch.apply(this, [u, o]);
      };
      window.nxIOSBild = function (name, frage) {
        window.__nxBilder = [name];
        var log = document.querySelector('.nxhh-log');
        if (log) { var z = document.createElement('div'); z.className = 'du';
          z.innerHTML = '<img src="/api/image/' + encodeURIComponent(name) + '" style="max-width:180px">'; log.appendChild(z); log.scrollTop = log.scrollHeight; }
        window.nxIOSText(frage);
      };
    })();
    """

    func makeCoordinator() -> Koordinator { Koordinator(client: client) }

    func makeUIView(context: Context) -> WKWebView {
        let k = WKWebViewConfiguration()
        k.allowsInlineMediaPlayback = true
        k.mediaTypesRequiringUserActionForPlayback = []          // Stimme des Helfers ohne extra Tippen
        let inhalt = WKUserContentController()
        inhalt.addUserScript(WKUserScript(source: HelferWeb.bruecke, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        inhalt.add(SchwacherHandler(context.coordinator), name: "nxMikro")
        k.userContentController = inhalt
        let w = WKWebView(frame: .zero, configuration: k)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.uiDelegate = context.coordinator
        context.coordinator.web = w
        bruecke.web = w
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}

    static func dismantleUIView(_ w: WKWebView, coordinator: Koordinator) {
        coordinator.zuhoerer.abbrechen()
        w.configuration.userContentController.removeScriptMessageHandler(forName: "nxMikro")
    }

    @MainActor
    final class Koordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        let client: NXClient
        let zuhoerer = Zuhoerer()

        init(client: NXClient) {
            self.client = client
            super.init()
            zuhoerer.fertig = { [weak self] datei in Task { await self?.verstehen(datei) } }
            zuhoerer.zustand = { [weak self] an, text in self?.zustand(an, text) }
        }

        nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            let befehl = message.body as? String ?? ""
            Task { @MainActor in
                if befehl == "start" { await self.zuhoerer.starten() } else { self.zuhoerer.stoppen() }
            }
        }

        private func zustand(_ an: Bool, _ text: String) {
            let t = (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? "\"\""
            web?.evaluateJavaScript("window.nxIOSZustand && window.nxIOSZustand(\(an), \(t))", completionHandler: nil)
        }

        private func verstehen(_ datei: URL) async {
            zustand(false, "💭 verstehe …")
            defer { try? FileManager.default.removeItem(at: datei) }
            do {
                let d = try Data(contentsOf: datei)
                let r = try await client.hochladen("/api/anruf/hoeren", daten: d, dateiname: "iphone.wav", typ: "audio/wav",
                                                   felder: ["sprache": "German"])
                let text = (r["text"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { zustand(false, "Nichts verstanden – nochmal 🎤"); return }
                let lit = (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? nil
                zustand(false, "")
                if let lit { web?.evaluateJavaScript("window.nxIOSText && window.nxIOSText(\(lit))", completionHandler: nil) }
            } catch {
                zustand(false, "Verstehen ging nicht: \(error.localizedDescription)")
            }
        }

        // Kamera/Mikro-Anfragen der Seite (z. B. über die sichere Tailscale-Adresse) erlauben
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}

/// WKUserContentController hält seine Handler fest - so entsteht kein Kreis mit dem Koordinator.
@MainActor
final class SchwacherHandler: NSObject, WKScriptMessageHandler {
    weak var ziel: WKScriptMessageHandler?
    init(_ z: WKScriptMessageHandler) { ziel = z }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        ziel?.userContentController(uc, didReceive: message)
    }
}

/// Sprechen: Aufnahme 16 kHz mono (wie der Helfer am PC), Stopp automatisch nach ~1,2 s Stille.
@MainActor
final class Zuhoerer: NSObject {
    var fertig: ((URL) -> Void)?
    var zustand: ((Bool, String) -> Void)?
    private var rekorder: AVAudioRecorder?
    private var uhr: Timer?
    private var start = Date()
    private var sprache: Date?
    private var stille: Date?

    func starten() async {
        guard rekorder == nil else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            zustand?(false, "Mikrofon nicht erlaubt – in den iPhone-Einstellungen bei NitraX einschalten")
            return
        }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try? s.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("helfer-\(UUID().uuidString.prefix(6)).wav")
        let einst: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let r = try? AVAudioRecorder(url: url, settings: einst) else { zustand?(false, "Aufnahme ging nicht"); return }
        r.isMeteringEnabled = true
        r.record(forDuration: 30)
        rekorder = r
        start = Date()
        sprache = nil
        stille = nil
        zustand?(true, "🎤 Ich höre …")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        uhr = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.messen() }
        }
    }

    private func messen() {
        guard let r = rekorder else { return }
        r.updateMeters()
        let pegel = r.averagePower(forChannel: 0)
        let jetzt = Date()
        if pegel > -38 {
            if sprache == nil { sprache = jetzt }
            stille = nil
        } else if sprache != nil {
            if stille == nil { stille = jetzt }
            if let st = stille, jetzt.timeIntervalSince(st) > 1.2 { stoppen() }
        }
        if sprache == nil && jetzt.timeIntervalSince(start) > 8 { abbrechen(); zustand?(false, "Ich hab nichts gehört") }
        if jetzt.timeIntervalSince(start) > 29.5 { stoppen() }
    }

    func stoppen() {
        uhr?.invalidate()
        uhr = nil
        guard let r = rekorder else { return }
        r.stop()
        rekorder = nil
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        if sprache != nil { fertig?(r.url) } else { zustand?(false, "") }
    }

    func abbrechen() {
        uhr?.invalidate()
        uhr = nil
        rekorder?.stop()
        if let u = rekorder?.url { try? FileManager.default.removeItem(at: u) }
        rekorder = nil
        zustand?(false, "")
    }
}
