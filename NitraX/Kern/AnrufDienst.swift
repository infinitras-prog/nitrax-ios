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

    func auflegen() {
        guard let a = aktiv else { return }
        steuerung.request(CXTransaction(action: CXEndCallAction(call: a.uuid))) { _ in }
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
            try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
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

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in self.gespraech?.beenden() }
    }
}

/// Das eigentliche Telefonat: sprechen -> zuhören (mit Reinreden) -> verstehen -> Helfer antwortet -> sprechen …
@MainActor
final class AnrufGespraech: NSObject, AVAudioPlayerDelegate {
    let client: NXClient
    let begruessung: String
    var aufgelegt: (() -> Void)?
    private let ohr = Dauergespraech()
    private var spieler: AVAudioPlayer?
    private var warteschlange: [String] = []
    private var chat: String?
    private var aus = false
    private var stille = 0
    private var stimme: String?

    init(client: NXClient, begruessung: String) {
        self.client = client
        self.begruessung = begruessung
    }

    func starten() {
        ohr.satzFertig = { [weak self] wav in Task { await self?.gehoert(wav) } }
        ohr.insWortGefallen = { [weak self] in self?.stillSein() }
        Task {
            if let c = try? await client.post("/api/begleiter/chat", [:]) { chat = c["id"]?.text }
            if let b = try? await client.get("/api/begleiter", JSONWert.self) { stimme = b["einst"]?["stimme"]?.text }
            sagen([begruessung])
            try? ohr.starten(sitzung: false)
        }
    }

    func beenden() {
        aus = true
        ohr.stoppen()
        spieler?.stop()
        spieler = nil
    }

    private func stillSein() {
        warteschlange.removeAll()
        spieler?.stop()
        spieler = nil
        ohr.helferZustand = "hoeren"
    }

    private func sagen(_ saetze: [String]) {
        warteschlange += saetze.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if spieler == nil { Task { await naechster() } }
    }

    private func naechster() async {
        guard !aus, !warteschlange.isEmpty else { ohr.helferZustand = "ruhe"; return }
        let satz = warteschlange.removeFirst()
        ohr.helferZustand = "sprechen"
        var body: [String: Any] = ["text": satz, "sprache": "de"]
        if let stimme, !stimme.isEmpty { body["stimme"] = stimme }
        guard let url = client.url("/api/anruf/sprechen"), let daten = try? JSONSerialization.data(withJSONObject: body) else { await naechster(); return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = daten
        r.timeoutInterval = 60
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, w) in client.cookieKopf { r.setValue(w, forHTTPHeaderField: k) }
        guard let (ton, _) = try? await URLSession.shared.data(for: r), !aus, let p = try? AVAudioPlayer(data: ton) else { await naechster(); return }
        spieler = p
        p.delegate = self
        p.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.spieler = nil
            await self.naechster()
        }
    }

    private func gehoert(_ wav: Data) async {
        defer { ohr.weiter() }
        guard !aus, let r = try? await client.hochladen("/api/anruf/hoeren", daten: wav, dateiname: "anruf.wav", typ: "audio/wav", felder: ["sprache": "German"]) else { return }
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
        guard let chat else { return }
        var ganz = ""
        let nachricht = "(Ihr telefoniert gerade – er hat dich angerufen bzw. abgehoben. Antworte kurz, natürlich gesprochen, 1-3 Sätze, ohne Emojis.)\n" + text
        do {
            for try await ev in client.strom("/api/chats/\(chat)/senden", ["text": nachricht, "modus": "begleiter",
                                                                           "werkzeuge": ["web": true, "bild": true, "gedaechtnis": true, "denken": "aus"]]) {
                switch ev["t"]?.text ?? "" {
                case "text": ganz += ev["d"]?.text ?? ""
                case "zurueck": ganz = String(ganz.dropLast(min(Int(ev["n"]?.zahl ?? 0), ganz.count)))
                default: break
                }
            }
        } catch { ganz = "Oh, da hat gerade die Verbindung gewackelt – sag das bitte nochmal." }
        let sauber = SiriHilfe.sprechbar(ganz)
        let saetze = sauber.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) + "." }.filter { $0.count > 2 }
        sagen(saetze.isEmpty ? [sauber] : saetze)
    }
}
