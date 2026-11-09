import Foundation

/// Ein Auftrag aus NitraX AI Studio (Video, Bild, Song, Musikvideo, Film …). Nachsichtig dekodiert: unbekannte oder
/// anders getypte Felder lassen den Auftrag nicht scheitern.
struct Auftrag: Decodable, Identifiable, Hashable {
    let id: String
    var kind: String = ""
    var status: String = ""
    var progress: Double = 0
    var stage: String = ""
    var eta: Double?
    var elapsed: Double?
    var original: String = ""
    var image: String?
    var bilderAnzahl: Int = 0
    var hatVideo = false
    var songInput: String?
    var created: Double = 0
    var started: Double?
    var finished: Double?
    var fehler: String?
    var clipsFertig = 0
    var clipsGesamt = 0
    var probeHalt = false
    var sekunden: Double?
    var fav = false
    var wiederholbar = false          // »again« am PC gemerkt -> 🎲 Neue Variante
    var maximal = ""                  // Status 💎 Maximal (rechnet/fertig/…)
    var vorMaximal = false
    var realismus = ""
    var vorRealismus = false
    var lob = ""                      // gut/schlecht (👍/👎)
    var stichworte = ""               // 🔎 Bildinhalt in Stichwörtern (PC beschreibt im Leerlauf) - für die Suche
    var vorlageWf: String?            // 🧬 Workflow + Eingaben, mit denen er vom Handy gestartet wurde (»Ähnliches erstellen«)
    var vorlageFelder: [String: JSONWert] = [:]
    var zurueckgestellt = false       // ⏸ vom Handy zurückgestellt
    var reihe: Double?                // Platz in der Warteschlange (kleiner = früher)
    var projekt: String?              // 📁 Projekt-Mappe

    enum K: String, CodingKey {
        case id, kind, status, progress, stage, eta, elapsed, original, image, bilder, video, song_input, created, started, finished
        case error, fehler_klar, clips, probe_halt, total_seconds, fav
        case again, maximal, vor_maximal, realismus, vor_realismus, lob
        case ki_stichworte, handy_vorlage, halt_hand, order, projekt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        func w<T: Decodable>(_ t: T.Type, _ k: K) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        kind = w(String.self, .kind) ?? "i2v"
        status = w(String.self, .status) ?? ""
        progress = w(Double.self, .progress) ?? 0
        stage = w(String.self, .stage) ?? ""
        eta = w(Double.self, .eta)
        elapsed = w(Double.self, .elapsed)
        original = w(String.self, .original) ?? ""
        image = w(String.self, .image)
        bilderAnzahl = w([JSONWert].self, .bilder)?.count ?? 0
        if let v = w(JSONWert.self, .video) { hatVideo = !v.istLeer }
        songInput = w(String.self, .song_input)
        created = w(Double.self, .created) ?? 0
        started = w(Double.self, .started)
        finished = w(Double.self, .finished)
        fehler = w(String.self, .fehler_klar) ?? w(String.self, .error)
        if let cl = w([JSONWert].self, .clips) {
            clipsGesamt = cl.count
            clipsFertig = cl.filter { $0["status"]?.text == "fertig" }.count
        }
        probeHalt = w(JSONWert.self, .probe_halt)?.wahr ?? false
        sekunden = w(Double.self, .total_seconds)
        fav = w(Bool.self, .fav) ?? false
        wiederholbar = !(w(JSONWert.self, .again)?.istLeer ?? true)
        maximal = w(JSONWert.self, .maximal)?["status"]?.text ?? ""
        vorMaximal = !(w(JSONWert.self, .vor_maximal)?.istLeer ?? true)
        realismus = w(JSONWert.self, .realismus)?["status"]?.text ?? ""
        vorRealismus = !(w(JSONWert.self, .vor_realismus)?.istLeer ?? true)
        lob = w(String.self, .lob) ?? ""
        stichworte = w(String.self, .ki_stichworte) ?? ""
        if let v = w(JSONWert.self, .handy_vorlage), let wf = v["wf"]?.text, !wf.isEmpty {
            vorlageWf = wf
            vorlageFelder = v["felder"]?.objekt ?? [:]
        }
        zurueckgestellt = w(JSONWert.self, .halt_hand)?.wahr ?? false
        reihe = w(Double.self, .order)
        projekt = w(String.self, .projekt)
    }

