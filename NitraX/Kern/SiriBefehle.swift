import AppIntents
import Foundation

/// 🗣 Siri & Kurzbefehle: »Frag NitraX«, »Wie weit ist NitraX«, »Erstelle mit NitraX …«, »Male mit NitraX …«,
/// »Pausiere NitraX« / »NitraX weitermachen«. Läuft ohne die App zu öffnen - direkt mit dem PC.
enum SiriHilfe {
    static func client() throws -> NXClient {
        guard let v = Verbindung.laden() else {
            throw NSError(domain: "NitraX", code: 1, userInfo: [NSLocalizedDescriptionKey: "NitraX ist noch nicht mit deinem PC verbunden. Öffne die App und scanne den QR-Code."])
        }
        return NXClient(v, zeitlimit: 25)
    }

    /// Nachricht an einen Chat schicken und die fertige Antwort einsammeln (Ereignisstrom bis »ende«)
    static func antwort(_ c: NXClient, chat: String, text: String, werkzeuge: [String: Any], modus: String? = nil) async throws -> String {
        var t = ""
        var body: [String: Any] = ["text": text, "werkzeuge": werkzeuge]
        if let modus { body["modus"] = modus }
        for try await ev in c.strom("/api/chats/\(chat)/senden", body) {
            switch ev["t"]?.text ?? "" {
            case "text": t += ev["d"]?.text ?? ""
            case "zurueck": t = String(t.dropLast(min(Int(ev["n"]?.zahl ?? 0), t.count)))
            case "fehler": throw NSError(domain: "NitraX", code: 2, userInfo: [NSLocalizedDescriptionKey: ev["d"]?.text ?? "Fehler"])
            default: break
            }
        }
        return sprechbar(t)
    }

    /// Siri liest vor: Markdown, Links, Gefühls-/Aktionsmarken des Helfers ([freude], [oeffne:…], [pc:…]),
    /// Regieanweisungen (*lächelt*) und Emojis raus - sonst liest Siri »Klammer freude« oder Emoji-Namen vor.
    static func sprechbar(_ t: String) -> String {
        var s = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]{0,240}\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*[^*\n]{1,60}\*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[#>*-]+\s*"#, with: "", options: .regularExpression)
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            !(u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value > 0x238C)
              || u.value == 0xFE0F || u.value == 0x200D || (0x1F3FB...0x1F3FF).contains(u.value))
        }))
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([.,!?])"#, with: "$1", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Ich habe gerade keine Antwort bekommen." : String(s.prefix(700))
    }

    static func helfer(_ frage: String) async throws -> String {
        let c = try client()
        let r = try await c.post("/api/begleiter/chat", [:])
        guard let id = r["id"]?.text else { throw NXFehler.antwort }
        // modus »begleiter« = derselbe Helfer wie in der App (Persönlichkeit, Gedächtnis, Programmlage)
        return try await antwort(c, chat: id, text: "(Du siehst gerade: er spricht über Siri mit dir, ohne Bildschirm – antworte in ein bis drei kurzen, gesprochenen Sätzen, ohne Listen, ohne Emojis)\n" + frage,
                                 werkzeuge: ["web": true, "bild": false, "gedaechtnis": true, "denken": "aus"], modus: "begleiter")
    }

    /// Workflow-Agent in einem eigenen »Siri«-Chat (bleibt erhalten, damit Rückfragen weitergehen)
    static func agent(_ auftrag: String) async throws -> String {
        let c = try client()
        var id = Gemeinsam.defaults.string(forKey: "siri_chat")
        var gueltig = false
        if let vorhanden = id { gueltig = (try? await c.get("/api/chats/\(vorhanden)", JSONWert.self)) != nil }
        if !gueltig {
            id = try await c.post("/api/chats", ["art": "werkstatt"])["id"]?.text
            Gemeinsam.defaults.set(id, forKey: "siri_chat")
        }
        guard let id else { throw NXFehler.antwort }
        return try await antwort(c, chat: id, text: auftrag + "\n\n(Über Siri: Aufträge nur anlegen, NICHT auf das Ergebnis warten. Antworte in ein bis zwei kurzen Sätzen.)",
                                 werkzeuge: ["web": true, "bild": true, "gedaechtnis": true, "denken": "aus"])
    }

    static func status() async throws -> String {
        let s = try await client().stand()
        let lauf = s.auftraege.filter { $0.laeuft }
        let wart = s.auftraege.filter { $0.wartet }.count
        if !s.fremd.isEmpty && lauf.isEmpty { return "Am PC läuft gerade \(s.fremd.joined(separator: ", ")) – NitraX wartet, bis die Grafikkarte frei ist." }
        guard !lauf.isEmpty else {
            if let f = s.auftraege.filter({ $0.fertig }).max(by: { ($0.finished ?? 0) < ($1.finished ?? 0) }) {
                return wart > 0 ? "Gerade rechnet nichts, \(wart) warten. Zuletzt fertig: \(f.titel)." : "Alles ruhig. Zuletzt fertig: \(f.titel)."
            }
            return "Gerade rechnet nichts."
        }
        let teile = lauf.prefix(2).map { a in
            "\(a.artName) \(a.titel): \(Int(a.progress)) Prozent" + (a.eta.map { ", noch etwa \(Zeit.dauer($0).replacingOccurrences(of: "min", with: "Minuten").replacingOccurrences(of: " s", with: " Sekunden"))" } ?? "")
        }
        return teile.joined(separator: ". ") + (wart > 0 ? ". Danach warten noch \(wart)." : ".")
    }
}

