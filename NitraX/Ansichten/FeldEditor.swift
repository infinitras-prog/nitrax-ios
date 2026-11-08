import SwiftUI
import PhotosUI
import PencilKit
import AVFoundation
import UniformTypeIdentifiers

/// Video aus der Mediathek als Datei übernehmen
struct FilmDatei: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { r in
            let ext = r.file.pathExtension.isEmpty ? "mov" : r.file.pathExtension
            let ziel = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: r.file, to: ziel)
            return FilmDatei(url: ziel)
        }
    }
}

/// Ein Formularfeld (Art wie in handy_wf.py: text, lang, zahl, schalter, wahl, stimme, bildmodell, bild, bilder, video,
/// videodatei, audio, zeichnung, aufnahme)
@MainActor
struct FeldEditor: View {
    @EnvironmentObject private var studio: Studio
    let feld: Feld
    let workflow: Workflow
    @Binding var wert: JSONWert?
    var alle: [String: JSONWert]

    @State private var fotos: [PhotosPickerItem] = []
    @State private var film: PhotosPickerItem?
    @State private var laedtHoch = false
    @State private var prozent: Double?
    @State private var kamera = false
    @State private var ergebnisse = false
    @State private var tonDatei = false
    @State private var malen = false
    @State private var helferVarianten: [String] = []
    @State private var helferLaeuft = false
    @State private var fehler: String?
    @State private var kiLaeuft: String?          // "vorschlag" / "verbessern"
    @State private var kiVorher: String?          // ↩ zurück zum eigenen Text

