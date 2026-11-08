import AVFoundation

/// 🔊 Gestreamte Helferstimme (/api/anruf/sprechen_strom): 4 Byte Abtastrate (little endian), danach 16-bit-PCM mono.
/// Der erste Ton kommt ~0,3 s nach der Anfrage – statt erst, wenn der ganze Satz berechnet ist.
@MainActor
final class StromSpieler {
    private let motor = AVAudioEngine()
    private let knoten = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var aufgabe: Task<Bool, Never>?
    private var offen = 0                       // eingeplante, noch nicht gespielte Stücke
    private var fertig: CheckedContinuation<Void, Never>?
    private(set) var pegel: Float = 0           // für die Anzeige (Helfer spricht)

    init() {
        motor.attach(knoten)
    }

    /// spielt den Satz; false = Streaming geht nicht (409/Fehler, bevor Ton kam) -> Aufrufer nimmt einen anderen Weg
    func spielen(_ anfrage: URLRequest) async -> Bool {
        stoppen()
        let t = Task { await self.lauf(anfrage) }
        aufgabe = t
        return await t.value
    }

    func stoppen() {
        aufgabe?.cancel()
        aufgabe = nil
        knoten.stop()
        offen = 0
        pegel = 0
        fertig?.resume()
        fertig = nil
    }

    private func lauf(_ anfrage: URLRequest) async -> Bool {
        // Netz lesen abseits des Hauptfadens; je ~80 ms Ton ein Stück an den Spieler
        let (strom, fortsetzung) = AsyncStream<Data>.makeStream()
        let leser = Task.detached { () -> Bool in
            defer { fortsetzung.finish() }
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: anfrage)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
                var stueck = Data()
                var rateGesendet = false
                for try await b in bytes {
                    if Task.isCancelled { return true }
                    stueck.append(b)
                    if !rateGesendet {
                        if stueck.count == 4 { fortsetzung.yield(stueck); stueck.removeAll(); rateGesendet = true }
                    } else if stueck.count >= 3840 {             // 80 ms bei 24 kHz, 16 bit
                        fortsetzung.yield(stueck); stueck.removeAll(keepingCapacity: true)
                    }
                }
                if !stueck.isEmpty { fortsetzung.yield(stueck) }
                return rateGesendet
            } catch { return false }
        }
        var rate: Double = 0
        var gespielt = false
        for await d in strom {
            if Task.isCancelled { leser.cancel(); return true }
            if rate == 0 {
                guard d.count == 4 else { continue }
                rate = Double(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                guard rate >= 8000, rate <= 96000, (try? einrichten(rate)) != nil else { leser.cancel(); return false }
                continue
            }
            einplanen(d)
            if !gespielt { knoten.play(); gespielt = true }
        }
        let ok = await leser.value
        if Task.isCancelled { return true }
        guard ok || gespielt else { return false }
        if offen > 0 { await withCheckedContinuation { fertig = $0 } }
        pegel = 0
        return true
    }

    private func einrichten(_ rate: Double) throws {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        if format?.sampleRate != rate {
            motor.stop()
            motor.disconnectNodeOutput(knoten)
            motor.connect(knoten, to: motor.mainMixerNode, format: f)
            format = f
        }
        if !motor.isRunning { motor.prepare(); try motor.start() }
    }

    private func einplanen(_ roh: Data) {
        guard let f = format else { return }
        let n = roh.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        var summe: Float = 0
        roh.withUnsafeBytes { p in
            let q = p.bindMemory(to: Int16.self)
            let z = buf.floatChannelData![0]
            for i in 0..<n { let v = Float(Int16(littleEndian: q[i])) / 32768; z[i] = v; summe += v * v }
        }
        let laut = sqrt(summe / Float(n))
        offen += 1
        knoten.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pegel = min(1, laut * 6)
                self.offen -= 1
                if self.offen <= 0, let c = self.fertig { self.fertig = nil; c.resume() }
            }
        }
    }
}
