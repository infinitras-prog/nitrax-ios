import Foundation
import UIKit

/// 📱 Echte Push-Mitteilungen über Apple: die App meldet ihr Gerätezeichen beim PC an (/api/apns/geraet), der PC
/// schickt »Auftrag fertig«, Nachrichten des Helfers und Wecker sofort - auch wenn die App geschlossen ist.
enum Push {
    private static let tokenSchluessel = "apns_token"
    private static let aktivSchluessel = "apns_aktiv"

    static var token: String? { Gemeinsam.defaults.string(forKey: tokenSchluessel) }

    /// PC hat das Gerät angenommen UND ist eingerichtet -> lokale Mitteilungen aus dem Abgleich abschalten (sonst doppelt)
    static var aktiv: Bool { Gemeinsam.defaults.bool(forKey: aktivSchluessel) }

    static func registrieren() {
        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
    }

    static func tokenErhalten(_ daten: Data) {
        let t = daten.map { String(format: "%02x", $0) }.joined()
        Gemeinsam.defaults.set(t, forKey: tokenSchluessel)
        Task { await anmelden() }
    }

    /// Beim PC anmelden (nach jedem Start/Verbinden - der PC kann gewechselt haben)
    static func anmelden() async {
        guard let t = token, let v = Verbindung.laden() else { return }
        #if DEBUG
        let umgebung = "sandbox"
        #else
        let umgebung = "production"
        #endif
        let c = NXClient(v, zeitlimit: 10)
        let name = await MainActor.run { UIDevice.current.name }
        if let r = try? await c.post("/api/apns/geraet", ["token": t, "umgebung": umgebung, "name": name]) {
            Gemeinsam.defaults.set(r["eingerichtet"]?.wahr ?? false, forKey: aktivSchluessel)
        }
    }

    struct Stand { var eingerichtet: Bool; var geraete: [String] }

    static func stand(_ c: NXClient) async -> Stand? {
        guard let r = try? await c.get("/api/apns", JSONWert.self) else { return nil }
        let e = r["eingerichtet"]?.wahr ?? false
        Gemeinsam.defaults.set(e && token != nil, forKey: aktivSchluessel)
        return Stand(eingerichtet: e, geraete: (r["geraete"]?.liste ?? []).compactMap { $0["name"]?.text })
    }

    static func test(_ c: NXClient) async throws -> Bool {
        let r = try await c.post("/api/apns/test", [:], zeit: 30)
        return r["ok"]?.wahr ?? false
    }
}