struct HelferFragen: AppIntent {
    static var title: LocalizedStringResource = "Helfer fragen"
    static var description = IntentDescription("Stellt deinem NitraX-Helfer eine Frage und liest dir die Antwort vor.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Frage", requestValueDialog: IntentDialog("Was möchtest du deinen Helfer fragen?"))
    var frage: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let a = try await SiriHilfe.helfer(frage)
        return .result(value: a, dialog: "\(a)")
    }
}

/// Freihändig mit dem Helfer reden: öffnet die App beim Helfer und hört sofort zu (Erkennung am PC = genauer als Diktat)
struct HelferGespraech: AppIntent {
    static var title: LocalizedStringResource = "Mit dem Helfer sprechen"
    static var description = IntentDescription("Öffnet deinen 3D-Helfer und hört dir sofort zu.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Navigation.shared.reiter = .helfer
        Navigation.shared.helferZuhoeren = true
        return .result()
    }
}

struct StudioStatus: AppIntent {
    static var title: LocalizedStringResource = "Studio-Status"
    static var description = IntentDescription("Sagt dir, was NitraX gerade rechnet und wie lange es noch dauert.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let t = try await SiriHilfe.status()
        return .result(value: t, dialog: "\(t)")
    }
}

struct AuftragAnNitraX: AppIntent {
    static var title: LocalizedStringResource = "Auftrag an NitraX"
    static var description = IntentDescription("Der Workflow-Agent legt an, was du beschreibst – Video, Bild, Song, Musikvideo, Film …")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Was soll entstehen?", requestValueDialog: IntentDialog("Was soll NitraX erstellen?"))
    var auftrag: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let t = try await SiriHilfe.agent(auftrag)
        return .result(dialog: "\(t)")
    }
}

struct BildErstellen: AppIntent {
    static var title: LocalizedStringResource = "Bild erstellen"
    static var description = IntentDescription("Malt ein Bild nach deiner Beschreibung – du bekommst eine Mitteilung, wenn es fertig ist.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Beschreibung", requestValueDialog: IntentDialog("Was soll auf dem Bild sein?"))
    var beschreibung: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try SiriHilfe.client()
        _ = try await c.post("/api/handy/start", ["wf": "x-t2i", "felder": ["prompt": beschreibung]], zeit: 60)
        return .result(dialog: "Ich male das Bild – du bekommst eine Mitteilung, sobald es fertig ist.")
    }
}

