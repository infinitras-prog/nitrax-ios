import Foundation
import Network
import UserNotifications
import EventKit
import CoreLocation
import UIKit

// MARK: - 📶 Sparmodus (Runde 3, Nr. 2): im Mobilfunk kleinere Bilder, Videos erst auf Tippen, Helfer mit 30 Bildern/s

final class Netzlage: @unchecked Sendable {
    static let shared = Netzlage()
    private let monitor = NWPathMonitor()
    private let sperre = NSLock()
    private var _teuer = false

    /// »auto« (nur im Mobilfunk / Datensparmodus) · »an« · »aus«
    static var modus: String {
        get { UserDefaults.standard.string(forKey: "spar_modus") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "spar_modus") }
    }

    var teuer: Bool { sperre.lock(); defer { sperre.unlock() }; return _teuer }

    static var sparen: Bool {
        switch modus {
        case "an": return true
        case "aus": return false
        default: return shared.teuer
        }
    }

    func starten() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            let t = p.isExpensive || p.isConstrained
            self.sperre.lock(); self._teuer = t; self.sperre.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "nx.netzlage"))
    }

    /// Vorschaubild-Adresse im Sparmodus verkleinern lassen (PC liefert dann ein kleines JPEG)
    static func klein(_ u: URL?, breite: Int = 420) -> URL? {
        guard let u, sparen, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "w", value: String(breite))]
        return c.url ?? u
    }
}

// MARK: - 🌙 Ruhezeiten (Runde 3, Nr. 3)

enum Ruhezeit {
    static var an: Bool { UserDefaults.standard.bool(forKey: "ruhe_an") }
    static var von: String { UserDefaults.standard.string(forKey: "ruhe_von") ?? "22:00" }
    static var bis: String { UserDefaults.standard.string(forKey: "ruhe_bis") ?? "07:00" }

    private static func minuten(_ s: String) -> Int {
        let t = s.split(separator: ":").compactMap { Int($0) }
        return t.count == 2 ? t[0] * 60 + t[1] : 0
    }

    static func aktiv(_ d: Date = Date()) -> Bool {
        guard an else { return false }
        let k = Calendar.current.dateComponents([.hour, .minute], from: d)
        let n = (k.hour ?? 0) * 60 + (k.minute ?? 0), a = minuten(von), b = minuten(bis)
        return a < b ? (n >= a && n < b) : (n >= a || n < b)
    }

    static func setzen(an: Bool, von: String, bis: String) {
        UserDefaults.standard.set(an, forKey: "ruhe_an")
        UserDefaults.standard.set(von, forKey: "ruhe_von")
        UserDefaults.standard.set(bis, forKey: "ruhe_bis")
    }

    /// an den PC (der schickt dann auch keine Pushs/Anrufe)
    static func senden(_ c: NXClient) async {
        _ = try? await c.post("/api/handy/ruhezeit", ["an": an, "von": von, "bis": bis])
    }

    /// Stand vom PC übernehmen (z. B. nach Neuinstallation)
    static func holen(_ c: NXClient) async {
        guard let r = try? await c.get("/api/handy/ruhezeit", JSONWert.self) else { return }
        setzen(an: r["an"]?.wahr ?? false, von: r["von"]?.text ?? von, bis: r["bis"]?.text ?? bis)
    }
}

// MARK: - 📅 Kalender (Runde 3, Nr. 12) – freiwillig: sie kennt deine Termine, erinnert dich, plant Aufträge darum herum

@MainActor
final class KalenderDienst: ObservableObject {
    static let shared = KalenderDienst()
    private let speicher = EKEventStore()
    @Published private(set) var termine: [Termin] = []
    @Published var an: Bool = UserDefaults.standard.bool(forKey: "kalender_an") {
        didSet { UserDefaults.standard.set(an, forKey: "kalender_an"); Task { await self.abgleichen(sofort: true) } }
    }
    @Published var erinnern: Bool = UserDefaults.standard.object(forKey: "kalender_erinnern") as? Bool ?? true {
        didSet { UserDefaults.standard.set(erinnern, forKey: "kalender_erinnern"); Task { await self.abgleichen(sofort: true) } }
    }
    private var zuletzt = Date.distantPast

