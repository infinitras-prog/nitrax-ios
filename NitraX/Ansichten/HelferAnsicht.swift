import SwiftUI
import WebKit
import AVFoundation
import CoreMotion

/// 🧍 Der 3D-Helfer - Figur, Touch-Gesten, Gespräch, Spiele, Listen, Wecker (die Helfer-Ansicht des PCs, eingebettet).
/// Das Mikrofon macht die App selbst: in Webansichten sperrt iOS es ohne HTTPS - so geht Sprechen auch im WLAN.
/// Die Seite öffnet den Helfer selbst nicht zuverlässig (sie räumt beim Laden ihre Adresse auf) - deshalb öffnet die App
/// ihn nach dem Laden über window.nxHandyHelfer und blendet die übrige Handy-Seite aus.
@MainActor
struct HelferAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    @State private var neuLaden = UUID()
    @StateObject private var bruecke = HelferBruecke()
    @State private var kamera = false
    @State private var einstellungen = false
    @StateObject private var augen = HelferAugen()
    @AppStorage("helfer_augen") private var augenAn = true

    var body: some View {
        ZStack {
            Hintergrund()
            if let url = adresse, let c = studio.client {
                HelferWeb(url: url, client: c, bruecke: bruecke, augen: augen).id(neuLaden).ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Nicht verbunden", systemImage: "wifi.exclamationmark")
            }
            if !bruecke.bereit && bruecke.fehler == nil {
                ProgressView("Helfer kommt …").tint(.white).padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if let f = bruecke.fehler {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(f).multilineTextAlignment(.center).font(.callout)
                    Button("Nochmal") { neuLaden = UUID() }.buttonStyle(.borderedProminent)
                }
                .padding(22).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(30)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 10) {
                // 👁 Live-Kamera als Augen an/aus
                Button { augenAn.toggle() } label: {
                    Image(systemName: augenAn ? "eye.fill" : "eye.slash").frame(width: 20, height: 20).padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(augen.laeuft ? Color.green.opacity(0.8) : .clear, lineWidth: 1.5))
                }
                // 📷 Foto für den Helfer: er schaut es sich an und antwortet
                Button { kamera = true } label: {
                    Image(systemName: "camera.fill").frame(width: 20, height: 20).padding(10).background(.ultraThinMaterial, in: Circle())
                }
                // ⚙ Helfer anpassen
                Button { einstellungen = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 20, height: 20).padding(10).background(.ultraThinMaterial, in: Circle())
                }
                Button { neuLaden = UUID() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20).padding(10).background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.trailing, 12).padding(.top, 58)
            .opacity(0.88)
        }
        .overlay(alignment: .topLeading) {
            if augen.laeuft {
                KameraVorschau(sitzung: augen.sitzung)
                    .frame(width: 66, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.35), lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) { Circle().fill(.green).frame(width: 8, height: 8).padding(6) }
                    .padding(.leading, 12).padding(.top, 58)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: augen.laeuft)
        .sheet(isPresented: $einstellungen) {
            HelferEinstellungen { neuLaden = UUID() }
        }
        .fullScreenCover(isPresented: $kamera) {
            KameraAufnahme { d in Task { await fotoSenden(d) } }.ignoresSafeArea()
        }
        .onAppear {
            auftraegeUebernehmen()
            HelferTon.einrichten()
            if augenAn { Task { await augen.starten() } }
        }
        .onDisappear { augen.stoppen() }
        .onChange(of: augenAn) { _, an in if an { Task { await augen.starten() } } else { augen.stoppen() } }
        .onChange(of: augen.fehler) { _, f in if let f { studio.meldung = f; augen.fehler = nil } }
        .onChange(of: navigation.helferMeldung) { _, _ in auftraegeUebernehmen() }
        .onChange(of: navigation.helferZuhoeren) { _, _ in auftraegeUebernehmen() }
    }

    private var adresse: URL? {
        guard let v = studio.verbindung, let basis = studio.client?.aktuelleBasis ?? v.reihenfolge.first else { return nil }
        let k = v.schluessel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v.schluessel
        return URL(string: basis + "/?k=" + k + "#helfer")
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

    /// Mitteilung angetippt (der Helfer sagt sie dir) bzw. »Sprich mit NitraX« (sofort zuhören)
    private func auftraegeUebernehmen() {
        if let m = navigation.helferMeldung {
            navigation.helferMeldung = nil
            bruecke.meldung(m)
        }
        if navigation.helferZuhoeren {
            navigation.helferZuhoeren = false
            bruecke.zuhoeren()
        }
    }
}

