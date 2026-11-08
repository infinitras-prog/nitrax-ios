import Foundation

/// Gemeinsamer Speicher von App und Widget (App Group).
enum Gemeinsam {
    static let gruppe = "group.de.infinitras.nitrax"
    static var defaults: UserDefaults { UserDefaults(suiteName: gruppe) ?? .standard }
}

/// Zugang zum PC: eine oder mehrere Adressen (Heimnetz, Tailscale) und der geheime Schlüssel aus dem QR-Code.
struct Verbindung: Codable, Equatable {
    var adressen: [String]
    var schluessel: String
    var aktiv: String?

    static func laden() -> Verbindung? {
        guard let d = Gemeinsam.defaults.data(forKey: "verbindung") else { return nil }
        return try? JSONDecoder().decode(Verbindung.self, from: d)
    }

    func speichern() {
        if let d = try? JSONEncoder().encode(self) { Gemeinsam.defaults.set(d, forKey: "verbindung") }
    }

    static func loeschen() { Gemeinsam.defaults.removeObject(forKey: "verbindung") }

    /// QR-Link aus NitraX AI Studio (Einstellungen → Handy), z. B. »http://192.168.1.20:8296/?k=…« -> Verbindung.
    static func ausLink(_ text: String) -> Verbindung? {
        let roh = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: roh),
              let k = c.queryItems?.first(where: { $0.name == "k" })?.value, !k.isEmpty,
              let schema = c.scheme?.lowercased(), schema == "http" || schema == "https",
              c.host != nil else { return nil }
        c.query = nil
        c.fragment = nil
        c.path = ""
        guard let basis = c.url?.absoluteString else { return nil }
        return Verbindung(adressen: [basis], schluessel: k, aktiv: basis)
    }

    /// Weitere Adresse aufnehmen (z. B. die Tailscale-Adresse für unterwegs), gleicher Schlüssel.
    mutating func dazu(_ andere: Verbindung) {
        for a in andere.adressen where !adressen.contains(a) { adressen.append(a) }
        schluessel = andere.schluessel
    }

    var reihenfolge: [String] {
        var l = adressen
        if let a = aktiv, let i = l.firstIndex(of: a) { l.remove(at: i); l.insert(a, at: 0) }
        return l
    }
}
