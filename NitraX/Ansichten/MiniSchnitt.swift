import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// ✂ Runde 3, Nr. 6: Mini-Schnitt am Handy – Anfang/Ende kürzen, Ton leiser oder stumm, Text einblenden, dann teilen
/// oder in Fotos sichern. Untertitel an/aus geht nicht: die sind bei NitraX fest ins Bild gerechnet.
@MainActor
struct MiniSchnitt: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let auftrag: Auftrag

    @State private var datei: URL?
    @State private var spieler: AVPlayer?
    @State private var dauer: Double = 0
    @State private var von: Double = 0
    @State private var bis: Double = 0
    @State private var ton = 1.0
    @State private var text = ""
    @State private var textOben = false
    @State private var laedt = true
    @State private var arbeitet = false
    @State private var fehler: String?
    @State private var teilen: [URL] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let spieler {
                        VideoPlayer(player: spieler).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets())
                    } else if laedt {
                        ProgressView("Video wird geladen …").frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .listRowBackground(Color.clear)
                if dauer > 0 {
                    Section("Länge · \(String(format: "%.1f", bis - von)) s von \(String(format: "%.1f", dauer)) s") {
                        VStack(alignment: .leading) {
                            Text("Anfang \(String(format: "%.1f", von)) s").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $von, in: 0...max(0.1, dauer), onEditingChanged: { e in if !e { vorschau(von) } })
                                .onChange(of: von) { _, v in if v > bis - 0.5 { von = max(0, bis - 0.5) } }
                        }
                        VStack(alignment: .leading) {
                            Text("Ende \(String(format: "%.1f", bis)) s").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $bis, in: 0...max(0.1, dauer), onEditingChanged: { e in if !e { vorschau(max(0, bis - 1.5)) } })
                                .onChange(of: bis) { _, v in if v < von + 0.5 { bis = min(dauer, von + 0.5) } }
                        }
                    }
                    Section("Ton") {
                        Picker("Lautstärke", selection: $ton) {
                            Text("Normal").tag(1.0); Text("Leiser").tag(0.4); Text("Stumm").tag(0.0)
                        }
                        .pickerStyle(.segmented)
                    }
                    Section {
                        TextField("z. B. Sommer 2026 ☀️", text: $text)
                        if !text.isEmpty { Toggle("Oben statt unten", isOn: $textOben) }
                    } header: { Text("Text einblenden (optional)") } footer: {
                        Text("Untertitel lassen sich nicht ausblenden – NitraX rechnet sie fest ins Bild.")
                    }
                    Section {
                        Button { Task { await exportieren(sichern: false) } } label: { Label("Teilen", systemImage: "square.and.arrow.up") }
                        Button { Task { await exportieren(sichern: true) } } label: { Label("In Fotos sichern", systemImage: "photo.badge.arrow.down") }
                        if arbeitet { ProgressView("Wird geschnitten …") }
                        if let fehler { Text(fehler).font(.footnote).foregroundStyle(Farbe.fehler) }
                    }
                    .disabled(arbeitet)
                }
            }
            .scrollContentBackground(.hidden)
            .nxHintergrund()
            .navigationTitle("Kürzen & teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { spieler?.pause(); dismiss() } } }
            .task { await laden() }
            .sheet(isPresented: Binding(get: { !teilen.isEmpty }, set: { if !$0 { teilen = [] } })) {
                TeilenBlatt(dateien: teilen).presentationDetents([.medium, .large])
            }
        }
    }

    private func laden() async {
        defer { laedt = false }
        guard let c = studio.client else { return }
        do {
            let u = try await Herunterladen.datei(c, pfad: "/api/video/\(auftrag.id)", name: "NitraX-\(auftrag.id).mp4")
            datei = u
            let a = AVURLAsset(url: u)
            dauer = (try? await a.load(.duration).seconds) ?? 0
            bis = dauer
            spieler = AVPlayer(url: u)
        } catch { fehler = error.localizedDescription }
    }

    private func vorschau(_ t: Double) {
        spieler?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        spieler?.play()
    }

    private func exportieren(sichern: Bool) async {
        guard let quelle = datei else { return }
        arbeitet = true
        fehler = nil
        defer { arbeitet = false }
        spieler?.pause()
        do {
            let ziel = try await Self.schneiden(quelle, von: von, bis: bis, ton: ton, text: text, oben: textOben)
            if sichern {
                try await Herunterladen.inFotos(ziel, video: true)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                studio.meldung = "✂ Geschnitten und in Fotos gesichert"
            } else {
                teilen = [ziel]
            }
        } catch { fehler = error.localizedDescription }
    }

    /// Schnitt + Lautstärke + Texteinblendung -> neue MP4 im Temp-Ordner
    static func schneiden(_ quelle: URL, von: Double, bis: Double, ton: Double, text: String, oben: Bool) async throws -> URL {
        let asset = AVURLAsset(url: quelle)
        let bereich = CMTimeRange(start: CMTime(seconds: von, preferredTimescale: 600), end: CMTime(seconds: bis, preferredTimescale: 600))
        let mix = AVMutableComposition()
        guard let vSpur = try await asset.loadTracks(withMediaType: .video).first,
              let vZiel = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "NitraX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine Videospur gefunden"])
        }
        try vZiel.insertTimeRange(bereich, of: vSpur, at: .zero)
        vZiel.preferredTransform = try await vSpur.load(.preferredTransform)
        var audioMix: AVMutableAudioMix?
        if ton > 0, let aSpur = try await asset.loadTracks(withMediaType: .audio).first,
           let aZiel = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try aZiel.insertTimeRange(bereich, of: aSpur, at: .zero)
            if ton < 0.99 {
                let p = AVMutableAudioMixInputParameters(track: aZiel)
                p.setVolume(Float(ton), at: .zero)
                let m = AVMutableAudioMix()
                m.inputParameters = [p]
                audioMix = m
            }
        }
        var komposition: AVMutableVideoComposition?
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            let groesse = try await vSpur.load(.naturalSize).applying(vZiel.preferredTransform)
            let g = CGSize(width: abs(groesse.width), height: abs(groesse.height))
            let k = AVMutableVideoComposition(propertiesOf: mix)
            k.renderSize = g
            let video = CALayer(), eltern = CALayer(), schrift = CATextLayer()
            video.frame = CGRect(origin: .zero, size: g)
            eltern.frame = video.frame
            let hoehe = g.height * 0.12
            schrift.string = t
            schrift.font = UIFont.systemFont(ofSize: hoehe * 0.55, weight: .bold)
            schrift.fontSize = hoehe * 0.55
            schrift.alignmentMode = .center
            schrift.foregroundColor = UIColor.white.cgColor
            schrift.shadowColor = UIColor.black.cgColor
            schrift.shadowOpacity = 0.8
            schrift.shadowRadius = 6
            schrift.shadowOffset = .zero
            schrift.contentsScale = 2
            // Core Animation zählt y von unten
            schrift.frame = CGRect(x: g.width * 0.05, y: oben ? g.height - hoehe * 1.6 : hoehe * 0.5, width: g.width * 0.9, height: hoehe)
            eltern.addSublayer(video)
            eltern.addSublayer(schrift)
            k.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: eltern)
            komposition = k
        }
        let ziel = FileManager.default.temporaryDirectory.appendingPathComponent("NitraX-Schnitt-\(UUID().uuidString.prefix(6)).mp4")
        guard let ex = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "NitraX", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export nicht möglich"])
        }
        ex.outputURL = ziel
        ex.outputFileType = .mp4
        ex.audioMix = audioMix
        if let komposition { ex.videoComposition = komposition }
        await ex.export()
        if ex.status != .completed {
            throw ex.error ?? NSError(domain: "NitraX", code: 3, userInfo: [NSLocalizedDescriptionKey: "Schneiden fehlgeschlagen"])
        }
        return ziel
    }
}
