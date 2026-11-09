import AVFoundation
import Accelerate

/// 🎙 Freihändiges Dauergespräch: hört ständig zu, erkennt Satzanfang/-ende selbst (Pegel), schickt den Satz zur Erkennung an
/// den PC und reicht den Text an den Helfer. Spricht der Helfer gerade, zählt nur deutlich lautere, längere Sprache als
/// »ins Wort fallen« (sein eigener Ton aus dem Lautsprecher soll ihn nicht unterbrechen) - dann wird er sofort still.
@MainActor
final class Dauergespraech: ObservableObject {
    enum Phase { case aus, lauscht, hoert, versteht }
    @Published private(set) var phase: Phase = .aus
    @Published private(set) var pegel: Float = 0                  // 0…1 für die Anzeige

    /// Zustand des Helfers (von der Seite gemeldet): "sprechen", "denken", "hoeren", "ruhe"
    var helferZustand = "ruhe"
    var satzFertig: ((Data) -> Void)?
    var insWortGefallen: (() -> Void)?
    /// so lange Stille = Satz zu Ende (Telefonat: kürzer, damit die Antwort schneller kommt)
    var stilleEnde: TimeInterval = 0.85

    /// eine Engine für Mikrofon UND Helferstimme (Telefonat): zwei Engines würgten sich gegenseitig ab (09.11.2026)
    let motor = AVAudioEngine()
    /// stumm geschaltet: Mikrofon wird ignoriert, die Engine (und damit die Stimme) läuft weiter
    var taub = false
    /// 🔇 Echo-Sperre (Liste Nr. 2): wie laut ihre Stimme gerade aus dem Lautsprecher kommt (dBFS) – ins Wort fallen zählt nur,
    /// wenn du deutlich lauter bist als ihr Echo
    var echoDb: Float = -100
    /// 🗣 jeder Mikrofon-Puffer (Audio-Faden) – für die Live-Erkennung auf dem iPhone
    nonisolated(unsafe) var tonSenke: ((AVAudioPCMBuffer) -> Void)?
    /// Satz fängt an (Pegel über der Schwelle)
    var satzBeginnt: (() -> Void)?
    /// läuft das Mikrofon wirklich? (für den Wächter im Telefonat)
    var laeuft: Bool { phase != .aus && motor.isRunning }
    private var sitzungMerk = true
    private var beobachter: NSObjectProtocol?
    private var konverter: AVAudioConverter?
    private let ziel = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var puffer = Data()
    private var vorlauf: [Data] = []                  // ~0,4 s vor dem Satzanfang (sonst fehlt das erste Wort)
    private var sprichtSeit: Date?
    private var stilleSeit: Date?
    private var satzStart: Date?
    private var unterbrochen = false

    // Schwellen (dBFS): normal / während der Helfer spricht (Barge-in)
    private let schwelle: Float = -42
    private let schwelleBargeIn: Float = -27

