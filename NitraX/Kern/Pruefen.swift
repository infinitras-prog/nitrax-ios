import Foundation
import Network
import UserNotifications
import AVFoundation
import Speech
import SwiftUI

/// Ein Prüfschritt (Verbindungs-Doktor und Selbsttest)
struct PruefPunkt: Codable, Identifiable, Hashable {
    enum Zustand: String, Codable { case laeuft, ok, warn, fehler }
    var id: String { name }
    var name: String
    var zustand: Zustand
    var text: String
    var ms: Int = 0

    var symbol: String {
        switch zustand {
        case .laeuft: return "circle.dotted"
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fehler: return "xmark.octagon.fill"
        }
    }
    var farbe: Color {
        switch zustand {
        case .laeuft: return .secondary
        case .ok: return Farbe.gut
        case .warn: return Farbe.warn
        case .fehler: return Farbe.fehler
        }
    }
}

// MARK: - 🩺 Verbindungs-Doktor (Runde 2, Nr. 11)

/// Findet heraus, WARUM der PC nicht erreichbar ist: Netz am iPhone, jede gespeicherte Adresse (Port offen? Schlüssel?),
/// Antwortzeit, Live-Verbindung – und sagt, was zu tun ist.
@MainActor
final class Doktor: ObservableObject {
    @Published var punkte: [PruefPunkt] = []
    @Published var fazit: (titel: String, text: String, gut: Bool)?
    @Published var laeuft = false
    private(set) var lokalesNetzGesperrt = false
    private(set) var schluesselFalsch = false

