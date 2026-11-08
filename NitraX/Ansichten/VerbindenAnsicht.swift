import SwiftUI
import VisionKit

/// Erster Start: PC verbinden - QR-Code aus NitraX AI Studio (Einstellungen → Handy) scannen oder Link einfügen.
@MainActor
struct VerbindenAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var scannen = false
    @State private var link = ""
    @State private var fehler: String?
    @State private var prueft = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 30)
                ZStack {
                    Circle().fill(Farbe.verlauf).frame(width: 110, height: 110).blur(radius: 30).opacity(0.7)
                    Image(systemName: "sparkles").font(.system(size: 54, weight: .semibold)).foregroundStyle(Farbe.verlauf)
                }
                Text("NitraX").font(.system(size: 40, weight: .heavy, design: .rounded))
                Text("Dein Studio auf dem iPhone – Videos, Bilder, Musik und Filme starten, Fortschritt sehen, mit dem Agenten und deinem Helfer sprechen.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Am PC: NitraX AI Studio → Einstellungen → Handy → »Handy-Zugang« an", systemImage: "1.circle")
                    Label("Den QR-Code dort mit dieser App scannen", systemImage: "2.circle")
                    Label("Unterwegs: Tailscale auf PC und iPhone – dann klappt es überall", systemImage: "3.circle")
                }
                .font(.footnote)
                .karte()

                Button { scannen = true } label: {
                    Label("QR-Code scannen", systemImage: "qrcode.viewfinder").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(spacing: 8) {
                    TextField("oder Link einfügen: http://…:8296/?k=…", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Farbe.karte))
                    HStack {
                        Button("Aus Zwischenablage") { link = UIPasteboard.general.string ?? "" }
                        Spacer()
                        Button("Verbinden") { Task { await pruefen(link) } }.disabled(link.isEmpty || prueft)
                    }
                    .font(.footnote)
                }
                if prueft { ProgressView("Verbinde …") }
                if let fehler { Text(fehler).font(.footnote).foregroundStyle(Farbe.fehler).multilineTextAlignment(.center) }
            }
            .padding(24)
        }
        .nxHintergrund()
        .sheet(isPresented: $scannen) {
            QRScanner { text in scannen = false; Task { await pruefen(text) } }
                .ignoresSafeArea()
        }
    }

    private func pruefen(_ text: String) async {
        fehler = nil
        guard let v = Verbindung.ausLink(text) else {
            fehler = "Das ist kein NitraX-Link. Er sieht so aus: http://192.168.…:8296/?k=…"
            return
        }
        prueft = true
        defer { prueft = false }
        let c = NXClient(v, zeitlimit: 6)
        if await c.basisFinden() != nil {
            studio.verbinden(v)
        } else {
            fehler = "Keine Verbindung zu \(v.adressen.first ?? ""). Ist das iPhone im selben WLAN (oder in Tailscale) und läuft NitraX am PC? Beim ersten Mal fragt iOS nach »Lokales Netzwerk« – bitte erlauben."
        }
    }
}

/// QR-Scanner (VisionKit). Auf Geräten ohne Scanner bleibt das Einfügen des Links.
struct QRScanner: UIViewControllerRepresentable {
    var gefunden: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            let vc = UIHostingController(rootView: Text("Der Scanner ist auf diesem Gerät nicht verfügbar – bitte den Link einfügen.")
                .padding().multilineTextAlignment(.center))
            return vc
        }
        let s = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                          isHighlightingEnabled: true)
        s.delegate = context.coordinator
        // erst starten, wenn der Scanner auf dem Bildschirm ist (vorher wirft startScanning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { try? s.startScanning() }
        return s
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}
    func makeCoordinator() -> Koordinator { Koordinator(gefunden) }

    final class Koordinator: NSObject, DataScannerViewControllerDelegate {
        let gefunden: (String) -> Void
        var fertig = false
        init(_ g: @escaping (String) -> Void) { gefunden = g }

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for i in items {
                if case .barcode(let b) = i, let t = b.payloadStringValue, !fertig, Verbindung.ausLink(t) != nil {
                    fertig = true
                    s.stopScanning()
                    gefunden(t)
                }
            }
        }
    }
}
