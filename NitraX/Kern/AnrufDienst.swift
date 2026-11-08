import Foundation
import PushKit
import CallKit
import AVFoundation
import UIKit

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

    private let registrierung = PKPushRegistry(queue: .main)
    private let anbieter: CXProvider
    private let steuerung = CXCallController()
    private var aktiv: (uuid: UUID, text: String, von: String)?
    private var gespraech: AnrufGespraech?

    override init() {
        let k = CXProviderConfiguration()
        k.supportsVideo = false
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
        Task { @MainActor in self.gespraech?.beenden(); self.gespraech = nil; self.imGespraech = false }
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

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.gespraech?.beenden()
            self.gespraech = nil
            self.aktiv = nil
            self.imGespraech = false
            self.seit = nil
            action.fulfill()
        }
    }

    /// Erst jetzt gehört uns der Ton - Gespräch starten
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            guard let a = self.aktiv, self.gespraech == nil, let v = Verbindung.laden() else { return }
            let g = AnrufGespraech(client: NXClient(v, zeitlimit: 60), begruessung: a.text)
            g.aufgelegt = { [weak self] in self?.auflegen() }
            self.gespraech = g
            g.starten()
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
        Task { @MainActor in self.gespraech?.beenden() }
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
    private var warteschlange: [String] = []
    private var chat: String?
    private var aus = false
    private var stille = 0
    private var stimme: String?
    private var pcStimmeLangsam = 0
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
        Task {
            if let c = try? await client.post("/api/begleiter/chat", [:]) { chat = c["id"]?.text }
            if let b = try? await client.get("/api/begleiter", JSONWert.self) { stimme = b["einst"]?["stimme"]?.text }
            // ⚡ Stimme + Sprachmodell am PC sofort laden (nach einem NitraX-Neustart dauerte die erste Antwort sonst > 1 min)
            var vor: [String: Any] = ["sprache": "German"]
            if let stimme, !stimme.isEmpty { vor["stimme"] = stimme }
            Task.detached { [client] in _ = try? await client.post("/api/anruf/vorbereiten", vor, zeit: 180) }
            sagen([begruessung])
            try? ohr.starten(sitzung: false)
        }
    }

    func stumm(_ an: Bool) {
        if an { ohr.stoppen() } else if !aus { try? ohr.starten(sitzung: false) }
    }

    func beenden() {
        aus = true
        ohr.stoppen()
        spieler?.stop()
        spieler = nil
        lokal.stopSpeaking(at: .immediate)
    }

    private func stillSein() {
        warteschlange.removeAll()
        spieler?.stop()
        spieler = nil
        if lokalSpricht { lokal.stopSpeaking(at: .immediate); lokalSpricht = false }
        ohr.helferZustand = "hoeren"
    }

    private var redet: Bool { spieler != nil || lokalSpricht || laedt }
    private var laedt = false

    private func sagen(_ saetze: [String]) {
        warteschlange += saetze.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 1 }
        if !redet { Task { await naechster() } }
    }

    private func naechster() async {
        guard !aus, !warteschlange.isEmpty else { if !redet { ohr.helferZustand = "ruhe" }; return }
        let satz = warteschlange.removeFirst()
        ohr.helferZustand = "sprechen"
        laedt = true
        let ton = pcStimmeLangsam >= 2 ? nil : await pcTon(satz)          // PC zweimal zu langsam -> nur noch lokal
        laedt = false
        guard !aus else { return }
        if let ton, let p = try? AVAudioPlayer(data: ton) {
            spieler = p
            p.delegate = self
            p.play()
        } else {
            lokalSprechen(satz)
        }
    }

    /// Satz von der PC-Stimme (mp3) – nil, wenn sie nicht in 20 s (erster Satz: 35 s) liefert
    private func pcTon(_ satz: String) async -> Data? {
        var body: [String: Any] = ["text": satz, "sprache": "de"]
        if let stimme, !stimme.isEmpty { body["stimme"] = stimme }
        guard let url = client.url("/api/anruf/sprechen"), let daten = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = daten
        r.timeoutInterval = ersterSatz ? 35 : 20
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
        guard !aus, let r = try? await client.hochladen("/api/anruf/hoeren", daten: wav, dateiname: "anruf.wav", typ: "audio/wav", felder: ["sprache": "German"]) else {
            sagen(["Ich hab dich gerade nicht verstanden, sag das bitte nochmal."])
            return
        }
        let text = (r["text"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 1 else {
            stille += 1
            return
        }
        if text.lowercased().range(of: #"\b(tschüss|tschüs|ciao|bis dann|bis später|ich leg auf|leg auf|auflegen|gute nacht)\b"#, options: .regularExpression) != nil {
            sagen(["Alles klar, bis gleich!"])
            try? await Task.sleep(for: .seconds(2.5))
            aufgelegt?()
            return
        }
        guard let chat else { sagen(["Moment, ich bin gleich wieder da."]); return }
        let nachricht = "(Ihr telefoniert gerade – er hat dich angerufen bzw. abgehoben. Antworte kurz, natürlich gesprochen, 1-3 Sätze, ohne Emojis.)\n" + text
        // 💬 kurzer Laut, wenn das Nachdenken dauert (sonst wirkt die Leitung tot)
        let fueller = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard let self, !Task.isCancelled, !self.redet else { return }
            self.lokalSprechen(["Mhm, Moment.", "Mhm, lass mich kurz überlegen.", "Moment."].randomElement()!)
        }
        // Satz für Satz sprechen, sobald er fertig ist (nicht erst nach der ganzen Antwort)
        var ganz = "", gesprochen = 0
        func fertigeSaetze(_ ende: Bool) -> [String] {
            let rest = String(ganz.dropFirst(gesprochen))
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
            gesprochen += rest.distance(from: rest.startIndex, to: ende ? rest.endIndex : start)
            return aus.map { SiriHilfe.sprechbar($0) }.filter { $0.count > 1 }
        }
        do {
            for try await ev in client.strom("/api/chats/\(chat)/senden", ["text": nachricht, "modus": "begleiter",
                                                                           "werkzeuge": ["web": true, "bild": true, "gedaechtnis": true, "denken": "aus"]]) {
                switch ev["t"]?.text ?? "" {
                case "text":
                    ganz += ev["d"]?.text ?? ""
                    let s = fertigeSaetze(false)
                    if !s.isEmpty { fueller.cancel(); sagen(s) }
                case "zurueck":
                    let n = min(Int(ev["n"]?.zahl ?? 0), ganz.count - gesprochen)
                    if n > 0 { ganz = String(ganz.dropLast(n)) }
                default: break
                }
            }
            fueller.cancel()
            let s = fertigeSaetze(true)
            if !s.isEmpty { sagen(s) } else if gesprochen == 0 { sagen(["Hm, da ist mir gerade nichts eingefallen – sag das bitte nochmal."]) }
        } catch {
            fueller.cancel()
            sagen(["Oh, da hat gerade die Verbindung gewackelt – sag das bitte nochmal."])
        }
    }
}