    func pruefen(_ v: Verbindung?) async {
        guard !laeuft else { return }
        laeuft = true
        punkte = []
        fazit = nil
        lokalesNetzGesperrt = false
        schluesselFalsch = false
        defer { laeuft = false }
        guard let v else {
            fazit = ("Noch nicht verbunden", "Scanne den QR-Code in NitraX AI Studio (Einstellungen → Handy).", false)
            return
        }
        // 1) Netz am iPhone
        let netz = await Self.netz()
        punkte.append(PruefPunkt(name: "iPhone-Netz", zustand: netz.wlan || netz.vpn ? .ok : (netz.da ? .warn : .fehler), text: netz.text))
        // 2) jede Adresse: Port + Schlüssel
        var erreichbar: String?
        for a in v.reihenfolge {
            guard let u = URL(string: a), let host = u.host else { continue }
            let port = UInt16(u.port ?? (u.scheme == "https" ? 443 : 80))
            let art = Self.art(host)
            let name = "\(art.name) · \(host):\(port)"
            let idx = punkte.count
            punkte.append(PruefPunkt(name: name, zustand: .laeuft, text: "prüfe …"))
            let t0 = Date()
            let tcp = await Self.tcp(host: host, port: port)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            switch tcp {
            case .offen:
                // Handyzugang antwortet – stimmt der Schlüssel?
                var r = URLRequest(url: URL(string: a + "/api/begleiter/meldungen?seit=9999999999")!)
                r.timeoutInterval = 5
                r.setValue("nx_handy=\(v.schluessel)", forHTTPHeaderField: "Cookie")
                let code = ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200..<400:
                    punkte[idx] = PruefPunkt(name: name, zustand: .ok, text: "erreichbar, Schlüssel passt (\(ms) ms)", ms: ms)
                    if erreichbar == nil { erreichbar = a }
                case 403:
                    schluesselFalsch = true
                    punkte[idx] = PruefPunkt(name: name, zustand: .fehler, text: "PC antwortet, aber der Schlüssel passt nicht mehr (am PC wurde ein neuer erzeugt) – QR-Code neu scannen.", ms: ms)
                case 503:
                    punkte[idx] = PruefPunkt(name: name, zustand: .warn, text: "Handyzugang startet gerade – in ein paar Sekunden nochmal prüfen.", ms: ms)
                case 0:
                    punkte[idx] = PruefPunkt(name: name, zustand: .warn, text: "Port offen, aber keine Antwort – NitraX am PC hängt oder startet noch.", ms: ms)
                default:
                    punkte[idx] = PruefPunkt(name: name, zustand: .warn, text: "unerwartete Antwort (HTTP \(code))", ms: ms)
                }
            case .abgewiesen:
                punkte[idx] = PruefPunkt(name: name, zustand: .fehler, text: "PC ist an, aber der Handyzugang läuft nicht – NitraX AI Studio starten bzw. in den Einstellungen → Handy einschalten.", ms: ms)
            case .gesperrt:
                lokalesNetzGesperrt = true
                punkte[idx] = PruefPunkt(name: name, zustand: .fehler, text: "iOS blockiert den Zugriff aufs Heimnetz – Einstellungen → Datenschutz → Lokales Netzwerk → NitraX einschalten.", ms: ms)
            case .zeit:
                let warum: String
                if art.lan && !netz.wlan { warum = "Du bist nicht im WLAN – diese Adresse geht nur zu Hause. Unterwegs: Tailscale am iPhone einschalten." }
                else if art.tailscale && !netz.vpn { warum = "Tailscale scheint am iPhone aus zu sein – in der Tailscale-App verbinden." }
                else { warum = "Keine Antwort – PC aus oder im Standby, anderes WLAN, oder die Windows-Firewall blockt (Private Netzwerke erlauben)." }
                punkte[idx] = PruefPunkt(name: name, zustand: .fehler, text: warum, ms: ms)
            case .fehler(let t):
                punkte[idx] = PruefPunkt(name: name, zustand: .fehler, text: t, ms: ms)
            }
        }
        // 3) wenn erreichbar: Studio-Stand, Engine, Live-Verbindung
        if let a = erreichbar {
            let c = NXClient(Verbindung(adressen: [a], schluessel: v.schluessel, aktiv: a), zeitlimit: 10)
            let t0 = Date()
            if let s = try? await c.stand() {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                punkte.append(PruefPunkt(name: "NitraX AI Studio", zustand: s.engineBereit ? .ok : .warn,
                                         text: (s.engineBereit ? "läuft, Engine bereit" : "läuft, die Engine startet noch") + " · Antwort in \(ms) ms"
                                             + (s.fremd.isEmpty ? "" : " · \(s.fremd.joined(separator: ", ")) nutzt die Grafikkarte"), ms: ms))
            } else {
                punkte.append(PruefPunkt(name: "NitraX AI Studio", zustand: .fehler, text: "Stand ließ sich nicht laden"))
            }
            let live = await Self.live(c)
            punkte.append(PruefPunkt(name: "Live-Verbindung", zustand: live ? .ok : .warn,
                                     text: live ? "Änderungen kommen sofort" : "kommt nicht durch – die App fragt dann alle paar Sekunden nach (geht trotzdem)"))
            fazit = ("Alles in Ordnung", "Der PC ist über \(Self.art(URL(string: a)?.host ?? "").name) erreichbar.", true)
        } else if schluesselFalsch {
            fazit = ("QR-Code neu scannen", "Am PC: NitraX → Einstellungen → Handy → QR-Code. Hier: Einstellungen → Weitere Adresse scannen.", false)
        } else if lokalesNetzGesperrt {
            fazit = ("Heimnetz-Zugriff erlauben", "iOS-Einstellungen → Datenschutz & Sicherheit → Lokales Netzwerk → NitraX einschalten.", false)
        } else {
            fazit = ("PC nicht erreichbar", punkte.last(where: { $0.zustand == .fehler })?.text ?? "Keine Adresse antwortet.", false)
        }
    }

    // MARK: Bausteine

    struct Netz: Sendable { var da: Bool; var wlan: Bool; var vpn: Bool; var text: String }

    /// genau einmal (Rückruf aus fremden Threads)
    final class Einmal: @unchecked Sendable {
        private let sperre = NSLock()
        private var erledigt = false
        var fehler: NWError?
        func erstes() -> Bool { sperre.lock(); defer { sperre.unlock() }; if erledigt { return false }; erledigt = true; return true }
    }

    nonisolated static func netz() async -> Netz {
        await withCheckedContinuation { (k: CheckedContinuation<Netz, Never>) in
            let m = NWPathMonitor()
            let einmal = Einmal()
            m.pathUpdateHandler = { p in
                guard einmal.erstes() else { return }
                m.cancel()
                let wlan = p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet)
                let vpn = p.availableInterfaces.contains { $0.type == .other && ($0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec")) }
                let mobil = p.usesInterfaceType(.cellular)
                let da = p.status == .satisfied
                var t = !da ? "Kein Netz – Flugmodus? WLAN aus?" : wlan ? "WLAN" : mobil ? "Mobilfunk (nicht im WLAN)" : "verbunden"
                if da && vpn { t += " · VPN/Tailscale aktiv" }
                k.resume(returning: Netz(da: da, wlan: wlan, vpn: vpn, text: t))
            }
            m.start(queue: .global())
        }
    }

    struct Art { var name: String; var lan: Bool; var tailscale: Bool }

    nonisolated static func art(_ host: String) -> Art {
        let teile = host.split(separator: ".").compactMap { Int($0) }
        if host.hasSuffix(".ts.net") { return Art(name: "Tailscale", lan: false, tailscale: true) }
        if teile.count == 4 {
            if teile[0] == 100, (64...127).contains(teile[1]) { return Art(name: "Tailscale", lan: false, tailscale: true) }
            if teile[0] == 10 || (teile[0] == 192 && teile[1] == 168) || (teile[0] == 172 && (16...31).contains(teile[1])) {
                return Art(name: "Heimnetz", lan: true, tailscale: false)
            }
        }
        return Art(name: "Adresse", lan: false, tailscale: false)
    }

    enum TCP: Sendable { case offen, abgewiesen, gesperrt, zeit, fehler(String) }

    nonisolated static func deuten(_ e: NWError) -> TCP {
        switch e {
        case .posix(let c) where c == .ECONNREFUSED: return .abgewiesen
        case .posix(let c) where c == .ETIMEDOUT: return .zeit
        case .dns(let c) where c == -65570: return .gesperrt                   // kDNSServiceErr_PolicyDenied: »Lokales Netzwerk« verboten
        default: return .fehler(e.localizedDescription)
        }
    }

    nonisolated static func tcp(host: String, port: UInt16, zeit: Double = 3.5) async -> TCP {
        await withCheckedContinuation { (k: CheckedContinuation<TCP, Never>) in
            let q = DispatchQueue(label: "nx.doktor")
            let v = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 80, using: .tcp)
            let einmal = Einmal()
            let ende: @Sendable (TCP) -> Void = { e in guard einmal.erstes() else { return }; v.cancel(); k.resume(returning: e) }
            v.stateUpdateHandler = { s in
                switch s {
                case .ready: ende(.offen)
                case .failed(let e): ende(Doktor.deuten(e))
                case .waiting(let e):
                    q.async { einmal.fehler = e }
                    if case .posix(let c) = e, c == .ECONNREFUSED { ende(.abgewiesen) }
                    if case .dns(let c) = e, c == -65570 { ende(.gesperrt) }
                default: break
                }
            }
            v.start(queue: q)
            q.asyncAfter(deadline: .now() + zeit) {
                var t = TCP.zeit
                if let f = einmal.fehler { t = Doktor.deuten(f); if case .fehler = t { t = .zeit } }
                ende(t)
            }
        }
    }

    /// SSE: kommt die erste Zeile in 5 s?
    nonisolated static func live(_ c: NXClient) async -> Bool {
        guard let url = c.url("/api/handy/live") else { return false }
        var r = URLRequest(url: url)
        r.timeoutInterval = 6
        for (k, v) in c.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
        let t = Task { () -> Bool in
            guard let (bytes, resp) = try? await URLSession.shared.bytes(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            for try await z in bytes.lines where z.hasPrefix("data:") { return true }
            return false
        }
        let w = Task { try? await Task.sleep(for: .seconds(5)); t.cancel() }
        let ok = (try? await t.value) ?? false
        w.cancel()
        return ok
    }
}