    /// sitzung = false: Ton gehört schon jemand anderem (Telefonat über CallKit - Hörmuschel statt Lautsprecher)
    func starten(sitzung: Bool = true) throws {
        guard phase == .aus else { return }
        sitzungMerk = sitzung
        if sitzung { HelferTon.einrichten() }
        let ein = motor.inputNode
        let format = ein.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "NitraX", code: 3, userInfo: [NSLocalizedDescriptionKey: "Kein Mikrofon verfügbar"]) }
        konverter = AVAudioConverter(from: format, to: ziel)
        let k = konverter, z = ziel
        ein.removeTap(onBus: 0)
        ein.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.tonSenke?(buf)
            let roh = Self.umwandeln(buf, k, z)
            let db = Self.dbfs(buf)
            Task { @MainActor in self?.verarbeiten(roh, db) }
        }
        motor.prepare()
        try motor.start()
        phase = .lauscht
        if beobachter == nil {
            // iOS stoppt die Engine bei Umschalten Hörmuschel/Lautsprecher, Bluetooth usw. -> sofort neu starten
            beobachter = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: motor, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.neuStarten() }
            }
        }
    }

    private func neuStarten() {
        guard phase != .aus else { return }
        let s = sitzungMerk
        motor.inputNode.removeTap(onBus: 0)
        motor.stop()
        phase = .aus
        puffer = Data(); vorlauf = []
        sprichtSeit = nil; stilleSeit = nil; satzStart = nil
        // während eines Routenwechsels liefert iOS kurz kein Format -> ein paar Mal versuchen statt stumm zu bleiben
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                guard let self, self.phase == .aus else { return }
                if (try? self.starten(sitzung: s)) != nil { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stoppen() {
        motor.inputNode.removeTap(onBus: 0)
        motor.stop()
        phase = .aus
        puffer = Data(); vorlauf = []
        sprichtSeit = nil; stilleSeit = nil; satzStart = nil
    }

    /// Nach der Erkennung wieder lauschen
    func weiter() { if phase != .aus { phase = .lauscht } }

    private func verarbeiten(_ roh: Data?, _ db: Float) {
        guard phase != .aus, let roh else { return }
        if taub { pegel = 0; return }
        pegel = max(0, min(1, (db + 60) / 45))
        let jetzt = Date()
        let helferRedet = helferZustand == "sprechen"
        switch phase {
        case .lauscht:
            vorlauf.append(roh)
            if vorlauf.count > 4 { vorlauf.removeFirst() }
            let grenze = helferRedet ? max(schwelleBargeIn, echoDb + 9) : schwelle
            if db > grenze {
                if sprichtSeit == nil { sprichtSeit = jetzt }
                // während sie redet: erst nach 0,35 s lauter Sprache unterbrechen (kein Fehlalarm durch ihr Echo)
                if jetzt.timeIntervalSince(sprichtSeit!) > (helferRedet ? 0.35 : 0.12) {
                    if helferRedet { insWortGefallen?(); unterbrochen = true }
                    phase = .hoert
                    satzBeginnt?()
                    puffer = vorlauf.reduce(Data(), +)
                    satzStart = jetzt
                    stilleSeit = nil
                }
            } else { sprichtSeit = nil }
        case .hoert:
            puffer.append(roh)
            if db > schwelle { stilleSeit = nil } else if stilleSeit == nil { stilleSeit = jetzt }
            let lang = jetzt.timeIntervalSince(satzStart ?? jetzt)
            if let st = stilleSeit, jetzt.timeIntervalSince(st) > stilleEnde || lang > 25 {
                if lang > 0.6 {
                    phase = .versteht
                    satzFertig?(Self.wav(puffer))
                } else { phase = .lauscht }
                puffer = Data(); sprichtSeit = nil; stilleSeit = nil
            }
        case .versteht, .aus:
            break
        }
    }

    // MARK: Audio-Hilfen (laufen auf dem Audio-Faden)

    nonisolated private static func dbfs(_ b: AVAudioPCMBuffer) -> Float {
        guard let k = b.floatChannelData?[0], b.frameLength > 0 else { return -90 }
        var rms: Float = 0
        vDSP_rmsqv(k, 1, &rms, vDSP_Length(b.frameLength))
        return 20 * log10(max(rms, 1e-7))
    }

    nonisolated private static func umwandeln(_ b: AVAudioPCMBuffer, _ k: AVAudioConverter?, _ ziel: AVAudioFormat?) -> Data? {
        guard let k, let ziel else { return nil }
        let kap = AVAudioFrameCount(Double(b.frameLength) * ziel.sampleRate / b.format.sampleRate) + 32
        guard let aus = AVAudioPCMBuffer(pcmFormat: ziel, frameCapacity: kap) else { return nil }
        var geliefert = false
        var fehler: NSError?
        k.convert(to: aus, error: &fehler) { _, status in
            if geliefert { status.pointee = .noDataNow; return nil }
            geliefert = true
            status.pointee = .haveData
            return b
        }
        guard fehler == nil, let p = aus.int16ChannelData?[0] else { return nil }
        return Data(bytes: p, count: Int(aus.frameLength) * 2)
    }

    nonisolated static func wav(_ pcm: Data, rate: UInt32 = 16000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