    struct Termin: Identifiable, Hashable { let id: String; let titel: String; let start: Date; let ende: Date; let ganztag: Bool }

    var erlaubt: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func erlaubnis() async -> Bool {
        if erlaubt { return true }
        return (try? await speicher.requestFullAccessToEvents()) ?? false
    }

    /// höchstens alle 20 min (oder sofort): Termine lesen, an den PC, Erinnerungen planen
    func abgleichen(sofort: Bool = false) async {
        let zentrum = UNUserNotificationCenter.current()
        let alt = await zentrum.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("nx-termin-") }
        guard an, erlaubt else {
            zentrum.removePendingNotificationRequests(withIdentifiers: alt)
            if !an, termine.isEmpty == false || sofort {
                termine = []
                if let v = Verbindung.laden() { _ = try? await NXClient(v, zeitlimit: 10).post("/api/handy/kalender", ["termine": [], "leer": true]) }
            }
            return
        }
        guard sofort || Date().timeIntervalSince(zuletzt) > 20 * 60 else { return }
        zuletzt = Date()
        let jetzt = Date()
        let p = speicher.predicateForEvents(withStart: jetzt.addingTimeInterval(-3600), end: jetzt.addingTimeInterval(3 * 86400), calendars: nil)
        termine = speicher.events(matching: p).prefix(40).map {
            Termin(id: $0.calendarItemIdentifier + "-\(Int($0.startDate.timeIntervalSince1970))", titel: $0.title ?? "Termin",
                   start: $0.startDate, ende: $0.endDate, ganztag: $0.isAllDay)
        }
        if let v = Verbindung.laden() {
            let liste: [[String: Any]] = termine.map { ["titel": $0.titel, "start": $0.start.timeIntervalSince1970, "ende": $0.ende.timeIntervalSince1970, "ganztag": $0.ganztag] }
            _ = try? await NXClient(v, zeitlimit: 10).post("/api/handy/kalender", ["termine": liste, "leer": liste.isEmpty])
        }
        // ⏰ 10 min vorher erinnert dich dein Helfer (nicht in der Ruhezeit, keine ganztägigen)
        let name = Gemeinsam.defaults.string(forKey: "helfer_name") ?? "Dein Helfer"
        var soll: Set<String> = []
        if erinnern {
            for t in termine where !t.ganztag {
                let wann = t.start.addingTimeInterval(-600)
                guard wann > jetzt.addingTimeInterval(5), !Ruhezeit.aktiv(wann) else { continue }
                let id = "nx-termin-" + String(t.id.filter { $0.isLetter || $0.isNumber }.suffix(60))     // stabil über App-Starts
                soll.insert(id)
                if alt.contains(id) { continue }
                let i = UNMutableNotificationContent()
                i.title = "🧍 \(name)"
                i.body = "In 10 Minuten: \(t.titel) – denk dran!"
                i.sound = .default
                i.threadIdentifier = "helfer"
                i.userInfo = ["helfer": true]
                let k = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: wann)
                try? await zentrum.add(UNNotificationRequest(identifier: id, content: i, trigger: UNCalendarNotificationTrigger(dateMatching: k, repeats: false)))
            }
        }
        zentrum.removePendingNotificationRequests(withIdentifiers: alt.filter { !soll.contains($0) })
    }

    /// erster Termin, der zwischen jetzt und `bis` beginnt (für die Zeitschätzung)
    func naechster(bis: Date) -> Termin? {
        termine.filter { !$0.ganztag && $0.start > Date() && $0.start < bis }.min { $0.start < $1.start }
    }

    func naechsterUeberhaupt(innerhalb s: TimeInterval) -> Termin? { naechster(bis: Date().addingTimeInterval(s)) }
}

// MARK: - 📍 Orts-Routinen (Runde 3, Nr. 11): heimkommen / losfahren – der Ort bleibt auf dem iPhone, an den PC geht nur das Ereignis

