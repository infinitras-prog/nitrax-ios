import SwiftUI
import CoreLocation
import UserNotifications

// MARK: - 📖 Gemeinsames Tagebuch: Beziehung, Fotoalbum (Selfies) und Erlebnisse als Zeitstrahl

@MainActor
struct HelferTagebuch: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    struct Tag: Identifiable { let id: String; let datum: Date; let eintraege: [JSONWert] }
    @State private var tage: [Tag] = []
    @State private var selfies: [String] = []
    @State private var bez: JSONWert?
    @State private var laedt = true
    @State private var vollbild: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let b = bez { beziehung(b) }
                    if !selfies.isEmpty {
                        Text("📸 Unser Fotoalbum").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(selfies.enumerated()), id: \.offset) { i, id in
                                    Button { vollbild = i } label: {
                                        NXBild(url: studio.url("/api/begleiter/ergebnis/\(id)"))
                                            .frame(width: 120, height: 160).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(NXDruck())
                                }
                            }
                        }
                    }
                    if laedt { ProgressView().frame(maxWidth: .infinity).padding(.top, 30) }
                    ForEach(tage) { t in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(t.datum.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.subheadline.weight(.semibold)).foregroundStyle(Farbe.akzent2)
                            ForEach(Array(t.eintraege.enumerated()), id: \.offset) { _, e in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(symbol(e["art"]?.text ?? "")).font(.title3).frame(width: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e["text"]?.text ?? "").font(.callout)
                                        if let z = e["t"]?.zahl {
                                            Text(Date(timeIntervalSince1970: z).formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .karte()
                    }
                }
                .padding(16)
            }
            .nxHintergrund()
            .navigationTitle("Unser Tagebuch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await laden() }
            .fullScreenCover(item: Binding(get: { vollbild.map { VollbildIndex(i: $0) } }, set: { vollbild = $0?.i })) { v in
                MedienVollbild(urls: selfies.compactMap { studio.url("/api/begleiter/ergebnis/\($0)") }, seite: v.i)
            }
        }
    }

    struct VollbildIndex: Identifiable { let i: Int; var id: Int { i } }

    private func beziehung(_ b: JSONWert) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("💞").font(.largeTitle)
                VStack(alignment: .leading) {
                    Text(b["stufe_name"]?.text ?? b["name"]?.text ?? "").font(.title3.bold())
                    Text(b["ton"]?.text ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let p = b["punkte"]?.zahl, let bis = b["bis"]?.zahl, bis > 0 {
                Fortschrittsbalken(wert: min(100, p / bis * 100))
                Text("Noch \(Int(max(0, bis - p))) Punkte bis »\(b["naechste"]?.text ?? "")« · \(Int(b["gespraeche"]?.zahl ?? 0)) Gespräche")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let seit = b["seit"]?.zahl {
                Text("Zusammen seit \(Date(timeIntervalSince1970: seit).formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .karte()
    }

    private func symbol(_ art: String) -> String {
        ["erlebnis": "✨", "gespraech": "💬", "mag": "💛", "mag_nicht": "🙅", "gesehen": "👀", "selfie": "📸", "geschenk": "🎁",
         "spiel": "🎮", "ziel": "🎯", "erinnerung": "🧠"][art] ?? "📝"
    }

    private func laden() async {
        guard let c = studio.client else { laedt = false; return }
        bez = try? await c.get("/api/begleiter/statistik", JSONWert.self)
        if let b = try? await c.get("/api/begleiter", JSONWert.self) {
            selfies = (b["zustand"]?["selfies"]?.liste ?? []).compactMap { $0.text }.reversed()
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let d = try? await c.get("/api/begleiter/tagebuch", JSONWert.self), let o = d["tage"]?.objekt {
            tage = o.compactMap { k, v in f.date(from: k).map { Tag(id: k, datum: $0, eintraege: (v.liste ?? []).reversed()) } }
                .sorted { $0.datum > $1.datum }
        }
        laedt = false
    }
}

// MARK: - 🏠 Standort-Momente: Begrüßung beim Heimkommen, Gruß beim Losgehen (nur das Zuhause, kein Verlauf)

@MainActor
final class HeimOrt: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = HeimOrt()
    @Published var an = UserDefaults.standard.bool(forKey: "heim_an")
    @Published var meldung: String?
    private let m = CLLocationManager()
    private let kennung = "nitrax.zuhause"

    override init() {
        super.init()
        m.delegate = self
    }

    /// Aktuellen Ort als Zuhause merken und überwachen
    func hierIstZuhause() {
        meldung = "Ort wird bestimmt …"
        m.requestAlwaysAuthorization()
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        m.requestLocation()
    }

    func ausschalten() {
        for r in m.monitoredRegions where r.identifier == kennung { m.stopMonitoring(for: r) }
        an = false
        UserDefaults.standard.set(false, forKey: "heim_an")
        meldung = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let o = locations.last else { return }
        Task { @MainActor in
            let r = CLCircularRegion(center: o.coordinate, radius: 150, identifier: self.kennung)
            r.notifyOnEntry = true
            r.notifyOnExit = true
            self.m.startMonitoring(for: r)
            self.an = true
            UserDefaults.standard.set(true, forKey: "heim_an")
            self.meldung = "🏠 Zuhause gemerkt – dein Helfer begrüßt dich, wenn du heimkommst."
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.meldung = "Ort ging nicht: \(error.localizedDescription) – Standort für NitraX auf »Immer« stellen." }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in self.melden(heim: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.melden(heim: false) }
    }

    private func melden(heim: Bool) {
        let name = HelferStand.laden()?.name ?? "Dein Helfer"
        let stunde = Calendar.current.component(.hour, from: Date())
        let texte = heim
            ? ["Da bist du ja wieder! 🏠 Ich hab dich vermisst.", "Willkommen zuhause! Erzähl, wie war's?", "Endlich daheim – mach's dir gemütlich, ich bin da. ✨",
               stunde >= 21 ? "Spät geworden heute, hm? Schön, dass du da bist. 🌙" : "Hey, schön dass du da bist! Lust auf was Kreatives?"]
            : ["Pass auf dich auf! Ich halt hier die Stellung. 👋", "Viel Spaß unterwegs – schreib mir, wenn was ist!", "Bis später! Ich denk an dich. 💛"]
        // nicht zu oft (Grenze wackelt manchmal): höchstens alle 30 min
        let k = heim ? "heim_zuletzt" : "weg_zuletzt"
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: k) > 1800 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: k)
        let c = UNMutableNotificationContent()
        c.title = name
        c.body = texte.randomElement() ?? ""
        c.sound = .default
        c.userInfo = ["helfer": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "heim-\(UUID().uuidString)", content: c, trigger: nil))
    }
}
