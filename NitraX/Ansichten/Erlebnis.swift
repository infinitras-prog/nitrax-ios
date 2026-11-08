import SwiftUI
import AVFoundation

// MARK: - ✨ Enthüllung: fertige Werke erscheinen aus der Unschärfe, mit Funken und Haptik

struct Enthuellung: ViewModifier {
    var aktiv: Bool
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var da = false
    @State private var funken = false

    func body(content: Content) -> some View {
        content
            .blur(radius: aktiv && !da && !ruhig ? 22 : 0)
            .scaleEffect(aktiv && !da && !ruhig ? 1.06 : 1)
            .saturation(aktiv && !da ? 0.2 : 1)
            .overlay {
                if aktiv && funken && !ruhig {
                    TimelineView(.animation) { t in
                        Canvas { ctx, g in
                            let s = t.date.timeIntervalSinceReferenceDate
                            for i in 0..<26 {
                                let a = Double(i) * 2.399 + s * 0.6
                                let r = (s * 120 + Double(i * 17)).truncatingRemainder(dividingBy: max(g.width, g.height) * 0.7)
                                let p = CGPoint(x: g.width / 2 + cos(a) * r, y: g.height / 2 + sin(a) * r)
                                let f = [Farbe.akzent, Farbe.pink, Farbe.mint, Farbe.limette][i % 4]
                                ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 4, height: 4)), with: .color(f.opacity(1 - r / (g.width * 0.7))))
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .onAppear {
                guard aktiv, !da else { return }
                funken = true
                withAnimation(.easeOut(duration: 1.1)) { da = true }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { funken = false } }
            }
    }
}

extension View {
    func enthuellen(_ aktiv: Bool) -> some View { modifier(Enthuellung(aktiv: aktiv)) }
}

/// Merkt sich, welche Werke schon enthüllt wurden (nur beim ersten Ansehen)
enum Enthuellt {
    static func neu(_ id: String) -> Bool {
        var l = UserDefaults.standard.stringArray(forKey: "enthuellt") ?? []
        guard !l.contains(id) else { return false }
        l.append(id)
        UserDefaults.standard.set(Array(l.suffix(400)), forKey: "enthuellt")
        return true
    }
}

// MARK: - 🔍 Vollbild mit Pinch-Zoom, Doppeltipp, Wischen zwischen Bildern

struct ZoomBild: UIViewRepresentable {
    let bild: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let s = UIScrollView()
        s.minimumZoomScale = 1
        s.maximumZoomScale = 6
        s.showsVerticalScrollIndicator = false
        s.showsHorizontalScrollIndicator = false
        s.delegate = context.coordinator
        s.backgroundColor = .clear
        let iv = UIImageView(image: bild)
        iv.contentMode = .scaleAspectFit
        iv.frame = s.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        iv.isUserInteractionEnabled = true
        s.addSubview(iv)
        context.coordinator.bildAnsicht = iv
        let d = UITapGestureRecognizer(target: context.coordinator, action: #selector(Koordinator.doppelt(_:)))
        d.numberOfTapsRequired = 2
        s.addGestureRecognizer(d)
        return s
    }

    func updateUIView(_ s: UIScrollView, context: Context) {}
    func makeCoordinator() -> Koordinator { Koordinator() }

