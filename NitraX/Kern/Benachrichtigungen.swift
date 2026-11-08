import Foundation
import UserNotifications
import BackgroundTasks
import WidgetKit
import UIKit

/// Mitteilungen: Auftrag fertig/fehlgeschlagen und Meldungen des Helfers - im Vordergrund aus dem 3-s-Abgleich, im
/// Hintergrund über BGAppRefresh (iOS entscheidet, wann; meist alle 15-60 min).
enum Benachrichtigungen {
    static let aufgabe = "de.infinitras.nitrax.abholen"
    private static let statusSchluessel = "letzte_status"
    private static let meldungSchluessel = "meldungen_seit"

    static func erlaubnisHolen() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            if ok { Push.registrieren() }                     // echte Push-Mitteilungen über Apple
        }
    }

    static var an: Bool {
        get { Gemeinsam.defaults.object(forKey: "mitteilungen_an") as? Bool ?? true }
        set { Gemeinsam.defaults.set(newValue, forKey: "mitteilungen_an") }
    }

    /// Statuswechsel seit dem letzten Abgleich -> Mitteilungen
    static func vergleichen(_ s: StudioStand) {
        let alt = Gemeinsam.defaults.dictionary(forKey: statusSchluessel) as? [String: String] ?? [:]
        let pushAktiv = Push.aktiv                        // dann meldet der PC selbst (sonst käme alles doppelt)
        var neu: [String: String] = [:]
        for a in s.auftraege where a.offen || a.fertig || a.gescheitert {
            neu[a.id] = a.status
            guard !pushAktiv, let vorher = alt[a.id], vorher != a.status, ["läuft", "wartet", "angehalten"].contains(vorher) else { continue }
            if a.fertig {
                let kat = a.hatVideo ? "NX_VIDEO" : (a.bilderAnzahl > 0 ? "NX_BILD" : "NX_AUFTRAG")
                let bild: String? = a.bilderAnzahl > 0 ? "/api/img/file/\(a.id)/0" : (a.hatVideo ? "/api/begleiter/ergebnis/\(a.id)" : nil)
                let titel = "✓ \(a.artName) fertig", text = a.titel, ziel = a.id
                Task { await sendenMitBild(id: "fertig-\(ziel)", titel: titel, text: text, ziel: ziel, kategorie: kat, bild: bild) }
            } else if a.status == "fehler" {
                senden(id: "fehler-\(a.id)", titel: "⚠ \(a.artName) fehlgeschlagen", text: a.fehler ?? a.titel, ziel: a.id)
            }
        }
        // nur die letzten Aufträge merken (Speicher klein halten)
        let behalten = s.auftraege.sorted { $0.created > $1.created }.prefix(150).map(\.id)
        Gemeinsam.defaults.set(neu.filter { behalten.contains($0.key) }, forKey: statusSchluessel)
    }

    /// Meldungen des Helfers (Erinnerungen, »bin fertig«, Grüße) seit dem letzten Abholen
    static func helferAbholen(_ c: NXClient) async {
        let seit = Gemeinsam.defaults.double(forKey: meldungSchluessel)
        guard let r = try? await c.get("/api/begleiter/meldungen?seit=\(seit)", JSONWert.self) else { return }
        if let jetzt = r["jetzt"]?.zahl { Gemeinsam.defaults.set(jetzt, forKey: meldungSchluessel) }
        guard seit > 0, !Push.aktiv else { return }          // erstes Abholen: nur Zeitpunkt merken; mit Push meldet der PC selbst
        let name = r["name"]?.text ?? "Dein Helfer"
        for m in (r["meldungen"]?.liste ?? []).suffix(3) {
            let id = m["id"]?.text ?? UUID().uuidString
            senden(id: "helfer-\(id)", titel: m["titel"]?.text ?? name, text: m["text"]?.text ?? "", ziel: nil, helfer: true)
        }
    }

    static func senden(id: String, titel: String, text: String, ziel: String?, helfer: Bool = false) {
        guard an else { return }
        let inhalt = UNMutableNotificationContent()
        inhalt.title = titel
        inhalt.body = text
        inhalt.sound = .default
        inhalt.threadIdentifier = helfer ? "helfer" : "auftraege"
        if let ziel { inhalt.userInfo = ["auftrag": ziel] }
        if helfer { inhalt.userInfo = ["helfer": true] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: inhalt, trigger: nil))
    }

    // MARK: 🖼 Vorschaubild + Schnellaktionen (Variante, Schärfen, 2× größer)

    static func kategorienEinrichten() {
        let variante = UNNotificationAction(identifier: "variante", title: "🎲 Neue Variante", options: [])
        let schaerfen = UNNotificationAction(identifier: "schaerfen", title: "💎 Maximal schärfen", options: [])
        let groesser = UNNotificationAction(identifier: "groesser", title: "⤢ 2× größer", options: [])
        let filmlook = UNNotificationAction(identifier: "filmlook", title: "🎞 Film-Look", options: [])
        let oeffnen = UNNotificationAction(identifier: "oeffnen", title: "Ansehen", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "NX_BILD", actions: [variante, groesser, oeffnen], intentIdentifiers: []),
            UNNotificationCategory(identifier: "NX_VIDEO", actions: [variante, schaerfen, filmlook, oeffnen], intentIdentifiers: []),
            UNNotificationCategory(identifier: "NX_AUFTRAG", actions: [variante, oeffnen], intentIdentifiers: []),
        ])
    }

    /// Schnellaktion aus der Mitteilung - läuft im Hintergrund, Ergebnis als kurze Mitteilung
    static func aktion(_ art: String, auftrag id: String) async {
        guard let v = Verbindung.laden() else { return }
        let c = NXClient(v, zeitlimit: 60)
        do {
            switch art {
            case "variante": _ = try await c.post("/api/handy/start", ["wf": "_variante", "felder": ["id": id]], zeit: 120)
            case "groesser": _ = try await c.post("/api/handy/start", ["wf": "_hoch", "felder": ["id": id + ":0", "ziel": "2x"]], zeit: 120)
            case "schaerfen": _ = try await c.post("/api/jobs/\(id)/maximal")
            case "filmlook": _ = try await c.post("/api/jobs/\(id)/realismus")
            default: return
            }
            let t = ["variante": "🎲 Neue Variante läuft", "groesser": "⤢ Wird vergrößert", "schaerfen": "💎 Wird maximal geschärft",
                     "filmlook": "🎞 Film-Look läuft"][art] ?? "Läuft"
            senden(id: "aktion-\(id)-\(art)", titel: t, text: "NitraX meldet sich, wenn es fertig ist.", ziel: id)
        } catch {
            senden(id: "aktion-\(id)-\(art)", titel: "⚠ Ging gerade nicht", text: error.localizedDescription, ziel: id)
        }
    }

    static func sendenMitBild(id: String, titel: String, text: String, ziel: String?, kategorie: String, bild: String?) async {
        guard an else { return }
        let inhalt = UNMutableNotificationContent()
        inhalt.title = titel
        inhalt.body = text
        inhalt.sound = .default
        inhalt.threadIdentifier = "auftraege"
        inhalt.categoryIdentifier = kategorie
        if let ziel { inhalt.userInfo = ["auftrag": ziel] }
        if let bild, let v = Verbindung.laden() {
            let c = NXClient(v, zeitlimit: 15)
            if let url = c.url(bild) {
                var r = URLRequest(url: url)
                for (k, w) in c.cookieKopf { r.setValue(w, forHTTPHeaderField: k) }
                if let (d, antwort) = try? await URLSession.shared.data(for: r), (antwort as? HTTPURLResponse)?.statusCode == 200 {
                    let datei = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                    let klein = UIImage(data: d).flatMap { b -> Data? in
                        let f = min(1, 900 / max(b.size.width, b.size.height))
                        let g = CGSize(width: b.size.width * f, height: b.size.height * f)
                        return UIGraphicsImageRenderer(size: g).image { _ in b.draw(in: CGRect(origin: .zero, size: g)) }.jpegData(compressionQuality: 0.8)
                    } ?? d
                    if (try? klein.write(to: datei)) != nil, let a = try? UNNotificationAttachment(identifier: "bild", url: datei) {
                        inhalt.attachments = [a]
                    }
                }
            }
        }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: inhalt, trigger: nil))
    }

    // MARK: Hintergrund

    static func planen() {
        let r = BGAppRefreshTaskRequest(identifier: aufgabe)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Im Hintergrund: Stand holen, vergleichen, Widget auffrischen, Helfer-Meldungen abholen
    static func imHintergrund() async {
        planen()
        guard let v = Verbindung.laden() else { return }
        let c = NXClient(v, zeitlimit: 12)
        if let s = try? await c.stand() {
            vergleichen(s)
            Schnappschuss.aus(s).speichern()
            WidgetCenter.shared.reloadAllTimelines()
        }
        await helferAbholen(c)
    }
}
