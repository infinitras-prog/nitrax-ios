import SwiftUI
import AVKit

/// 📦 Offline-Galerie: fertige Bilder (und auf Wunsch Videos) liegen auf dem iPhone - ansehen, teilen und sichern auch ohne
/// Verbindung zum PC. Neue Bilder werden beim Abgleich automatisch geholt (die neuesten 120, höchstens 6 pro Durchgang).
@MainActor
final class OfflineGalerie: ObservableObject {
    static let shared = OfflineGalerie()

    struct Eintrag: Codable, Identifiable, Hashable {
        var id: String
        var titel: String
        var art: String
        var datum: Date
        var bilder: [String]          // Dateinamen im Galerie-Ordner
        var video: String?
        var istVideo: Bool
    }

    @Published private(set) var eintraege: [Eintrag] = []
    @Published private(set) var laedt: Set<String> = []
    private var laeuft = false
    private var zuletzt = Date.distantPast

    let ordner: URL = {
        let o = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Galerie", isDirectory: true)
        try? FileManager.default.createDirectory(at: o, withIntermediateDirectories: true)
        return o
    }()
    private var index: URL { ordner.appendingPathComponent("index.json") }

    init() {
        if let d = try? Data(contentsOf: index), let l = try? JSONDecoder().decode([Eintrag].self, from: d) { eintraege = l }
    }

    func datei(_ name: String) -> URL { ordner.appendingPathComponent(name) }

