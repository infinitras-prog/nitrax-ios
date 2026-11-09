import Speech
import AVFoundation

/// 🗣 Spracherkennung direkt auf dem iPhone, schon WÄHREND du sprichst (Apple, Deutsch, möglichst offline).
/// Wenn der Satz zu Ende ist, liegt der Text praktisch sofort vor – kein Hochladen, kein Whisper am PC (kalt bis 12 s).
/// Klappt sie nicht (keine Erlaubnis, Sprache nicht verfügbar, leer), nimmt der Aufrufer die PC-Erkennung.
final class LiveErkennung: @unchecked Sendable {
    private let erkenner = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private let sperre = NSLock()
    private var anfrage: SFSpeechAudioBufferRecognitionRequest?
    private var aufgabe: SFSpeechRecognitionTask?
    private var vorlauf: [AVAudioPCMBuffer] = []          // ~0,5 s vor dem Satzanfang (sonst fehlt das erste Wort)
    private var text = ""
    private var fertig: CheckedContinuation<String, Never>?
    private var endgueltig = false
    private(set) var erlaubt = false
    /// Zwischenstand für die Untertitel (Hauptfaden)
    var teil: ((String) -> Void)?

    var bereit: Bool { erlaubt && (erkenner?.isAvailable ?? false) }
    var offline: Bool { erkenner?.supportsOnDeviceRecognition ?? false }

    func erlaubnisHolen() async {
        let s = SFSpeechRecognizer.authorizationStatus()
        if s == .authorized { erlaubt = true; return }
        guard s == .notDetermined else { erlaubt = false; return }
        erlaubt = await withCheckedContinuation { k in
            SFSpeechRecognizer.requestAuthorization { k.resume(returning: $0 == .authorized) }
        }
    }

    /// vom Audio-Faden: jeder Mikrofon-Puffer
    func fuettern(_ b: AVAudioPCMBuffer) {
        sperre.lock()
        if let a = anfrage { a.append(b) } else {
            vorlauf.append(b)
            if vorlauf.count > 6 { vorlauf.removeFirst() }
        }
        sperre.unlock()
    }

    /// Satz fängt an (Pegel erkannt): neue Erkennung, mit dem Vorlauf
    func beginnen() {
        guard bereit, let erkenner else { return }
        abbrechen()
        let a = SFSpeechAudioBufferRecognitionRequest()
        a.shouldReportPartialResults = true
        a.taskHint = .dictation
        if erkenner.supportsOnDeviceRecognition { a.requiresOnDeviceRecognition = true }
        if #available(iOS 16, *) { a.addsPunctuation = true }
        sperre.lock()
        for b in vorlauf { a.append(b) }
        vorlauf.removeAll()
        anfrage = a
        text = ""
        endgueltig = false
        sperre.unlock()
        aufgabe = erkenner.recognitionTask(with: a) { [weak self] erg, fehler in
            guard let self else { return }
            self.sperre.lock()
            if let erg { self.text = erg.bestTranscription.formattedString }
            let ende = (erg?.isFinal ?? false) || fehler != nil
            let t = self.text
            var k: CheckedContinuation<String, Never>?
            if ende { self.endgueltig = true; k = self.fertig; self.fertig = nil }
            self.sperre.unlock()
            if let teil = self.teil, !t.isEmpty { DispatchQueue.main.async { teil(t) } }
            k?.resume(returning: t)
        }
    }

    /// Satz zu Ende: Text holen (höchstens `warten` s auf das Endergebnis, sonst der letzte Zwischenstand)
    func beenden(warten: Double = 1.2) async -> String {
        sperre.lock()
        guard let a = anfrage else { sperre.unlock(); return "" }
        anfrage = nil
        if endgueltig { let t = text; sperre.unlock(); return t }
        sperre.unlock()
        a.endAudio()
        let t: String = await withCheckedContinuation { k in
            sperre.lock()
            if endgueltig { let t = text; sperre.unlock(); k.resume(returning: t); return }
            fertig = k
            sperre.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + warten) { [weak self] in
                guard let self else { return }
                self.sperre.lock()
                let w = self.fertig; self.fertig = nil
                let t = self.text
                self.sperre.unlock()
                w?.resume(returning: t)
            }
        }
        aufgabe = nil
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func abbrechen() {
        aufgabe?.cancel()
        aufgabe = nil
        sperre.lock()
        anfrage?.endAudio()
        anfrage = nil
        let k = fertig; fertig = nil
        sperre.unlock()
        k?.resume(returning: "")
    }
}
