import Foundation
#if !NX_ERWEITERUNG
import UIKit
#endif

enum NXFehler: LocalizedError {
    case keineVerbindung
    case server(Int, String)
    case antwort

    var errorDescription: String? {
        switch self {
        case .keineVerbindung: return "Dein PC ist nicht erreichbar. Läuft NitraX AI Studio und ist der Handy-Zugang an?"
        case .server(let code, let text):
            if code == 403 { return text.isEmpty ? "Zugang verweigert – bitte den QR-Code neu scannen." : text }
            // 💬 verständlich statt Technik
            if text.contains("Loading model") { return "Das Sprachmodell am PC lädt gerade noch – in ein paar Sekunden nochmal versuchen." }
            if code == 503 { return text.isEmpty ? "Der PC ist gerade beschäftigt (lädt oder rechnet) – gleich nochmal versuchen." : text }
            if code == 502 || code == 504 { return "NitraX am PC antwortet gerade nicht – läuft das Programm noch?" }
            if code == 413 { return "Die Datei ist zu groß für den Handy-Zugang." }
            return text.isEmpty ? "Fehler \(code)" : text
        case .antwort: return "Unerwartete Antwort vom PC."
        }
    }
}

/// Netzwerk zum NitraX-Handyzugang (Port 8296). Anmeldung wie im Browser: Cookie »nx_handy« = Schlüssel.
final class NXClient: @unchecked Sendable {
    private(set) var verbindung: Verbindung
    private let session: URLSession
    private var basis: String?

    init(_ v: Verbindung, zeitlimit: TimeInterval = 20) {
        verbindung = v
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = zeitlimit
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        basis = v.aktiv
    }

    var aktuelleBasis: String? { basis }

    /// Erste erreichbare Adresse (Heimnetz zuerst, sonst Tailscale) - kurz prüfen, dann merken.
    @discardableResult
    func basisFinden() async -> String? {
        for a in verbindung.reihenfolge {
            // kleiner Ping: Meldungen »seit fern in der Zukunft« = leere Liste, aber mit Schlüsselprüfung
            var r = anfrage(a, "/api/begleiter/meldungen?seit=9999999999")
            r.timeoutInterval = 4
            if let antwort = try? await session.data(for: r), let h = antwort.1 as? HTTPURLResponse, h.statusCode < 400 {
                basis = a
                if verbindung.aktiv != a { verbindung.aktiv = a; verbindung.speichern() }
                return a
            }
        }
        return nil
    }