/// Verbindung SwiftUI <-> Helfer-Seite. Aktionen warten, bis die Figur da ist.
@MainActor
final class HelferBruecke: ObservableObject {
    weak var web: WKWebView?
    weak var koordinator: HelferWeb.Koordinator?
    @Published var bereit = false
    @Published var fehler: String?
    private var wartend: [() -> Void] = []

    func neu() { bereit = false; fehler = nil }

    func fertig() {
        bereit = true
        let liste = wartend
        wartend = []
        liste.forEach { $0() }
    }

    private func wennBereit(_ f: @escaping () -> Void) { if bereit { f() } else { wartend.append(f) } }

    func js(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }

    func bild(_ name: String, frage: String = "📷 Schau mal – was siehst du auf dem Foto?") {
        let n = (try? String(data: JSONEncoder().encode(name), encoding: .utf8)) ?? nil
        let f = (try? String(data: JSONEncoder().encode(frage), encoding: .utf8)) ?? nil
        guard let n, let f else { return }
        wennBereit { [weak self] in self?.js("window.nxIOSBild && window.nxIOSBild(\(n), \(f))") }
    }

    func meldung(_ m: Int) {
        wennBereit { [weak self] in self?.js("location.hash = '#helfer&m=\(m)'") }
    }

    func zuhoeren() {
        wennBereit { [weak self] in
            guard let k = self?.koordinator else { return }
            Task { await k.zuhoerer.starten() }
        }
    }
}

struct HelferWeb: UIViewRepresentable {
    let url: URL
    let client: NXClient
    let bruecke: HelferBruecke
    let augen: HelferAugen

    /// Öffnet den Helfer, blendet die übrige Handy-Seite aus und verbindet 🎤 mit dem nativen Mikrofon.
    /// (Swift-Mehrzeilentext: im JS KEINE Backslashes verwenden.)
    static let skript = """
    (function(){
      if (window.__nxIOS) return; window.__nxIOS = true;
      var st = document.createElement('style');
      st.textContent = 'html, body { background: #07080f !important } '
        + 'body > *:not(.nxhh):not(.nxhh-toast) { visibility: hidden !important } '
        + '#nxhh-start, .nxhh [data-a="push"], .nxhh [data-a="zu"] { display: none !important } '
        + '.nxhh-kopf { padding-right: 104px !important }';
      (document.head || document.documentElement).appendChild(st);
      function melden(was) { try { window.webkit.messageHandlers.nxHelfer.postMessage(was) } catch (e) {} }
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
      var versuche = 0;
      (function auf() {
        versuche++;
        if (document.querySelector('.nxhh canvas')) { binden(); setTimeout(function () { melden('bereit') }, 400); return; }
        if (window.nxHandyHelfer && !document.querySelector('.nxhh')) { try { window.nxHandyHelfer.oeffnen() } catch (e) {} }
        if (versuche > 150) { melden(window.nxHandyHelfer ? 'keinbild' : 'keinhelfer'); return; }
        setTimeout(auf, 100);
      })();
      window.nxIOSZustand = function (an, t) {
        var b = document.querySelector('.nxhh [data-a="mikro"]'); if (b) b.classList.toggle('an', !!an);
        var z = document.querySelector('.nxhh-zust'); if (z && typeof t === 'string') z.textContent = t;
        try { if (window.nxHandyHelfer && window.nxHandyHelfer.hoert) window.nxHandyHelfer.hoert(!!an) } catch (e) {}
      };
      window.nxIOSText = function (t) {
        if (!t) return;
        if (window.nxHandyHelfer && window.nxHandyHelfer.fragen) { window.nxHandyHelfer.fragen(t); return; }
        var i = document.querySelector('.nxhh-unten input'), s = document.querySelector('.nxhh [data-a="senden"]');
        if (i && s) { i.value = t; s.click(); }
      };
      // 👁 Seh-Fragen beantwortet die App mit der Frontkamera (der PC beschreibt das Bild)
      var SEH = ['siehst du', 'siehst mich', 'kannst du mich sehen', 'kamera', 'wie sehe ich', 'wie seh ich', 'wie sehe ich aus',
        'was habe ich', 'was hab ich', 'was halte ich', 'was trage ich', 'erkennst du mich', 'schau mal', 'schau mich', 'guck mal',
        'guck mich', 'sieh mal', 'sieh mich', 'zeig dir', 'vor dir', 'deine augen', 'wie findest du mein', 'mein outfit'];
      window.nxAugen = { kontext: async function (frage) {
        var q = String(frage || '').toLowerCase();
        if (!SEH.some(function (w) { return q.indexOf(w) >= 0; })) return null;
        try { var t = await window.webkit.messageHandlers.nxAuge.postMessage(q); return t ? {text: t, bilder: []} : null; }
        catch (e) { return null; }
      }};
      // 📳 Vibration der Seite (Spiele, Touch) -> echte iPhone-Haptik
      navigator.vibrate = function (m) {
        try { window.webkit.messageHandlers.nxHaptik.postMessage(Array.isArray(m) ? Math.ceil(m.length / 2) : 1); } catch (e) {}
        return true;
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
        var i = document.querySelector('.nxhh-unten input'), s = document.querySelector('.nxhh [data-a="senden"]');
        if (i && s) { i.value = frage; s.click(); }
      };
    })();
    """

