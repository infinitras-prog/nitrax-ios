import Foundation
import MetricKit

/// 🧾 Liste Nr. 9: Fehlerbericht für die ganze App – Netzfehler (Pfad, Code, Dauer) und Abstürze/Hänger (MetricKit, kommen beim
/// nächsten Start) werden gesammelt und gebündelt an den PC geschickt (data/handy_fehler.log). Nur Technik, keine Inhalte.
final class Fehlerbericht: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Fehlerbericht()
    private let sperre = NSLock()
    private var zeilen: [String] = []
    private var zuletztGesendet = Date.distantPast

    func starten() {
        MXMetricManager.shared.add(self)
        // offene Zeilen vom letzten Mal (App beendet, bevor gesendet wurde)
        if let alt = UserDefaults.standard.stringArray(forKey: "fehler_offen") { zeilen = alt }
    }

    /// z. B. melden("Netz", "/api/state -> keine Verbindung")
    func melden(_ ort: String, _ text: String) {
        let z = Date().formatted(.dateTime.hour().minute().second()) + "  [\(ort)] " + text
        sperre.lock()
        zeilen.append(String(z.prefix(ort == "Absturz" || ort == "Hänger" ? 1600 : 380)))
        if zeilen.count > 200 { zeilen.removeFirst(zeilen.count - 200) }
        UserDefaults.standard.set(zeilen, forKey: "fehler_offen")
        sperre.unlock()
    }

    /// höchstens alle 2 Minuten, nur wenn etwas da ist
    func senden(_ c: NXClient, sofort: Bool = false) async {
        sperre.lock()
        guard !zeilen.isEmpty, sofort || Date().timeIntervalSince(zuletztGesendet) > 120 else { sperre.unlock(); return }
        let paket = zeilen
        zuletztGesendet = Date()
        sperre.unlock()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if (try? await c.post("/api/handy/fehlerbericht", ["zeilen": paket, "version": "\(version) (\(build))"], zeit: 20)) != nil {
            sperre.lock()
            zeilen.removeFirst(min(paket.count, zeilen.count))
            UserDefaults.standard.set(zeilen, forKey: "fehler_offen")
            sperre.unlock()
        }
    }

    /// Aufrufkette des betroffenen Fadens kompakt: »NitraX+0x1a2b3c < SwiftUI+0x… < …« (oberste 12 Ebenen)
    static func stapel(_ json: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let staepel = o["callStacks"] as? [[String: Any]] else { return "?" }
        let faden = staepel.first { ($0["threadAttributed"] as? Bool) == true } ?? staepel.first
        var aus: [String] = []
        var rahmen = (faden?["callStackRootFrames"] as? [[String: Any]])?.first
        while let r = rahmen, aus.count < 12 {
            let name = r["binaryName"] as? String ?? "?"
            let ab = (r["offsetIntoBinaryTextSegment"] as? NSNumber)?.intValue ?? 0
            aus.append("\(name)+0x\(String(ab, radix: 16))")
            rahmen = (r["subFrames"] as? [[String: Any]])?.first
        }
        return aus.isEmpty ? "?" : aus.joined(separator: " < ")
    }

    // MARK: MetricKit – Abstürze, Hänger, Speicher-Abbrüche (kommen gesammelt, meist beim nächsten Start)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                var grund = ""
                if #available(iOS 17.0, *), let e = c.exceptionReason { grund = " · \(e.className): \(e.composedMessage)" }
                melden("Absturz", "App \(c.applicationVersion) · Signal \(c.signal.map { "\($0)" } ?? "?") · Ausnahme \(c.exceptionType.map { "\($0)" } ?? "-")"
                       + (c.exceptionCode.map { " · Code \($0)" } ?? "") + grund + (c.terminationReason.map { " · " + $0 } ?? "")
                       + " · Stapel: " + Self.stapel(c.callStackTree.jsonRepresentation()))
            }
            for h in p.hangDiagnostics ?? [] {
                melden("Hänger", "\(h.hangDuration.formatted()) · Stapel: " + Self.stapel(h.callStackTree.jsonRepresentation()))
            }
            for d in p.diskWriteExceptionDiagnostics ?? [] { melden("Schreiblast", "\(d.totalWritesCaused.formatted())") }
            for c in p.cpuExceptionDiagnostics ?? [] { melden("Prozessor", "\(c.totalCPUTime.formatted())") }
        }
    }
}
