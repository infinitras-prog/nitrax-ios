import Foundation

/// 👋 Vorrat an Sätzen in IHRER Stimme auf dem iPhone (Begrüßungen, »Mhm, Moment.«): Beim Abheben spielt die Begrüßung sofort –
/// egal, ob die Stimme am PC gerade schläft oder lädt. Wird im Hintergrund aufgefüllt (Helfer-Tab bereit, nach Anrufen).
enum Stimmvorrat {
    /// Begrüßungen, wenn DU anrufst
    static let gruesse = ["Hey, schön, dass du anrufst! Was gibt's?", "Hi! Na, was kann ich für dich tun?",
                          "Hallo du! Schön, dich zu hören.", "Hey! Ich hab grad an dich gedacht."]
    static let fueller = ["Mhm, Moment.", "Mhm, lass mich kurz überlegen."]
    static var alle: [String] { gruesse + fueller }

    private static let ordner: URL = {
        let o = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NitraX-Stimme", isDirectory: true)
        try? FileManager.default.createDirectory(at: o, withIntermediateDirectories: true)
        return o
    }()

    /// stabiler Schlüssel (FNV-1a) aus Stimme + Text
    private static func schluessel(_ text: String, _ stimme: String?) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in ((stimme ?? "") + "|" + text).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    static func daten(_ text: String, _ stimme: String?) -> Data? {
        try? Data(contentsOf: ordner.appendingPathComponent(schluessel(text, stimme) + ".wav"))
    }

    static func merken(_ d: Data, _ text: String, _ stimme: String?) {
        guard alle.contains(text) else { return }
        try? d.write(to: ordner.appendingPathComponent(schluessel(text, stimme) + ".wav"), options: .atomic)
    }

    private static var laeuft = false

    /// fehlende Sätze vom PC holen (schnelle Stimme, ganzer Satz -> WAV)
    @MainActor
    static func auffuellen(_ c: NXClient) async {
        guard !laeuft, !AnrufDienst.shared.imGespraech else { return }
        laeuft = true
        defer { laeuft = false }
        if let b = try? await c.get("/api/begleiter", JSONWert.self) {
            if let st = b["einst"]?["stimme"]?.text { Gemeinsam.defaults.set(st, forKey: "helfer_stimme") }
            if let m = b["einst"]?["modell"]?.text { Gemeinsam.defaults.set(m, forKey: "helfer_modell") }
            if let n = b["einst"]?["name"]?.text, !n.isEmpty { Gemeinsam.defaults.set(n, forKey: "helfer_name") }
        }
        let stimme = Gemeinsam.defaults.string(forKey: "helfer_stimme")
        for satz in alle where daten(satz, stimme) == nil {
            guard !AnrufDienst.shared.imGespraech else { return }
            var body: [String: Any] = ["text": satz, "sprache": "de"]
            if let stimme, !stimme.isEmpty { body["stimme"] = stimme }
            guard let url = c.url("/api/anruf/sprechen_strom"), let daten = try? JSONSerialization.data(withJSONObject: body) else { return }
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.httpBody = daten
            r.timeoutInterval = 60
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (k, w) in c.cookieKopf { r.setValue(w, forHTTPHeaderField: k) }
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, d.count > 2004 else { return }
            let rate = d.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard rate >= 8000 && rate <= 96000 else { return }
            merken(AnrufGespraech.wav(pcm: d.dropFirst(4), rate: rate), satz, stimme)
        }
    }
}
