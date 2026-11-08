import SwiftUI
import WebKit

/// Splash wie am PC (Chrom-Unendlichkeitszeichen, Neonlicht, Pixel-Schriftzug, Lichtstreif) - ohne Ladebalken,
/// fürs Hochformat zugeschnitten, mit Haptik im Takt. Antippen überspringt; »Bewegung reduzieren« zeigt nur kurz das Logo.
struct SplashAnsicht: View {
    @Environment(\.accessibilityReduceMotion) private var ruhig
    var fertig: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.012, green: 0.020, blue: 0.039).ignoresSafeArea()
            SplashWeb(ruhig: ruhig, fertig: fertig).ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .onTapGesture { fertig() }
        .task {
            try? await Task.sleep(for: .seconds(6.5))           // Sicherheit, falls die Seite nichts meldet
            fertig()
        }
        .statusBarHidden()
    }
}

struct SplashWeb: UIViewRepresentable {
    var ruhig: Bool
    var fertig: () -> Void

    func makeCoordinator() -> Koordinator { Koordinator(fertig) }

    func makeUIView(context: Context) -> WKWebView {
        let k = WKWebViewConfiguration()
        k.userContentController.add(context.coordinator, name: "nxSplash")
        let w = WKWebView(frame: .zero, configuration: k)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.isUserInteractionEnabled = false                      // Antippen geht an SwiftUI (überspringen)
        if let url = Bundle.main.url(forResource: "splash", withExtension: "html") {
            // ruhig: fertiges Bild (t = 5,2 s) statt Animation
            let ziel = ruhig ? (URL(string: url.absoluteString + "?t=5.2") ?? url) : url
            w.loadFileURL(ziel, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { context.coordinator.fertig() }
        }
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}

    static func dismantleUIView(_ w: WKWebView, coordinator: Koordinator) {
        w.configuration.userContentController.removeScriptMessageHandler(forName: "nxSplash")
    }

    final class Koordinator: NSObject, WKScriptMessageHandler {
        let fertig: () -> Void
        private let leicht = UIImpactFeedbackGenerator(style: .light)
        private let stark = UIImpactFeedbackGenerator(style: .rigid)

        init(_ f: @escaping () -> Void) {
            fertig = f
            super.init()
            leicht.prepare()
            stark.prepare()
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.body as? String {
            case "tick": leicht.impactOccurred(intensity: 0.55)        // Buchstabe rastet ein
            case "boom": stark.impactOccurred(intensity: 0.9)          // Lichtstreif
            default: fertig()
            }
        }
    }
}
