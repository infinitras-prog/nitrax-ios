import SwiftUI
import PhotosUI

/// 🎬 Storyboard-Editor: Kurzfilm Szene für Szene planen (Ort, Handlung, Dialog, Länge, Perspektive), feste Figuren mit
/// Foto, ziehen zum Umsortieren - dann dreht das Filmstudio (x-film) genau diese Szenen. Entwürfe bleiben auf dem iPhone.
struct StoryboardSzene: Codable, Identifiable, Hashable {
    var id = UUID()
    var ort = ""
    var handlung = ""
    var dialog = ""
    var perspektive = "normal"
    var sekunden = 8
}

struct StoryboardFigur: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var bild: String?              // Upload-Name am PC
    var stumm = false
}

struct Storyboard: Codable, Identifiable, Hashable {
    var id = UUID()
    var titel = "Mein Kurzfilm"
    var stil = ""
    var format = "16:9"
    var dialog = true
    var probe = false
    var szenen: [StoryboardSzene] = [StoryboardSzene()]
    var figuren: [StoryboardFigur] = []
    var geaendert = Date()

    var sekunden: Int { szenen.reduce(0) { $0 + $1.sekunden } }

    static let schluessel = "storyboards"
    static func alle() -> [Storyboard] {
        guard let d = UserDefaults.standard.data(forKey: schluessel) else { return [] }
        return (try? JSONDecoder().decode([Storyboard].self, from: d)) ?? []
    }
    static func sichern(_ l: [Storyboard]) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: schluessel) }
    }

    /// Beschreibung für die Regie des Filmstudios
    var idee: String {
        var t = "Kurzfilm »\(titel)« – bitte GENAU diese \(szenen.count) Szenen in dieser Reihenfolge drehen:\n"
        for (i, s) in szenen.enumerated() {
            var z = "Szene \(i + 1) (ca. \(s.sekunden) s"
            if !s.ort.isEmpty { z += ", Ort: \(s.ort)" }
            if s.perspektive != "normal" { z += ", \(StoryboardAnsicht.perspektiven.first { $0.0 == s.perspektive }?.1 ?? s.perspektive)" }
            z += "): " + (s.handlung.isEmpty ? "(Regie entscheidet)" : s.handlung)
            if !s.dialog.trimmingCharacters(in: .whitespaces).isEmpty { z += "\n  Dialog: " + s.dialog }
            t += z + "\n"
        }
        return t
    }
}

@MainActor
struct StoryboardListe: View {
    @State private var boards = Storyboard.alle()

