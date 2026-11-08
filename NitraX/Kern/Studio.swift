import Foundation
import SwiftUI
import UIKit
import WidgetKit

/// Workflows, Stimmen und letzte Ergebnisse (GET /api/handy/workflows)
struct WorkflowListe: Decodable {
    struct Stimme: Decodable, Hashable, Identifiable { var id: String; var name: String }
    struct Ergebnis: Decodable, Hashable, Identifiable {
        var id: String
        var titel: String
        var anzahl: Int?
        var bild: String?
        var sekunden: Double?
    }
    struct Ergebnisse: Decodable { var bilder: [Ergebnis] = []; var videos: [Ergebnis] = []; var songs: [Ergebnis] = [] }

    var kategorien: [[String]] = []
    var workflows: [Workflow] = []
    var stimmen: [Stimme] = []
    var ergebnisse = Ergebnisse()

    enum K: String, CodingKey { case kategorien, workflows, stimmen, ergebnisse }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        kategorien = (try? c.decodeIfPresent([[String]].self, forKey: .kategorien)) ?? []
        workflows = (try? c.decodeIfPresent([Workflow].self, forKey: .workflows)) ?? []
        stimmen = (try? c.decodeIfPresent([Stimme].self, forKey: .stimmen)) ?? []
        ergebnisse = (try? c.decodeIfPresent(Ergebnisse.self, forKey: .ergebnisse)) ?? Ergebnisse()
    }
}

struct Workflow: Decodable, Identifiable, Hashable {
    var id: String
    var kat: String
    var name: String
    var glyph: String
    var text: String
    var felder: [Feld]

    enum K: String, CodingKey { case id, kat, name, glyph, text, felder }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        kat = ((try? c.decodeIfPresent(String.self, forKey: .kat)) ?? nil) ?? "video"
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? id
        glyph = ((try? c.decodeIfPresent(String.self, forKey: .glyph)) ?? nil) ?? "✦"
        text = ((try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil) ?? ""
        felder = ((try? c.decodeIfPresent([Feld].self, forKey: .felder)) ?? nil) ?? []
    }
}

struct Feld: Decodable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var art: String
    var label: String
    var pflicht = false
    var platz: String?
    var optionen: [(schluessel: JSONWert, text: String)] = []
    var wert: JSONWert?
    var max: Double?
    var min: Double?
    var schritt: Double?
    var ki = false
    var nurLtx = false

    static func == (a: Feld, b: Feld) -> Bool { a.name == b.name && a.art == b.art && a.label == b.label }
    func hash(into h: inout Hasher) { h.combine(name); h.combine(art) }

    enum K: String, CodingKey { case name, art, label, pflicht, platz, optionen, wert, max, min, schritt, ki, nur_ltx }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func w<T: Decodable>(_ t: T.Type, _ k: K) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        name = w(String.self, .name) ?? UUID().uuidString
        art = w(String.self, .art) ?? "text"
        label = w(String.self, .label) ?? name
        pflicht = w(JSONWert.self, .pflicht)?.wahr ?? false
        platz = w(String.self, .platz)
        wert = w(JSONWert.self, .wert)
        max = w(JSONWert.self, .max)?.zahl
        min = w(JSONWert.self, .min)?.zahl
        schritt = w(JSONWert.self, .schritt)?.zahl
        ki = w(JSONWert.self, .ki)?.wahr ?? false
        nurLtx = w(JSONWert.self, .nur_ltx)?.wahr ?? false
        optionen = (w([JSONWert].self, .optionen) ?? []).compactMap { o in
            guard let l = o.liste, let k = l.first else { return nil }
            return (k, l.count > 1 ? (l[1].text ?? k.text ?? "") : (k.text ?? ""))
        }
    }
}

struct Bildmodell: Decodable, Hashable, Identifiable {
    var id: String
    var label: String
    var ok: Bool?
    var family: String?
}

/// Zentrale Daten der App: Verbindung zum PC, Live-Stand der Aufträge (alle 3 s, solange die App offen ist).
@MainActor
final class Studio: ObservableObject {
    @Published private(set) var verbindung: Verbindung?
    @Published var stand = StudioStand()
    @Published var erreichbar = false
    @Published var meldung: String?
    @Published var workflows: WorkflowListe?
    @Published var bildmodelle: [Bildmodell] = []
    @Published var angehalten = false
    private(set) var client: NXClient?
    private var takt: Task<Void, Never>?
    private var widgetZuletzt = ""
    private var widgetZeit = Date.distantPast