    func anfrage(_ basis: String, _ pfad: String, methode: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: basis + pfad)!)
        r.httpMethod = methode
        r.setValue("nx_handy=\(verbindung.schluessel)", forHTTPHeaderField: "Cookie")
        return r
    }

    func url(_ pfad: String) -> URL? {
        guard let b = basis ?? verbindung.reihenfolge.first else { return nil }
        return URL(string: b + pfad)
    }

    var cookieKopf: [String: String] { ["Cookie": "nx_handy=\(verbindung.schluessel)"] }

    private func senden(_ pfad: String, methode: String, body: Data?, typ: String?, zeit: TimeInterval? = nil,
                        beobachter: URLSessionTaskDelegate? = nil) async throws -> Data {
        var versuche = 0
        while true {
            var gefunden = basis
            if gefunden == nil { gefunden = await basisFinden() }
            guard let b = gefunden else { throw NXFehler.keineVerbindung }
            var r = anfrage(b, pfad, methode: methode)
            if let zeit { r.timeoutInterval = zeit }
            if let body, beobachter == nil { r.httpBody = body }
            if let typ { r.setValue(typ, forHTTPHeaderField: "Content-Type") }
            do {
                let (d, resp): (Data, URLResponse)
                if let body, let beobachter { (d, resp) = try await session.upload(for: r, from: body, delegate: beobachter) }
                else { (d, resp) = try await session.data(for: r) }
                guard let h = resp as? HTTPURLResponse else { throw NXFehler.antwort }
                if h.statusCode >= 400 { throw NXFehler.server(h.statusCode, String(data: d, encoding: .utf8) ?? "") }
                return d
            } catch let e as URLError where versuche == 0 && [.cannotConnectToHost, .timedOut, .networkConnectionLost,
                                                              .notConnectedToInternet, .cannotFindHost].contains(e.code) {
                versuche += 1
                basis = nil                                  // andere Adresse probieren (z. B. unterwegs über Tailscale)
            } catch let e as URLError {
                if e.code == .cancelled { throw e }
                #if !NX_ERWEITERUNG
                Fehlerbericht.shared.melden("Netz", "\(methode) \(pfad.prefix(80)) -> \(e.code.rawValue) \(e.localizedDescription)")
                #endif
                throw NXFehler.keineVerbindung
            } catch let NXFehler.server(code, text) {
                #if !NX_ERWEITERUNG
                if code >= 500 { Fehlerbericht.shared.melden("Server", "\(methode) \(pfad.prefix(80)) -> \(code) \(text.prefix(160))") }
                #endif
                throw NXFehler.server(code, text)
            }
        }
    }

    func roh(_ pfad: String) async throws -> Data { try await senden(pfad, methode: "GET", body: nil, typ: nil) }

    func get<T: Decodable>(_ pfad: String, _ t: T.Type) async throws -> T {
        let d = try await senden(pfad, methode: "GET", body: nil, typ: nil)
        return try JSONDecoder().decode(T.self, from: d)
    }

    @discardableResult
    func post(_ pfad: String, _ body: [String: Any] = [:], zeit: TimeInterval? = nil) async throws -> JSONWert {
        let daten = try JSONSerialization.data(withJSONObject: body)
        let d = try await senden(pfad, methode: "POST", body: daten, typ: "application/json", zeit: zeit)
        return (try? JSONDecoder().decode(JSONWert.self, from: d)) ?? .nichts
    }

    /// Datei hochladen (Feld »datei«) -> Antwort des PCs, z. B. {"name": "autoi2v_….png"}
    func hochladen(_ pfad: String, daten: Data, dateiname: String, typ: String, felder: [String: String] = [:],
                   fortschritt: (@Sendable (Double) -> Void)? = nil) async throws -> JSONWert {
        let grenze = "nx-" + UUID().uuidString
        var body = Data()
        for (k, v) in felder {
            body.append("--\(grenze)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(grenze)\r\nContent-Disposition: form-data; name=\"datei\"; filename=\"\(dateiname)\"\r\nContent-Type: \(typ)\r\n\r\n".data(using: .utf8)!)
        body.append(daten)
        body.append("\r\n--\(grenze)--\r\n".data(using: .utf8)!)
        #if !NX_ERWEITERUNG
        // ⏳ große Uploads laufen weiter, auch wenn man kurz die App wechselt (iOS gibt dafür einige Minuten)
        let hintergrund = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "NitraX-Upload") }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(hintergrund) } }
        #endif
        let d = try await senden(pfad, methode: "POST", body: body, typ: "multipart/form-data; boundary=\(grenze)", zeit: 600,
                                 beobachter: fortschritt.map { UploadBeobachter($0) })
        return (try? JSONDecoder().decode(JSONWert.self, from: d)) ?? .nichts
    }

    /// Ereignisstrom (Chat): jede Zeile »data: {…}« als JSONWert
    func strom(_ pfad: String, _ body: [String: Any]) -> AsyncThrowingStream<JSONWert, Error> {
        AsyncThrowingStream { fortsetzung in
            let aufgabe = Task {
                do {
                    var gefunden = self.basis
                    if gefunden == nil { gefunden = await self.basisFinden() }
                    guard let b = gefunden else { throw NXFehler.keineVerbindung }
                    var r = self.anfrage(b, pfad, methode: "POST")
                    r.httpBody = try JSONSerialization.data(withJSONObject: body)
                    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    r.timeoutInterval = 4 * 3600
                    let (bytes, resp) = try await self.session.bytes(for: r)
                    if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                        var t = ""
                        for try await z in bytes.lines { t += z }
                        throw NXFehler.server(h.statusCode, t)
                    }
                    for try await zeile in bytes.lines {
                        guard zeile.hasPrefix("data:") else { continue }
                        let json = zeile.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let d = json.data(using: .utf8), let w = try? JSONDecoder().decode(JSONWert.self, from: d) {
                            fortsetzung.yield(w)
                        }
                    }
                    fortsetzung.finish()
                } catch {
                    fortsetzung.finish(throwing: error)
                }
            }
            fortsetzung.onTermination = { _ in aufgabe.cancel() }
        }
    }

    func stand() async throws -> StudioStand { try await get("/api/state", StudioStand.self) }
}


/// 📤 meldet, wie viel vom Upload schon beim PC ist (0…1)
final class UploadBeobachter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let melden: @Sendable (Double) -> Void
    init(_ melden: @escaping @Sendable (Double) -> Void) { self.melden = melden }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        melden(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
