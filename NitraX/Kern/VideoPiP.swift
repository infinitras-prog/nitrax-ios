import AVKit
import WebKit
import SwiftUI

/// 🖼 Liste Nr. 4: Bild-in-Bild im Videoanruf – die Helferin bleibt als kleines Fenster sichtbar, wenn du die App wechselst.
/// Die 3D-Figur (WKWebView) wird ~12× pro Sekunde abfotografiert und als Video-Bild in einen AVSampleBufferDisplayLayer gegeben.
@MainActor
final class VideoPiP: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = VideoPiP()
    let ebene = AVSampleBufferDisplayLayer()
    private var steuerung: AVPictureInPictureController?
    private var takt: Timer?
    private weak var web: WKWebView?
    private var start = CACurrentMediaTime()

    func an(_ w: WKWebView) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        web = w
        ebene.videoGravity = .resizeAspect
        if steuerung == nil {
            let quelle = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: ebene, playbackDelegate: self)
            let s = AVPictureInPictureController(contentSource: quelle)
            s.canStartPictureInPictureAutomaticallyFromInline = true
            steuerung = s
        }
        takt?.invalidate()
        takt = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.bild() }
        }
    }

    func aus() {
        takt?.invalidate(); takt = nil
        steuerung?.stopPictureInPicture()
        ebene.flushAndRemoveImage()
    }

    private func bild() {
        guard let w = web, w.bounds.width > 10 else { return }
        let k = WKSnapshotConfiguration()
        k.snapshotWidth = 360
        w.takeSnapshot(with: k) { [weak self] b, _ in
            guard let self, let b, let puffer = Self.puffer(b) else { return }
            Task { @MainActor in self.einreihen(puffer) }
        }
    }

    private func einreihen(_ pb: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return }
        let jetzt = CMTime(seconds: CACurrentMediaTime() - start, preferredTimescale: 600)
        var zeit = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 12), presentationTimeStamp: jetzt, decodeTimeStamp: .invalid)
        var probe: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format, sampleTiming: &zeit, sampleBufferOut: &probe)
        guard let probe else { return }
        if let a = CMSampleBufferGetSampleAttachmentsArray(probe, createIfNecessary: true), CFArrayGetCount(a) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if ebene.status == .failed { ebene.flush() }
        ebene.enqueue(probe)
    }

    nonisolated private static func puffer(_ bild: UIImage) -> CVPixelBuffer? {
        guard let cg = bild.cgImage else { return nil }
        let b = cg.width, h = cg.height
        var pb: CVPixelBuffer?
        let attr = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, b, h, kCVPixelFormatType_32BGRA, attr, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: b, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(UIColor(red: 0.04, green: 0.04, blue: 0.09, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: b, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: b, height: h))
        return pb
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate (live, nie pausiert)
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}

/// Die Ebene muss sichtbar in der Ansicht hängen, damit iOS daraus Bild-in-Bild machen kann (liegt unsichtbar klein hinter dem Video)
struct PiPEbene: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.layer.addSublayer(VideoPiP.shared.ebene)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { VideoPiP.shared.ebene.frame = v.bounds }
}
