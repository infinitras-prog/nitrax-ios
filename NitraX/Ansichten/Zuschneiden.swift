import SwiftUI
import UIKit

/// 📷 Runde 2, Nr. 6: Foto aufnehmen -> zuschneiden (Format wählen, verschieben, zoomen) -> JPEG
@MainActor
struct KameraMitZuschnitt: View {
    @Environment(\.dismiss) private var dismiss
    var fertig: (Data) -> Void
    @State private var bild: UIImage?

    var body: some View {
        Group {
            if let bild {
                ZuschneidenAnsicht(bild: bild, neu: { self.bild = nil }) { d in fertig(d); dismiss() }
            } else {
                KameraRoh(abbruch: { dismiss() }) { b in bild = Zuschnitt.aufrecht(b) }.ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Kamera ohne eigenes Schließen (danach kommt das Zuschneiden im selben Vollbild)
struct KameraRoh: UIViewControllerRepresentable {
    var abbruch: () -> Void
    var fertig: (UIImage) -> Void

    func makeCoordinator() -> Koordinator { Koordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Koordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let eltern: KameraRoh
        init(_ e: KameraRoh) { eltern = e }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let b = info[.originalImage] as? UIImage { eltern.fertig(b) } else { eltern.abbruch() }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { eltern.abbruch() }
    }
}

enum Zuschnitt {
    /// Ausrichtung »einbacken« (Kamerabilder sind oft gedreht gespeichert) und auf höchstens 2400 px verkleinern
    static func aufrecht(_ b: UIImage, maxKante: CGFloat = 2400) -> UIImage {
        let f = min(1, maxKante / max(b.size.width, b.size.height))
        let g = CGSize(width: (b.size.width * f).rounded(), height: (b.size.height * f).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: g, format: format).image { _ in b.draw(in: CGRect(origin: .zero, size: g)) }
    }

    static func schneiden(_ b: UIImage, _ r: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let g = CGSize(width: max(1, r.width.rounded()), height: max(1, r.height.rounded()))
        return UIGraphicsImageRenderer(size: g, format: format).image { _ in
            b.draw(at: CGPoint(x: -r.minX, y: -r.minY))
        }
    }
}

/// ✂ Zuschneiden: festes Format, das Bild darunter verschieben und zoomen (wie in Fotos)
@MainActor
struct ZuschneidenAnsicht: View {
    let bild: UIImage
    var neu: () -> Void
    var fertig: (Data) -> Void

    enum Format: String, CaseIterable, Identifiable {
        case original = "Original", quadrat = "1:1", hoch = "9:16", quer = "16:9", portrait = "4:5"
        var id: String { rawValue }
        func verhaeltnis(_ b: CGSize) -> CGFloat {
            switch self {
            case .original: return b.width / max(1, b.height)
            case .quadrat: return 1
            case .hoch: return 9.0 / 16
            case .quer: return 16.0 / 9
            case .portrait: return 4.0 / 5
            }
        }
    }

    @State private var format: Format = .original
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var versatz: CGSize = .zero
    @State private var versatzStart: CGSize = .zero

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Neu aufnehmen") { neu() }
                Spacer()
                Text("Zuschneiden").font(.headline)
                Spacer()
                Button("Übernehmen") { uebernehmen() }.fontWeight(.semibold)
            }
            .padding(.horizontal, 16).padding(.top, 12)
            GeometryReader { geo in
                let rahmen = rahmenGroesse(in: geo.size)
                let s = skala(rahmen) * zoom
                let anzeige = CGSize(width: bild.size.width * s, height: bild.size.height * s)
                ZStack {
                    Image(uiImage: bild).resizable().frame(width: anzeige.width, height: anzeige.height)
                        .offset(begrenzt(versatz, anzeige, rahmen))
                    // abgedunkelt außerhalb des Rahmens
                    Rectangle().fill(.black.opacity(0.55))
                        .mask {
                            Rectangle().overlay { Rectangle().frame(width: rahmen.width, height: rahmen.height).blendMode(.destinationOut) }
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)
                    Rectangle().stroke(.white.opacity(0.9), lineWidth: 1.5).frame(width: rahmen.width, height: rahmen.height)
                        .overlay { Drittel().stroke(.white.opacity(0.3), lineWidth: 0.7) }
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { g in versatz = CGSize(width: versatzStart.width + g.translation.width, height: versatzStart.height + g.translation.height) }
                        .onEnded { _ in versatz = begrenzt(versatz, anzeige, rahmen); versatzStart = versatz }
                        .simultaneously(with: MagnificationGesture()
                            .onChanged { z in zoom = max(1, min(6, zoomStart * z)) }
                            .onEnded { _ in zoomStart = zoom; versatz = begrenzt(versatz, anzeige, rahmen); versatzStart = versatz })
                )
                .onChange(of: format) { _, _ in withAnimation(.snappy) { zoom = 1; zoomStart = 1; versatz = .zero; versatzStart = .zero } }
                .onAppear { letzteGeo = geo.size }
                .onChange(of: geo.size) { _, g in letzteGeo = g }
            }
            Picker("Format", selection: $format) {
                ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            Text("Ziehen zum Verschieben · zwei Finger zum Zoomen").font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
        }
        .background(Color.black.ignoresSafeArea())
    }

    @State private var letzteGeo: CGSize = .zero

    private func rahmenGroesse(in platz: CGSize) -> CGSize {
        let v = format.verhaeltnis(bild.size)
        let b = platz.width - 32, h = platz.height - 24
        return b / v <= h ? CGSize(width: b, height: b / v) : CGSize(width: h * v, height: h)
    }

    /// Bild füllt den Rahmen mindestens ganz aus
    private func skala(_ rahmen: CGSize) -> CGFloat {
        max(rahmen.width / bild.size.width, rahmen.height / bild.size.height)
    }

    private func begrenzt(_ v: CGSize, _ anzeige: CGSize, _ rahmen: CGSize) -> CGSize {
        let mx = max(0, (anzeige.width - rahmen.width) / 2), my = max(0, (anzeige.height - rahmen.height) / 2)
        return CGSize(width: min(mx, max(-mx, v.width)), height: min(my, max(-my, v.height)))
    }

    private func uebernehmen() {
        let rahmen = rahmenGroesse(in: letzteGeo)
        let s = skala(rahmen) * zoom
        let anzeige = CGSize(width: bild.size.width * s, height: bild.size.height * s)
        let v = begrenzt(versatz, anzeige, rahmen)
        // Rahmen-Mitte liegt in der Bildmitte minus Versatz -> in Bildpunkte umrechnen
        let x = (anzeige.width / 2 - v.width - rahmen.width / 2) / s
        let y = (anzeige.height / 2 - v.height - rahmen.height / 2) / s
        var r = CGRect(x: x, y: y, width: rahmen.width / s, height: rahmen.height / s)
        r = r.intersection(CGRect(origin: .zero, size: bild.size))
        let ergebnis = (format == .original && zoom <= 1.001) || r.isNull ? bild : Zuschnitt.schneiden(bild, r)
        if let d = ergebnis.jpegData(compressionQuality: 0.92) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fertig(d)
        }
    }
}

private struct Drittel: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        return p
    }
}