    func makeCoordinator() -> Koordinator { Koordinator(client: client, bruecke: bruecke, augen: augen) }

    func makeUIView(context: Context) -> WKWebView {
        let k = WKWebViewConfiguration()
        k.allowsInlineMediaPlayback = true
        k.mediaTypesRequiringUserActionForPlayback = []          // Stimme des Helfers ohne extra Tippen
        let inhalt = WKUserContentController()
        inhalt.addUserScript(WKUserScript(source: HelferWeb.skript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        inhalt.add(SchwacherHandler(context.coordinator), name: "nxMikro")
        inhalt.add(SchwacherHandler(context.coordinator), name: "nxHelfer")
        inhalt.add(SchwacherHandler(context.coordinator), name: "nxHaptik")
        let koordinator = context.coordinator
        inhalt.addScriptMessageHandler(AntwortHandler { frage in await koordinator.sehen(frage) }, contentWorld: .page, name: "nxAuge")
        k.userContentController = inhalt
        let w = WKWebView(frame: .zero, configuration: k)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.uiDelegate = context.coordinator
        w.navigationDelegate = context.coordinator
        context.coordinator.web = w
        bruecke.web = w
        bruecke.koordinator = context.coordinator
        bruecke.neu()
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}

    static func dismantleUIView(_ w: WKWebView, coordinator: Koordinator) {
        coordinator.zuhoerer.abbrechen()
        w.configuration.userContentController.removeScriptMessageHandler(forName: "nxMikro")
        w.configuration.userContentController.removeScriptMessageHandler(forName: "nxHelfer")
        w.configuration.userContentController.removeScriptMessageHandler(forName: "nxHaptik")
        w.configuration.userContentController.removeScriptMessageHandler(forName: "nxAuge", contentWorld: .page)
        coordinator.bewegungAus()
        coordinator.augen.verarbeitung.blick = nil
    }

    @MainActor
    final class Koordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        let client: NXClient
        let bruecke: HelferBruecke
        let augen: HelferAugen
        let zuhoerer = Zuhoerer()
        private let bewegung = CMMotionManager()
        private var schuettelT = Date.distantPast
        private let haptik = UIImpactFeedbackGenerator(style: .light)

        init(client: NXClient, bruecke: HelferBruecke, augen: HelferAugen) {
            self.client = client
            self.bruecke = bruecke
            self.augen = augen
            super.init()
            haptik.prepare()
            zuhoerer.fertig = { [weak self] datei in Task { await self?.verstehen(datei) } }
            zuhoerer.zustand = { [weak self] an, text in self?.zustand(an, text) }
        }

        nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            let name = message.name
            let befehl = message.body as? String ?? ""
            Task { @MainActor in
                if name == "nxHelfer" {
                    switch befehl {
                    case "bereit":
                        self.bruecke.fertig()
                        self.bewegungAn()
                        self.blickVerbinden()
                    case "keinhelfer": self.bruecke.fehler = "Die Helfer-Seite vom PC kam nicht vollständig an. Läuft NitraX AI Studio mit eingeschaltetem Helfer?"
                    default: self.bruecke.fehler = "Die 3D-Figur ließ sich nicht anzeigen. Tippe auf »Nochmal«."
                    }
                } else if name == "nxHaptik" {
                    let n = max(1, min(6, Int(message.body as? Int ?? (message.body as? NSNumber)?.intValue ?? 1)))
                    for i in 0..<n { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.075) { self.haptik.impactOccurred(intensity: 0.7) } }
                } else if befehl == "start" { await self.zuhoerer.starten() } else { self.zuhoerer.stoppen() }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            bruecke.fehler = "Verbindung zum PC unterbrochen: \(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            bruecke.fehler = "PC nicht erreichbar: \(error.localizedDescription)"
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            bruecke.neu()
            webView.reload()                                  // iOS hat die Seite (Speicher) beendet: neu laden statt schwarz
        }

        /// 📳 Schütteln -> schwindelig bzw. würfeln (Beschleunigung > ~2,3 g)
        func bewegungAn() {
            guard bewegung.isAccelerometerAvailable, !bewegung.isAccelerometerActive else { return }
            bewegung.accelerometerUpdateInterval = 1.0 / 30
            bewegung.startAccelerometerUpdates(to: .main) { [weak self] d, _ in
                guard let self, let a = d?.acceleration else { return }
                if (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() > 2.3, Date().timeIntervalSince(self.schuettelT) > 1.5 {
                    self.schuettelT = Date()
                    self.web?.evaluateJavaScript("window.nxHandyHelfer && window.nxHandyHelfer.geschuettelt && window.nxHandyHelfer.geschuettelt()", completionHandler: nil)
                }
            }
        }

        func bewegungAus() { if bewegung.isAccelerometerActive { bewegung.stopAccelerometerUpdates() } }

        /// 👁 Gesicht im Kamerabild -> sie schaut dich an
        func blickVerbinden() {
            augen.verarbeitung.blick = { [weak self] x, y in
                Task { @MainActor in
                    self?.web?.evaluateJavaScript(String(format: "window.nxHandyHelfer && window.nxHandyHelfer.blick && window.nxHandyHelfer.blick(%.3f, %.3f)", x, y),
                                                  completionHandler: nil)
                }
            }
        }

        /// 👁 Seh-Frage: aktuelles Kamerabild an den PC, der beschreibt es - ehrlicher Befund, wenn die Augen aus sind
        func sehen(_ frage: String) async -> String {
            guard augen.laeuft else {
                return "deine Augen (die Handykamera) sind gerade AUS – du siehst ihn nicht; sag ihm, dass er sie mit dem Augen-Knopf rechts einschalten kann"
            }
            guard let bild = augen.verarbeitung.jpeg() else { return "deine Handykamera liefert gerade kein Bild – du siehst ihn nicht" }
            if bild.isEmpty { return "die Handykamera zeigt nur ein SCHWARZES Bild (Objektiv abgedeckt oder sehr dunkel) – du siehst ihn gerade nicht" }
            do {
                let r = try await client.hochladen("/api/begleiter/kamera", daten: bild, dateiname: "blick.jpg", typ: "image/jpeg", felder: ["art": "beschreiben"])
                let t = (r["text"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? "deine Handykamera liefert gerade kein klares Bild" : "durch die Handykamera (Frontkamera, er hält das Handy) siehst du: " + t
            } catch {
                return "das Kamerabild kam gerade nicht beim PC an – du siehst ihn nicht"
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

/// Nachricht mit Antwort (JS: `await window.webkit.messageHandlers.nxAuge.postMessage(…)`)
final class AntwortHandler: NSObject, WKScriptMessageHandlerWithReply {
    let arbeit: @MainActor (String) async -> String
    init(_ a: @escaping @MainActor (String) async -> String) { arbeit = a }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let frage = message.body as? String ?? ""
        Task { @MainActor in replyHandler(await arbeit(frage), nil) }
    }
}

/// 🔊 Ton des Helfers: EINE feste Audio-Sitzung (Abspielen + Mikrofon, Lautsprecher) - früher schaltete jede Aufnahme die
/// Kategorie um, das unterbrach laufende Sprache kurz (abgehackt). Lautlos-Schalter stummt den Helfer nicht.
enum HelferTon {
    static func einrichten() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord || !s.categoryOptions.contains(.defaultToSpeaker) {
            try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth])
        }
        try? s.setActive(true)
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
        HelferTon.einrichten()                                 // ändert nichts, wenn schon richtig (kein Ton-Abriss)
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