struct WarteschlangeAnhalten: AppIntent {
    static var title: LocalizedStringResource = "Warteschlange anhalten"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await SiriHilfe.client().post("/api/queue/pause")
        return .result(dialog: "Die Warteschlange ist angehalten – der laufende Auftrag wird noch fertig.")
    }
}

struct WarteschlangeFortsetzen: AppIntent {
    static var title: LocalizedStringResource = "Warteschlange fortsetzen"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await SiriHilfe.client().post("/api/queue/resume")
        return .result(dialog: "NitraX rechnet weiter.")
    }
}

/// 📞 »Hey Siri, ruf NitraX an« – dein Helfer hebt sofort ab
struct HelferAnrufen: AppIntent {
    static var title: LocalizedStringResource = "Helfer anrufen"
    static var description = IntentDescription("Ruft deinen NitraX-Helfer an – wie ein normales Telefonat.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try? await Task.sleep(for: .milliseconds(400))
        AnrufDienst.shared.anrufen()
        return .result()
    }
}

/// 📹 »Hey Siri, Videoanruf mit NitraX«
struct HelferVideoanruf: AppIntent {
    static var title: LocalizedStringResource = "Videoanruf mit dem Helfer"
    static var description = IntentDescription("Startet einen Videoanruf mit deinem NitraX-Helfer.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try? await Task.sleep(for: .milliseconds(400))
        AnrufDienst.shared.anrufen(video: true)
        return .result()
    }
}

// MARK: - ⚡ Runde 3, Nr. 9: mehr Kurzbefehle (auch für Automationen in der Kurzbefehle-App)

struct VideoErstellen: AppIntent {
    static var title: LocalizedStringResource = "Video erstellen"
    static var description = IntentDescription("Erstellt ein Video nach deiner Beschreibung – du bekommst eine Mitteilung, wenn es fertig ist.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Beschreibung", requestValueDialog: IntentDialog("Was soll im Video passieren?"))
    var beschreibung: String

    @Parameter(title: "Länge (Sekunden)", default: 5, inclusiveRange: (3, 10))
    var laenge: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try SiriHilfe.client()
        _ = try await c.post("/api/handy/start", ["wf": "x-t2v", "felder": ["idee": beschreibung, "laenge": laenge]], zeit: 120)
        return .result(dialog: "Das Video ist in Arbeit – ich melde mich, wenn es fertig ist.")
    }
}

struct WasIstFertig: AppIntent {
    static var title: LocalizedStringResource = "Was ist fertig geworden?"
    static var description = IntentDescription("Nennt dir die Ergebnisse der letzten Stunden.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Zeitraum (Stunden)", default: 12, inclusiveRange: (1, 72))
    var stunden: Int

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let s = try await SiriHilfe.client().stand()
        let seit = Date().timeIntervalSince1970 - Double(stunden) * 3600
        let l = s.auftraege.filter { $0.fertig && ($0.finished ?? 0) > seit }.sorted { ($0.finished ?? 0) > ($1.finished ?? 0) }
        guard !l.isEmpty else { return .result(value: 0, dialog: "In den letzten \(stunden) Stunden ist nichts fertig geworden.") }
        let namen = l.prefix(3).map { "\($0.artName) »\($0.titel)«" }.joined(separator: ", ")
        return .result(value: l.count, dialog: "\(l.count) fertig: \(namen)\(l.count > 3 ? " und mehr" : "").")
    }
}

/// ❤ Ein Favorit als Vorlage (für »Starte meine Lieblingsvorlage«)
struct FavoritVorlage: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Lieblingsvorlage"
    static var defaultQuery = FavoritAbfrage()
    var id: String
    var titel: String
    var art: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(titel)", subtitle: "\(art)") }
}

