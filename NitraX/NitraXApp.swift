import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Benachrichtigungen.kategorienEinrichten()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.tokenErhalten(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push-Anmeldung bei Apple fehlgeschlagen: \(error.localizedDescription)")
    }

    // Mitteilung auch zeigen, wenn die App offen ist
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // Antippen: Auftrag bzw. Helfer öffnen
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // ⚡ Schnellaktion (Variante, Schärfen …) - ohne die App zu öffnen
        if let id = info["auftrag"] as? String, ["variante", "schaerfen", "groesser", "filmlook"].contains(response.actionIdentifier) {
            await Benachrichtigungen.aktion(response.actionIdentifier, auftrag: id)
            return
        }
        await MainActor.run {
            if let id = info["auftrag"] as? String { Navigation.shared.oeffne(auftrag: id) }
            else if info["helfer"] != nil {
                Navigation.shared.helferMeldung = (info["meldung"] as? Int) ?? (info["meldung"] as? NSNumber)?.intValue
                Navigation.shared.reiter = .helfer
            }
        }
    }
}

/// Reiter + Sprungziel (z. B. aus einer Mitteilung oder dem Widget)
@MainActor
final class Navigation: ObservableObject {
    static let shared = Navigation()
    enum Reiter: Hashable { case studio, erstellen, auftraege, chat, helfer }
    @Published var reiter: Reiter = .studio
    @Published var auftragZiel: String?
    /// Helfer-Meldung zum Vorlesen (Antippen einer Mitteilung: der Helfer sagt sie dir)
    @Published var helferMeldung: Int?
    /// »Sprich mit NitraX«: Helfer öffnen und sofort zuhören
    @Published var helferZuhoeren = false

    func oeffne(auftrag id: String) {
        reiter = .auftraege
        auftragZiel = id
    }
}

@main
struct NitraXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var studio = Studio()
    @StateObject private var navigation = Navigation.shared
    @StateObject private var sperre = Sperre()
    @State private var splash = true
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if studio.verbunden {
                    HauptAnsicht()
                } else {
                    VerbindenAnsicht()
                }
            }
            .overlay { if sperre.gesperrt { SperrAnsicht(sperre: sperre) } }
            .overlay {
                if splash {
                    SplashAnsicht { withAnimation(.easeOut(duration: 0.6)) { splash = false } }
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                        .zIndex(10)
                }
            }
            .environmentObject(studio)
            .environmentObject(navigation)
            .preferredColorScheme(.dark)
            .tint(Farbe.akzent)
            .onOpenURL { url in
                // nitrax://auftrag/<id> (Widget) oder ein QR-Link http(s)://…/?k=…
                if url.scheme == "nitrax", url.host == "auftrag" { navigation.oeffne(auftrag: url.lastPathComponent) }
                else if url.scheme == "nitrax", url.host == "helfer" {
                    navigation.reiter = .helfer
                    if url.query?.contains("hoeren=1") == true { navigation.helferZuhoeren = true }
                }
                else if let v = Verbindung.ausLink(url.absoluteString) { studio.verbinden(v) }
            }
        }
        .onChange(of: phase) { _, neu in
            switch neu {
            case .active:
                studio.starten()
                // 🎛 Kontrollzentrum / Sperrbildschirm: »Mit Helfer sprechen«
                let t = Gemeinsam.defaults.double(forKey: "helfer_oeffnen")
                if t > 0, Date().timeIntervalSince1970 - t < 30 {
                    Gemeinsam.defaults.removeObject(forKey: "helfer_oeffnen")
                    navigation.reiter = .helfer
                    navigation.helferZuhoeren = true
                }
                Benachrichtigungen.erlaubnisHolen()
            case .background:
                studio.anhalten()
                sperre.hintergrund()
                Benachrichtigungen.planen()
            default: break
            }
        }
        .backgroundTask(.appRefresh(Benachrichtigungen.aufgabe)) {
            await Benachrichtigungen.imHintergrund()
        }
    }
}
