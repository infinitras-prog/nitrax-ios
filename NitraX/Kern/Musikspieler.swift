import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI

/// 🎵 Runde 3, Nr. 7: deine Songs als Playlist – läuft im Hintergrund weiter, Steuerung auf dem Sperrbildschirm
/// und im Kontrollzentrum. Pausiert bei Anrufen und wenn der Helfer spricht.
@MainActor
final class Musikspieler: ObservableObject {
    static let shared = Musikspieler()

    struct Titel: Identifiable, Hashable { let id: String; let name: String; let url: URL; let bild: URL? }

    @Published private(set) var liste: [Titel] = []
    @Published private(set) var index = 0
    @Published private(set) var spielt = false
    @Published private(set) var zeit: Double = 0
    @Published private(set) var dauer: Double = 0
    @Published var zufall = false
    private var spieler: AVPlayer?
    private var beobachter: Any?
    private var endeBeob: NSObjectProtocol?
    private var fernEingerichtet = false

    var aktuell: Titel? { liste.indices.contains(index) ? liste[index] : nil }
    var aktiv: Bool { aktuell != nil }

    /// Tonpfad eines Auftrags (Song oder Sprache)
    static func tonPfad(_ a: Auftrag) -> String? {
        if a.kind == "x-stimme" { return "/api/stimmen/datei/\(a.id)/Dialog.flac" }
        if a.songInput != nil && !a.hatVideo { return "/api/flac/\(a.id)" }
        return nil
    }

    func abspielen(_ auftraege: [Auftrag], ab start: Int = 0, client: NXClient?, mischen: Bool = false) {
        guard let c = client else { return }
        var t = auftraege.compactMap { a -> Titel? in
            guard let p = Self.tonPfad(a), let u = c.url(p) else { return nil }
            return Titel(id: a.id, name: a.titel, url: u, bild: a.image.flatMap { $0.isEmpty ? nil : c.url("/api/image/" + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)) })
        }
        guard !t.isEmpty else { return }
        var s = min(max(0, start), t.count - 1)
        if mischen { let erster = t[s]; t.remove(at: s); t.shuffle(); t.insert(erster, at: 0); s = 0 }
        zufall = mischen
        liste = t
        laden(s, client: c)
    }

    private var client: NXClient?

    private func laden(_ i: Int, client c: NXClient? = nil) {
        if let c { client = c }
        guard liste.indices.contains(i), let c = client else { return }
        index = i
        let titel = liste[i]
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let asset = AVURLAsset(url: titel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": c.cookieKopf])
        let item = AVPlayerItem(asset: asset)
        if let b = beobachter, let s = spieler { s.removeTimeObserver(b) }
        if let e = endeBeob { NotificationCenter.default.removeObserver(e) }
        let p = spieler ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        spieler = p
        beobachter = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.zeit = t.seconds.isFinite ? t.seconds : 0
                if let d = self.spieler?.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - self.dauer) > 0.5 { self.dauer = d; self.anzeige() }
            }
        }
        endeBeob = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.weiter() }
        }
        zeit = 0
        dauer = 0
        p.play()
        spielt = true
        fernsteuerung()
        anzeige()
        Task { await bildLaden(titel) }
    }

    func umschalten() { spielt ? pause() : weiterSpielen() }

    func pause() {
        spieler?.pause()
        spielt = false
        anzeige()
    }

    func weiterSpielen() {
        guard spieler != nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        spieler?.play()
        spielt = true
        anzeige()
    }

    func weiter() {
        if index + 1 < liste.count { laden(index + 1) } else { pause(); spieler?.seek(to: .zero); zeit = 0 }
    }

    func zurueck() {
        if zeit > 3 { spieler?.seek(to: .zero); return }
        if index > 0 { laden(index - 1) } else { spieler?.seek(to: .zero) }
    }

    func springen(_ i: Int) { laden(i) }

    func suchen(_ s: Double) {
        spieler?.seek(to: CMTime(seconds: s, preferredTimescale: 600))
        zeit = s
        anzeige()
    }

    func beenden() {
        spieler?.pause()
        if let b = beobachter, let s = spieler { s.removeTimeObserver(b) }
        beobachter = nil
        spieler = nil
        liste = []
        spielt = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Sperrbildschirm

    private var cover: MPMediaItemArtwork?

    private func anzeige() {
        guard let t = aktuell else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: t.name, MPMediaItemPropertyArtist: "NitraX",
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: zeit, MPNowPlayingInfoPropertyPlaybackRate: spielt ? 1.0 : 0.0]
        if dauer > 0 { info[MPMediaItemPropertyPlaybackDuration] = dauer }
        if let cover { info[MPMediaItemPropertyArtwork] = cover }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func bildLaden(_ t: Titel) async {
        cover = nil
        guard let u = t.bild, let c = client else { anzeige(); return }
        var r = URLRequest(url: u)
        for (k, v) in c.cookieKopf { r.setValue(v, forHTTPHeaderField: k) }
        if let (d, _) = try? await URLSession.shared.data(for: r), let b = UIImage(data: d), aktuell?.id == t.id {
            cover = MPMediaItemArtwork(boundsSize: b.size) { _ in b }
            anzeige()
        }
    }

    private func fernsteuerung() {
        guard !fernEingerichtet else { return }
        fernEingerichtet = true
        let z = MPRemoteCommandCenter.shared()
        z.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.weiterSpielen() }; return .success }
        z.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        z.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.umschalten() }; return .success }
        z.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.weiter() }; return .success }
        z.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.zurueck() }; return .success }
        z.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { Task { @MainActor in self?.suchen(e.positionTime) } }
            return .success
        }
    }
}