struct FavoritAbfrage: EntityQuery {
    private func alle() async throws -> [FavoritVorlage] {
        let s = try await SiriHilfe.client().stand()
        return s.auftraege.filter { $0.fav && $0.fertig && $0.wiederholbar }.sorted { ($0.finished ?? 0) > ($1.finished ?? 0) }
            .prefix(20).map { FavoritVorlage(id: $0.id, titel: $0.titel, art: $0.artName) }
    }
    func entities(for identifiers: [String]) async throws -> [FavoritVorlage] { try await alle().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [FavoritVorlage] { try await alle() }
}

struct FavoritStarten: AppIntent {
    static var title: LocalizedStringResource = "Lieblingsvorlage starten"
    static var description = IntentDescription("Macht eine neue Variante eines deiner Favoriten – gleiche Einstellungen, neuer Zufall.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Favorit", requestValueDialog: IntentDialog("Welchen Favoriten?"))
    var favorit: FavoritVorlage

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await SiriHilfe.client().post("/api/handy/start", ["wf": "_variante", "felder": ["id": favorit.id]], zeit: 120)
        return .result(dialog: "Neue Variante von »\(favorit.titel)« läuft.")
    }
}

struct NitraXKurzbefehle: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: HelferAnrufen(), phrases: ["Ruf \(.applicationName) an", "Anruf mit \(.applicationName)",
                                                        "Telefoniere mit \(.applicationName)", "\(.applicationName) anrufen"],
                    shortTitle: "Helfer anrufen", systemImageName: "phone.fill")
        AppShortcut(intent: HelferVideoanruf(), phrases: ["Videoanruf mit \(.applicationName)", "\(.applicationName) Videoanruf"],
                    shortTitle: "Videoanruf", systemImageName: "video.fill")
        AppShortcut(intent: HelferGespraech(), phrases: ["Sprich mit \(.applicationName)", "Rede mit \(.applicationName)",
                                                          "\(.applicationName) Helfer", "Öffne meinen Helfer in \(.applicationName)"],
                    shortTitle: "Mit Helfer sprechen", systemImageName: "waveform")
        AppShortcut(intent: HelferFragen(), phrases: ["Frag \(.applicationName)", "Frag meinen Helfer in \(.applicationName)",
                                                       "Eine Frage an \(.applicationName)"],
                    shortTitle: "Helfer fragen", systemImageName: "person.wave.2")
        AppShortcut(intent: StudioStatus(), phrases: ["Wie weit ist \(.applicationName)", "Status von \(.applicationName)",
                                                       "Was rechnet \(.applicationName)"],
                    shortTitle: "Status", systemImageName: "gauge.with.dots.needle.67percent")
        AppShortcut(intent: AuftragAnNitraX(), phrases: ["Erstelle mit \(.applicationName)", "Auftrag an \(.applicationName)"],
                    shortTitle: "Auftrag", systemImageName: "wand.and.stars")
        AppShortcut(intent: BildErstellen(), phrases: ["Male mit \(.applicationName)", "Bild mit \(.applicationName)"],
                    shortTitle: "Bild erstellen", systemImageName: "photo")
        AppShortcut(intent: WarteschlangeAnhalten(), phrases: ["Pausiere \(.applicationName)"],
                    shortTitle: "Anhalten", systemImageName: "pause.circle")
        AppShortcut(intent: WarteschlangeFortsetzen(), phrases: ["\(.applicationName) weitermachen"],
                    shortTitle: "Fortsetzen", systemImageName: "play.circle")
        AppShortcut(intent: FavoritStarten(), phrases: ["Starte meine Lieblingsvorlage in \(.applicationName)", "\(.applicationName) Lieblingsvorlage"],
                    shortTitle: "Lieblingsvorlage", systemImageName: "heart.fill")
    }
}