// MARK: - 🧪 Selbsttest nach Updates (Runde 2, Nr. 12)

/// Nach jedem App-Update (und auf Knopfdruck): prüft alle Funktionen, die die App vom PC braucht, und die iPhone-Rechte.
/// Probleme gehen an den PC (Fehlerbericht) und erscheinen hier – so fällt ein Fehler auf, bevor du ihn suchst.
@MainActor
final class Selbsttest: ObservableObject {
    static let shared = Selbsttest()
    @Published private(set) var punkte: [PruefPunkt] = []
    @Published private(set) var laeuft = false
    @Published private(set) var zeit: Date?

    private init() {
        if let d = UserDefaults.standard.data(forKey: "selbsttest_ergebnis"), let p = try? JSONDecoder().decode([PruefPunkt].self, from: d) { punkte = p }
        let t = UserDefaults.standard.double(forKey: "selbsttest_zeit")
        if t > 0 { zeit = Date(timeIntervalSince1970: t) }
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + "-" +
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    var probleme: Int { punkte.filter { $0.zustand == .fehler }.count }
    var hinweise: Int { punkte.filter { $0.zustand == .warn }.count }

    /// einmal je App-Version (nach dem ersten erfolgreichen Kontakt zum PC)
    func nachUpdate(_ c: NXClient, studio: Studio) async {
        guard UserDefaults.standard.string(forKey: "selbsttest_version") != Self.version else { return }
        UserDefaults.standard.set(Self.version, forKey: "selbsttest_version")
        try? await Task.sleep(for: .seconds(8))                       // App erst in Ruhe starten lassen
        await laufen(c)
        if probleme > 0 { studio.meldung = "🧪 Selbsttest nach dem Update: \(probleme) Problem\(probleme == 1 ? "" : "e") – Details in Einstellungen" }
        else if hinweise > 0 { studio.meldung = "🧪 Selbsttest nach dem Update: läuft, \(hinweise) Hinweis\(hinweise == 1 ? "" : "e")" }
        else { studio.meldung = "🧪 Selbsttest nach dem Update: alles in Ordnung (\(punkte.count) Prüfungen)" }
    }

    func laufen(_ c: NXClient) async {
        guard !laeuft else { return }
        laeuft = true
        defer { laeuft = false }
        var p: [PruefPunkt] = []
        func pruefe(_ name: String, _ f: () async throws -> (PruefPunkt.Zustand, String)) async {
            let t0 = Date()
            do {
                let (z, t) = try await f()
                p.append(PruefPunkt(name: name, zustand: z, text: t, ms: Int(Date().timeIntervalSince(t0) * 1000)))
            } catch {
                p.append(PruefPunkt(name: name, zustand: .fehler, text: error.localizedDescription, ms: Int(Date().timeIntervalSince(t0) * 1000)))
            }
            punkte = p
        }
        let altPC = "PC-Programm ist älter als die App – NitraX am PC aktualisieren"
        await pruefe("PC-Stand") {
            let s = try await c.stand()
            return (.ok, "\(s.auftraege.count) Aufträge" + (s.engineBereit ? ", Engine bereit" : ", Engine startet noch"))
        }
        await pruefe("Workflows") {
            let d = try await c.roh("/api/handy/workflows")
            let w = try JSONDecoder().decode(WorkflowListe.self, from: d)
            if w.workflows.isEmpty { return (.fehler, "keine Workflows geliefert") }
            return (.ok, "\(w.workflows.count) Workflows")
        }
        await pruefe("Helfer") {
            let b = try await c.get("/api/begleiter", JSONWert.self)
            if b["einst"] == nil { return (.fehler, "keine Helfer-Daten") }
            return (.ok, b["einst"]?["name"]?.text ?? "bereit")
        }
        await pruefe("Helfer-Seite") {
            let d = try await c.roh("/static/begleiter/handy.js")
            let t = String(decoding: d, as: UTF8.self)
            if !t.contains("nxHandyHelfer") { return (.fehler, "Seite unvollständig") }
            if t.contains("garderobe") { return (.ok, "aktuell") }
            return (.warn, altPC + " (👗 Aussehen)")
        }
        await pruefe("Live-Verbindung") {
            if await Doktor.live(c) { return (.ok, "Änderungen kommen sofort") }
            return (.warn, "kommt nicht durch – Abfrage alle 3 s")
        }
        await pruefe("Anrufstimmen") {
            _ = try await c.roh("/api/anruf/stimmen")
            return (.ok, Gemeinsam.defaults.string(forKey: "helfer_stimme").map { "Stimme \($0)" } ?? "bereit")
        }
        await pruefe("Routinen & Anrufe") {
            _ = try await c.roh("/api/begleiter/routinen")
            _ = try await c.roh("/api/begleiter/anrufe")
            return (.ok, "erreichbar")
        }
        await pruefe("Gesprächsverlauf") {
            let d = try await c.roh("/api/chats")
            let n = (try? JSONDecoder().decode(JSONWert.self, from: d))?.liste?.count ?? 0
            return (.ok, "\(n) Gespräche")
        }
        await pruefe("Zeitschätzung & Warteschlange") {
            do { _ = try await c.roh("/api/handy/schaetzung?wf=i2v"); return (.ok, "erreichbar") }
            catch NXFehler.server(let code, _) where code == 403 || code == 404 { return (.warn, altPC) }
        }
        await pruefe("Mitteilungen") {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return (.ok, Push.aktiv ? "erlaubt · Sofort-Push aktiv" : "erlaubt")
            case .denied: return (.warn, "aus – iOS-Einstellungen → NitraX → Mitteilungen (sonst keine Anrufe/Fertig-Meldungen)")
            default: return (.warn, "noch nicht gefragt")
            }
        }
        await pruefe("Mikrofon & Spracherkennung") {
            let mik = AVAudioApplication.shared.recordPermission == .granted
            let sp = SFSpeechRecognizer.authorizationStatus() == .authorized
            if mik && sp { return (.ok, "erlaubt – Anrufe verstehen dich sofort") }
            if !mik { return (.warn, "Mikrofon nicht erlaubt – iOS-Einstellungen → NitraX → Mikrofon") }
            return (.warn, "Spracherkennung nicht erlaubt – dann erkennt der PC (etwas langsamer)")
        }
        await pruefe("Bild-Speicher") {
            let u = Studio.ablage("selbsttest.tmp")
            try Data("ok".utf8).write(to: u, options: .atomic)
            let ok = (try? Data(contentsOf: u)) == Data("ok".utf8)
            try? FileManager.default.removeItem(at: u)
            if ok { return (.ok, "schreib- und lesbar") }
            return (.fehler, "Zwischenspeicher nicht lesbar")
        }
        zeit = Date()
        UserDefaults.standard.set(zeit!.timeIntervalSince1970, forKey: "selbsttest_zeit")
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "selbsttest_ergebnis") }
        // Probleme an den PC (data/handy_fehler.log)
        let schlecht = p.filter { $0.zustand != .ok }
        if !schlecht.isEmpty {
            for s in schlecht { Fehlerbericht.shared.melden("Selbsttest", "\(s.zustand.rawValue): \(s.name) – \(s.text)") }
            await Fehlerbericht.shared.senden(c, sofort: true)
        }
    }
}

