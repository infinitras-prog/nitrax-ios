import Foundation
import PushKit
import CallKit
import AVFoundation
import UIKit
import WebKit

/// 📞 Der Helfer ruft an (nur für Aufträge, bei denen du das ausdrücklich gesagt hast): VoIP-Push vom PC -> echter Anruf
/// (CallKit, klingelt auch gesperrt). Abheben -> Gespräch mit dem Helfer: er sagt, worum es geht, du antwortest, ihr redet weiter,
/// bis du auflegst. Erkennung + Stimme am PC, Gesprächs-Kopf = derselbe Helfer-Chat wie in der App.
@MainActor
final class AnrufDienst: NSObject, ObservableObject {
    static let shared = AnrufDienst()
    @Published private(set) var imGespraech = false
    @Published private(set) var lautsprecher = false
    @Published private(set) var stumm = false
    @Published private(set) var seit: Date?
    @Published private(set) var anrufer = "Dein Helfer"
    /// 📞 Du rufst an: es klingelt (Freizeichen), solange der PC Stimme + Sprachmodell aufweckt – sie hebt ab, wenn alles bereit ist
    @Published private(set) var verbindet = false
    private var freizeichen: AVAudioPlayer?
    private weak var anbieterRef: CXProvider?
    private var ausgehend: UUID?
    /// 🎙 Anzeige im Anrufbildschirm: dein Mikrofonpegel (0…1), die letzten Werte als Welle, spricht gerade der Helfer
    @Published private(set) var pegel: Float = 0
    @Published private(set) var welle: [Float] = Array(repeating: 0, count: 48)
    @Published private(set) var helferSpricht = false
    /// 💬 Untertitel im Anrufbildschirm
    @Published private(set) var untertitel = ""
    @Published private(set) var untertitelSie = false
    private var anzeigeTakt: Timer?
    /// 📹 Videoanruf: Helfer als Live-Figur, du als kleines Bild (Frontkamera); sie sieht dich bei Seh-Fragen
    @Published private(set) var video = false
    let augen = HelferAugen()
    weak var videoWeb: WKWebView?
    private var videoZustand = ""

    var helferURL: URL? {
        guard let v = Verbindung.laden(), let basis = NXClient(v).url("") else { return nil }
        let k = v.schluessel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v.schluessel
        return URL(string: basis.absoluteString + "/?k=" + k + "#helfer")
    }

    func videoUmschalten() {
        video.toggle()
        gespraech?.augen = video ? augen : nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if video {
            Task { await augen.starten() }
            if !lautsprecher { lautsprecherUmschalten() }        // wie FaceTime: Video = Lautsprecher
        } else {
            augen.stoppen()
            videoWeb = nil
            if lautsprecher { lautsprecherUmschalten() }
        }
    }

    private let registrierung = PKPushRegistry(queue: .main)
    private let anbieter: CXProvider
    private let steuerung = CXCallController()
    private var aktiv: (uuid: UUID, text: String, von: String)?
    private var gespraech: AnrufGespraech?

    override init() {
        let k = CXProviderConfiguration()
        k.supportsVideo = true
        k.maximumCallsPerCallGroup = 1
        k.supportedHandleTypes = [.generic]
        k.iconTemplateImageData = UIImage(systemName: "person.wave.2.fill")?.pngData()
        anbieter = CXProvider(configuration: k)
        super.init()
        anbieter.setDelegate(self, queue: .main)
    }

    func starten() {
        registrierung.delegate = self
        registrierung.desiredPushTypes = [.voIP]
    }

    static var voipToken: String? {
        get { Gemeinsam.defaults.string(forKey: "voip_token") }
        set { Gemeinsam.defaults.set(newValue, forKey: "voip_token") }
    }

    /// Zeichen beim PC anmelden (beim Start und nach jeder neuen Verbindung)
    func anmelden() async {
        guard let t = Self.voipToken, let v = Verbindung.laden() else { return }
        #if DEBUG
        let umgebung = "development"
        #else
        let umgebung = "production"
        #endif
        _ = try? await NXClient(v, zeitlimit: 15).post("/api/apns/geraet", ["token": t, "umgebung": umgebung, "art": "voip",
                                                                         "name": UIDevice.current.name + " (Anruf)"])
    }

