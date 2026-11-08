import Foundation
import UserNotifications
import BackgroundTasks
import WidgetKit

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
                senden(id: "fertig-\(a.id)", titel: "✓ \(a.artName) fertig", text: a.titel, ziel: a.id)
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