/// kleine Leiste über den Reitern, solange Musik läuft
@MainActor
struct MiniSpieler: View {
    @ObservedObject private var m = Musikspieler.shared
    @State private var gross = false

    var body: some View {
        if let t = m.aktuell {
            HStack(spacing: 12) {
                NXBild(url: t.bild).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { if t.bild == nil { Image(systemName: "music.note").foregroundStyle(Farbe.akzent) } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    ProgressView(value: m.dauer > 0 ? min(1, m.zeit / m.dauer) : 0).tint(Farbe.akzent)
                }
                Button { m.umschalten() } label: { Image(systemName: m.spielt ? "pause.fill" : "play.fill").font(.title3) }
                Button { m.weiter() } label: { Image(systemName: "forward.fill") }.disabled(m.index + 1 >= m.liste.count)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onTapGesture { gross = true }
            .sheet(isPresented: $gross) { SpielerAnsicht().presentationDetents([.large]) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

@MainActor
struct SpielerAnsicht: View {
    @ObservedObject private var m = Musikspieler.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let t = m.aktuell {
                    NXBild(url: t.bild, modus: .fill).frame(width: 240, height: 240).clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay { if t.bild == nil { Image(systemName: "music.note").font(.system(size: 70)).foregroundStyle(Farbe.verlauf) } }
                        .shadow(radius: 18)
                    Text(t.name).font(.title3.bold()).multilineTextAlignment(.center).lineLimit(2).padding(.horizontal)
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { m.zeit }, set: { m.suchen($0) }), in: 0...max(1, m.dauer))
                        HStack {
                            Text(Self.mmss(m.zeit)); Spacer(); Text(Self.mmss(m.dauer))
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28)
                    HStack(spacing: 44) {
                        Button { m.zurueck() } label: { Image(systemName: "backward.fill").font(.title) }
                        Button { m.umschalten() } label: { Image(systemName: m.spielt ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                        Button { m.weiter() } label: { Image(systemName: "forward.fill").font(.title) }.disabled(m.index + 1 >= m.liste.count)
                    }
                    .foregroundStyle(.white)
                }
                List {
                    ForEach(m.liste.indices, id: \.self) { i in
                        Button { m.springen(i) } label: {
                            HStack {
                                Image(systemName: i == m.index ? (m.spielt ? "speaker.wave.2.fill" : "speaker.fill") : "music.note")
                                    .foregroundStyle(i == m.index ? Farbe.akzent : .secondary).frame(width: 24)
                                Text(m.liste[i].name).lineLimit(1).foregroundStyle(.primary)
                            }
                        }
                    }
                    .listRowBackground(Farbe.karte)
                }
                .scrollContentBackground(.hidden)
            }
            .padding(.top, 20)
            .nxHintergrund()
            .navigationTitle(m.zufall ? "🔀 Zufallswiedergabe" : "Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Beenden", role: .destructive) { m.beenden(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }

    static func mmss(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
