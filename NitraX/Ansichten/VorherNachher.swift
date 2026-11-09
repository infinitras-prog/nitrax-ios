import SwiftUI
import AVFoundation

/// ↔ Vorher/Nachher: Standbild der früheren Fassung (vor 💎 Maximal / 🎞 Film-Look) und der jetzigen, mit Schieber dazwischen.
/// Zeitpunkt wählbar (unten), Antippen links/rechts springt ganz zur Seite.
@MainActor
struct VorherNachher: View {
    @EnvironmentObject private var studio: Studio
    let auftrag: Auftrag
    @State private var fassung = "vor_maximal"
    @State private var teil: CGFloat = 0.5
    @State private var zeit: Double = 1
    @State private var vorher: UIImage?
    @State private var nachher: UIImage?
    @State private var laedt = false

    private var fassungen: [(String, String)] {
        var l: [(String, String)] = []
        if auftrag.vorMaximal { l.append(("vor_maximal", "💎 Maximal")) }
        if auftrag.vorRealismus { l.append(("vor_realismus", "🎞 Film-Look")) }
        return l
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Vorher / Nachher", systemImage: "rectangle.split.2x1").font(.headline)
                Spacer()
                if fassungen.count > 1 {
                    Picker("", selection: $fassung) { ForEach(fassungen.indices, id: \.self) { i in Text(fassungen[i].1).tag(fassungen[i].0) } }.pickerStyle(.menu)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    bild(nachher)
                    bild(vorher).mask(alignment: .leading) { Rectangle().frame(width: g.size.width * teil) }
                    Rectangle().fill(.white).frame(width: 2).offset(x: g.size.width * teil - 1).shadow(radius: 3)
                    Circle().fill(.white).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
                        .offset(x: g.size.width * teil - 15)
                    HStack {
                        Text("vorher").font(.caption2.bold()).padding(5).background(.black.opacity(0.5), in: Capsule())
                        Spacer()
                        Text("nachher").font(.caption2.bold()).padding(5).background(.black.opacity(0.5), in: Capsule())
                    }
                    .padding(8).frame(maxHeight: .infinity, alignment: .top)
                    if laedt { ProgressView().frame(maxWidth: .infinity) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { w in teil = min(1, max(0, w.location.x / g.size.width)) })
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let s = auftrag.sekunden, s > 1.5 {
                HStack {
                    Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $zeit, in: 0...max(1, s - 0.2), onEditingChanged: { aendernd in if !aendernd { Task { await laden() } } })
                    Text(String(format: "%.1f s", zeit)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .karte()
        .task(id: fassung) {
            if !fassungen.contains(where: { $0.0 == fassung }), let f = fassungen.first?.0 { fassung = f; return }
            await laden()
        }
    }

    private func bild(_ b: UIImage?) -> some View {
        ZStack {
            Rectangle().fill(Farbe.karte)
            if let b { Image(uiImage: b).resizable().scaledToFit() }
        }
    }

    private func laden() async {
        guard let c = studio.client, let alt = c.url("/api/video/\(auftrag.id)?fassung=\(fassung)"), let neu = c.url("/api/video/\(auftrag.id)") else { return }
        laedt = true
        defer { laedt = false }
        async let a = Self.standbild(alt, zeit, c.cookieKopf)
        async let b = Self.standbild(neu, zeit, c.cookieKopf)
        let (x, y) = await (a, b)
        vorher = x; nachher = y
    }

    nonisolated static func standbild(_ url: URL, _ sek: Double, _ kopf: [String: String]) async -> UIImage? {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": kopf])
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        guard let r = try? await gen.image(at: CMTime(seconds: sek, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: r.image)
    }
}
