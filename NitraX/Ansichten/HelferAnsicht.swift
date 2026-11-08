import SwiftUI
import WebKit
import AVFoundation

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

    var body: some View {
        ZStack {
            Hintergrund()
            if let url = adresse, let c = studio.client {
                HelferWeb(url: url, client: c, bruecke: bruecke).id(neuLaden).ignoresSafeArea(edges: .bottom)
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
            HStack(spacing: 10) {
                // 📷 Foto für den Helfer: er schaut es sich an und antwortet (Frontkamera = »Wie sehe ich aus?«)
                Button { kamera = true } label: {
                    Image(systemName: "camera.fill").padding(10).background(.ultraThinMaterial, in: Circle())
                }
                Button { neuLaden = UUID() } label: {
                    Image(systemName: "arrow.clockwise").padding(10).background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.trailing, 12).padding(.top, 52)
            .opacity(0.85)
        }
        .fullScreenCover(isPresented: $kamera) {
            KameraAufnahme { d in Task { await fotoSenden(d) } }.ignoresSafeArea()
        }
        .onAppear { auftraegeUebernehmen() }
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

    func makeCoordinator() -> Koordinator { Koordinator(client: client, bruecke: bruecke) }

    func makeUIView(context: Context) -> WKWebView {
        let k = WKWebViewConfiguration()
        k.allowsInlineMediaPlayback = true
        k.mediaTypesRequiringUserActionForPlayback = []          // Stimme des Helfers ohne extra Tippen
        let inhalt = WKUserContentController()
        inhalt.addUserScript(WKUserScript(source: HelferWeb.skript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        inhalt.add(SchwacherHandler(context.coordinator), name: "nxMikro")
        inhalt.add(SchwacherHandler(context.coordinator), name: "nxHelfer")
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
    }

    @MainActor
    final class Koordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        let client: NXClient
        let bruecke: HelferBruecke
        let zuhoerer = Zuhoerer()

        init(client: NXClient, bruecke: HelferBruecke) {
            self.client = client
            self.bruecke = bruecke
            super.init()
            zuhoerer.fertig = { [weak self] datei in Task { await self?.verstehen(datei) } }
            zuhoerer.zustand = { [weak self] an, text in self?.zustand(an, text) }
        }

        nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            let name = message.name
            let befehl = message.body as? String ?? ""
            Task { @MainActor in
                if name == "nxHelfer" {
                    switch befehl {
                    case "bereit": self.bruecke.fertig()
                    case "keinhelfer": self.bruecke.fehler = "Die Helfer-Seite vom PC kam nicht vollständig an. Läuft NitraX AI Studio mit eingeschaltetem Helfer?"
                    default: self.bruecke.fehler = "Die 3D-Figur ließ sich nicht anzeigen. Tippe auf »Nochmal«."
                    }
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
