import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// »An NitraX« im Teilen-Menü: Bilder aus Fotos, Safari, Instagram … direkt zum PC - als Video animieren oder ändern.
final class TeilenController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let anbieter = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let ansicht = TeilenAnsicht(anbieter: anbieter) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let h = UIHostingController(rootView: ansicht)
        addChild(h)
        h.view.frame = view.bounds
        h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(h.view)
        h.didMove(toParent: self)
    }
}

struct TeilenAnsicht: View {
    let anbieter: [NSItemProvider]
    let fertig: () -> Void
    @State private var bilder: [UIImage] = []
    @State private var text = ""
    @State private var laeuft = false
    @State private var meldung: String?

    private let akzent = Color(red: 0.91, green: 0.64, blue: 0.24)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Array(bilder.enumerated()), id: \.offset) { _, b in
                                Image(uiImage: b).resizable().scaledToFill().frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            if bilder.isEmpty { ProgressView().frame(height: 110) }
                        }
                    }
                }
                Section("Was soll passieren?") {
                    TextField("z. B. sie dreht sich lachend zur Kamera, Wind im Haar", text: $text, axis: .vertical).lineLimit(2...6)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.schnell.indices, id: \.self) { i in
                                let s = Self.schnell[i]
                                Button(s.0) { Task { text = s.2; await los(s.1) } }.buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                }
                Section {
                    Button { Task { await los("i2v") } } label: { Label("▶ Video daraus machen", systemImage: "play.rectangle") }
                    Button { Task { await los("x-r2i") } } label: { Label("◧ Bild nach Anweisung ändern", systemImage: "wand.and.rays") }
                } footer: {
                    if let meldung { Text(meldung) } else { Text("Der PC rechnet – du bekommst eine Mitteilung, wenn es fertig ist.") }
                }
                .disabled(laeuft || bilder.isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("An NitraX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { fertig() } } }
            .overlay { if laeuft { ProgressView("Wird gesendet …").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .tint(akzent)
        }
        .task { await laden() }
    }

    /// Ein Tipp = sofort los
    static let schnell: [(String, String, String)] = [
        ("🌸 Als Anime", "x-r2i", "Verwandle das Bild in einen hochwertigen Anime-Stil, gleiche Personen und Komposition"),
        ("🎨 Als Gemälde", "x-r2i", "Verwandle das Bild in ein Ölgemälde mit sichtbaren Pinselstrichen, gleiche Komposition"),
        ("✨ Lebendig machen", "i2v", "Natürliche, lebendige Bewegung passend zum Bild, sanfte Kamerafahrt"),
        ("🧸 Als 3D-Figur", "x-r2i", "Verwandle das Motiv in eine niedliche 3D-Figur im Pixar-Stil, gleiche Farben"),
    ]

    private func laden() async {
        for p in anbieter.prefix(4) where p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let d = await daten(p), let b = UIImage(data: d) { bilder.append(b) }
        }
        if bilder.isEmpty { meldung = "Hier war kein Bild dabei." }
    }

    private func daten(_ p: NSItemProvider) async -> Data? {
        await withCheckedContinuation { k in
            p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in k.resume(returning: d) }
        }
    }

    private func los(_ wf: String) async {
        guard let v = Verbindung.laden() else { meldung = "Erst in der NitraX-App mit dem PC verbinden."; return }
        laeuft = true
        defer { laeuft = false }
        let c = NXClient(v, zeitlimit: 60)
        do {
            var namen: [String] = []
            for b in bilder {
                // klein genug für die Erweiterung (Speichergrenze) und schnell im WLAN
                let s = min(1, 1600 / max(b.size.width, b.size.height))
                let g = CGSize(width: b.size.width * s, height: b.size.height * s)
                let jpg = UIGraphicsImageRenderer(size: g).image { _ in b.draw(in: CGRect(origin: .zero, size: g)) }.jpegData(compressionQuality: 0.9) ?? Data()
                let r = try await c.hochladen("/api/upload", daten: jpg, dateiname: "geteilt.jpg", typ: "image/jpeg")
                if let n = r["name"]?.text { namen.append(n) }
            }
            guard let erstes = namen.first else { throw NXFehler.antwort }
            let felder: [String: Any] = wf == "i2v"
                ? ["bild": ["quelle": "upload", "name": erstes], "idee": text]
                : ["bilder": namen.map { ["quelle": "upload", "name": $0] }, "anweisung": text]
            _ = try await c.post("/api/handy/start", ["wf": wf, "felder": felder], zeit: 300)
            meldung = "✓ Gestartet"
            try? await Task.sleep(for: .seconds(0.8))
            fertig()
        } catch {
            meldung = error.localizedDescription
        }
    }
}