    var body: some View {
        Group {
            switch feld.art {
            case "text":
                VStack(alignment: .leading, spacing: 8) {
                    HStack { TextField(feld.platz ?? "", text: textBindung); DiktierKnopf(text: textBindung) }
                    if feld.ki { automatikLeiste }
                }
            case "lang":
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        TextField(feld.platz ?? "", text: textBindung, axis: .vertical).lineLimit(3...10)
                        DiktierKnopf(text: textBindung)
                    }
                    if feld.ki { automatikLeiste }
                }
            case "zahl":
                HStack {
                    TextField(feld.platz ?? "", value: zahlBindung, format: .number).keyboardType(.decimalPad)
                    if let mi = feld.min, let ma = feld.max {
                        Stepper("", value: zahlBindung, in: mi...ma, step: feld.schritt ?? 1).labelsHidden()
                    }
                }
            case "schalter":
                Toggle(feld.label, isOn: Binding(get: { wert?.wahr ?? false }, set: { wert = .wahr($0) }))
            case "wahl":
                wahl
            case "stimme":
                Picker("Stimme", selection: textBindung) {
                    Text(feld.pflicht ? "– Stimme wählen –" : "automatisch").tag("")
                    ForEach(studio.workflows?.stimmen ?? []) { Text($0.name).tag($0.id) }
                }
            case "bildmodell":
                Picker("Bildmodell", selection: textBindung) {
                    Text("automatisch").tag("")
                    ForEach(studio.bildmodelle) { Text($0.label).tag($0.id) }
                }
            case "bild", "bilder", "zeichnung":
                bilder
            case "video":
                Menu {
                    ForEach(studio.workflows?.ergebnisse.videos ?? []) { v in
                        Button(v.titel) { wert = .text(v.id) }
                    }
                } label: {
                    zeile(symbol: "film", titel: videoTitel ?? "Video wählen", unter: "aus deinen fertigen Videos")
                }
            case "videodatei":
                PhotosPicker(selection: $film, matching: .videos) {
                    zeile(symbol: "video.badge.plus", titel: wert?["original"]?.text ?? "Video hochladen", unter: "aus deiner Mediathek")
                }
                .onChange(of: film) { _, item in if let item { Task { await videoHoch(item) } } }
            case "audio":
                Menu {
                    Button("Audiodatei vom iPhone …", systemImage: "folder") { tonDatei = true }
                    ForEach(studio.workflows?.ergebnisse.songs ?? []) { s in
                        Button(s.titel) { wert = .objekt(["quelle": .text("job"), "id": .text(s.id)]) }
                    }
                } label: {
                    zeile(symbol: "music.note", titel: audioTitel ?? "Audio wählen", unter: "aus deinen Songs oder eine Datei")
                }
                .fileImporter(isPresented: $tonDatei, allowedContentTypes: [.audio]) { r in
                    if case .success(let url) = r { Task { await audioHoch(url) } }
                }
            case "aufnahme":
                Aufnehmer { url, sek in Task { await audioHoch(url, original: "🎙 Aufnahme · \(Int(sek)) s") } }
                if let o = wert?["original"]?.text { Text(o).font(.caption).foregroundStyle(.secondary) }
            default:
                TextField(feld.platz ?? "", text: textBindung)
            }
        }
        .overlay(alignment: .topTrailing) {
            if laedtHoch {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(prozent.map { $0 >= 0.999 ? "PC verarbeitet …" : "Hochladen \(Int($0 * 100)) %" } ?? "Bitte warten …")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4).background(.ultraThinMaterial, in: Capsule())
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { fehler != nil }, set: { if !$0 { fehler = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(fehler ?? "") }
    }

    // MARK: Bindungen

    private var textBindung: Binding<String> {
        Binding(get: { wert?.text ?? "" }, set: { wert = .text($0) })
    }
    private var zahlBindung: Binding<Double> {
        Binding(get: { wert?.zahl ?? feld.min ?? 0 }, set: { wert = .zahl($0) })
    }

    @ViewBuilder private var wahl: some View {
        let bindung = Binding<Int>(
            get: { feld.optionen.firstIndex { $0.schluessel.text == wert?.text } ?? 0 },
            set: { i in if feld.optionen.indices.contains(i) { wert = feld.optionen[i].schluessel } })
        if feld.optionen.count <= 4 && feld.optionen.allSatisfy({ $0.text.count <= 14 }) {
            Picker(feld.label, selection: bindung) {
                ForEach(feld.optionen.indices, id: \.self) { Text(feld.optionen[$0].text).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            Picker(feld.label, selection: bindung) {
                ForEach(feld.optionen.indices, id: \.self) { Text(feld.optionen[$0].text).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    private func zeile(symbol: String, titel: String, unter: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Farbe.akzent).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(titel).foregroundStyle(.primary).lineLimit(1)
                Text(unter).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var videoTitel: String? {
        guard let id = wert?.text, !id.isEmpty else { return nil }
        return studio.workflows?.ergebnisse.videos.first { $0.id == id }?.titel ?? id
    }
    private var audioTitel: String? {
        guard let w = wert, !w.istLeer else { return nil }
        if w["quelle"]?.text == "job", let id = w["id"]?.text { return studio.workflows?.ergebnisse.songs.first { $0.id == id }?.titel ?? id }
        return w["original"]?.text ?? w["name"]?.text
    }

    // MARK: Bilder

    private var bildListe: [JSONWert] {
        if feld.art == "bilder" { return wert?.liste ?? [] }
        if let w = wert, !w.istLeer { return [w] }
        return []
    }
    private var maxBilder: Int { feld.art == "bilder" ? Int(feld.max ?? 4) : 1 }

    @ViewBuilder private var bilder: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !bildListe.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(bildListe.enumerated()), id: \.offset) { i, b in
                            ZStack(alignment: .topTrailing) {
                                NXBild(url: vorschau(b)).frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 10))
                                Button { entfernen(i) } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .padding(3)
                            }
                        }
                    }
                }
            }
            if bildListe.count < maxBilder {
                HStack(spacing: 8) {
                    if feld.art == "zeichnung" {
                        Button { malen = true } label: { Label("Zeichnen", systemImage: "pencil.tip") }
                    }
                    Button { kamera = true } label: { Label("Foto", systemImage: "camera") }
                    PhotosPicker(selection: $fotos, maxSelectionCount: maxBilder - bildListe.count, matching: .images) {
                        Label("Galerie", systemImage: "photo.on.rectangle")
                    }
                    if feld.art != "zeichnung" {
                        Button { ergebnisse = true } label: { Label("Ergebnis", systemImage: "sparkles.rectangle.stack") }
                    }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        }
        .onChange(of: fotos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for it in items { if let d = try? await it.loadTransferable(type: Data.self) { await bildHoch(d) } }
                fotos = []
            }
        }
        .fullScreenCover(isPresented: $kamera) {
            KameraAufnahme { d in Task { await bildHoch(d) } }.ignoresSafeArea()
        }
        .sheet(isPresented: $ergebnisse) {
            ErgebnisWahl { id, k in dazu(.objekt(["quelle": .text("job"), "id": .text(id), "k": .zahl(Double(k))])) }
        }
        .sheet(isPresented: $malen) {
            Malflaeche { d in Task { await bildHoch(d) } }
        }
    }

    private func vorschau(_ b: JSONWert) -> URL? {
        if b["quelle"]?.text == "upload", let n = b["name"]?.text { return studio.bildURL(n) }
        if let id = b["id"]?.text { return studio.url("/api/img/file/\(id)/\(Int(b["k"]?.zahl ?? 0))") }
        return nil
    }

    private func dazu(_ b: JSONWert) {
        if feld.art == "bilder" { wert = .liste(Array((bildListe + [b]).prefix(maxBilder))) } else { wert = b }
    }

    private func entfernen(_ i: Int) {
        if feld.art == "bilder" { var l = bildListe; l.remove(at: i); wert = .liste(l) } else { wert = nil }
    }

    /// 📤 Upload-Fortschritt fürs Feld und für den Starten-Knopf
    private var melder: @Sendable (Double) -> Void {
        { p in Task { @MainActor in prozent = p; UploadStand.shared.prozent = p } }
    }

    private func bildHoch(_ daten: Data) async {
        guard let c = studio.client else { return }
        // HEIC & Co. als JPEG (der PC liest alles, JPEG ist aber klein und überall bekannt)
        let jpeg = UIImage(data: daten)?.jpegData(compressionQuality: 0.92) ?? daten
        laedtHoch = true; prozent = nil; UploadStand.shared.laeuft += 1
        defer { laedtHoch = false; prozent = nil; UploadStand.shared.laeuft -= 1 }
        do {
            let r = try await c.hochladen("/api/upload", daten: jpeg, dateiname: "iphone.jpg", typ: "image/jpeg", fortschritt: melder)
            guard let n = r["name"]?.text else { throw NXFehler.antwort }
            dazu(.objekt(["quelle": .text("upload"), "name": .text(n)]))
        } catch { fehler = error.localizedDescription }
    }

    private func videoHoch(_ item: PhotosPickerItem) async {
        guard let c = studio.client else { return }
        laedtHoch = true; prozent = nil; UploadStand.shared.laeuft += 1
        defer { laedtHoch = false; prozent = nil; UploadStand.shared.laeuft -= 1; film = nil }
        do {
            guard let f = try await item.loadTransferable(type: FilmDatei.self) else { throw NXFehler.antwort }
            let d = try Data(contentsOf: f.url)
            let r = try await c.hochladen("/api/upload-video", daten: d, dateiname: f.url.lastPathComponent, typ: "video/quicktime", fortschritt: melder)
            try? FileManager.default.removeItem(at: f.url)
            guard let id = r["id"]?.text else { throw NXFehler.antwort }
            wert = .objekt(["id": .text(id), "original": r["original"] ?? .text("Video"), "duration": r["duration"] ?? .nichts])
        } catch { fehler = error.localizedDescription }
    }

    private func audioHoch(_ url: URL, original: String? = nil) async {
        guard let c = studio.client else { return }
        laedtHoch = true; prozent = nil; UploadStand.shared.laeuft += 1
        defer { laedtHoch = false; prozent = nil; UploadStand.shared.laeuft -= 1 }
        let zugriff = url.startAccessingSecurityScopedResource()
        defer { if zugriff { url.stopAccessingSecurityScopedResource() } }
        do {
            let d = try Data(contentsOf: url)
            let r = try await c.hochladen("/api/upload-audio", daten: d, dateiname: url.lastPathComponent, typ: "audio/" + (url.pathExtension.isEmpty ? "wav" : url.pathExtension), fortschritt: melder)
            guard let n = r["name"]?.text else { throw NXFehler.antwort }
            wert = .objekt(["quelle": .text("upload"), "name": .text(n), "original": .text(original ?? url.lastPathComponent)])
        } catch { fehler = error.localizedDescription }
    }

    // MARK: Prompt-Helfer (wie am PC: eigene Worte -> Prompt, nochmal = andere Variante)

    /// 🎲 Vorschlag (Autoprompt: die Regie-KI schreibt passend zu Bild und Einstellungen), ✨ Verbessern,
    /// 🪄 Prompt-Helfer (eigene Worte -> Prompt, nochmal = andere Variante), ↩ zurück - wie in der Handy-Seite.
    private var automatikLeiste: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kiKnopf("Vorschlag", symbol: "dice", modus: "vorschlag")
                kiKnopf("Verbessern", symbol: "sparkles", modus: "verbessern")
                Button {
                    Task { await promptHelfer() }
                } label: {
                    if helferLaeuft { ProgressView().controlSize(.small) }
                    else { Label(helferVarianten.isEmpty ? "Prompt-Helfer" : "Variante \(helferVarianten.count + 1)", systemImage: "wand.and.stars") }
                }
                .disabled(helferLaeuft || kiLaeuft != nil)
                if let v = kiVorher {
                    Button { wert = .text(v); kiVorher = nil } label: { Label("Zurück", systemImage: "arrow.uturn.backward") }
                }
            }
            .buttonStyle(.bordered).font(.footnote)
        }
    }

    private func kiKnopf(_ titel: String, symbol: String, modus: String) -> some View {
        Button {
            Task { await kiText(modus) }
        } label: {
            if kiLaeuft == modus { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(modus == "verbessern" ? "verbessert …" : "denkt …") } }
            else { Label(titel, systemImage: symbol) }
        }
        .disabled(kiLaeuft != nil || helferLaeuft)
    }

    private func kiText(_ modus: String) async {
        guard let c = studio.client else { return }
        let text = wert?.text ?? ""
        if modus == "verbessern" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fehler = "Erst etwas eintippen – dann verbessert die KI es."
            return
        }
        kiLaeuft = modus
        defer { kiLaeuft = nil }
        var felder: [String: Any] = [:]
        for (k, v) in alle { felder[k] = v.roh }
        do {
            let r = try await c.post("/api/handy/prompt", ["wf": workflow.id, "modus": modus, "text": text, "felder": felder], zeit: 180)
            guard let neu = r["text"]?.text, !neu.isEmpty else { throw NXFehler.antwort }
            kiVorher = text
            wert = .text(neu)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        } catch { fehler = error.localizedDescription }
    }

    private func promptHelfer() async {
        guard let c = studio.client else { return }
        let text = (wert?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { fehler = "Erst in eigenen Worten hineinschreiben, was du möchtest."; return }
        if let letzte = helferVarianten.last, text != letzte { helferVarianten = [] }     // neuer Wunsch
        let wunsch = helferVarianten.isEmpty ? text : (Gemeinsam.defaults.string(forKey: "ph-wunsch-\(feld.name)") ?? text)
        if helferVarianten.isEmpty { Gemeinsam.defaults.set(text, forKey: "ph-wunsch-\(feld.name)") }
        helferLaeuft = true
        defer { helferLaeuft = false }
        var kontext: [String: Any] = [:]
        for (k, v) in alle { if let t = v.text, t.count <= 80 { kontext[k] = t } }
        do {
            let r = try await c.post("/api/prompt/helfer", ["wunsch": wunsch, "wf": workflow.id, "feld": [feld.label, feld.platz ?? ""].joined(separator: " · "),
                                                           "kontext": kontext, "vorher": helferVarianten], zeit: 180)
            if let p = r["prompt"]?.text { wert = .text(p); helferVarianten.append(p) }
        } catch { fehler = error.localizedDescription }
    }
}

