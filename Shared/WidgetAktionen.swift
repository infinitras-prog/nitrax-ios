import AppIntents
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 🔘 Runde 3, Nr. 10: Knöpfe im Widget – laufen direkt (ohne die App zu öffnen), nur »Anrufen« öffnet sie.
enum WidgetHilfe {
    static func client() throws -> NXClient {
        guard let v = Verbindung.laden() else {
            throw NSError(domain: "NitraX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Noch nicht mit dem PC verbunden"])
        }
        return NXClient(v, zeitlimit: 20)
    }

    /// neuester fertiger Auftrag, von dem sich eine Variante machen lässt
    static func letzterWiederholbarer(_ c: NXClient) async throws -> Auftrag? {
        let s = try await c.stand()
        return s.auftraege.filter { $0.fertig && $0.wiederholbar }.max { ($0.finished ?? 0) < ($1.finished ?? 0) }
    }

    static func neuZeichnen() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

struct WidgetAnrufen: AppIntent {
    static var title: LocalizedStringResource = "Helfer anrufen (Widget)"
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        Gemeinsam.defaults.set(Date().timeIntervalSince1970, forKey: "anruf_oeffnen")
        return .result()
    }
}

struct WidgetVariante: AppIntent {
    static var title: LocalizedStringResource = "Neue Variante vom letzten Ergebnis"
    static var description = IntentDescription("Startet eine neue Variante deines zuletzt fertigen Ergebnisses.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try WidgetHilfe.client()
        guard let a = try await WidgetHilfe.letzterWiederholbarer(c) else { return .result(dialog: "Ich finde gerade kein Ergebnis für eine Variante.") }
        _ = try await c.post("/api/handy/start", ["wf": "_variante", "felder": ["id": a.id]], zeit: 120)
        Gemeinsam.defaults.set("🎲 Variante von »\(a.titel)« läuft", forKey: "widget_meldung")
        WidgetHilfe.neuZeichnen()
        return .result(dialog: "Neue Variante von »\(a.titel)« läuft.")
    }
}

struct WidgetWarteschlange: AppIntent {
    static var title: LocalizedStringResource = "Warteschlange anhalten/fortsetzen"
    static var description = IntentDescription("Hält die Warteschlange an – oder setzt sie fort, wenn sie schon steht.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try WidgetHilfe.client()
        let s = try await c.get("/api/handy/schaetzung", JSONWert.self)
        let pausiert = s["pausiert"]?.wahr ?? false
        _ = try await c.post(pausiert ? "/api/queue/resume" : "/api/queue/pause")
        Gemeinsam.defaults.set(!pausiert, forKey: "widget_pausiert")
        Gemeinsam.defaults.set(pausiert ? "▶ Warteschlange läuft weiter" : "⏸ Warteschlange angehalten", forKey: "widget_meldung")
        WidgetHilfe.neuZeichnen()
        return .result(dialog: pausiert ? "NitraX rechnet weiter." : "Warteschlange angehalten – der laufende Auftrag wird noch fertig.")
    }
}
