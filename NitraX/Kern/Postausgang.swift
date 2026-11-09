import Foundation
import UserNotifications

/// 📮 Liste Nr. 12: Offline-Warteschlange – ist der PC nicht erreichbar, wird ein Auftrag gemerkt und startet von selbst,
/// sobald der PC wieder da ist (Studio.aktualisieren erfolgreich).
enum Postausgang {
    private static let schluessel = "postausgang"

    struct Brief: Codable { let wf: String; let name: String; let felder: Data; let zeit: Date }

    static var anzahl: Int { liste().count }

    private static func liste() -> [Brief] {
        guard let d = Gemeinsam.defaults.data(forKey: schluessel) else { return [] }
        return (try? JSONDecoder().decode([Brief].self, from: d)) ?? []
    }

    private static func sichern(_ l: [Brief]) {
        Gemeinsam.defaults.set(try? JSONEncoder().encode(l), forKey: schluessel)
    }

    static func merken(wf: String, name: String, felder: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: felder) else { return }
        sichern(liste() + [Brief(wf: wf, name: name, felder: d, zeit: Date())])
    }

    private static var laeuft = false

    /// PC wieder da: alles der Reihe nach starten
    @MainActor
    static func abarbeiten(_ c: NXClient) async -> Int {
        guard !laeuft else { return 0 }
        laeuft = true
        defer { laeuft = false }
        var rest: [Brief] = [], n = 0
        for b in liste() {
            guard let felder = try? JSONSerialization.jsonObject(with: b.felder) as? [String: Any] else { continue }
            if (try? await c.post("/api/handy/start", ["wf": b.wf, "felder": felder], zeit: 300)) != nil { n += 1 } else { rest.append(b) }
        }
        sichern(rest)
        if n > 0 {
            let inhalt = UNMutableNotificationContent()
            inhalt.title = "📮 PC wieder da"
            inhalt.body = n == 1 ? "Dein gemerkter Auftrag läuft jetzt." : "\(n) gemerkte Aufträge laufen jetzt."
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "postausgang-\(Date().timeIntervalSince1970)", content: inhalt, trigger: nil))
        }
        return n
    }
}

/// 💬 Liste Nr. 11: aus einer Mitteilung antworten – der Text geht an den Helfer (mit Bezug auf den Auftrag), ihre Antwort kommt
/// als neue Mitteilung zurück. Läuft im Hintergrund (iOS gibt dafür ~30 s).
enum MitteilungsAntwort {
    static let aktion = UNTextInputNotificationAction(identifier: "antworten", title: "💬 Antworten", options: [],
                                                      textInputButtonTitle: "Senden", textInputPlaceholder: "z. B. mach's heller")

    static func senden(_ text: String, info: [AnyHashable: Any]) async {
        guard let v = Verbindung.laden() else { return }
        let c = NXClient(v, zeitlimit: 25)
        var nachricht = text
        if let id = info["auftrag"] as? String {
            nachricht = "(Er antwortet auf die Mitteilung zu Auftrag \(id). Wenn er etwas geändert haben will, gib es als Auftrag an die Werkstatt.) " + text
        }
        guard let h = try? await c.post("/api/begleiter/chat", [:]), let chat = h["id"]?.text else { return }
        var ganz = ""
        do {
            for try await ev in c.strom("/api/chats/\(chat)/senden", ["text": nachricht, "modus": "begleiter"]) {
                if ev["t"]?.text == "text" { ganz += ev["d"]?.text ?? "" }
            }
        } catch {}
        let sauber = ganz.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let inhalt = UNMutableNotificationContent()
        inhalt.title = Gemeinsam.defaults.string(forKey: "helfer_name") ?? "Dein Helfer"
        inhalt.body = sauber.isEmpty ? "Hab's bekommen – ich kümmere mich drum." : String(sauber.prefix(240))
        inhalt.userInfo = ["helfer": 1]
        inhalt.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "antwort-\(Date().timeIntervalSince1970)", content: inhalt, trigger: nil))
    }
}