@MainActor
final class OrtsRoutinen: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = OrtsRoutinen()
    private let ort = CLLocationManager()
    @Published private(set) var zuhause: CLLocationCoordinate2D?
    @Published var heimGruss: Bool = UserDefaults.standard.object(forKey: "ort_heim") as? Bool ?? true {
        didSet { UserDefaults.standard.set(heimGruss, forKey: "ort_heim") }
    }
    @Published var losStand: Bool = UserDefaults.standard.object(forKey: "ort_los") as? Bool ?? true {
        didSet { UserDefaults.standard.set(losStand, forKey: "ort_los") }
    }
    @Published private(set) var meldung: String?
    private var festlegen = false
    private static let region = "nx-zuhause"

    override init() {
        super.init()
        ort.delegate = self
        let d = UserDefaults.standard
        if d.object(forKey: "zuhause_breite") != nil {
            zuhause = CLLocationCoordinate2D(latitude: d.double(forKey: "zuhause_breite"), longitude: d.double(forKey: "zuhause_laenge"))
        }
    }

    /// beim App-Start: Delegat setzen, damit iOS uns bei Regions-Ereignissen weckt
    func starten() { _ = ort.monitoredRegions }

    var aktiv: Bool { zuhause != nil }

    func hierZuhause() {
        festlegen = true
        meldung = "Ort wird bestimmt …"
        if ort.authorizationStatus == .notDetermined { ort.requestAlwaysAuthorization() }
        ort.desiredAccuracy = kCLLocationAccuracyHundredMeters
        ort.requestLocation()
    }

    func entfernen() {
        for r in ort.monitoredRegions where r.identifier == Self.region { ort.stopMonitoring(for: r) }
        UserDefaults.standard.removeObject(forKey: "zuhause_breite")
        UserDefaults.standard.removeObject(forKey: "zuhause_laenge")
        zuhause = nil
        meldung = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            guard self.festlegen else { return }
            self.festlegen = false
            let k = l.coordinate
            UserDefaults.standard.set(k.latitude, forKey: "zuhause_breite")
            UserDefaults.standard.set(k.longitude, forKey: "zuhause_laenge")
            self.zuhause = k
            for r in self.ort.monitoredRegions where r.identifier == Self.region { self.ort.stopMonitoring(for: r) }
            let r = CLCircularRegion(center: k, radius: 150, identifier: Self.region)
            r.notifyOnEntry = true
            r.notifyOnExit = true
            self.ort.startMonitoring(for: r)
            if self.ort.authorizationStatus == .authorizedWhenInUse { self.ort.requestAlwaysAuthorization() }
            self.meldung = self.ort.authorizationStatus == .authorizedAlways ? "✓ Zuhause gespeichert (nur auf dem iPhone)"
                : "✓ Gespeichert – für Meldungen im Hintergrund bitte »Immer« erlauben (iOS-Einstellungen → NitraX → Standort)"
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.festlegen { self.festlegen = false; self.meldung = "Ort nicht bestimmbar: \(error.localizedDescription)" }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in await self.ereignis("heim") }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in await self.ereignis("los") }
    }

    private func ereignis(_ art: String) async {
        guard art == "heim" ? heimGruss : losStand else { return }
        // GPS-Zittern an der Grenze: höchstens ein Ereignis je 5 min
        let k = "ort_zuletzt_" + art
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: k) > 300 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: k)
        let bg = UIApplication.shared.beginBackgroundTask(withName: "NitraX-Ort")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        guard let v = Verbindung.laden(), let r = try? await NXClient(v, zeitlimit: 15).post("/api/handy/ort", ["ereignis": art], zeit: 15) else { return }
        guard !Ruhezeit.aktiv(), let titel = r["titel"]?.text, let text = r["text"]?.text else { return }
        let i = UNMutableNotificationContent()
        i.title = titel
        i.body = text
        i.sound = .default
        i.threadIdentifier = "helfer"
        i.userInfo = ["helfer": true]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nx-ort-\(art)-\(Int(Date().timeIntervalSince1970))", content: i, trigger: nil))
    }
}