/// 📷 »Mit Foto starten« im Erstellen-Tab: aufnehmen, zuschneiden, hochladen -> passenden Workflow wählen
@MainActor
struct FotoStartKarte: View {
    @EnvironmentObject private var studio: Studio
    @State private var kamera = false
    @State private var laedt = false
    @State private var prozent: Double?
    @State private var bildName: String?
    @State private var wahl = false
    @State private var ziel: FotoZiel?

    struct FotoZiel: Identifiable, Hashable { let id = UUID(); let workflow: Workflow; let werte: [String: JSONWert] }

    /// Workflows mit einem Bild-Feld (erstes Bild-Feld bekommt das Foto)
    private var passende: [(Workflow, Feld)] {
        (studio.workflows?.workflows ?? []).compactMap { w in
            w.felder.first(where: { ["bild", "bilder"].contains($0.art) }).map { (w, $0) }
        }
    }

    var body: some View {
        Button { kamera = true } label: {
            HStack(spacing: 12) {
                Text("📷").font(.system(size: 26)).frame(width: 44, height: 44).background(Circle().fill(Farbe.akzent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mit Foto starten").font(.subheadline.weight(.semibold))
                    Text(laedt ? (prozent.map { "Lädt hoch … \(Int($0 * 100)) %" } ?? "Lädt hoch …")
                               : "Aufnehmen, zuschneiden – dann wählen, was daraus werden soll")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if laedt { ProgressView() } else { Image(systemName: "camera.fill").foregroundStyle(Farbe.akzent) }
            }
            .karte()
        }
        .buttonStyle(.plain)
        .disabled(laedt || studio.client == nil)
        .fullScreenCover(isPresented: $kamera) {
            KameraMitZuschnitt { d in Task { await hoch(d) } }
        }
        .sheet(isPresented: $wahl) { auswahl.presentationDetents([.medium, .large]) }
        .navigationDestination(item: $ziel) { z in WorkflowFormular(workflow: z.workflow, vorbelegung: z.werte) }
    }

    private var auswahl: some View {
        NavigationStack {
            List {
                if let n = bildName {
                    Section { NXBild(url: studio.bildURL(n), modus: .fit).frame(maxHeight: 180).frame(maxWidth: .infinity) }
                        .listRowBackground(Color.clear)
                }
                Section("Was soll daraus werden?") {
                    ForEach(passende.indices, id: \.self) { i in
                        let w = passende[i].0, f = passende[i].1
                        Button {
                            guard let n = bildName else { return }
                            let b = JSONWert.objekt(["quelle": .text("upload"), "name": .text(n)])
                            wahl = false
                            ziel = FotoZiel(workflow: w, werte: [f.name: f.art == "bilder" ? .liste([b]) : b])
                        } label: {
                            HStack(spacing: 12) {
                                Text(w.glyph).font(.title2).frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(w.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text(w.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Foto verwenden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { wahl = false } } }
        }
    }

    private func hoch(_ d: Data) async {
        guard let c = studio.client else { return }
        laedt = true; prozent = nil
        defer { laedt = false; prozent = nil }
        do {
            let r = try await c.hochladen("/api/upload", daten: d, dateiname: "iphone.jpg", typ: "image/jpeg",
                                          fortschritt: { p in Task { @MainActor in prozent = p } })
            guard let n = r["name"]?.text else { throw NXFehler.antwort }
            bildName = n
            if studio.workflows == nil { await studio.workflowsLaden() }
            wahl = true
        } catch { studio.meldung = error.localizedDescription }
    }
}