// MARK: - Ansichten

@MainActor
struct VerbindungsDoktor: View {
    @EnvironmentObject private var studio: Studio
    @StateObject private var d = Doktor()
    @State private var scannen = false

    var body: some View {
        List {
            if let f = d.fazit {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(f.titel, systemImage: f.gut ? "checkmark.seal.fill" : "stethoscope").font(.headline)
                            .foregroundStyle(f.gut ? Farbe.gut : Farbe.warn)
                        Text(f.text).font(.subheadline)
                        if d.schluesselFalsch { Button("QR-Code scannen") { scannen = true }.buttonStyle(.borderedProminent).padding(.top, 4) }
                        if d.lokalesNetzGesperrt, let u = URL(string: UIApplication.openSettingsURLString) {
                            Link("iOS-Einstellungen öffnen", destination: u).buttonStyle(.borderedProminent).padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Farbe.karte)
            }
            Section("Schritt für Schritt") {
                ForEach(d.punkte) { p in
                    HStack(alignment: .top, spacing: 10) {
                        if p.zustand == .laeuft { ProgressView().frame(width: 22) }
                        else { Image(systemName: p.symbol).foregroundStyle(p.farbe).frame(width: 22) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.subheadline.weight(.semibold))
                            Text(p.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if d.punkte.isEmpty && d.laeuft { ProgressView().frame(maxWidth: .infinity) }
            }
            .listRowBackground(Farbe.karte)
            Section {
                Text("Aufwecken aus dem Standby geht vom iPhone aus leider nicht (iOS erlaubt Apps dafür keine Rundsende-Pakete im Heimnetz). Tipp: Am PC Energiesparen → Standby »Nie«, solange du unterwegs arbeiten willst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle("Verbindung prüfen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await nochmal() } } label: { Image(systemName: "arrow.clockwise") }.disabled(d.laeuft)
            }
        }
        .task { await nochmal() }
        .sheet(isPresented: $scannen) {
            QRScanner { text in
                scannen = false
                if let v = Verbindung.ausLink(text) { studio.verbinden(v); studio.meldung = "Neu verbunden"; Task { await nochmal() } }
            }
            .ignoresSafeArea()
        }
    }

    private func nochmal() async {
        await d.pruefen(studio.verbindung)
        if d.fazit?.gut == true {
            _ = await studio.client?.basisFinden()
            await studio.aktualisieren()
        }
    }
}

@MainActor
struct SelbsttestAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @ObservedObject private var t = Selbsttest.shared

    var body: some View {
        List {
            Section {
                Button { Task { if let c = studio.client { await t.laufen(c) } } } label: {
                    HStack {
                        Label(t.laeuft ? "Prüft …" : "Jetzt prüfen", systemImage: "checklist")
                        Spacer()
                        if t.laeuft { ProgressView() }
                    }
                }
                .disabled(t.laeuft || studio.client == nil)
            } footer: {
                Text(t.zeit.map { "Zuletzt: \($0.formatted(date: .abbreviated, time: .shortened)) · läuft nach jedem Update von selbst. Probleme gehen an den PC." }
                     ?? "Läuft nach jedem Update von selbst. Probleme gehen an den PC.")
            }
            .listRowBackground(Farbe.karte)
            Section("Ergebnis") {
                if t.punkte.isEmpty { Text("Noch nicht geprüft").foregroundStyle(.secondary) }
                ForEach(t.punkte) { p in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: p.symbol).foregroundStyle(p.farbe).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                if p.ms > 0 { Text("\(p.ms) ms").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
                            }
                            Text(p.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listRowBackground(Farbe.karte)
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle("Selbsttest")
        .navigationBarTitleDisplayMode(.inline)
    }
}