    init() {
        verbindung = Verbindung.laden()
        if let v = verbindung { client = NXClient(v) }
        // ⚡ Schnellstart: sofort den zuletzt bekannten Stand zeigen, im Hintergrund frisch holen
        if let d = try? Data(contentsOf: Self.ablage("stand.json")), let s = try? JSONDecoder().decode(StudioStand.self, from: d) { stand = s }
        if let d = try? Data(contentsOf: Self.ablage("workflows.json")), let w = try? JSONDecoder().decode(WorkflowListe.self, from: d) { workflows = w }
    }

    static func ablage(_ name: String) -> URL {
        let o = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NitraX", isDirectory: true)
        try? FileManager.default.createDirectory(at: o, withIntermediateDirectories: true)
        return o.appendingPathComponent(name)
    }

    private var selfieZeit = Date.distantPast
    private var workflowsFrisch = false

    /// 🧍 Neuestes Selfie des Helfers als Bild fürs Widget (App Group)
    private func selfieFuersWidget(_ c: NXClient) async {
        guard Date().timeIntervalSince(selfieZeit) > 600 else { return }
        selfieZeit = Date()
        guard let b = try? await c.get("/api/begleiter", JSONWert.self), let id = b["zustand"]?["selfies"]?.liste?.last?.text,
              id != Gemeinsam.defaults.string(forKey: "helfer_selfie_id"),
              let url = c.url("/api/begleiter/ergebnis/\(id)"),
              let ordner = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Gemeinsam.gruppe) else { return }
        var r = URLRequest(url: url)
        for (k, v) in c.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
        guard let (d, antwort) = try? await URLSession.shared.data(for: r), (antwort as? HTTPURLResponse)?.statusCode == 200,
              let bild = UIImage(data: d) else { return }
        let f = min(1, 600 / max(bild.size.width, bild.size.height))
        let g = CGSize(width: bild.size.width * f, height: bild.size.height * f)
        guard let jpg = UIGraphicsImageRenderer(size: g).image(actions: { _ in bild.draw(in: CGRect(origin: .zero, size: g)) }).jpegData(compressionQuality: 0.85) else { return }
        try? jpg.write(to: ordner.appendingPathComponent("helfer_selfie.jpg"), options: .atomic)
        Gemeinsam.defaults.set(id, forKey: "helfer_selfie_id")
        WidgetCenter.shared.reloadTimelines(ofKind: "NitraXHelfer")
    }

    var verbunden: Bool { verbindung != nil }

    func verbinden(_ v: Verbindung) {
        var neu = v
        if var alt = verbindung, alt.schluessel == v.schluessel { alt.dazu(v); alt.aktiv = v.aktiv; neu = alt }
        neu.speichern()
        verbindung = neu
        client = NXClient(neu)
        workflows = nil
        starten()
        Task { await Push.anmelden() }
    }

    func trennen() {
        anhalten()
        Verbindung.loeschen()
        verbindung = nil
        client = nil
        stand = StudioStand()
        erreichbar = false
    }

    func starten() {
        takt?.cancel()
        guard client != nil else { return }
        Task { await Push.anmelden() }
        takt = Task { [weak self] in
            while !Task.isCancelled {
                await self?.aktualisieren()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func anhalten() { takt?.cancel(); takt = nil }

    func aktualisieren() async {
        guard let c = client else { return }
        do {
            let roh = try await c.roh("/api/state")
            let s = try JSONDecoder().decode(StudioStand.self, from: roh)
            stand = s
            try? roh.write(to: Self.ablage("stand.json"), options: .atomic)
            erreichbar = true
            Benachrichtigungen.vergleichen(s)
            widgetAuffrischen(s)
            LiveAktivitaeten.abgleichen(s, client: c)
            if Date().timeIntervalSince(helferZeit) > 60 {           // 🧍 Stimmungs-Widget
                helferZeit = Date()
                if let h = try? await c.get("/api/begleiter/statistik", JSONWert.self) {
                    HelferStand(name: h["name"]?.text ?? "Helfer", stufe: h["stufe_name"]?.text ?? "", stimmung: h["stimmung"]?.zahl ?? 0.6,
                                punkte: Int(h["punkte"]?.zahl ?? 0), bis: Int(h["bis"]?.zahl ?? 0), gespraeche: Int(h["gespraeche"]?.zahl ?? 0),
                                zeit: Date()).speichern()
                    WidgetCenter.shared.reloadTimelines(ofKind: "NitraXHelfer")
                }
                await selfieFuersWidget(c)
            }
            OfflineGalerie.shared.abgleichen(s, client: c)
        } catch {
            erreichbar = false
        }
    }

    /// Widget nur bei Änderung (oder jede Minute) neu zeichnen lassen - nicht alle 3 s
    private var helferZeit = Date.distantPast

    private func widgetAuffrischen(_ s: StudioStand) {
        let schnapp = Schnappschuss.aus(s)
        schnapp.speichern()
        // App offen: Widget darf oft neu zeichnen (zählt nicht gegen das iOS-Budget) - jede 2 % bzw. alle 20 s
        let sig = s.auftraege.filter { $0.offen || $0.fertig }.prefix(12).map { "\($0.id)\($0.status)\(Int($0.progress / 2))" }.joined()
        if sig != widgetZuletzt || Date().timeIntervalSince(widgetZeit) > 20 {
            widgetZuletzt = sig
            widgetZeit = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func workflowsLaden(neu: Bool = false) async {
        guard let c = client, neu || workflows == nil || !workflowsFrisch else { return }
        workflowsFrisch = true
        do {
            let roh = try await c.roh("/api/handy/workflows")
            workflows = try JSONDecoder().decode(WorkflowListe.self, from: roh)
            try? roh.write(to: Self.ablage("workflows.json"), options: .atomic)
        } catch { meldung = error.localizedDescription }
        if bildmodelle.isEmpty || neu {
            struct M: Decodable { var models: [Bildmodell]? }
            if let m = try? await c.get("/api/img/models", M.self) {
                bildmodelle = (m.models ?? []).filter { ($0.ok ?? true) && $0.family != "qwen_edit" }
            }
        }
    }

    // MARK: Aktionen an Aufträgen

    func abbrechen(_ a: Auftrag) async {
        await aktion { try await $0.post("/api/jobs/\(a.id)/cancel") }
    }

    /// 🗑 Auftrag samt Dateien löschen (am PC in den Papierkorb - wiederherstellbar)
    func loeschen(_ a: Auftrag) async {
        guard let c = client else { return }
        do {
            _ = try await c.post("/api/jobs/\(a.id)/delete-files")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            meldung = "🗑 Gelöscht (am PC im Papierkorb)"
            await aktualisieren()
        } catch { meldung = error.localizedDescription }
    }

    func fortsetzen(_ a: Auftrag) async {
        await aktion { try await $0.post("/api/\(a.kind == "x-film" ? "film" : "music")/\(a.id)/fortsetzen") }
        meldung = "▶ Wird fortgesetzt – fertige Stücke bleiben"
    }

    func wartendeAbbrechen() async -> Int {
        let liste = stand.auftraege.filter { $0.nieGestartet }
        var n = 0
        for a in liste { if (try? await client?.post("/api/jobs/\(a.id)/cancel")) != nil { n += 1 } }
        await aktualisieren()
        return n
    }

    func warteschlange(anhalten an: Bool) async {
        await aktion { try await $0.post(an ? "/api/queue/pause" : "/api/queue/resume") }
        angehalten = an
    }

    private func aktion(_ f: (NXClient) async throws -> JSONWert) async {
        guard let c = client else { return }
        do { _ = try await f(c); await aktualisieren() } catch { meldung = error.localizedDescription }
    }

    // MARK: Medien-Adressen (mit Cookie in der Anfrage)

    func url(_ pfad: String) -> URL? { client?.url(pfad) }
    func bildURL(_ name: String) -> URL? { url("/api/image/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)) }
    func vorschauURL(_ a: Auftrag) -> URL? {
        if a.bilderAnzahl > 0 { return url("/api/img/file/\(a.id)/0") }
        if let i = a.image, !i.isEmpty { return bildURL(i) }
        return nil
    }
}