    fileprivate func eingehend(_ info: [AnyHashable: Any], fertig: @escaping () -> Void) {
        let a = info["anruf"] as? [String: Any] ?? [:]
        let von = a["von"] as? String ?? "Dein Helfer"
        anrufer = von
        let text = a["text"] as? String ?? "Ich wollte dir kurz was sagen."
        let uuid = UUID()
        aktiv = (uuid, text, von)
        let u = CXCallUpdate()
        u.remoteHandle = CXHandle(type: .generic, value: von)
        u.localizedCallerName = "\(von) · NitraX"
        u.hasVideo = false
        u.supportsHolding = false
        u.supportsDTMF = false
        anbieter.reportNewIncomingCall(with: uuid, update: u) { _ in fertig() }
    }

    /// 📞 Anruf, den das iPhone selbst geplant hat (ohne VoIP-Push): als echter CallKit-Anruf melden;
    /// annehmen = gleich abheben (der Nutzer hat die Klingel-Mitteilung schon angenommen)
    func lokal(von: String, text: String, annehmen: Bool) {
        eingehend(["anruf": ["von": von, "text": text.isEmpty ? "Du wolltest, dass ich dich anrufe – hier bin ich!" : text]]) { [weak self] in
            Task { @MainActor in
                guard annehmen, let self, let a = self.aktiv else { return }
                self.steuerung.request(CXTransaction(action: CXAnswerCallAction(call: a.uuid))) { _ in }
            }
        }
    }

    private var videoGewuenscht = false

    /// 📞 Du rufst den Helfer an (wie ein normaler ausgehender Anruf; video = gleich als Videoanruf)
    func anrufen(video: Bool = false) {
        if aktiv != nil && !imGespraech { aktiv = nil }                 // hängengebliebener alter Anruf
        guard aktiv == nil, !imGespraech else { return }
        let name = Gemeinsam.defaults.string(forKey: "helfer_name") ?? "Dein Helfer"
        let uuid = UUID()
        anrufer = name
        videoGewuenscht = video
        aktiv = (uuid, Stimmvorrat.gruesse.randomElement()!, name)
        let a = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
        a.isVideo = video
        a.contactIdentifier = name
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        steuerung.request(CXTransaction(action: a)) { fehler in
            if fehler != nil { Task { @MainActor in self.aktiv = nil } }
        }
    }

    func auflegen() {
        guard let a = aktiv else { return }
        steuerung.request(CXTransaction(action: CXEndCallAction(call: a.uuid))) { _ in }
    }

    /// 🔊 Hörmuschel ⇄ Lautsprecher (wie beim normalen Telefonieren)
    func lautsprecherUmschalten() {
        lautsprecher.toggle()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(lautsprecher ? .speaker : .none)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 🎙 Stumm: über CallKit (dann stimmt auch die Anzeige auf dem Sperrbildschirm)
    func stummUmschalten() {
        guard let a = aktiv else { return }
        steuerung.request(CXTransaction(action: CXSetMutedCallAction(call: a.uuid, muted: !stumm))) { _ in }
    }
}

extension AnrufDienst: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate cred: PKPushCredentials, for type: PKPushType) {
        let t = cred.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            AnrufDienst.voipToken = t
            await self.anmelden()
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                                  completion: @escaping () -> Void) {
        let info = payload.dictionaryPayload
        // iOS verlangt: jeder VoIP-Push MUSS sofort als Anruf gemeldet werden
        MainActor.assumeIsolated { self.eingehend(info, fertig: completion) }
    }
}