    /// passt zur Suche (Titel, Art, Bildinhalt) - jedes Wort muss irgendwo vorkommen
    func passt(zu suche: String) -> Bool {
        let woerter = suche.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !woerter.isEmpty else { return true }
        let heu = (titel + " " + artName + " " + original + " " + stichworte).lowercased()
        return woerter.allSatisfy { heu.contains($0) }
    }

    var laeuft: Bool { status == "läuft" }
    var wartet: Bool { status == "wartet" || status == "angehalten" }
    var offen: Bool { laeuft || wartet }
    var fertig: Bool { status == "fertig" }
    var gescheitert: Bool { ["fehler", "abgebrochen", "unterbrochen"].contains(status) }

    /// Musikvideo/Film mit fertigen Stücken, abgebrochen -> »▶ Fortsetzen« (wie am PC)
    var fortsetzbar: Bool {
        ["x-music", "x-film"].contains(kind) && gescheitert && !probeHalt && clipsFertig > 0 && clipsFertig < clipsGesamt
    }
    /// Noch nicht angefangen (für »Wartende abbrechen«)
    var nieGestartet: Bool { wartet && started == nil && !probeHalt && clipsFertig == 0 }

    var titel: String {
        let t = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let datei = t.hasPrefix("autoi2v") || [".png", ".jpg", ".jpeg", ".webp", ".flac", ".wav", ".mp4"].contains { t.lowercased().hasSuffix($0) }
        return t.isEmpty || datei ? artName : t
    }

    var artName: String {
        switch kind {
        case "x-img": return "Bild"
        case "x-track", "x-song": return "Song"
        case "x-music": return "Musikvideo"
        case "x-film": return "Kurzfilm"
        case "x-remix": return "Remix"
        case "x-3d", "x-rig": return "3D-Modell"
        case "x-sprite": return "Spritesheet"
        case "x-stimme", "x-sound": return "Sprache"
        case "x-sfx": return "Soundeffekt"
        case "x-gif": return "GIF"
        default: return "Video"
        }
    }

    var symbol: String {
        switch kind {
        case "x-img", "x-r2i", "x-inp": return "photo"
        case "x-track", "x-song", "x-remix": return "music.note"
        case "x-music": return "music.note.tv"
        case "x-film": return "film"
        case "x-3d", "x-rig": return "cube"
        case "x-stimme", "x-sound", "x-sfx": return "waveform"
        default: return "play.rectangle"
        }
    }

    var istAudio: Bool { songInput != nil && !hatVideo }
}

/// Antwort von /api/state (nur, was die App braucht)
struct StudioStand: Decodable {
    var engineBereit = false
    var auftraege: [Auftrag] = []
    var fremd: [String] = []
    var gpuAuslastung: Int?
    var vram: Double?
    var vramGesamt: Double?
    var gpuName: String?

    enum K: String, CodingKey { case engine, jobs, foreign, gpu }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        engineBereit = ((try? c.decodeIfPresent(JSONWert.self, forKey: .engine)) ?? nil)?["up"]?.wahr ?? false
        // Aufträge einzeln dekodieren: ein kaputter Eintrag darf die Liste nicht leeren
        if let roh = (try? c.decodeIfPresent([JSONWert].self, forKey: .jobs)) ?? nil {
            let enc = JSONEncoder(), dec = JSONDecoder()
            auftraege = roh.compactMap { w in (try? enc.encode(w)).flatMap { try? dec.decode(Auftrag.self, from: $0) } }
        }
        if let f = (try? c.decodeIfPresent([JSONWert].self, forKey: .foreign)) ?? nil {
            fremd = f.compactMap { $0["name"]?.text }
        }
        if let g = (try? c.decodeIfPresent(JSONWert.self, forKey: .gpu)) ?? nil {
            gpuAuslastung = g["util"]?.zahl.map { Int($0) }
            vram = g["vram"]?.zahl
            vramGesamt = g["vram_total"]?.zahl
            gpuName = g["name"]?.text
        }
    }
}

enum Zeit {
    /// 95 -> »2 min«, 4000 -> »1 h 07 min«
    static func dauer(_ s: Double?) -> String {
        guard let s, s.isFinite, s > 0 else { return "–" }
        let sek = Int(s.rounded())
        if sek < 60 { return "\(sek) s" }
        let h = sek / 3600, m = (sek % 3600 + 30) / 60
        return h > 0 ? String(format: "%d h %02d min", h, min(m, 59)) : "\(max(1, m)) min"
    }
}
