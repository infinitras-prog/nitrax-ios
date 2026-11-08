import Foundation
import AppIntents

/// 🧍 Stand des Helfers für Widget, Sperrbildschirm und Kontrollzentrum (App Group). Die App schreibt ihn etwa jede Minute.
struct HelferStand: Codable {
    var name: String
    var stufe: String          // »Freunde«, »Gute Freunde« …
    var stimmung: Double       // 0 … 1
    var punkte: Int
    var bis: Int
    var gespraeche: Int
    var zeit: Date

    static let schluessel = "helfer_stand"

    static func laden() -> HelferStand? {
        guard let d = Gemeinsam.defaults.data(forKey: schluessel) else { return nil }
        return try? JSONDecoder().decode(HelferStand.self, from: d)
    }

    func speichern() {
        if let d = try? JSONEncoder().encode(self) { Gemeinsam.defaults.set(d, forKey: HelferStand.schluessel) }
    }

    var emoji: String {
        switch stimmung {
        case ..<0.25: return "😔"
        case ..<0.45: return "😐"
        case ..<0.65: return "🙂"
        case ..<0.85: return "😊"
        default: return "🥰"
        }
    }

    var stimmungText: String {
        switch stimmung {
        case ..<0.25: return "vermisst dich"
        case ..<0.45: return "ist nachdenklich"
        case ..<0.65: return "ist entspannt"
        case ..<0.85: return "ist gut drauf"
        default: return "ist glücklich"
        }
    }

    var fortschritt: Double { bis > 0 ? min(1, Double(punkte) / Double(bis)) : 0 }
}

/// Öffnet NitraX beim Helfer und lässt ihn sofort zuhören (Kontrollzentrum, Sperrbildschirm, Aktionstaste).
/// Liegt in App und Widget-Erweiterung; die App liest das Merkzeichen beim Aktivwerden.
struct HelferOeffnenIntent: AppIntent {
    static var title: LocalizedStringResource = "Helfer öffnen"
    static var description = IntentDescription("Öffnet deinen 3D-Helfer und hört dir sofort zu.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        Gemeinsam.defaults.set(Date().timeIntervalSince1970, forKey: "helfer_oeffnen")
        return .result()
    }
}