    final class Koordinator: NSObject, UIScrollViewDelegate {
        weak var bildAnsicht: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { bildAnsicht }
        @objc func doppelt(_ g: UITapGestureRecognizer) {
            guard let s = g.view as? UIScrollView else { return }
            if s.zoomScale > 1 { s.setZoomScale(1, animated: true) } else {
                let p = g.location(in: bildAnsicht)
                s.zoom(to: CGRect(x: p.x - 60, y: p.y - 60, width: 120, height: 120), animated: true)
            }
        }
    }
}

@MainActor
struct MedienVollbild: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]
    @State var seite: Int
    @State private var bilder: [Int: UIImage] = [:]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $seite) {
                ForEach(urls.indices, id: \.self) { i in
                    Group {
                        if let b = bilder[i] { ZoomBild(bild: b) } else { ProgressView().tint(.white) }
                    }
                    .tag(i)
                    .task { await laden(i) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
        .statusBarHidden()
    }

    private func laden(_ i: Int) async {
        guard bilder[i] == nil else { return }
        let u = urls[i]
        if u.isFileURL { bilder[i] = UIImage(contentsOfFile: u.path); return }
        if let b = BildSpeicher.cache.object(forKey: u as NSURL), b.size.width > 900 { bilder[i] = b; return }
        var r = URLRequest(url: u)
        for (k, v) in studio.client?.cookieKopf ?? [:] { r.setValue(v, forHTTPHeaderField: k) }
        if let (d, _) = try? await URLSession.shared.data(for: r), let b = UIImage(data: d) { bilder[i] = b }
    }
}

// MARK: - 🎭 Startseite als Bühne: das neueste Werk groß, Laufendes als Fortschrittsringe

@MainActor
struct BuehneKarte: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var schweben = false

    private var neuestes: Auftrag? {
        studio.stand.auftraege.filter { $0.fertig && (studio.vorschauURL($0) != nil) }.max { ($0.finished ?? 0) < ($1.finished ?? 0) }
    }
    private var laufend: [Auftrag] { studio.stand.auftraege.filter { $0.laeuft || $0.wartet }.prefix(6).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let a = neuestes {
                Button { navigation.oeffne(auftrag: a.id) } label: {
                    ZStack(alignment: .bottomLeading) {
                        NXBild(url: studio.vorschauURL(a))
                            .frame(height: 250).frame(maxWidth: .infinity)
                            .scaleEffect(schweben ? 1.06 : 1.0)
                            .clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Neuestes Werk", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(Farbe.akzent2)
                            Text(a.titel).font(.title3.bold()).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                            Text(a.artName + (a.finished.map { " · " + Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)) } ?? ""))
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Farbe.ring.opacity(0.55), lineWidth: 1.5))
                    .shadow(color: Farbe.akzent.opacity(0.25), radius: 20, y: 10)
                }
                .buttonStyle(NXDruck())
                .onAppear { if !ruhig { withAnimation(.easeInOut(duration: 9).repeatForever()) { schweben = true } } }
            }
            if !laufend.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(laufend) { a in
                            Button { navigation.oeffne(auftrag: a.id) } label: { FortschrittsRing(a: a) }.buttonStyle(NXDruck())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct FortschrittsRing: View {
    @EnvironmentObject private var studio: Studio
    let a: Auftrag
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Farbe.rand, lineWidth: 5)
                Circle().trim(from: 0, to: a.laeuft ? max(0.03, a.progress / 100) : 0)
                    .stroke(Farbe.ring, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: a.progress)
                NXBild(url: studio.vorschauURL(a)).clipShape(Circle()).padding(7)
                if studio.vorschauURL(a) == nil { Image(systemName: a.symbol).foregroundStyle(Farbe.akzent) }
                if a.laeuft { Text("\(Int(a.progress))%").font(.caption2.bold()).padding(3).background(.black.opacity(0.55), in: Capsule()).offset(y: 24) }
            }
            .frame(width: 66, height: 66)
            .laufGlut(a.laeuft)
            Text(a.wartet ? "wartet" : a.artName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 74)
        }
    }
}

// MARK: - 🧩 Vorlagen: beliebte Einstellungen mit einem Tippen

struct Vorlage: Identifiable {
    let id: String
    let emoji: String
    let name: String
    let wf: String
    let werte: [String: JSONWert]
}

