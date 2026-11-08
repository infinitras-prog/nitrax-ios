import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity eines laufenden Auftrags (Sperrbildschirm + Dynamic Island). Der PC aktualisiert sie per Push
/// (apns_nx.aktivitaet_tick) - die Schlüssel von ContentState müssen dort gleich heißen: fortschritt, stufe, rest, status.
struct AuftragAttribute: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var fortschritt: Double
        var stufe: String
        var rest: Double?
        var status: String
    }
    var id: String
    var titel: String
    var art: String
    var symbol: String
}
#endif
