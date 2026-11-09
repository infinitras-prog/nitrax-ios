import SwiftUI
import AVFoundation

/// 📚 Bibliothek: alle fertigen Ergebnisse als übersichtliches Raster – nach Tagen gruppiert, Filter (Bilder/Videos/Musik/
/// Favoriten), Sortierung, Rastergröße, Mehrfachauswahl mit Löschen (am PC in den Papierkorb), Favorit per PC.
@MainActor
struct BibliothekAnsicht: View {
    @EnvironmentObject private var studio: Studio
    let suche: String

    enum Art: String, CaseIterable, Identifiable {
        case alle = "Alle", bilder = "Bilder", videos = "Videos", musik = "Musik", favoriten = "❤ Favoriten"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .alle: return "square.grid.2x2"
            case .bilder: return "photo"
            case .videos: return "film"
            case .musik: return "music.note"
            case .favoriten: return "heart.fill"
            }
        }
    }

    @AppStorage("bib_art") private var artRoh = Art.alle.rawValue
    @AppStorage("bib_spalten") private var spalten = 3
    @AppStorage("bib_alt_zuerst") private var altZuerst = false
    @State private var auswahl: Set<String> = []
    @State private var waehlen = false
    @State private var loeschFrage = false
    @State private var loescht = false
    @State private var teilen: [URL] = []
    @State private var arbeitet: String?                 // »Lädt 3/7 …«

    private var art: Art { Art(rawValue: artRoh) ?? .alle }

    private func passt(_ a: Auftrag) -> Bool {
        switch art {
        case .alle: return true
        case .bilder: return a.bilderAnzahl > 0 && !a.hatVideo
        case .videos: return a.hatVideo
        case .musik: return a.istAudio || ["x-music", "x-stimme", "x-sound", "x-sfx", "x-remix"].contains(a.kind) && !a.hatVideo
        case .favoriten: return a.fav
        }
    }

    private var eintraege: [Auftrag] {
        let q = suche.trimmingCharacters(in: .whitespaces).lowercased()
        return studio.stand.auftraege
            .filter { $0.fertig && passt($0) }
            .filter { q.isEmpty || $0.titel.lowercased().contains(q) || $0.artName.lowercased().contains(q) }
            .sorted { altZuerst ? zeit($0) < zeit($1) : zeit($0) > zeit($1) }
    }

    private func zeit(_ a: Auftrag) -> Double { a.finished ?? a.created }

    /// nach Tagen gruppiert: Heute, Gestern, Diese Woche, dann Monat
    struct Gruppe: Identifiable { let id: String; let liste: [Auftrag] }

    private var gruppen: [Gruppe] {
        let k = Calendar.current
        var reihenfolge: [String] = []
        var map: [String: [Auftrag]] = [:]
        for a in eintraege {
            let d = Date(timeIntervalSince1970: zeit(a))
            let name: String
            if k.isDateInToday(d) { name = "Heute" }
            else if k.isDateInYesterday(d) { name = "Gestern" }
            else if let t = k.dateComponents([.day], from: d, to: Date()).day, t < 7 { name = "Diese Woche" }
            else { name = d.formatted(.dateTime.month(.wide).year()) }
            if map[name] == nil { reihenfolge.append(name) }
            map[name, default: []].append(a)
        }
        return reihenfolge.map { Gruppe(id: $0, liste: map[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filterLeiste
                kopfzeile
                if eintraege.isEmpty {
                    ContentUnavailableView(art == .favoriten ? "Noch keine Favoriten" : "Noch nichts in der Bibliothek",
                                           systemImage: art.symbol,
                                           description: Text(art == .favoriten ? "Halte ein Ergebnis gedrückt → »Favorit«." : "Fertige Ergebnisse erscheinen hier."))
                        .padding(.top, 40)
                }
                ForEach(gruppen) { g in
                    Text(g.id).font(.headline).padding(.top, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: spalten), spacing: 6) {
                        ForEach(g.liste) { a in kachel(a) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, waehlen ? 90 : 20)
        }
        .overlay(alignment: .bottom) { if waehlen { auswahlLeiste } }
        .sheet(isPresented: Binding(get: { !teilen.isEmpty }, set: { if !$0 { teilen = [] } })) {
            TeilenBlatt(dateien: teilen).presentationDetents([.medium, .large])
        }
        .animation(.spring(duration: 0.3), value: waehlen)
        .confirmationDialog("\(auswahl.count) \(auswahl.count == 1 ? "Ergebnis" : "Ergebnisse") löschen? Die Dateien landen am PC im Papierkorb.",
                            isPresented: $loeschFrage, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { Task { await loeschen() } }
        }
    }

    // MARK: Teile

    private var filterLeiste: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Art.allCases) { a in
                    let an = a == art
                    Button { withAnimation(.snappy) { artRoh = a.rawValue } } label: {
                        Label(a.rawValue.replacingOccurrences(of: "❤ ", with: ""), systemImage: a.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(an ? AnyShapeStyle(Farbe.verlauf) : AnyShapeStyle(Farbe.karte), in: Capsule())
                            .foregroundStyle(an ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var kopfzeile: some View {
        HStack {
            Text("\(eintraege.count) \(eintraege.count == 1 ? "Ergebnis" : "Ergebnisse")").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Sortierung", selection: $altZuerst) {
                    Label("Neueste zuerst", systemImage: "arrow.down").tag(false)
                    Label("Älteste zuerst", systemImage: "arrow.up").tag(true)
                }
                Picker("Größe", selection: $spalten) {
                    Label("Groß", systemImage: "square.grid.2x2").tag(2)
                    Label("Mittel", systemImage: "square.grid.3x3").tag(3)
                    Label("Klein", systemImage: "square.grid.4x3.fill").tag(4)
                }
            } label: { Image(systemName: "arrow.up.arrow.down.circle").font(.title3) }
            Button(waehlen ? "Fertig" : "Auswählen") {
                waehlen.toggle()
                if !waehlen { auswahl = [] }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func kachel(_ a: Auftrag) -> some View {
        let gewaehlt = auswahl.contains(a.id)
        let inhalt = BibliothekKachel(a: a)
            .overlay(alignment: .topTrailing) {
                if waehlen {
                    Image(systemName: gewaehlt ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(gewaehlt ? Farbe.akzent : .white)
                        .shadow(radius: 3).padding(6)
                }
            }
            .overlay { if gewaehlt { RoundedRectangle(cornerRadius: 10).stroke(Farbe.akzent, lineWidth: 3) } }
            .scaleEffect(gewaehlt ? 0.94 : 1)
            .animation(.snappy(duration: 0.2), value: gewaehlt)
        if waehlen {
            inhalt.onTapGesture {
                if gewaehlt { auswahl.remove(a.id) } else { auswahl.insert(a.id) }
                UISelectionFeedbackGenerator().selectionChanged()
            }
        } else {
            NavigationLink(value: a) { inhalt }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { Task { await favorit(a) } } label: {
                        Label(a.fav ? "Kein Favorit mehr" : "Favorit", systemImage: a.fav ? "heart.slash" : "heart")
                    }
                    Button { waehlen = true; auswahl = [a.id] } label: { Label("Auswählen", systemImage: "checkmark.circle") }
                    Button(role: .destructive) { auswahl = [a.id]; loeschFrage = true } label: { Label("Löschen", systemImage: "trash") }
                } preview: {
                    BibliothekKachel(a: a, gross: true).frame(width: 300, height: 300)
                }
        }
    }

    private var auswahlLeiste: some View {
        HStack(spacing: 14) {
            Button(auswahl.count == eintraege.count ? "Keine" : "Alle") {
                auswahl = auswahl.count == eintraege.count ? [] : Set(eintraege.map(\.id))
            }
            Spacer()
            if let arbeitet { Text(arbeitet).font(.caption.monospacedDigit()) }
            else { Text("\(auswahl.count) ausgewählt").font(.subheadline.weight(.semibold)) }
            Spacer()
            // 📤 alle markierten teilen · ⬇ in Fotos sichern
            Button { Task { await holenAlle(sichern: false) } } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(auswahl.isEmpty || arbeitet != nil)
            Button { Task { await holenAlle(sichern: true) } } label: { Image(systemName: "square.and.arrow.down") }
                .disabled(auswahl.isEmpty || arbeitet != nil)
            Button(role: .destructive) { loeschFrage = true } label: {
                if loescht { ProgressView() } else { Label("Löschen", systemImage: "trash").labelStyle(.titleAndIcon) }
            }
            .disabled(auswahl.isEmpty || loescht)
            .tint(Farbe.fehler)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Aktionen

    private func loeschen() async {
        guard let c = studio.client else { return }
        loescht = true
        defer { loescht = false }
        var ok = 0, fehler = 0
        for id in auswahl {
            if (try? await c.post("/api/jobs/\(id)/delete-files")) != nil { ok += 1 } else { fehler += 1 }
        }
        UINotificationFeedbackGenerator().notificationOccurred(fehler == 0 ? .success : .warning)
        studio.meldung = fehler == 0 ? "🗑 \(ok) gelöscht (am PC im Papierkorb)" : "🗑 \(ok) gelöscht, \(fehler) ging nicht"
        auswahl = []
        waehlen = false
        await studio.aktualisieren()
    }

    /// Datei eines Ergebnisses (Video, sonst Bilder, sonst Ton)
    private func dateien(_ a: Auftrag) -> [(String, String, Bool)] {
        if a.hatVideo { return [("/api/video/\(a.id)", "NitraX-\(a.id).mp4", true)] }
        if a.bilderAnzahl > 0 { return (0..<a.bilderAnzahl).map { ("/api/img/file/\(a.id)/\($0)", "NitraX-\(a.id)-\($0 + 1).png", false) } }
        if a.songInput != nil { return [("/api/flac/\(a.id)", "NitraX-\(a.id).flac", false)] }
        return []
    }

    private func holenAlle(sichern: Bool) async {
        guard let c = studio.client else { return }
        let liste = eintraege.filter { auswahl.contains($0.id) }.flatMap(dateien)
        guard !liste.isEmpty else { return }
        var fertig: [URL] = [], fehler = 0
        for (i, d) in liste.enumerated() {
            arbeitet = "\(sichern ? "Sichert" : "Lädt") \(i + 1)/\(liste.count) …"
            do {
                let u = try await Herunterladen.datei(c, pfad: d.0, name: d.1)
                if sichern {
                    if d.1.hasSuffix(".flac") { fehler += 1; continue }          // Ton kann nicht in die Fotos
                    try await Herunterladen.inFotos(u, video: d.2)
                }
                fertig.append(u)
            } catch { fehler += 1 }
        }
        arbeitet = nil
        UINotificationFeedbackGenerator().notificationOccurred(fehler == 0 ? .success : .warning)
        if sichern {
            studio.meldung = "⬇ \(fertig.count) in Fotos gesichert" + (fehler > 0 ? " · \(fehler) nicht möglich" : "")
            auswahl = []; waehlen = false
        } else {
            teilen = fertig
        }
    }

    private func favorit(_ a: Auftrag) async {
        guard let c = studio.client else { return }
        _ = try? await c.post("/api/jobs/\(a.id)/favorite")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        await studio.aktualisieren()
    }
}

/// Eine Kachel: Vorschaubild (bei Videos ein Standbild aus dem Video), Art-Symbol, Dauer, Favorit
@MainActor
struct BibliothekKachel: View {
    @EnvironmentObject private var studio: Studio
    let a: Auftrag
    var gross = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let u = studio.vorschauURL(a) {
                    NXBild(url: u)
                } else if a.hatVideo, let u = studio.url("/api/video/\(a.id)") {
                    VideoStandbild(url: u)
                } else {
                    ZStack {
                        Farbe.verlauf.opacity(0.35)
                        Image(systemName: a.symbol).font(.system(size: gross ? 60 : 28)).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Image(systemName: a.hatVideo ? "play.fill" : a.bilderAnzahl > 1 ? "square.stack.fill" : a.symbol)
                    if a.hatVideo, let s = a.sekunden, s > 0 { Text(String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)) }
                    else if a.bilderAnzahl > 1 { Text("\(a.bilderAnzahl)") }
                }
                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(5)
            }
            .overlay(alignment: .topLeading) {
                if a.fav { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink).shadow(radius: 2).padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Standbild aus einem Video vom PC (mit Cookie), zwischengespeichert
@MainActor
struct VideoStandbild: View {
    @EnvironmentObject private var studio: Studio
    let url: URL
    @State private var bild: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Farbe.karte)
            if let bild { Image(uiImage: bild).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "film").foregroundStyle(.secondary) }
        }
        .task(id: url) { await laden() }
    }

    private func laden() async {
        if let b = BildSpeicher.cache.object(forKey: url as NSURL) { bild = b; return }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": studio.client?.cookieKopf ?? [:]])
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        if let r = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
            let b = UIImage(cgImage: r.image)
            BildSpeicher.cache.setObject(b, forKey: url as NSURL)
            bild = b
        }
    }
}
