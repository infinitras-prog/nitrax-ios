import Foundation

/// Kurzer Stand für Widget und Benachrichtigungen (im gemeinsamen Speicher der App Group).
struct Schnappschuss: Codable {
    struct Eintrag: Codable, Hashable {
        var id: String
        var titel: String
        var art: String
        var symbol: String
        var status: String
        var fortschritt: Double
        var stufe: String
        var rest: Double?
    }
    var zeit: Date
    var erreichbar: Bool
    var laufend: [Eintrag]
    var wartend: Int
    var zuletztFertig: Eintrag?
    var gpu: Int?

    static let schluessel = "schnappschuss"

    static func laden() -> Schnappschuss? {
        guard let d = Gemeinsam.defaults.data(forKey: schluessel) else { return nil }
        return try? JSONDecoder().decode(Schnappschuss.self, from: d)
    }

    func speichern() {
        if let d = try? JSONEncoder().encode(self) { Gemeinsam.defaults.set(d, forKey: Schnappschuss.schluessel) }
    }

    static func aus(_ s: StudioStand) -> Schnappschuss {
        func e(_ a: Auftrag) -> Eintrag {
            Eintrag(id: a.id, titel: a.titel, art: a.artName, symbol: a.symbol, status: a.status, fortschritt: a.progress,
                    stufe: a.stage, rest: a.eta)
        }
        let lauf = s.auftraege.filter { $0.laeuft }.sorted { $0.created < $1.created }
        let fertig = s.auftraege.filter { $0.fertig }.max { ($0.finished ?? 0) < ($1.finished ?? 0) }
        return Schnappschuss(zeit: Date(), erreichbar: true, laufend: lauf.prefix(3).map(e),
                             wartend: s.auftraege.filter { $0.wartet }.count, zuletztFertig: fertig.map(e), gpu: s.gpuAuslastung)
    }
}
