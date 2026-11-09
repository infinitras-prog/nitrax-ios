import SwiftUI
import AVKit
import Photos

/// Bilder vom PC (mit Anmelde-Cookie) samt kleinem Zwischenspeicher
enum BildSpeicher {
    static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 300
        return c
    }()

    /// 💾 Plattenspeicher (Caches/NitraX-Bilder): Bibliothek und Vorschaubilder sind sofort da – auch offline. Höchstens ~400 MB.
    private static let ordner: URL = {
        let o = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NitraX-Bilder", isDirectory: true)
        try? FileManager.default.createDirectory(at: o, withIntermediateDirectories: true)
        return o
    }()

    private static func datei(_ url: URL) -> URL {
        // ohne Rechnername (WLAN/Tailscale liefern dasselbe Bild)
        let schluessel = (url.path + "?" + (url.query ?? "")).data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return ordner.appendingPathComponent(String(schluessel.suffix(120)) + ".img")
    }

    static func ausPlatte(_ url: URL) -> UIImage? {
        guard let d = try? Data(contentsOf: datei(url)), let b = UIImage(data: d) else { return nil }
        cache.setObject(b, forKey: url as NSURL)
        return b
    }

    static func aufPlatte(_ daten: Data, _ url: URL) {
        let ziel = datei(url)
        DispatchQueue.global(qos: .utility).async {
            try? daten.write(to: ziel, options: .atomic)
            aufraeumen()
        }
    }

    private static var zuletztAufgeraeumt = Date.distantPast
    private static func aufraeumen() {
        guard Date().timeIntervalSince(zuletztAufgeraeumt) > 300 else { return }
        zuletztAufgeraeumt = Date()
        let fm = FileManager.default
        guard let liste = try? fm.contentsOfDirectory(at: ordner, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]) else { return }
        var eintraege = liste.compactMap { u -> (URL, Int, Date)? in
            guard let w = try? u.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]) else { return nil }
            return (u, w.fileSize ?? 0, w.contentAccessDate ?? .distantPast)
        }
        var summe = eintraege.reduce(0) { $0 + $1.1 }
        eintraege.sort { $0.2 < $1.2 }
        for e in eintraege where summe > 400_000_000 { try? fm.removeItem(at: e.0); summe -= e.1 }
    }
}

@MainActor
struct NXBild: View {
    @EnvironmentObject private var studio: Studio
    var url: URL?
    var modus: ContentMode = .fill
    @State private var bild: UIImage?
    @State private var fehlt = false

    var body: some View {
        ZStack {
            if let bild {
                Image(uiImage: bild).resizable().aspectRatio(contentMode: modus)
            } else {
                Rectangle().fill(Farbe.karte)
                if url != nil && !fehlt { ProgressView().controlSize(.small) }
            }
        }
        .task(id: url) { await laden() }
    }

    private func laden() async {
        guard let url else { bild = nil; return }
        if let b = BildSpeicher.cache.object(forKey: url as NSURL) { bild = b; return }
        let live = url.path.hasSuffix("/vorschau")
        if !live, let b = BildSpeicher.ausPlatte(url) { bild = b; return }
        var r = URLRequest(url: url)
        for (k, v) in studio.client?.cookieKopf ?? [:] { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode ?? 500 < 400, let b = UIImage(data: d) else { fehlt = true; return }
            BildSpeicher.cache.setObject(b, forKey: url as NSURL)
            if !live { BildSpeicher.aufPlatte(d, url) }
            bild = b
        } catch { fehlt = true }
    }
}

/// Video/Audio vom PC abspielen (Cookie in den HTTP-Kopf der Wiedergabe)
@MainActor
struct NXPlayer: View {
    @EnvironmentObject private var studio: Studio
    var url: URL
    var nurTon = false
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(height: nurTon ? 64 : nil)
            .onAppear {
                guard player == nil else { return }
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": studio.client?.cookieKopf ?? [:]])
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
    }
}

/// Datei vom PC in den temporären Ordner laden (zum Teilen/Sichern)
enum Herunterladen {
    static func datei(_ client: NXClient, pfad: String, name: String) async throws -> URL {
        guard let url = client.url(pfad) else { throw NXFehler.keineVerbindung }
        var r = URLRequest(url: url)
        for (k, v) in client.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
        r.timeoutInterval = 600
        let (tmp, resp) = try await URLSession.shared.download(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw NXFehler.server(h.statusCode, "") }
        let ziel = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: ziel)
        try FileManager.default.moveItem(at: tmp, to: ziel)
        return ziel
    }

    /// In die Fotos-Mediathek sichern (Bild oder Video)
    static func inFotos(_ datei: URL, video: Bool) async throws {
        let ok = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard ok == .authorized || ok == .limited else {
            throw NSError(domain: "NitraX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kein Zugriff auf Fotos – in den iPhone-Einstellungen erlauben."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            if video { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: datei) }
            else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: datei) }
        }
    }
}

/// Teilen-Blatt (UIActivityViewController)
struct TeilenBlatt: UIViewControllerRepresentable {
    var dateien: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: dateien, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