    var body: some View {
        List {
            Section {
                Button {
                    var b = Storyboard()
                    b.titel = "Kurzfilm \(boards.count + 1)"
                    boards.insert(b, at: 0)
                    Storyboard.sichern(boards)
                } label: { Label("Neues Storyboard", systemImage: "plus.rectangle.on.rectangle") }
            }
            ForEach($boards) { $b in
                NavigationLink {
                    StoryboardAnsicht(board: $b) { Storyboard.sichern(boards) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(b.titel).font(.headline)
                        Text("\(b.szenen.count) Szenen · ca. \(b.sekunden) s · \(b.geaendert.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Farbe.karte)
            }
            .onDelete { boards.remove(atOffsets: $0); Storyboard.sichern(boards) }
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle("Storyboards")
    }
}

@MainActor
struct StoryboardAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    @Binding var board: Storyboard
    var sichern: () -> Void

    static let perspektiven = [("normal", "Normal"), ("nah", "Nahaufnahme"), ("totale", "Totale"), ("ego", "Ego-Perspektive"),
                               ("selfie", "Selfie / GoPro"), ("drohne", "Drohne von oben"), ("fahrt", "Kamerafahrt")]
    @State private var fotos: PhotosPickerItem?
    @State private var fotoFuer: UUID?
    @State private var startet = false
    @State private var kiLaeuft = false
    @State private var fehler: String?

    var body: some View {
        List {
            Section("Film") {
                TextField("Titel", text: $board.titel)
                TextField("Stil (optional, z. B. Pixar, Noir, Anime)", text: $board.stil)
                Picker("Format", selection: $board.format) {
                    Text("16:9 quer").tag("16:9"); Text("9:16 hoch").tag("9:16"); Text("1:1").tag("1:1")
                }
                Toggle("Mit Dialog", isOn: $board.dialog)
                Toggle("Erst 2 Szenen als Probe", isOn: $board.probe)
                Button {
                    Task { await kiVorschlag() }
                } label: {
                    if kiLaeuft {
                        HStack {
                            ProgressView()
                            Text("Regie denkt …")
                        }
                    } else {
                        Label("🎲 Szenen von der KI vorschlagen", systemImage: "wand.and.stars")
                    }
                }
                .disabled(kiLaeuft)
            }

            Section {
                ForEach($board.szenen) { $s in
                    let nr = (board.szenen.firstIndex(of: s) ?? 0) + 1
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Szene \(nr)").font(.headline)
                            Spacer()
                            Stepper("\(s.sekunden) s", value: $s.sekunden, in: 3...20).fixedSize()
                        }
                        TextField("Ort (z. B. Strand bei Sonnenuntergang)", text: $s.ort)
                        TextField("Was passiert?", text: $s.handlung, axis: .vertical).lineLimit(2...6)
                        if board.dialog { TextField("Dialog (optional) – z. B. Tom: »Schau mal!«", text: $s.dialog, axis: .vertical).lineLimit(1...4) }
                        Picker("Kamera", selection: $s.perspektive) {
                            ForEach(Self.perspektiven, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Farbe.karte)
                }
                .onMove { board.szenen.move(fromOffsets: $0, toOffset: $1); geaendert() }
                .onDelete { board.szenen.remove(atOffsets: $0); geaendert() }
                Button { board.szenen.append(StoryboardSzene()); geaendert() } label: { Label("Szene hinzufügen", systemImage: "plus") }
            } header: { Text("Szenen · ca. \(board.sekunden) s") } footer: {
                Text("Halten und ziehen zum Umsortieren, nach links wischen zum Löschen.")
            }

            Section {
                ForEach($board.figuren) { $f in
                    HStack(spacing: 12) {
                        PhotosPicker(selection: Binding(get: { nil }, set: { item in fotoFuer = f.id; fotos = item }), matching: .images) {
                            Group {
                                if let n = f.bild { NXBild(url: studio.bildURL(n)) } else { Image(systemName: "person.crop.square.badge.camera").font(.title2) }
                            }
                            .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading) {
                            TextField("Name", text: $f.name)
                            Toggle("spricht nie", isOn: $f.stumm).font(.caption)
                        }
                    }
                    .listRowBackground(Farbe.karte)
                }
                .onDelete { board.figuren.remove(atOffsets: $0); geaendert() }
                if board.figuren.count < 4 {
                    Button { board.figuren.append(StoryboardFigur()); geaendert() } label: { Label("Figur hinzufügen", systemImage: "person.badge.plus") }
                }
            } header: { Text("Feste Figuren (optional, bis 4)") } footer: {
                Text("Mit Foto sieht die Figur in jeder Szene gleich aus.")
            }

            Section {
                Button {
                    Task { await drehen() }
                } label: {
                    HStack {
                        Spacer()
                        if startet { ProgressView() } else { Label("Film drehen", systemImage: "film.stack").font(.headline) }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(startet || board.szenen.allSatisfy { $0.handlung.isEmpty && $0.ort.isEmpty })
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle(board.titel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onChange(of: board) { _, _ in sichern() }
        .onChange(of: fotos) { _, item in if let item, let ziel = fotoFuer { Task { await figurFoto(item, ziel) } } }
        .alert("Storyboard", isPresented: Binding(get: { fehler != nil }, set: { if !$0 { fehler = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(fehler ?? "") }
    }

    private func geaendert() { board.geaendert = Date(); sichern() }

    private func figurFoto(_ item: PhotosPickerItem, _ id: UUID) async {
        defer { fotos = nil }
        guard let c = studio.client, let d = try? await item.loadTransferable(type: Data.self) else { return }
        let jpeg = UIImage(data: d)?.jpegData(compressionQuality: 0.9) ?? d
        do {
            let r = try await c.hochladen("/api/upload", daten: jpeg, dateiname: "figur.jpg", typ: "image/jpeg")
            if let n = r["name"]?.text, let i = board.figuren.firstIndex(where: { $0.id == id }) { board.figuren[i].bild = n; geaendert() }
        } catch { fehler = error.localizedDescription }
    }

    /// Regie schlägt eine Handlung vor -> auf die Szenen verteilt
    private func kiVorschlag() async {
        guard let c = studio.client else { return }
        kiLaeuft = true
        defer { kiLaeuft = false }
        do {
            let r = try await c.post("/api/handy/prompt", ["wf": "x-film", "modus": "vorschlag", "text": board.titel,
                                                           "felder": ["dialog": board.dialog, "stil": board.stil]], zeit: 180)
            let text = r["text"]?.text ?? ""
            let saetze = text.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 8 }
            guard !saetze.isEmpty else { fehler = "Die Regie hatte gerade keine Idee – nochmal versuchen?"; return }
            let anzahl = max(3, min(6, saetze.count))
            var neu: [StoryboardSzene] = []
            for i in 0..<anzahl {
                var s = i < board.szenen.count ? board.szenen[i] : StoryboardSzene()
                if s.handlung.isEmpty { s.handlung = saetze[min(i, saetze.count - 1)] + "." }
                neu.append(s)
            }
            board.szenen = neu
            geaendert()
        } catch { fehler = error.localizedDescription }
    }

    private func drehen() async {
        guard let c = studio.client else { return }
        startet = true
        defer { startet = false }
        let sek = board.sekunden
        let laenge = [30, 60, 90, 120].min { abs($0 - sek) < abs($1 - sek) } ?? 60
        let szenen = [3, 4, 6, 8].contains(board.szenen.count) ? String(board.szenen.count) : "0"
        var felder: [String: Any] = ["idee": board.idee, "sekunden": String(laenge), "szenen": szenen, "dialog": board.dialog,
                                     "format": board.format, "probe": board.probe]
        if !board.stil.isEmpty { felder["stil"] = board.stil }
        let mitFoto = board.figuren.filter { $0.bild != nil }
        if !mitFoto.isEmpty {
            felder["figuren"] = mitFoto.map { ["quelle": "upload", "name": $0.bild ?? ""] }
            felder["figurnamen"] = mitFoto.map { $0.name.isEmpty ? "Figur" : $0.name }.joined(separator: ", ")
        }
        let stumm = board.figuren.filter { $0.stumm && !$0.name.isEmpty }.map(\.name)
        if !stumm.isEmpty { felder["stumm"] = stumm.joined(separator: ", ") }
        do {
            _ = try await c.post("/api/handy/start", ["wf": "x-film", "felder": felder], zeit: 300)
            studio.meldung = "🎬 »\(board.titel)« wird gedreht"
            await studio.aktualisieren()
            navigation.reiter = .auftraege
        } catch { fehler = error.localizedDescription }
    }
}