extension AnrufDienst: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.gespraech?.beenden(); self.gespraech = nil; self.imGespraech = false; self.aktiv = nil; self.seit = nil }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])   // Hörmuschel wie beim Telefonieren
            self.lautsprecher = false
            self.stumm = false
            self.seit = Date()
            self.imGespraech = true
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            self.lautsprecher = false
            self.stumm = false
            self.seit = nil
            self.verbindet = true                                  // es klingelt – abheben, sobald der PC bereit ist (didActivate)
            self.ausgehend = action.callUUID
            self.anbieterRef = provider
            self.imGespraech = true
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.gespraech?.beenden()
            self.gespraech = nil
            self.freizeichen?.stop(); self.freizeichen = nil
            self.verbindet = false
            self.ausgehend = nil
            self.anzeigeTakt?.invalidate()
            self.anzeigeTakt = nil
            self.pegel = 0
            self.welle = Array(repeating: 0, count: 48)
            self.helferSpricht = false
            if self.video { self.video = false; self.augen.stoppen(); self.videoWeb = nil }
            self.aktiv = nil
            self.imGespraech = false
            self.seit = nil
            action.fulfill()
        }
    }

    /// Erst jetzt gehört uns der Ton - Gespräch starten
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            guard let a = self.aktiv, let v = Verbindung.laden() else { return }
            if self.verbindet {
                // 🔔 Freizeichen, während der PC aufwacht (Stimme + Sprachmodell laden) – höchstens 40 s, dann hebt sie trotzdem ab
                if let u = Bundle.main.url(forResource: "freizeichen", withExtension: "wav"), let p = try? AVAudioPlayer(contentsOf: u) {
                    p.numberOfLoops = -1; p.volume = 0.7; p.play(); self.freizeichen = p
                }
                let c = NXClient(v, zeitlimit: 45)
                var vor: [String: Any] = ["sprache": "de", "geraet": true]
                if let st = Gemeinsam.defaults.string(forKey: "helfer_stimme") { vor["stimme"] = st }
                if let m = Gemeinsam.defaults.string(forKey: "helfer_modell") { vor["modell"] = m }
                let start = Date()
                _ = try? await c.post("/api/anruf/vorbereiten", vor, zeit: 40)
                // mindestens einmal klingeln lassen (wirkt echter), dann abheben
                let rest = 2.2 - Date().timeIntervalSince(start)
                if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
                self.freizeichen?.stop(); self.freizeichen = nil
                guard self.verbindet, self.aktiv?.uuid == a.uuid else { return }          // inzwischen aufgelegt
                self.verbindet = false
                self.seit = Date()
                if let id = self.ausgehend { self.anbieterRef?.reportOutgoingCall(with: id, connectedAt: Date()) }
                self.ausgehend = nil
            }
            if let alt = self.gespraech { alt.beenden(); self.gespraech = nil }          // nie ein altes Gespräch weiterlaufen lassen
            let g = AnrufGespraech(client: NXClient(v, zeitlimit: 60), begruessung: a.text)
            g.aufgelegt = { [weak self] in self?.auflegen() }
            g.untertitel = { [weak self] t, sie in self?.untertitel = t; self?.untertitelSie = sie }
            self.untertitel = ""
            g.gefuehl = { [weak self] name in
                guard let self, self.video else { return }
                self.videoWeb?.evaluateJavaScript("window.nxVideo && window.nxVideo.gefuehl('\(name)')", completionHandler: nil)
            }
            if self.video { g.augen = self.augen }
            if self.videoGewuenscht { self.videoGewuenscht = false; if !self.video { self.videoUmschalten() } }
            self.gespraech = g
            g.starten()
            self.anzeigeTakt?.invalidate()
            self.anzeigeTakt = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let g = self.gespraech else { return }
                    let p = self.stumm ? 0 : g.eingangPegel
                    self.pegel = self.pegel * 0.5 + p * 0.5
                    self.welle.removeFirst()
                    self.welle.append(p)
                    self.helferSpricht = g.helferRedet
                    if self.video, let w = self.videoWeb {             // 📹 Mund der Figur zur Stimme
                        let z = g.helferRedet ? "sprechen" : (g.denkt ? "denken" : "hoeren")
                        var js = String(format: "window.nxVideo && window.nxVideo.pegel(%.3f);", g.ausgangPegel)
                        if z != self.videoZustand { self.videoZustand = z; js += "window.nxVideo && window.nxVideo.zustand('\(z)');" }
                        w.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            self.stumm = action.isMuted
            self.gespraech?.stumm(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in self.gespraech?.beenden(); self.gespraech = nil }
    }
}

