import SwiftUI
import AVFoundation
import Vision
import CoreImage

/// 👁 Live-Kamera als Augen des Helfers (Frontkamera): Gesicht verfolgen -> sie schaut dich an; bei Seh-Fragen
/// (»Siehst du mich?«, »Wie sehe ich aus?«) ein Bild an den PC, der beschreibt, was sie sieht. Nichts wird gespeichert.
@MainActor
final class HelferAugen: ObservableObject {
    @Published private(set) var laeuft = false
    @Published private(set) var front = true          // false = Rückkamera (Dinge zeigen)
    @Published var fehler: String?
    let sitzung = AVCaptureSession()
    let verarbeitung = AugenVerarbeitung()
    private let schlange = DispatchQueue(label: "de.infinitras.nitrax.augen")
    private var eingerichtet = false

    func starten() async {
        guard !laeuft else { return }
        let erlaubt: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: erlaubt = true
        case .notDetermined: erlaubt = await AVCaptureDevice.requestAccess(for: .video)
        default: erlaubt = false
        }
        guard erlaubt else { fehler = "Die Kamera ist für NitraX nicht erlaubt (iPhone-Einstellungen → NitraX → Kamera)."; return }
        if !eingerichtet {
            sitzung.beginConfiguration()
            if sitzung.canSetSessionPreset(.vga640x480) { sitzung.sessionPreset = .vga640x480 }
            guard let geraet = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
                  let eingang = try? AVCaptureDeviceInput(device: geraet), sitzung.canAddInput(eingang) else {
                sitzung.commitConfiguration()
                fehler = "Keine Frontkamera gefunden."
                return
            }
            sitzung.addInput(eingang)
            let ausgabe = AVCaptureVideoDataOutput()
            ausgabe.alwaysDiscardsLateVideoFrames = true
            ausgabe.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            ausgabe.setSampleBufferDelegate(verarbeitung, queue: schlange)
            if sitzung.canAddOutput(ausgabe) { sitzung.addOutput(ausgabe) }
            if let c = ausgabe.connection(with: .video) {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }          // Hochformat, aufrecht
                if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
            }
            sitzung.commitConfiguration()
            eingerichtet = true
        }
        let s = sitzung
        await Task.detached(priority: .userInitiated) { s.startRunning() }.value
        laeuft = s.isRunning
        if !laeuft { fehler = "Die Kamera startet gerade nicht (von einer anderen App belegt?)." }
    }

    /// 🔄 Front ⇄ Rück: Eingang tauschen, ohne die Sitzung neu aufzubauen
    func drehen() {
        let neu: AVCaptureDevice.Position = front ? .back : .front
        guard eingerichtet, let geraet = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: neu),
              let eingang = try? AVCaptureDeviceInput(device: geraet) else { return }
        sitzung.beginConfiguration()
        for alt in sitzung.inputs { sitzung.removeInput(alt) }
        if sitzung.canAddInput(eingang) { sitzung.addInput(eingang) }
        if let c = (sitzung.outputs.first as? AVCaptureVideoDataOutput)?.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        }
        sitzung.commitConfiguration()
        front = neu == .front
        verarbeitung.gesichterSuchen = front              // Blickkontakt nur, wenn du selbst im Bild bist
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func stoppen() {
        guard laeuft else { return }
        laeuft = false
        let s = sitzung
        Task.detached { s.stopRunning() }
    }
}

/// Läuft auf der Kamera-Warteschlange: letztes Bild merken, alle paar Bilder das Gesicht suchen.
final class AugenVerarbeitung: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sperre = NSLock()
    private var bild: CVPixelBuffer?
    private var zaehler = 0
    private let kontext = CIContext()
    var gesichterSuchen = true
    /// x, y in -1…1 (x > 0 = zu deiner rechten Seite, y > 0 = oben) - wird auf dem Hauptthread gemeldet
    var blick: (@Sendable (Double, Double) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from verbindung: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        sperre.lock(); bild = pb; sperre.unlock()
        zaehler += 1
        guard zaehler % 5 == 0, gesichterSuchen, let melden = blick else { return }           // ~6 Gesichtssuchen pro Sekunde reichen
        let anfrage = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([anfrage])
        guard let g = anfrage.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return }
        let x = 1 - 2 * Double(g.boundingBox.midX), y = 2 * Double(g.boundingBox.midY) - 1
        DispatchQueue.main.async { melden(x, y) }
    }

    /// Aktuelles Kamerabild als JPEG (lange Seite höchstens `kante` Pixel) - oder nil, wenn es (fast) schwarz ist.
    func jpeg(kante: CGFloat = 768) -> Data? {
        sperre.lock(); let pb = bild; sperre.unlock()
        guard let pb else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        let s = min(1, kante / max(ci.extent.width, ci.extent.height))
        let klein = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = kontext.createCGImage(klein, from: klein.extent) else { return nil }
        // fast schwarz (Objektiv abgedeckt) -> nicht raten lassen
        let mittel = CIImage(cgImage: cg).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: klein.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        kontext.render(mittel, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        if (Int(px[0]) + Int(px[1]) + Int(px[2])) / 3 < 8 { return Data() }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }
}

/// Kleines Live-Vorschaubild (gespiegelt wie ein Selfie), damit du siehst, was der Helfer sieht.
struct KameraVorschau: UIViewRepresentable {
    let sitzung: AVCaptureSession

    func makeUIView(context: Context) -> Flaeche {
        let v = Flaeche()
        v.ebene.session = sitzung
        v.ebene.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: Flaeche, context: Context) {}

    final class Flaeche: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var ebene: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = ebene.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
    }
}