    var groesse: Int64 {
        let dateien = (try? FileManager.default.contentsOfDirectory(at: ordner, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return dateien.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func sichern() {
        if let d = try? JSONEncoder().encode(eintraege) { try? d.write(to: index, options: .atomic) }
    }

    /// Beim Abgleich (alle paar Sekunden) aufgerufen - holt höchstens alle 30 s ein paar neue Bilder
    func abgleichen(_ s: StudioStand, client: NXClient) {
        guard !laeuft, Date().timeIntervalSince(zuletzt) > 30 else { return }
        let vorhanden = Set(eintraege.map(\.id))
        let neu = s.auftraege.filter { $0.fertig && ($0.bilderAnzahl > 0 || $0.hatVideo) && !vorhanden.contains($0.id) }
            .sorted { ($0.finished ?? $0.created) > ($1.finished ?? $1.created) }.prefix(120)
        guard !neu.isEmpty else { zuletzt = Date(); return }
        laeuft = true
        Task {
            for a in neu.prefix(6) { await holen(a, client: client) }
            laeuft = false
            zuletzt = Date()
        }
    }

    private func laden(_ pfad: String, _ c: NXClient) async -> Data? {
        guard let url = c.url(pfad) else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 120
        for (k, v) in c.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
        guard let (d, antwort) = try? await URLSession.shared.data(for: r), (antwort as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    private func holen(_ a: Auftrag, client c: NXClient) async {
        var bilder: [String] = []
        if a.bilderAnzahl > 0 {
            for k in 0..<min(a.bilderAnzahl, 4) {
                guard let d = await laden("/api/img/file/\(a.id)/\(k)", c) else { continue }
                let name = "\(a.id)_\(k).jpg"
                let jpeg = UIImage(data: d)?.jpegData(compressionQuality: 0.9) ?? d
                if (try? jpeg.write(to: datei(name))) != nil { bilder.append(name) }
            }
        } else if let d = await laden("/api/begleiter/ergebnis/\(a.id)", c) {          // Video: Vorschaubild
            let name = "\(a.id)_v.jpg"
            if (try? d.write(to: datei(name))) != nil { bilder.append(name) }
        }
        guard !bilder.isEmpty else { return }
        eintraege.insert(Eintrag(id: a.id, titel: a.titel, art: a.artName, datum: Date(timeIntervalSince1970: a.finished ?? a.created),
                                 bilder: bilder, video: nil, istVideo: a.hatVideo), at: 0)
        eintraege.sort { $0.datum > $1.datum }
        sichern()
    }

    /// Video zusätzlich offline speichern (auf Wunsch - Videos sind groß)
    func videoSpeichern(_ e: Eintrag, client: NXClient?) async -> Bool {
        guard let c = client, let url = c.url("/api/video/\(e.id)") else { return false }
        laedt.insert(e.id)
        defer { laedt.remove(e.id) }
        var r = URLRequest(url: url)
        r.timeoutInterval = 900
        for (k, v) in c.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
        guard let (tmp, antwort) = try? await URLSession.shared.download(for: r), (antwort as? HTTPURLResponse)?.statusCode == 200 else { return false }
        let name = "\(e.id).mp4"
        try? FileManager.default.removeItem(at: datei(name))
        guard (try? FileManager.default.moveItem(at: tmp, to: datei(name))) != nil else { return false }
        if let i = eintraege.firstIndex(where: { $0.id == e.id }) { eintraege[i].video = name; sichern() }
        return true
    }

    func entfernen(_ e: Eintrag) {
        for n in e.bilder + [e.video].compactMap({ $0 }) { try? FileManager.default.removeItem(at: datei(n)) }
        eintraege.removeAll { $0.id == e.id }
        sichern()
    }

    func allesLeeren() {
        for e in eintraege { for n in e.bilder + [e.video].compactMap({ $0 }) { try? FileManager.default.removeItem(at: datei(n)) } }
        eintraege = []
        sichern()
    }
}

/// Galerie-Ansicht: funktioniert komplett ohne PC
@MainActor
struct GalerieAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @ObservedObject private var galerie = OfflineGalerie.shared
    @State private var leerenFrage = false

    var body: some View {
        ScrollView {
            if galerie.eintraege.isEmpty {
                ContentUnavailableView("Noch nichts offline", systemImage: "photo.stack",
                                       description: Text("Fertige Bilder landen automatisch hier, sobald die App mit dem PC verbunden ist – danach gehen sie auch ohne Verbindung."))
                    .padding(.top, 60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 6)], spacing: 6) {
                ForEach(galerie.eintraege) { e in
                    NavigationLink(value: e) {
                        ZStack(alignment: .bottomTrailing) {
                            GalerieBild(url: galerie.datei(e.bilder[0])).frame(height: 120).clipped()
                            if e.istVideo {
                                Image(systemName: e.video != nil ? "play.circle.fill" : "play.circle").font(.title3)
                                    .foregroundStyle(.white).shadow(radius: 3).padding(5)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .contextMenu {
                        Button("Aus der Galerie entfernen", systemImage: "trash", role: .destructive) { galerie.entfernen(e) }
                    }
                }
            }
            .padding(10)
            if !galerie.eintraege.isEmpty {
                Text("\(galerie.eintraege.count) Werke · \(ByteCountFormatter.string(fromByteCount: galerie.groesse, countStyle: .file)) auf dem iPhone")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 20)
            }
        }
        .nxHintergrund()
        .navigationTitle("Offline-Galerie")
        .navigationDestination(for: OfflineGalerie.Eintrag.self) { GalerieDetail(e: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Galerie leeren", systemImage: "trash", role: .destructive) { leerenFrage = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Alle offline gespeicherten Werke vom iPhone löschen? Am PC bleibt alles erhalten.", isPresented: $leerenFrage, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { galerie.allesLeeren() }
        }
    }
}

struct GalerieBild: View {
    let url: URL
    var modus: ContentMode = .fill
    var body: some View {
        if let b = UIImage(contentsOfFile: url.path) {
            Image(uiImage: b).resizable().aspectRatio(contentMode: modus)
        } else {
            Rectangle().fill(Farbe.karte)
        }
    }
}

@MainActor
struct GalerieDetail: View {
    @EnvironmentObject private var studio: Studio
    @ObservedObject private var galerie = OfflineGalerie.shared
    let e: OfflineGalerie.Eintrag
    @State private var teilen: [URL]?

    private var aktuell: OfflineGalerie.Eintrag { galerie.eintraege.first { $0.id == e.id } ?? e }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let v = aktuell.video {
                    VideoPlayer(player: AVPlayer(url: galerie.datei(v))).frame(height: 420).clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    TabView {
                        ForEach(aktuell.bilder, id: \.self) { n in GalerieBild(url: galerie.datei(n), modus: .fit) }
                    }
                    .tabViewStyle(.page)
                    .frame(height: 460)
                }
                Text(aktuell.titel).font(.headline).multilineTextAlignment(.center)
                Text("\(aktuell.art) · \(aktuell.datum.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button {
                        teilen = aktuell.video.map { [galerie.datei($0)] } ?? aktuell.bilder.map { galerie.datei($0) }
                    } label: { Label("Teilen / Sichern", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    if aktuell.istVideo && aktuell.video == nil {
                        Button {
                            Task { _ = await galerie.videoSpeichern(aktuell, client: studio.client) }
                        } label: {
                            if galerie.laedt.contains(e.id) { ProgressView() } else { Label("Video offline", systemImage: "arrow.down.circle") }
                        }
                        .buttonStyle(.bordered)
                        .disabled(studio.client == nil)
                    }
                }
            }
            .padding()
        }
        .nxHintergrund()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { teilen != nil }, set: { if !$0 { teilen = nil } })) {
            if let t = teilen { TeilenBlatt(dateien: t) }
        }
    }
}