enum Vorlagen {
    static let alle: [Vorlage] = [
        Vorlage(id: "trailer", emoji: "🎬", name: "Kinoreifer Trailer", wf: "x-t2v",
                werte: ["idee": .text("Epischer Kinotrailer: dramatische Kamerafahrt über eine nebelige Berglandschaft bei Sonnenaufgang, ein einsamer Reiter, tiefer Bass, Zeitlupe")]),
        Vorlage(id: "anime", emoji: "🌸", name: "Anime-Porträt", wf: "x-t2i",
                werte: ["prompt": .text("anime portrait of a young woman with flowing silver hair, cherry blossoms, soft rim light, detailed eyes, studio quality, vibrant colors")]),
        Vorlage(id: "lofi", emoji: "🎧", name: "Lo-Fi-Song", wf: "x-track",
                werte: ["idee": .text("Entspannter Lo-Fi-Hip-Hop zum Lernen: Regen am Fenster, warme Vinyl-Knistern, sanftes Klavier, langsamer Beat")]),
        Vorlage(id: "fantasy", emoji: "🐉", name: "Fantasy-Welt", wf: "x-t2i",
                werte: ["prompt": .text("breathtaking fantasy landscape, floating islands, waterfalls into clouds, a dragon in the distance, golden hour, matte painting, highly detailed")]),
        Vorlage(id: "kurzfilm", emoji: "🎞", name: "Mini-Kurzfilm", wf: "x-film",
                werte: ["idee": .text("Ein kleiner Roboter findet im verlassenen Park eine Blume und versucht, sie vor dem Regen zu schützen. Rührendes Ende.")]),
        Vorlage(id: "poster", emoji: "🪧", name: "Retro-Poster", wf: "x-t2i",
                werte: ["prompt": .text("retro 80s synthwave poster, neon sunset, palm trees, chrome sports car, grid horizon, bold typography space, grainy print texture")]),
        Vorlage(id: "partysong", emoji: "🎉", name: "Party-Hit", wf: "x-track",
                werte: ["idee": .text("Mitreißender deutscher Party-Song über einen verrückten Samstagabend, Refrain zum Mitsingen, 128 BPM")]),
        Vorlage(id: "natur", emoji: "🌊", name: "Naturvideo", wf: "x-t2v",
                werte: ["idee": .text("Ruhiges Naturvideo: Wellen rollen an einen einsamen Strand, Möwen, warmes Abendlicht, langsame Drohnenfahrt")]),
    ]
}

struct VorlagePaar: Identifiable {
    let v: Vorlage
    let w: Workflow
    var id: String { v.id }
}

@MainActor
struct VorlagenLeiste: View {
    @EnvironmentObject private var studio: Studio
    var body: some View {
        let verfuegbar: [VorlagePaar] = Vorlagen.alle.compactMap { v in studio.workflows?.workflows.first { $0.id == v.wf }.map { VorlagePaar(v: v, w: $0) } }
        if !verfuegbar.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Vorlagen").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(verfuegbar) { paar in
                            let v = paar.v, w = paar.w
                            NavigationLink { WorkflowFormular(workflow: w, vorbelegung: v.werte) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(v.emoji).font(.system(size: 28))
                                    Text(v.name).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(w.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 112, height: 108, alignment: .topLeading)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Farbe.karte))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Farbe.rand))
                            }
                            .buttonStyle(NXDruck())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 🎙 Diktieren in jedes Textfeld (Erkennung am PC, genauer als die Tastatur-Diktierfunktion)

@MainActor
final class Diktat: ObservableObject {
    @Published var laeuft = false
    @Published var versteht = false
    private var rekorder: AVAudioRecorder?

    func umschalten(_ c: NXClient?, fertig: @escaping (String) -> Void) {
        if laeuft { stoppen(c, fertig: fertig) } else { Task { await starten() } }
    }

    private func starten() async {
        guard await AVAudioApplication.requestRecordPermission() else { return }
        HelferTon.einrichten()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diktat-\(UUID().uuidString.prefix(6)).wav")
        let e: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let r = try? AVAudioRecorder(url: url, settings: e) else { return }
        r.record(forDuration: 60)
        rekorder = r
        laeuft = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func stoppen(_ c: NXClient?, fertig: @escaping (String) -> Void) {
        guard let r = rekorder else { return }
        r.stop()
        rekorder = nil
        laeuft = false
        versteht = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        Task {
            defer { versteht = false; try? FileManager.default.removeItem(at: r.url) }
            guard let c, let d = try? Data(contentsOf: r.url),
                  let a = try? await c.hochladen("/api/anruf/hoeren", daten: d, dateiname: "diktat.wav", typ: "audio/wav", felder: ["sprache": "German"]) else { return }
            let t = (a["text"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { fertig(t) }
        }
    }
}

@MainActor
struct DiktierKnopf: View {
    @EnvironmentObject private var studio: Studio
    @Binding var text: String
    @StateObject private var d = Diktat()

    var body: some View {
        Button {
            d.umschalten(studio.client) { neu in text = text.isEmpty ? neu : text + " " + neu }
        } label: {
            Group {
                if d.versteht { ProgressView().controlSize(.small) }
                else { Image(systemName: d.laeuft ? "stop.circle.fill" : "mic.circle").font(.title3) }
            }
            .foregroundStyle(d.laeuft ? Farbe.fehler : Farbe.akzent)
            .symbolEffect(.pulse, isActive: d.laeuft)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d.laeuft ? "Diktat beenden" : "Diktieren")
    }
}
