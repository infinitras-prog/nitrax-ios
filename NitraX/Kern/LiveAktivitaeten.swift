import Foundation
import ActivityKit

/// Startet je laufendem Auftrag eine Live Activity (höchstens 2), hält sie aktuell solange die App offen ist und meldet
/// ihr Push-Zeichen an den PC - dann aktualisiert der PC sie auch bei geschlossener App und beendet sie bei »fertig«.
@MainActor
enum LiveAktivitaeten {
    private static var beobachtet: Set<String> = []

    static var an: Bool {
        get { Gemeinsam.defaults.object(forKey: "live_an") as? Bool ?? true }
        set { Gemeinsam.defaults.set(newValue, forKey: "live_an") }
    }

    static func abgleichen(_ s: StudioStand, client: NXClient?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let laufend = s.auftraege.filter { $0.laeuft }.sorted { $0.created > $1.created }
        let aktiv = Activity<AuftragAttribute>.activities

        for act in aktiv {
            if let a = s.auftraege.first(where: { $0.id == act.attributes.id }) {
                let z = zustand(a)
                if a.offen {
                    if act.content.state != z { Task { await act.update(ActivityContent(state: z, staleDate: Date().addingTimeInterval(15 * 60))) } }
                } else {
                    Task { await act.end(ActivityContent(state: z, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(20 * 60))) }
                }
            } else if !s.auftraege.isEmpty {
                Task { await act.end(nil, dismissalPolicy: .immediate) }
            }
        }

        guard an else { return }
        let vorhanden = Set(aktiv.map(\.attributes.id))
        for a in laufend.prefix(2) where !vorhanden.contains(a.id) {
            let attr = AuftragAttribute(id: a.id, titel: a.titel, art: a.artName, symbol: a.symbol)
            do {
                let act = try Activity.request(attributes: attr, content: ActivityContent(state: zustand(a), staleDate: nil),
                                               pushType: .token)
                beobachten(act, client: client)
            } catch {
                print("Live Activity: \(error.localizedDescription)")
            }
        }
        for act in aktiv where !beobachtet.contains(act.id) { beobachten(act, client: client) }
    }

    private static func zustand(_ a: Auftrag) -> AuftragAttribute.ContentState {
        .init(fortschritt: a.progress, stufe: a.stage, rest: a.eta, status: a.status)
    }

    /// Push-Zeichen an den PC (es kann sich ändern - jedes neue melden)
    private static func beobachten(_ act: Activity<AuftragAttribute>, client: NXClient?) {
        beobachtet.insert(act.id)
        guard let client else { return }
        Task {
            for await daten in act.pushTokenUpdates {
                let t = daten.map { String(format: "%02x", $0) }.joined()
                #if DEBUG
                let umgebung = "sandbox"
                #else
                let umgebung = "production"
                #endif
                _ = try? await client.post("/api/apns/aktivitaet", ["job": act.attributes.id, "token": t, "umgebung": umgebung])
            }
        }
    }
}