/// Das eigentliche Telefonat: sprechen -> zuhören (mit Reinreden) -> verstehen -> Helfer antwortet -> sprechen …
@MainActor
final class AnrufGespraech: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    let client: NXClient
    let begruessung: String
    var aufgelegt: (() -> Void)?
    private let ohr = Dauergespraech()
    private var spieler: AVAudioPlayer?
    private let lokal = AVSpeechSynthesizer()          // 🗣 Rückfall: das iPhone spricht selbst, wenn die PC-Stimme nicht rechtzeitig kommt
    private var lokalSpricht = false
    /// Satz + sein Ton, der schon geladen wird, während der vorige Satz noch läuft
    private var warteschlange: [(satz: String, ton: Task<Data?, Never>)] = []
    private var chat: String?
    private var aus = false
    private var stille = 0
    private var stimme: String?
    private var helferModell: String?
    private var pcStimmeLangsam = 0
    private var fuellTon: Data?                          // »Mhm, Moment.« in IHRER Stimme (beim Abheben geholt)
    private var stromGeht = true
    private var stromFehler = 0
    private let live = LiveErkennung()                 // 🗣 Erkennung auf dem iPhone, schon während du sprichst
    private var waechter: Timer?
    private var sekunden = 0
    private let beginn = Date()
    private var protokoll: [String] = []
    /// 💬 Untertitel: (Text, spricht sie?)
    var untertitel: ((String, Bool) -> Void)?

    /// 📋 Zeitleiste (nur Technik, keine Inhalte) – geht nach dem Anruf an den PC (data/begleiter/anrufprotokoll.log)
    func log(_ t: String) {
        protokoll.append(String(format: "%6.2f s  ", Date().timeIntervalSince(beginn)) + t)
        if protokoll.count > 400 { protokoll.removeFirst() }
    }
    var eingangPegel: Float { ohr.pegel }
    var gefuehl: ((String) -> Void)?
    weak var augen: HelferAugen?
    private(set) var denkt = false
    /// Lautstärke der Helferstimme (für den Mund der Figur im Videoanruf)
    var ausgangPegel: Float {
        if let p = spieler {
            p.updateMeters()
            return max(0, min(1, (p.averagePower(forChannel: 0) + 45) / 38))
        }
        if lokalSpricht { return 0.35 + 0.3 * Float(abs(sin(Date().timeIntervalSince1970 * 9))) }
        return 0
    }
    var helferRedet: Bool { spieler != nil || lokalSpricht }
    private var ersterSatz = true

    init(client: NXClient, begruessung: String) {
        self.client = client
        self.begruessung = begruessung
        super.init()
        lokal.delegate = self
        lokal.usesApplicationAudioSession = true
    }

    func starten() {
        ohr.satzFertig = { [weak self] wav in Task { await self?.gehoert(wav) } }
        ohr.insWortGefallen = { [weak self] in self?.stillSein() }
        ohr.stilleEnde = 0.6                                     // ⚡ Satzende schneller erkennen
        let l = live
        ohr.tonSenke = { b in l.fuettern(b) }
        ohr.satzBeginnt = { [weak self] in
            guard let self else { return }
            self.log("Satz beginnt (Pegel)")
            self.live.beginnen()
            self.mitgedacht = false
        }
        live.teil = { [weak self] t in
            guard let self else { return }
            self.untertitel?(t, false)
            // ⚡ Mitdenken: ab 4 Wörtern liest das Sprachmodell deinen halben Satz schon mit (einmal je Satz)
            if !self.mitgedacht, t.split(separator: " ").count >= 4, let chat = self.chat {
                self.mitgedacht = true
                let c = self.client
                Task.detached { _ = try? await c.post("/api/begleiter/vordenken", ["chat": chat, "text": t], zeit: 30) }
            }
        }
        log("Anruf gestartet")
        // 🐕 Wächter: Mikro tot (Routenwechsel, Unterbrechung) -> sofort wieder an
        waechter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.aus else { return }
                self.sekunden += 1
                if self.sekunden % 60 == 0 {                      // ⏰ Stimme + Sprachmodell am PC wach halten
                    var vor: [String: Any] = ["sprache": "de", "geraet": true]
                    if let st = self.stimme, !st.isEmpty { vor["stimme"] = st }
                    if let m = self.helferModell, !m.isEmpty { vor["modell"] = m }
                    let c = self.client
                    Task.detached { _ = try? await c.post("/api/anruf/vorbereiten", vor, zeit: 60) }
                }
                guard !self.ohr.laeuft else { return }
                self.log("Wächter: Mikro lief nicht (phase \(self.ohr.phase)) – starte neu")
                self.ohr.stoppen()
                do { try self.ohr.starten(sitzung: false); self.log("Mikro neu gestartet") } catch { self.log("Mikro-Start fehlgeschlagen: \(error.localizedDescription)") }
            }
        }
        Task {
            // 👋 Begrüßung SOFORT – aus dem Vorrat in ihrer Stimme (kein Warten auf den PC), erst danach der Rest
            stimme = Gemeinsam.defaults.string(forKey: "helfer_stimme")
            sagen([begruessung])
            do { try ohr.starten(sitzung: false); log("Mikro gestartet") } catch { log("Mikro-Start fehlgeschlagen: \(error.localizedDescription)") }
            fuellTon = Stimmvorrat.daten(Stimmvorrat.fueller[0], stimme)
            await live.erlaubnisHolen()
            log("iPhone-Erkennung: \(live.bereit ? (live.offline ? "bereit (offline)" : "bereit (online)") : "nicht verfügbar – PC erkennt")")
            let b = try? await client.get("/api/begleiter", JSONWert.self)
            if let st = b?["einst"]?["stimme"]?.text { stimme = st; Gemeinsam.defaults.set(st, forKey: "helfer_stimme") }
            helferModell = b?["einst"]?["modell"]?.text ?? Gemeinsam.defaults.string(forKey: "helfer_modell")
            // ⚡ PC vorbereiten: Bildmodelle raus, schnelle Stimme + HELFER-Modell laden (vorher: falsche Sprache -> Fish, falsches Modell -> Qwen 27B)
            let vorbereitet = Task.detached { [client, stimme, helferModell] in
                var vor: [String: Any] = ["sprache": "de", "geraet": true]
                if let stimme, !stimme.isEmpty { vor["stimme"] = stimme }
                if let helferModell, !helferModell.isEmpty { vor["modell"] = helferModell }
                _ = try? await client.post("/api/anruf/vorbereiten", vor, zeit: 180)
            }
            // ⚡ eigener, schlanker Telefonat-Chat (der große Helfer-Chat mit allem Verlauf machte jede Antwort langsam);
            // er erscheint im Gesprächsverlauf, das Gedächtnis des Helfers gilt trotzdem
            var neu: [String: Any] = ["art": "begleiter"]
            if let m = b?["einst"]?["modell"]?.text, !m.isEmpty { neu["modell"] = m }
            if let c = try? await client.post("/api/chats", neu), let id = c["id"]?.text {
                chat = id
                _ = try? await client.post("/api/chats/\(id)/aendern", ["titel": "📞 Telefonat " + Date().formatted(date: .abbreviated, time: .shortened)])
                // ⚡ Anfang (Anweisungen, ~4600 Token) schon einlesen, sobald das Modell bereit ist -> erste Antwort 0,6 s statt 5 s
                Task.detached { [client] in
                    _ = await vorbereitet.value
                    _ = try? await client.post("/api/begleiter/vordenken", ["chat": id], zeit: 60)
                }
            } else if let c = try? await client.post("/api/begleiter/chat", [:]) { chat = c["id"]?.text }
            if let n = b?["einst"]?["name"]?.text, !n.isEmpty { Gemeinsam.defaults.set(n, forKey: "helfer_name") }
            if fuellTon == nil {
                Task { [weak self] in
                    _ = await vorbereitet.value
                    guard let self, !self.aus else { return }
                    self.fuellTon = await self.tonHolen(Stimmvorrat.fueller[0])
                }
            }
        }
    }

    func stumm(_ an: Bool) {
        ohr.taub = an                                    // Mikro aus, ihre Stimme läuft weiter
    }

    func beenden() {
        guard !aus else { return }
        aus = true
        waechter?.invalidate()
        live.abbrechen()
        log("Anruf beendet")
        let zeilen = protokoll, c = client
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        Task.detached { _ = try? await c.post("/api/begleiter/anrufprotokoll", ["zeilen": zeilen, "version": version], zeit: 20) }
        Task { @MainActor in try? await Task.sleep(for: .seconds(3)); await Stimmvorrat.auffuellen(c) }
        ohr.stoppen()
        spieler?.stop()
        spieler = nil
        lokal.stopSpeaking(at: .immediate)
        for e in warteschlange { e.ton.cancel() }
        warteschlange.removeAll()
    }

    private func stillSein() {
        for e in warteschlange { e.ton.cancel() }
        warteschlange.removeAll()
        spieler?.stop()
        spieler = nil
        if lokalSpricht { lokal.stopSpeaking(at: .immediate); lokalSpricht = false }
        ohr.helferZustand = "hoeren"
    }

    private var redet: Bool { spieler != nil || lokalSpricht || laedt }
    private var laedt = false

    private func sagen(_ saetze: [String]) {
        for s in saetze.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where s.count > 1 {
            let t = Task { [weak self] () -> Data? in await self?.tonHolen(s) }           // sofort laden (parallel zum Sprechen)
            warteschlange.append((s, t))
        }
        if !redet { Task { await naechster() } }
    }

    private func naechster() async {
        guard !aus, !warteschlange.isEmpty else { if !redet { ohr.helferZustand = "ruhe" }; return }
        let (satz, holen) = warteschlange.removeFirst()
        ohr.helferZustand = "sprechen"
        laedt = true
        let tTon = Date()
        let ton = await holen.value
        laedt = false
        log(String(format: "Ton für Satz bereit nach %.2f s (%@)", Date().timeIntervalSince(tTon), ton == nil ? "keiner → iPhone-Stimme" : "\(ton!.count / 1000) KB"))
        untertitel?(satz, true)
        guard !aus else { return }
        if let ton, let p = try? AVAudioPlayer(data: ton) {
            p.isMeteringEnabled = true
            spieler = p
            p.delegate = self
            p.play()
        } else {
            lokalSprechen(satz)
        }
    }

    /// Ton eines Satzes in IHRER Stimme: schnelle Stimme (ganzer Satz als PCM -> WAV, ~1 s), sonst mp3
    private func tonHolen(_ satz: String) async -> Data? {
        if let d = Stimmvorrat.daten(satz, stimme) { log("Stimme aus dem Vorrat (sofort)"); return d }
        if stromGeht, let anfrage = stromAnfrage(satz) {
            for versuch in 1...2 {
                let t = Date()
                do {
                    let (d, resp) = try await URLSession.shared.data(for: anfrage)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200, d.count > 2004 {
                        let rate = d.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                        if rate >= 8000 && rate <= 96000 {
                            log(String(format: "Stimme (Strom) %.2f s, %d KB", Date().timeIntervalSince(t), d.count / 1000))
                            stromFehler = 0
                            let w = Self.wav(pcm: d.dropFirst(4), rate: rate)
                            Stimmvorrat.merken(w, satz, stimme)
                            return w
                        }
                    }
                    log(String(format: "Stimme (Strom) HTTP %d nach %.2f s (Versuch %d)", code, Date().timeIntervalSince(t), versuch))
                    if code == 409 { break }                        // kein Streaming am PC
                } catch {
                    log(String(format: "Stimme (Strom) Fehler nach %.2f s: %@ (Versuch %d)", Date().timeIntervalSince(t), error.localizedDescription, versuch))
                }
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(600))
            }
            stromFehler += 1
            if stromFehler >= 3 { stromGeht = false }
        }
        if Task.isCancelled || pcStimmeLangsam >= 3 { return nil }
        return await pcTon(satz)
    }

    /// 16-bit-PCM mono -> WAV-Datei (für AVAudioPlayer)
    static func wav(pcm: Data, rate: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let n = UInt32(pcm.count - pcm.count % 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + n); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(n)
        d.append(pcm.prefix(Int(n)))
        return d
    }

    private func stromAnfrage(_ satz: String) -> URLRequest? {
        var body: [String: Any] = ["text": satz, "sprache": "de"]
        if let stimme, !stimme.isEmpty { body["stimme"] = stimme }
        guard let url = client.url("/api/anruf/sprechen_strom"), let daten = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = daten
        r.timeoutInterval = 50                           // kalte Stimme braucht bis ~30 s – lieber warten als fremde Stimme
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, w) in client.cookieKopf { r.setValue(w, forHTTPHeaderField: k) }
        return r
    }

    /// Satz von der PC-Stimme (mp3) – nil, wenn sie nicht in 20 s (erster Satz: 35 s) liefert
    private func pcTon(_ satz: String) async -> Data? {
        var body: [String: Any] = ["text": satz, "sprache": "de"]
        if let stimme, !stimme.isEmpty { body["stimme"] = stimme }
        body["schnell"] = true
        guard let url = client.url("/api/anruf/sprechen"), let daten = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = daten
        r.timeoutInterval = ersterSatz ? 60 : 40
        ersterSatz = false
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, w) in client.cookieKopf { r.setValue(w, forHTTPHeaderField: k) }
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode ?? 500 < 400, d.count > 200 else { pcStimmeLangsam += 1; return nil }
            pcStimmeLangsam = 0
            return d
        } catch {
            pcStimmeLangsam += 1
            return nil
        }
    }

    private func lokalSprechen(_ satz: String) {
        let u = AVSpeechUtterance(string: satz)
        u.voice = AVSpeechSynthesisVoice(language: "de-DE")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        lokalSpricht = true
        lokal.speak(u)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.spieler = nil
            await self.naechster()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.lokalSpricht = false
            await self.naechster()
        }
    }

    private func gehoert(_ wav: Data) async {
        defer { ohr.weiter() }
        guard !aus else { return }
        let t0 = Date()
        var text = await live.beenden()
        if text.count > 1 {
            log(String(format: "iPhone erkannt in %.2f s (%d Zeichen)", Date().timeIntervalSince(t0), text.count))
        } else {
            // Rückfall: PC-Erkennung (Whisper)
            log("iPhone-Erkennung leer – frage den PC (\(wav.count / 32000) s Ton)")
            guard let r = try? await client.hochladen("/api/anruf/hoeren", daten: wav, dateiname: "anruf.wav", typ: "audio/wav", felder: ["sprache": "German"]) else {
                log("PC-Erkennung fehlgeschlagen")
                sagen(["Ich hab dich gerade nicht verstanden, sag das bitte nochmal."])
                return
            }
            text = (r["text"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            log(String(format: "PC erkannt in %.2f s (%d Zeichen)", Date().timeIntervalSince(t0), text.count))
        }
        guard text.count > 1 else {
            stille += 1
            return
        }
        untertitel?(text, false)
        if text.lowercased().range(of: #"\b(tschüss|tschüs|ciao|bis dann|bis später|ich leg auf|leg auf|auflegen|gute nacht)\b"#, options: .regularExpression) != nil {
            sagen(["Alles klar, bis gleich!"])
            try? await Task.sleep(for: .seconds(2.5))
            aufgelegt?()
            return
        }
        guard let chat else { sagen(["Moment, ich bin gleich wieder da."]); return }
        var nachricht = "(Ihr telefoniert gerade – er hat dich angerufen bzw. abgehoben. Antworte kurz, natürlich gesprochen, 1-3 Sätze, ohne Emojis.)\n" + text
        var bilder: [String] = []
        if let augen, augen.laeuft {
            nachricht = "(Videoanruf: ihr seht euch gerade.) " + nachricht
            // 👁 Seh-Fragen: aktuelles Kamerabild mitschicken (nicht bei jedem Satz – das würde jede Antwort verlangsamen)
            if text.lowercased().range(of: #"\b(siehst|sieh|schau|guck|zeig|erkennst|wie seh|wie find|was hab ich|was halte|kamera|hier|das da|dieses|diese)\b"#, options: .regularExpression) != nil,
               let jpeg = augen.verarbeitung.jpeg(kante: 768), !jpeg.isEmpty,
               let r = try? await client.hochladen("/api/chat/upload", daten: jpeg, dateiname: "video.jpg", typ: "image/jpeg"),
               let name = r["name"]?.text {
                bilder = [name]
                nachricht = "(Videoanruf: angehängt ist, was seine Kamera gerade zeigt – beziehe dich darauf.) " + nachricht
            }
        }
        denkt = true
        defer { denkt = false }
        // 💬 kurzer Laut, wenn das Nachdenken dauert (sonst wirkt die Leitung tot)
        let fueller = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled, !self.redet else { return }
            if let d = self.fuellTon, let p = try? AVAudioPlayer(data: d) {
                p.isMeteringEnabled = true
                p.delegate = self
                self.spieler = p
                p.play()
            }
        }
        // Satz für Satz sprechen, sobald er fertig ist (nicht erst nach der ganzen Antwort)
        antwortGanz = ""
        antwortGesprochen = 0
        let tFrage = Date()
        let body: [String: Any] = ["text": nachricht, "modus": "begleiter", "bilder": bilder,
                                   // gedaechtnis aus: genau wie beim Vorlesen -> der Anfang liegt schon im Zwischenspeicher (0,6 s statt 5 s)
                                   "werkzeuge": ["web": false, "bild": false, "gedaechtnis": false, "denken": "aus"]]
        let lauf = Task { @MainActor [weak self] () -> String? in
            guard let self else { return nil }
            var ersterText = true
            do {
                for try await ev in self.client.strom("/api/chats/\(chat)/senden", body) {
                    if Task.isCancelled { return "abgebrochen" }
                    switch ev["t"]?.text ?? "" {
                    case "text":
                        if ersterText { ersterText = false; self.log(String(format: "erstes Wort vom Sprachmodell nach %.2f s", Date().timeIntervalSince(tFrage))) }
                        self.antwortGanz += ev["d"]?.text ?? ""
                        let s = self.fertigeSaetze(false)
                        if !s.isEmpty { fueller.cancel(); self.sagen(s) }
                    case "zurueck":
                        let n = min(Int(ev["n"]?.zahl ?? 0), self.antwortGanz.count - self.antwortGesprochen)
                        if n > 0 { self.antwortGanz = String(self.antwortGanz.dropLast(n)) }
                    default: break
                    }
                }
                return nil
            } catch {
                return Task.isCancelled ? "abgebrochen" : error.localizedDescription
            }
        }
        // ⏱ hängt die Antwort (PC beschäftigt), nach 30 s abbrechen – sonst hörte das Mikro nie wieder zu
        let grenze = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.log("Antwort hängt > 30 s – breche ab")
            lauf.cancel()
        }
        let fehler = await lauf.value
        grenze.cancel()
        fueller.cancel()
        if let fehler {
            log("Antwort-Strom: \(fehler)")
            sagen(["Oh, da hat gerade die Verbindung gewackelt – sag das bitte nochmal."])
            return
        }
        let rest = fertigeSaetze(true)
        if !rest.isEmpty { sagen(rest) } else if antwortGesprochen == 0 { sagen(["Hm, da ist mir gerade nichts eingefallen – sag das bitte nochmal."]) }
    }

    private var mitgedacht = false
    private var antwortGanz = ""
    private var antwortGesprochen = 0

    private func fertigeSaetze(_ ende: Bool) -> [String] {
        let rest = String(antwortGanz.dropFirst(antwortGesprochen))
        var aus: [String] = [], start = rest.startIndex, i = rest.startIndex
        while i < rest.endIndex {
            let z = rest[i]
            let naechstes = rest.index(after: i)
            if ".!?".contains(z) && (naechstes == rest.endIndex ? ende : rest[naechstes].isWhitespace) {
                aus.append(String(rest[start...i]))
                start = naechstes
            }
            i = naechstes
        }
        if ende, start < rest.endIndex { aus.append(String(rest[start...])) }
        antwortGesprochen += rest.distance(from: rest.startIndex, to: ende ? rest.endIndex : start)
        for roh in aus {                                   // [freude] & Co. -> Gesicht der Figur im Videoanruf
            if let r = roh.range(of: #"\[([a-zäöü]+)\]"#, options: .regularExpression) {
                gefuehl?(String(roh[r]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            }
        }
        return aus.map { SiriHilfe.sprechbar($0) }.filter { $0.count > 1 }
    }
}
