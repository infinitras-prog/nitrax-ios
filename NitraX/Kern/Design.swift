import SwiftUI

/// NitraX-Look: tiefes Nachtblau, violettes Licht (wie das Hauptmenü am PC)
enum Farbe {
    static let akzent = Color(red: 0.49, green: 0.55, blue: 1.0)
    static let akzent2 = Color(red: 0.78, green: 0.42, blue: 1.0)
    static let grund = Color(red: 0.043, green: 0.047, blue: 0.071)
    static let karte = Color.white.opacity(0.06)
    static let rand = Color.white.opacity(0.09)
    static let gut = Color(red: 0.36, green: 0.85, blue: 0.6)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.3)
    static let fehler = Color(red: 1.0, green: 0.42, blue: 0.47)
    static let verlauf = LinearGradient(colors: [akzent, akzent2], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Aurora: langsam wanderndes Violett-Licht (wie das Hauptmenü am PC). Rechnet etwas, pulsiert es sanft;
/// »Bewegung reduzieren« in iOS hält es still.
struct Hintergrund: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.accessibilityReduceMotion) private var ruhig

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: ruhig)) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            let puls: Double = studio.stand.auftraege.contains(where: { $0.laeuft }) ? 0.06 * sin(s * 1.6) : 0
            ZStack {
                Farbe.grund
                RadialGradient(colors: [Farbe.akzent.opacity(0.26 + puls), .clear],
                               center: UnitPoint(x: 0.2 + 0.15 * sin(s / 9), y: 0.1 + 0.08 * cos(s / 11)), startRadius: 10, endRadius: 460)
                RadialGradient(colors: [Farbe.akzent2.opacity(0.18 + puls), .clear],
                               center: UnitPoint(x: 0.85 + 0.1 * cos(s / 13), y: 0.85 + 0.1 * sin(s / 10)), startRadius: 10, endRadius: 420)
                RadialGradient(colors: [Color(red: 0.2, green: 0.8, blue: 0.9).opacity(0.07), .clear],
                               center: UnitPoint(x: 0.5 + 0.3 * sin(s / 17), y: 0.5), startRadius: 10, endRadius: 360)
            }
        }
        .ignoresSafeArea()
    }
}

struct KarteStil: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Farbe.karte))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Farbe.rand, lineWidth: 1))
    }
}

extension View {
    func karte() -> some View { modifier(KarteStil()) }
    func nxHintergrund() -> some View { background(Hintergrund()) }
}

struct Fortschrittsbalken: View {
    var wert: Double          // 0-100
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Farbe.verlauf).frame(width: max(6, g.size.width * min(1, max(0, wert / 100))))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: wert)
    }
}

struct StatusPunkt: View {
    var a: Auftrag
    var body: some View {
        Circle().fill(farbe).frame(width: 8, height: 8)
    }
    var farbe: Color {
        if a.laeuft { return Farbe.akzent }
        if a.wartet { return Farbe.warn }
        if a.fertig { return Farbe.gut }
        return Farbe.fehler
    }
}

/// Kurztext zum Stand eines Auftrags
func standText(_ a: Auftrag) -> String {
    switch a.status {
    case "läuft": return "\(Int(a.progress)) % · \(a.stage)" + (a.eta.map { " · noch \(Zeit.dauer($0))" } ?? "")
    case "wartet": return "wartet" + (a.eta.map { " · ≈ \(Zeit.dauer($0))" } ?? "")
    case "angehalten": return "angehalten (Warteschlange pausiert)"
    case "fertig": return "fertig" + (a.elapsed.map { " in \(Zeit.dauer($0))" } ?? "")
    case "abgebrochen": return a.fortsetzbar ? "abgebrochen · \(a.clipsFertig)/\(a.clipsGesamt) Stücke fertig" : "abgebrochen"
    default: return a.fehler ?? a.status
    }
}
