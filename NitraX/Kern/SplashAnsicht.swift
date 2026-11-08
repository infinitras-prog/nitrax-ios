import SwiftUI
import AVFoundation

/// Splash wie am PC (Chrom-Unendlichkeitszeichen, Neonlicht, Pixel-Schriftzug, Lichtstreif) - ohne Ladebalken.
/// Als vorgerendertes Video (60 fps, HEVC, 1178 x 2556, am PC Bild für Bild aus der Splash-Seite erzeugt): die Live-Seite
/// mit SVG-Filtern ruckelte in WebKit, das Video läuft auf dem Hardware-Decoder immer flüssig.
/// Haptik im Takt, Antippen überspringt, »Bewegung reduzieren« zeigt kurz das fertige Logo.
struct SplashAnsicht: View {
    @Environment(\.accessibilityReduceMotion) private var ruhig
    var fertig: () -> Void
    @State private var beendet = false

    var body: some View {
        ZStack {
            Color(red: 0.012, green: 0.020, blue: 0.039).ignoresSafeArea()
            if ruhig, let bild = UIImage(named: "splash_ende.jpg") ?? Bundle.main.path(forResource: "splash_ende", ofType: "jpg").flatMap(UIImage.init(contentsOfFile:)) {
                Image(uiImage: bild).resizable().scaledToFill().ignoresSafeArea()
            } else if !ruhig {
                SplashVideo(fertig: ende).ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { ende() }
        .task {
            try? await Task.sleep(for: .seconds(ruhig ? 1.4 : 7.5))      // Sicherheit, falls das Video nichts meldet
            ende()
        }
        .statusBarHidden()
    }

    private func ende() {
        guard !beendet else { return }
        beendet = true
        fertig()
    }
}

/// AVPlayerLayer ohne Steuerelemente; zeigt erst etwas, wenn das erste Bild bereit ist (kein Aufblitzen).
struct SplashVideo: UIViewRepresentable {
    var fertig: () -> Void

    func makeCoordinator() -> Koordinator { Koordinator(fertig) }

    func makeUIView(context: Context) -> SpielerFlaeche {
        let v = SpielerFlaeche()
        v.backgroundColor = .clear
        guard let url = Bundle.main.url(forResource: "splash", withExtension: "mp4") else {
            DispatchQueue.main.async { context.coordinator.fertig() }
            return v
        }
        // Das Video hat keine Tonspur - es weckt die Audio-Sitzung nicht und unterbricht keine Musik anderer Apps
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        v.ebene.player = p
        v.ebene.videoGravity = .resizeAspectFill
        v.ebene.opacity = 0
        context.coordinator.starten(p, ebene: v.ebene)
        return v
    }

    func updateUIView(_ v: SpielerFlaeche, context: Context) {}

    static func dismantleUIView(_ v: SpielerFlaeche, coordinator: Koordinator) {
        coordinator.aufraeumen()
        v.ebene.player = nil
    }

    final class SpielerFlaeche: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var ebene: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Koordinator: NSObject {
        let fertig: () -> Void
        private var spieler: AVPlayer?
        private var beobachter: NSKeyValueObservation?
        private var zeitBeobachter: Any?
        private var endeBeobachter: NSObjectProtocol?
        private let leicht = UIImpactFeedbackGenerator(style: .light)
        private let stark = UIImpactFeedbackGenerator(style: .rigid)

        init(_ f: @escaping () -> Void) {
            fertig = f
            super.init()
            leicht.prepare()
            stark.prepare()
        }

        func starten(_ p: AVPlayer, ebene: AVPlayerLayer) {
            spieler = p
            // erst abspielen, wenn das erste Bild da ist - dann weich einblenden (die Startfarbe ist identisch)
            beobachter = ebene.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] e, _ in
                guard e.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.15)
                    e.opacity = 1
                    CATransaction.commit()
                    self?.spieler?.play()
                }
            }
            // Haptik genau im Bild: Buchstaben rasten ein (2,45 s + je 0,12 s), Lichtstreif (3,6 s)
            var takte: [NSValue] = (0..<6).map { NSValue(time: CMTime(seconds: 2.53 + Double($0) * 0.12, preferredTimescale: 600)) }
            takte.append(NSValue(time: CMTime(seconds: 3.6, preferredTimescale: 600)))
            var nummer = 0
            zeitBeobachter = p.addBoundaryTimeObserver(forTimes: takte, queue: .main) { [weak self] in
                if nummer < 6 { self?.leicht.impactOccurred(intensity: 0.55) } else { self?.stark.impactOccurred(intensity: 0.9) }
                nummer += 1
            }
            endeBeobachter = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem,
                                                                    queue: .main) { [weak self] _ in self?.fertig() }
        }

        func aufraeumen() {
            if let z = zeitBeobachter { spieler?.removeTimeObserver(z) }
            if let e = endeBeobachter { NotificationCenter.default.removeObserver(e) }
            beobachter = nil
            spieler?.pause()
            spieler = nil
        }
    }
}