/// Fertige Bilder vom PC auswählen
@MainActor
struct ErgebnisWahl: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    var gewaehlt: (String, Int) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(studio.workflows?.ergebnisse.bilder ?? []) { e in
                        ForEach(0..<max(1, e.anzahl ?? 1), id: \.self) { k in
                            Button { gewaehlt(e.id, k); dismiss() } label: {
                                NXBild(url: studio.url("/api/img/file/\(e.id)/\(k)")).frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Bild wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

/// Kamera (UIImagePickerController)
struct KameraAufnahme: UIViewControllerRepresentable {
    var fertig: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Koordinator { Koordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Koordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let eltern: KameraAufnahme
        init(_ e: KameraAufnahme) { eltern = e }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let b = info[.originalImage] as? UIImage, let d = b.jpegData(compressionQuality: 0.92) { eltern.fertig(d) }
            eltern.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { eltern.dismiss() }
    }
}

/// Zeichenfläche (PencilKit) -> PNG
@MainActor
struct Malflaeche: View {
    @Environment(\.dismiss) private var dismiss
    var fertig: (Data) -> Void
    @State private var leinwand = PKCanvasView()

    var body: some View {
        NavigationStack {
            LeinwandAnsicht(leinwand: leinwand)
                .background(Color.white)
                .aspectRatio(1, contentMode: .fit)
                .padding()
                .navigationTitle("Zeichnen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Übernehmen") {
                            let r = CGRect(origin: .zero, size: leinwand.bounds.size)
                            let bild = UIGraphicsImageRenderer(size: r.size).image { ctx in
                                UIColor.white.setFill(); ctx.fill(r)
                                leinwand.drawing.image(from: r, scale: 2).draw(in: r)
                            }
                            if let d = bild.pngData() { fertig(d) }
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button { leinwand.drawing = PKDrawing() } label: { Label("Leeren", systemImage: "trash") }
                    }
                }
        }
    }
}

struct LeinwandAnsicht: UIViewRepresentable {
    let leinwand: PKCanvasView
    final class Koordinator { let werkzeuge = PKToolPicker() }
    func makeCoordinator() -> Koordinator { Koordinator() }
    func makeUIView(context: Context) -> PKCanvasView {
        let werkzeuge = context.coordinator.werkzeuge
        leinwand.drawingPolicy = .anyInput
        leinwand.backgroundColor = .white
        leinwand.overrideUserInterfaceStyle = .light
        leinwand.tool = PKInkingTool(.pen, color: .black, width: 8)
        werkzeuge.setVisible(true, forFirstResponder: leinwand)
        werkzeuge.addObserver(leinwand)
        DispatchQueue.main.async { leinwand.becomeFirstResponder() }
        return leinwand
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {}
}

/// Melodie aufnehmen (WAV, 5-60 s)
@MainActor
struct Aufnehmer: View {
    var fertig: (URL, Double) -> Void
    @State private var rekorder: AVAudioRecorder?
    @State private var start = Date()
    @State private var sekunden = 0.0
    @State private var uhr: Timer?

    var body: some View {
        HStack {
            Button {
                if rekorder == nil { beginnen() } else { beenden() }
            } label: {
                Label(rekorder == nil ? "Aufnehmen" : "Stopp", systemImage: rekorder == nil ? "mic.circle.fill" : "stop.circle.fill")
                    .font(.headline)
                    .foregroundStyle(rekorder == nil ? Farbe.akzent : Farbe.fehler)
            }
            .buttonStyle(.plain)
            Spacer()
            if rekorder != nil { Text(String(format: "%.0f s", sekunden)).monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    private func beginnen() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? s.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aufnahme-\(UUID().uuidString.prefix(6)).wav")
        let einst: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        guard let r = try? AVAudioRecorder(url: url, settings: einst) else { return }
        r.record(forDuration: 60)
        rekorder = r
        start = Date()
        uhr = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            sekunden = Date().timeIntervalSince(start)
            if sekunden >= 60 { beenden() }
        }
    }

    private func beenden() {
        uhr?.invalidate()
        guard let r = rekorder else { return }
        r.stop()
        rekorder = nil
        let dauer = Date().timeIntervalSince(start)
        if dauer >= 2 { fertig(r.url, dauer) }
    }
}


/// 📤 laufende Uploads im Formular (damit »Starten« sagen kann, worauf es wartet)
@MainActor
final class UploadStand: ObservableObject {
    static let shared = UploadStand()
    @Published var laeuft = 0
    @Published var prozent: Double?
}
