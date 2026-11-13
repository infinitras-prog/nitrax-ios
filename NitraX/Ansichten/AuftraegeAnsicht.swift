import SwiftUI

@MainActor
struct AuftraegeAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var loeschKandidat: Auftrag?
    @EnvironmentObject private var navigation: Navigation
    enum Filter: String, CaseIterable, Identifiable {
        case alle = "Alle", laeuft = "Läuft", videos = "Videos", bilder = "Bilder", audio = "Audio"
        var id: String { rawValue }
    }
    @State private var filter: Filter = .alle
    @State private var suche = ""
    @State private var pfad = NavigationPath()
    @AppStorage("auftraege_bibliothek") private var bibliothek = false     // 📚 oben umschaltbar

    private var liste: [Auftrag] {
        let q = suche.trimmingCharacters(in: .whitespaces).lowercased()
        return studio.stand.auftraege
            .filter { a in
                switch filter {
                case .alle: return true
                case .laeuft: return a.offen
                case .videos: return a.hatVideo
                case .bilder: return a.bilderAnzahl > 0
                case .audio: return a.istAudio || ["x-stimme", "x-sound", "x-sfx"].contains(a.kind)
                }
            }
            .filter { q.isEmpty || $0.passt(zu: q) }
            .sorted { $0.created > $1.created }
    }

    var body: some View {
        NavigationStack(path: $pfad) {
            Group {
            if bibliothek {
                BibliothekAnsicht(suche: suche)
            } else {
            List {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if suche.isEmpty { VergleichKarten() }                       // 🎲 Varianten vergleichen
                // ⏳ Warteschlange ordnen, zurückstellen, vorziehen
                let wartend = studio.stand.auftraege.filter { $0.wartet }
                if !wartend.isEmpty && (filter == .alle || filter == .laeuft) && suche.isEmpty {
                    NavigationLink { WarteschlangeAnsicht() } label: {
                        HStack {
                            Label("Warteschlange", systemImage: "list.number").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(wartend.count) warte\(wartend.count == 1 ? "t" : "n")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Farbe.karte)
                }
                if liste.isEmpty {
                    if studio.erreichbar {
                        ContentUnavailableView("Keine Aufträge", systemImage: "tray", description: Text("Unter »Erstellen« legst du los."))
                            .listRowBackground(Color.clear)
                    } else {
                        ContentUnavailableView {
                            Label("PC nicht erreichbar", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("Starte NitraX AI Studio am PC.")
                        } actions: {
                            NavigationLink { VerbindungsDoktor() } label: { Label("Verbindung prüfen", systemImage: "stethoscope") }
                                .buttonStyle(.borderedProminent)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                ForEach(liste.prefix(200)) { a in
                    NavigationLink(value: a) { AuftragZeile(a: a) }
                        .listRowBackground(Farbe.karte)
                        .swipeActions(edge: .trailing) {
                            if a.offen {
                                Button("Abbrechen", role: .destructive) { Task { await studio.abbrechen(a) } }
                            }
                            if a.fortsetzbar {
                                Button("Fortsetzen") { Task { await studio.fortsetzen(a) } }.tint(Farbe.akzent)
                            }
                            if !a.offen {
                                Button(role: .destructive) { loeschKandidat = a } label: { Label("Löschen", systemImage: "trash") }
                            }
                        }
                }
            }
            }
            }
            .scrollContentBackground(.hidden)
            .nxHintergrund()
            .searchable(text: $suche, prompt: bibliothek ? "Bibliothek durchsuchen" : "Suchen")
            .confirmationDialog("»\(loeschKandidat?.titel ?? "")« löschen? Die Dateien landen am PC im Papierkorb.",
                                isPresented: Binding(get: { loeschKandidat != nil }, set: { if !$0 { loeschKandidat = nil } }), titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { if let a = loeschKandidat { Task { await studio.loeschen(a) } }; loeschKandidat = nil }
            }
            .navigationTitle(bibliothek ? "Bibliothek" : "Aufträge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Ansicht", selection: $bibliothek.animation(.snappy)) {
                        Text("Aufträge").tag(false)
                        Text("Bibliothek").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { GalerieAnsicht() } label: { Label("Offline-Galerie", systemImage: "photo.stack") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { ProjekteAnsicht() } label: { Label("Projekte", systemImage: "folder") }   // 📁
                }
            }
            .refreshable { await studio.aktualisieren() }
            .navigationDestination(for: Auftrag.self) { AuftragDetail(auftrag: $0) }
            .onChange(of: navigation.auftragZiel) { _, id in springen(id) }
            .onAppear { springen(navigation.auftragZiel) }
        }
    }

    private func springen(_ id: String?) {
        guard let id, let a = studio.stand.auftraege.first(where: { $0.id == id }) else { return }
        navigation.auftragZiel = nil
        pfad = NavigationPath()
        pfad.append(a)
    }
}

@MainActor
struct AuftragZeile: View {
    @EnvironmentObject private var studio: Studio
    var a: Auftrag
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                NXBild(url: studio.vorschauURL(a))
                if studio.vorschauURL(a) == nil { Image(systemName: a.symbol).foregroundStyle(Farbe.akzent) }
                if a.laeuft { LiveZwischenbild(auftrag: a.id) }          // 🎞 was gerade gerechnet wird
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusPunkt(a: a)
                    Text(a.titel).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text(a.artName + " · " + standText(a)).font(.caption).foregroundStyle(a.gescheitert && !a.fortsetzbar ? Farbe.fehler : .secondary).lineLimit(2)
                if a.laeuft { Fortschrittsbalken(wert: a.progress) }
            }
        }
        .padding(.vertical, 4)
        .laufGlut(a.laeuft)
    }
}

@MainActor
struct AuftragDetail: View {
    @EnvironmentObject private var studio: Studio
    let auftrag: Auftrag
    @State private var teilen: [URL] = []
    @State private var laedt = false
    @State private var abbrechenFrage = false
    @State private var loeschFrage = false
    @Environment(\.dismiss) private var schliessen
    @State private var vollbild: Int?
    @State private var enthuellen = false
    @State private var live: UIImage?
    @State private var schnitt = false
    @State private var veroeffentlichen = false

    /// immer der aktuelle Stand (Fortschritt läuft live weiter)
    private var a: Auftrag { studio.stand.auftraege.first { $0.id == auftrag.id } ?? auftrag }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                medien
                VStack(alignment: .leading, spacing: 8) {
                    HStack { StatusPunkt(a: a); Text(a.artName).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(a.titel).font(.title3.bold())
                    if !a.regie.isEmpty || !a.eigeneModelle.isEmpty {
                        Text([a.regie.isEmpty ? nil : "🎬 Regie: " + a.regie,
                              a.eigeneModelle.first.map { "Modell: " + (($0.split(separator: "\\").last.map(String.init) ?? $0).replacingOccurrences(of: ".safetensors", with: "")) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(standText(a)).font(.subheadline).foregroundStyle(a.gescheitert && !a.fortsetzbar ? Farbe.fehler : .secondary)
                    if a.laeuft { Fortschrittsbalken(wert: a.progress) }
                    if a.clipsGesamt > 0 {
                        Text("\(a.clipsFertig) von \(a.clipsGesamt) \(a.kind == "x-film" ? "Szenen" : "Stücken") fertig")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .karte()
                aktionen
                if a.fertig && a.hatVideo && (a.vorMaximal || a.vorRealismus) { VorherNachher(auftrag: a) }   // ↔
                if a.fertig { weiterKnoepfe }
            }
            .padding(16)
        }
        .nxHintergrund()
        .navigationTitle(a.artName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { !teilen.isEmpty }, set: { if !$0 { teilen = [] } })) {
            TeilenBlatt(dateien: teilen).presentationDetents([.medium, .large])
        }
        .confirmationDialog("Auftrag abbrechen? Bisher Gerechnetes bleibt erhalten.", isPresented: $abbrechenFrage, titleVisibility: .visible) {
            Button("Abbrechen", role: .destructive) { Task { await studio.abbrechen(a) } }
        }
        .confirmationDialog("Auftrag löschen? Die Dateien landen am PC im Papierkorb.", isPresented: $loeschFrage, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { Task { await studio.loeschen(a); schliessen() } }
        }
        .toolbar {
            if !a.offen {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { loeschFrage = true } label: { Image(systemName: "trash") }.tint(Farbe.fehler)
                }
            }
        }
        .task { await liveHolen() }
        .sheet(isPresented: $schnitt) { MiniSchnitt(auftrag: a) }
        .sheet(isPresented: $veroeffentlichen) { VeroeffentlichenAnsicht(auftragID: a.id) }
        .onAppear { if a.fertig && a.bilderAnzahl > 0 { enthuellen = Enthuellt.neu(a.id) } }
        .onChange(of: a.fertig) { _, f in if f && a.bilderAnzahl > 0 { enthuellen = Enthuellt.neu(a.id) } }
        .fullScreenCover(item: Binding(get: { vollbild.map { BildNr(i: $0) } }, set: { vollbild = $0?.i })) { v in
            MedienVollbild(urls: (0..<a.bilderAnzahl).compactMap { studio.url("/api/img/file/\(a.id)/\($0)") }, seite: v.i)
        }
    }

    struct BildNr: Identifiable { let i: Int; var id: Int { i } }

    @ViewBuilder private var medien: some View {
        if a.fertig, a.hatVideo, let u = studio.url("/api/video/\(a.id)") {
            NXPlayer(url: u).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if a.bilderAnzahl > 0 {
            TabView {
                ForEach(0..<a.bilderAnzahl, id: \.self) { k in
                    NXBild(url: studio.url("/api/img/file/\(a.id)/\(k)"), modus: .fit)
                        .onTapGesture { vollbild = k }
                }
            }
            .tabViewStyle(.page)
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .enthuellen(enthuellen)
        } else if a.fertig, let ton = tonPfad, let u = studio.url(ton) {
            VStack(spacing: 10) {
                if let i = a.image, !i.isEmpty {
                    NXBild(url: studio.bildURL(i), modus: .fit).frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    Image(systemName: "waveform").font(.system(size: 54)).foregroundStyle(Farbe.verlauf).frame(height: 120)
                }
                NXPlayer(url: u, nurTon: true).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else if a.laeuft, let live {
            // 👀 Live-Vorschau: Zwischenbild, während es entsteht
            Image(uiImage: live).resizable().scaledToFit().frame(maxHeight: 340)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Label("live", systemImage: "dot.radiowaves.left.and.right").font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Farbe.fehler.opacity(0.85), in: Capsule()).padding(8)
                }
                .laufGlut(true)
                .animation(.easeInOut(duration: 0.4), value: live)
        } else if let v = studio.vorschauURL(a) {
            NXBild(url: v, modus: .fit).frame(maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Zwischenbilder holen, solange der Auftrag läuft (alle 2 s)
    private func liveHolen() async {
        while !Task.isCancelled {
            if a.laeuft, let c = studio.client, let url = c.url("/api/jobs/\(a.id)/vorschau") {
                var r = URLRequest(url: url)
                r.timeoutInterval = 8
                for (k, v) in c.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
                if let (d, antwort) = try? await URLSession.shared.data(for: r), (antwort as? HTTPURLResponse)?.statusCode == 200, let b = UIImage(data: d) { live = b }
            } else if !a.laeuft { live = nil }
            try? await Task.sleep(for: .seconds(Netzlage.sparen ? 6 : 2))
        }
    }

    private var tonPfad: String? {
        if a.kind == "x-stimme" { return "/api/stimmen/datei/\(a.id)/Dialog.flac" }
        if a.songInput != nil { return "/api/flac/\(a.id)" }
        return nil
    }

    @ViewBuilder private var aktionen: some View {
        VStack(spacing: 10) {
            if a.fortsetzbar {
                Button { Task { await studio.fortsetzen(a) } } label: {
                    Label("Fortsetzen (\(a.clipsFertig)/\(a.clipsGesamt) fertig)", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if a.wartet && !a.probeHalt {                                  // ⏳ Warteschlange
                HStack(spacing: 10) {
                    if a.zurueckgestellt {
                        Button { Task { await studio.zurueckstellen(a, an: false) } } label: {
                            Label("Wieder einreihen", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                    } else {
                        Button { Task { await studio.stelle(a, zu: 0) } } label: {
                            Label("Als Nächstes", systemImage: "arrow.up.to.line").frame(maxWidth: .infinity)
                        }
                        Button { Task { await studio.zurueckstellen(a, an: true) } } label: {
                            Label("Zurückstellen", systemImage: "pause.fill").frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            if a.offen {
                Button(role: .destructive) { abbrechenFrage = true } label: {
                    Label("Abbrechen", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            ProjektZuordnen(auftrag: a)                                     // 📁
            if a.fertig && a.hatVideo {
                Button { veroeffentlichen = true } label: { Label("Veröffentlichen (TikTok, Reels, Shorts …)", systemImage: "paperplane.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { schnitt = true } label: { Label("Kürzen & teilen", systemImage: "scissors").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            if a.fertig, Musikspieler.tonPfad(a) != nil {                     // 🎵 in den Player (läuft im Hintergrund weiter)
                Button {
                    let alle = studio.stand.auftraege.filter { $0.fertig && Musikspieler.tonPfad($0) != nil }.sorted { ($0.finished ?? 0) > ($1.finished ?? 0) }
                    Musikspieler.shared.abspielen(alle, ab: alle.firstIndex(where: { $0.id == a.id }) ?? 0, client: studio.client)
                } label: { Label("Im Player abspielen", systemImage: "music.note.list").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            if a.fertig, let d = datei {
                let (pfad, name, video) = d
                HStack(spacing: 10) {
                    Button { Task { await holen(pfad, name) { teilen = [$0] } } } label: {
                        Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    if !name.hasSuffix(".flac") {
                        Button {
                            Task {
                                await holen(pfad, name) { url in
                                    Task {
                                        do { try await Herunterladen.inFotos(url, video: video); studio.meldung = "In Fotos gesichert" }
                                        catch { studio.meldung = error.localizedDescription }
                                    }
                                }
                            }
                        } label: { Label("In Fotos", systemImage: "photo.badge.arrow.down").frame(maxWidth: .infinity) }
                    }
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(laedt)
                if laedt { ProgressView("Wird geladen …").font(.caption) }
            }
        }
    }

    // MARK: Weitermachen mit dem Ergebnis (wie die Handy-Web-App)

    private func wf(_ id: String) -> Workflow? { studio.workflows?.workflows.first { $0.id == id } }

    /// 🧬 »Ähnliches erstellen«: dasselbe Formular mit denselben Eingaben zum Abwandeln. Vom Handy gestartet -> die gemerkten
    /// Eingaben; am PC gestartet -> wenigstens Beschreibung (+ Startbild) übernehmen.
    private var aehnlich: (Workflow, [String: JSONWert])? {
        if let id = a.vorlageWf, let w = wf(id), !a.vorlageFelder.isEmpty {
            let namen = Set(w.felder.map(\.name))
            return (w, a.vorlageFelder.filter { namen.contains($0.key) })
        }
        let text = a.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 3, a.titel == text else { return nil }               // nur echte Beschreibungen, keine Dateinamen
        if a.bilderAnzahl > 0, !a.hatVideo, let w = wf("x-t2i") { return (w, ["prompt": .text(text)]) }
        if a.hatVideo, let w = wf("i2v"), let bild = a.image, !bild.isEmpty {
            return (w, ["idee": .text(text), "bild": .objekt(["quelle": .text("upload"), "name": .text(bild)])])
        }
        if a.hatVideo, let w = wf("x-t2v") { return (w, ["idee": .text(text)]) }
        return nil
    }

    @ViewBuilder private var weiterKnoepfe: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weitermachen").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                if let ae = aehnlich { link("🧬 Ähnliches erstellen", ae.0, ae.1) }
                if a.wiederholbar { knopf("🎲 Neue Variante") { await starten(["wf": "_variante", "felder": ["id": a.id]], "Neue Variante läuft") } }
                if a.bilderAnzahl > 0 {
                    knopf("⤢ 2× größer") { await starten(["wf": "_hoch", "felder": ["id": a.id + ":0", "ziel": "2x"]], "Wird vergrößert") }
                    knopf("⤢ 4× größer") { await starten(["wf": "_hoch", "felder": ["id": a.id + ":0", "ziel": "4x"]], "Wird vergrößert") }
                    if let w = wf("i2v") { link("▶ Animieren", w, ["bild": .objekt(["quelle": .text("job"), "id": .text(a.id), "k": .zahl(0)])]) }
                    if let w = wf("x-r2i") { link("◧ Ändern", w, ["bilder": .liste([.objekt(["quelle": .text("job"), "id": .text(a.id), "k": .zahl(0)])])]) }
                }
                if a.hatVideo {
                    if a.maximal == "rechnet" {
                        knopf("⏹ 💎 abbrechen") { await post("/api/jobs/\(a.id)/maximal/stopp", "💎 wird abgebrochen – das Video bleibt") }
                    } else if !a.vorMaximal {
                        knopf("💎 Maximal schärfen") { await post("/api/jobs/\(a.id)/maximal", "💎 Wird maximal geschärft – das dauert eine Weile") }
                    }
                    if !a.vorRealismus && a.realismus != "rechnet" {
                        knopf("🎞 Film-Look") { await post("/api/jobs/\(a.id)/realismus", "🎞 Film-Look wird aufgetragen") }
                    }
                    if let w = wf("x-extend") { link("⇥ Verlängern", w, ["video": .text(a.id)]) }
                }
            }
            HStack(spacing: 8) {
                knopf(a.lob == "gut" ? "👍 Gefällt mir ✓" : "👍 Gefällt mir") { await bewerten(a.lob == "gut" ? "weg" : "gut") }
                knopf(a.lob == "schlecht" ? "👎 Nicht so ✓" : "👎 Nicht so") { await bewerten(a.lob == "schlecht" ? "weg" : "schlecht") }
            }
            Text("👍/👎 merkt sich NitraX – ähnliche Wünsche bekommen die Einstellungen, die dir gefallen.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .karte()
    }

    private func knopf(_ t: String, _ tun: @escaping () async -> Void) -> some View {
        Button { Task { await tun() } } label: {
            Text(t).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    private func link(_ t: String, _ w: Workflow, _ werte: [String: JSONWert]) -> some View {
        NavigationLink { WorkflowFormular(workflow: w, vorbelegung: werte) } label: {
            Text(t).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    private func starten(_ body: [String: Any], _ ok: String) async {
        guard let c = studio.client else { return }
        do { _ = try await c.post("/api/handy/start", body, zeit: 300); studio.meldung = "✓ " + ok; await studio.aktualisieren() }
        catch { studio.meldung = error.localizedDescription }
    }

    private func post(_ pfad: String, _ ok: String) async {
        guard let c = studio.client else { return }
        do { _ = try await c.post(pfad); studio.meldung = ok; await studio.aktualisieren() }
        catch { studio.meldung = error.localizedDescription }
    }

    private func bewerten(_ art: String) async {
        guard let c = studio.client else { return }
        do {
            _ = try await c.post("/api/lernen/bewerten", ["job": a.id, "art": art])
            studio.meldung = art == "weg" ? "Bewertung zurückgenommen" : "🧠 Gemerkt"
            await studio.aktualisieren()
        } catch { studio.meldung = error.localizedDescription }
    }

    private var datei: (String, String, Bool)? {
        if a.hatVideo { return ("/api/video/\(a.id)", "NitraX-\(a.id).mp4", true) }
        if a.bilderAnzahl > 0 { return ("/api/img/file/\(a.id)/0", "NitraX-\(a.id).png", false) }
        if let t = tonPfad { return (t, "NitraX-\(a.id).flac", false) }
        return nil
    }

    private func holen(_ pfad: String, _ name: String, _ fertig: @escaping (URL) -> Void) async {
        guard let c = studio.client else { return }
        laedt = true
        defer { laedt = false }
        do { fertig(try await Herunterladen.datei(c, pfad: pfad, name: name)) }
        catch { studio.meldung = error.localizedDescription }
    }
}


/// 🎞 Zwischenbild eines laufenden Auftrags (alle 3 s neu), blendet weich über das Vorschaubild
@MainActor
struct LiveZwischenbild: View {
    @EnvironmentObject private var studio: Studio
    let auftrag: String
    @State private var bild: UIImage?

    var body: some View {
        ZStack {
            if let bild { Image(uiImage: bild).resizable().scaledToFill().transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.4), value: bild)
        .task(id: auftrag) {
            while !Task.isCancelled {
                if let c = studio.client, let url = c.url("/api/jobs/\(auftrag)/vorschau") {
                    var r = URLRequest(url: url)
                    r.timeoutInterval = 6
                    for (k, v) in c.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
                    if let (d, a) = try? await URLSession.shared.data(for: r), (a as? HTTPURLResponse)?.statusCode == 200, let b = UIImage(data: d) { bild = b }
                }
                try? await Task.sleep(for: .seconds(Netzlage.sparen ? 10 : 3))
            }
        }
    }
}
