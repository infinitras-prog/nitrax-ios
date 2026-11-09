import Foundation
import UserNotifications
import CallKit

/// 📞 Anrufe ohne Apple-Push-Schlüssel (09.11.2026): Der PC nennt die geplanten Anrufe (»ruf mich in 5 Minuten an«),
/// das iPhone stellt sich selbst einen klingelnden Alarm. Annehmen -> echtes Anrufgespräch mit dem Helfer (CallKit,
/// Hörmuschel, Lautsprecher umschaltbar). Ist die App gerade offen, kommt direkt der Anrufbildschirm.
/// Hat der PC einen APNs-Schlüssel (push = true), ruft er selbst per VoIP an – dann wird hier nichts geplant.
enum LokaleAnrufe {
    static let kennung = "nx-anruf-"
    static let kategorie = "NX_ANRUF"
    nonisolated(unsafe) private static var zuletzt = Date.distantPast

    static func kategorie(_ liste: inout [UNNotificationCategory]) {
        let annehmen = UNNotificationAction(identifier: "annehmen", title: "📞 Annehmen", options: [.foreground])
        let ablehnen = UNNotificationAction(identifier: "ablehnen", title: "Ablehnen", options: [.destructive])
        liste.append(UNNotificationCategory(identifier: kategorie, actions: [annehmen, ablehnen], intentIdentifiers: [],
                                            options: [.customDismissAction]))
    }

    /// Geplante Anrufe vom PC holen und als Klingel-Alarme einplanen (höchstens alle 8 s, außer `sofort`)
    static func abgleichen(_ c: NXClient, sofort: Bool = false) async {
        guard sofort || Date().timeIntervalSince(zuletzt) > 8 else { return }
        zuletzt = Date()
        guard let w = try? await c.get("/api/begleiter/anrufe", JSONWert.self) else { return }
        let zentrum = UNUserNotificationCenter.current()
        let offen = await zentrum.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(kennung) }
        if w["push"]?.wahr == true {                          // PC ruft selbst an
            zentrum.removePendingNotificationRequests(withIdentifiers: offen)
            return
        }
        var soll: Set<String> = []
        for a in w["anrufe"]?.liste ?? [] {
            guard let t = a["t"]?.zahl else { continue }
            let von = a["von"]?.text ?? "Dein Helfer", text = a["text"]?.text ?? ""
            // dreimal klingeln (wie ein Anruf, der nicht aufhört): sofort, nach 28 s, nach 56 s
            let erledigt = Set(Gemeinsam.defaults.stringArray(forKey: "anrufe_erledigt") ?? [])
            for (i, versatz) in [0.0, 28, 56].enumerated() {
                var wann = t + versatz - Date().timeIntervalSince1970
                // gerade fällig (z. B. »Auftrag fertig«), aber erst jetzt abgeholt -> sofort klingeln (einmal)
                if i == 0, wann <= 0.5, wann > -90, !erledigt.contains("\(Int(t))") {
                    wann = 1
                    var e = Array(erledigt); e.append("\(Int(t))")              // nur einmal (sonst klingelt es bei jedem Abgleich neu)
                    Gemeinsam.defaults.set(Array(e.suffix(50)), forKey: "anrufe_erledigt")
                }
                guard wann > 0.5 else { continue }
                let id = "\(kennung)\(Int(t))-\(i)"
                soll.insert(id)
                if offen.contains(id) { continue }
                let inhalt = UNMutableNotificationContent()
                inhalt.title = "📞 \(von) ruft an"
                inhalt.body = i == 0 ? "Tippe zum Annehmen" : "Klingelt noch – tippe zum Annehmen"
                inhalt.sound = UNNotificationSound(named: UNNotificationSoundName("klingeln.wav"))
                inhalt.categoryIdentifier = kategorie
                inhalt.threadIdentifier = "nx-anruf"
                inhalt.interruptionLevel = .active
                inhalt.userInfo = ["nx_anruf": Int(t), "von": von, "text": text]
                let r = UNNotificationRequest(identifier: id, content: inhalt,
                                              trigger: UNTimeIntervalNotificationTrigger(timeInterval: wann, repeats: false))
                try? await zentrum.add(r)
            }
        }
        zentrum.removePendingNotificationRequests(withIdentifiers: offen.filter { !soll.contains($0) })
    }

    /// alle Klingel-Alarme dieses Anrufs weg (angenommen / abgelehnt)
    static func beenden(_ t: Int) {
        var e = Gemeinsam.defaults.stringArray(forKey: "anrufe_erledigt") ?? []
        e.append("\(t)"); Gemeinsam.defaults.set(Array(e.suffix(50)), forKey: "anrufe_erledigt")
        let zentrum = UNUserNotificationCenter.current()
        let ids = (0..<3).map { "\(kennung)\(t)-\($0)" }
        zentrum.removePendingNotificationRequests(withIdentifiers: ids)
        zentrum.removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func istAnruf(_ info: [AnyHashable: Any]) -> Bool { info["nx_anruf"] != nil }

    /// Mitteilung kam / wurde angetippt -> Anrufgespräch
    @MainActor
    static func klingeln(_ info: [AnyHashable: Any], annehmen: Bool) {
        let t = (info["nx_anruf"] as? Int) ?? (info["nx_anruf"] as? NSNumber)?.intValue ?? 0
        beenden(t)
        guard !AnrufDienst.shared.imGespraech else { return }
        AnrufDienst.shared.lokal(von: info["von"] as? String ?? "Dein Helfer", text: info["text"] as? String ?? "", annehmen: annehmen)
    }
}
