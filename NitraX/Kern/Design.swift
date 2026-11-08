import SwiftUI

/// NitraX-Look wie das Hauptprogramm am PC (studio.css + fx.css): Nachtgrau, Bernstein-Akzent, Regenbogen-Lichtring am Logo,
/// treibende Aurora, Karten mit Glanzkante und Einblenden, glühende laufende Aufträge, schimmernder Fortschritt.
enum Farbe {
    static let akzent = Color(red: 0.91, green: 0.64, blue: 0.24)        // #e8a33d
    static let akzent2 = Color(red: 0.95, green: 0.75, blue: 0.41)       // #f3c069
    static let pink = Color(red: 1.0, green: 0.44, blue: 0.75)           // #ff6fbf
    static let mint = Color(red: 0.44, green: 0.94, blue: 0.85)          // #6ff0d8
    static let limette = Color(red: 0.78, green: 0.97, blue: 0.42)       // #c6f76a
    static let info = Color(red: 0.42, green: 0.66, blue: 1.0)           // #6aa8ff
    static let grund = Color(red: 0.051, green: 0.059, blue: 0.075)      // #0d0f13
    static let panel = Color(red: 0.082, green: 0.094, blue: 0.129)      // #151821
    static let panel2 = Color(red: 0.106, green: 0.122, blue: 0.165)     // #1b1f2a
    static let karte = panel.opacity(0.82)
    static let rand = Color(red: 0.149, green: 0.169, blue: 0.22)        // #262b38
    static let gut = Color(red: 0.30, green: 0.76, blue: 0.54)           // #4cc38a
    static let warn = akzent
    static let fehler = Color(red: 0.90, green: 0.39, blue: 0.42)        // #e5636b
    static let verlauf = LinearGradient(colors: [akzent, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ring = AngularGradient(colors: [akzent, pink, mint, limette, akzent], center: .center)
}

/// Aurora: drei große, langsam treibende Lichtflecken (Bernstein, Pink, Mint) - wie hinter den Werkstätten am PC.
/// Rechnet etwas, atmet sie etwas heller. »Bewegung reduzieren« hält sie still.
struct Hintergrund: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.accessibilityReduceMotion) private var ruhig

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: ruhig)) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            let puls: Double = studio.stand.auftraege.contains(where: { $0.laeuft }) ? 0.05 * (1 + sin(s * 1.4)) : 0
            GeometryReader { g in
                let m = max(g.size.width, g.size.height)
                ZStack {
                    Farbe.grund
                    fleck(Farbe.akzent, 0.20 + puls, m * 0.75)
                        .offset(x: -g.size.width * 0.35 + g.size.width * 0.25 * sin(s / 19), y: -g.size.height * 0.32 + g.size.height * 0.12 * cos(s / 23))
                    fleck(Farbe.pink, 0.15 + puls, m * 0.7)
                        .offset(x: g.size.width * 0.4 - g.size.width * 0.22 * sin(s / 23), y: g.size.height * 0.36 - g.size.height * 0.1 * cos(s / 17))
                    fleck(Farbe.mint, 0.07, m * 0.5)
                        .offset(x: g.size.width * 0.2 * sin(s / 27), y: g.size.height * 0.05 + g.size.height * 0.18 * cos(s / 29))
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .ignoresSafeArea()
    }

    private func fleck(_ c: Color, _ staerke: Double, _ d: CGFloat) -> some View {
        Circle().fill(RadialGradient(colors: [c.opacity(staerke), .clear], center: .center, startRadius: 0, endRadius: d / 2))
            .frame(width: d, height: d)
            .blur(radius: 30)
    }
}

/// Karte wie am PC: Panel, feine Linie, Glanz an der Oberkante, weiches Einblenden (fxIn)
struct KarteStil: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var da = false

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Farbe.karte)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center)))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Farbe.rand, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            .opacity(da || ruhig ? 1 : 0)
            .offset(y: da || ruhig ? 0 : 14)
            .blur(radius: da || ruhig ? 0 : 3)
            .onAppear { withAnimation(.spring(duration: 0.55, bounce: 0.18)) { da = true } }
    }
}

/// Laufende Aufträge glühen in Bernstein (fxRunGlow), fertige leuchten kurz grün auf (fxDone)
struct LaufGlut: ViewModifier {
    var an: Bool
    var fertigBlitz = false
    @State private var phase = false
    func body(content: Content) -> some View {
        content
            .shadow(color: (an ? Farbe.akzent : Farbe.gut).opacity(an ? (phase ? 0.55 : 0.15) : (fertigBlitz && phase ? 0.6 : 0)), radius: phase ? 16 : 6)
            .onAppear { if an || fertigBlitz { withAnimation(.easeInOut(duration: 1.3).wiederholt(an)) { phase = true } } }
            .onChange(of: an) { _, neu in phase = false; if neu { withAnimation(.easeInOut(duration: 1.3).repeatForever()) { phase = true } } }
    }
}

private extension Animation {
    func wiederholt(_ immer: Bool) -> Animation { immer ? repeatForever() : self }
}

/// Knopfdruck wie am PC (fxRipple/Pop): leicht eindrücken, Lichtkante
struct NXDruck: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

extension View {
    func karte() -> some View { modifier(KarteStil()) }
    func nxHintergrund() -> some View { background(Hintergrund()) }
    func laufGlut(_ an: Bool, fertig: Bool = false) -> some View { modifier(LaufGlut(an: an, fertigBlitz: fertig)) }
}

/// Logo mit kreisendem Regenbogen-Lichtrand (wie oben links am PC)
struct NXLogo: View {
    @Environment(\.accessibilityReduceMotion) private var ruhig
    var groesse: CGFloat = 30
    @State private var winkel = 0.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: groesse * 0.32, style: .continuous)
                .fill(Farbe.ring).rotationEffect(.degrees(winkel)).mask(RoundedRectangle(cornerRadius: groesse * 0.34, style: .continuous).padding(-2))
                .frame(width: groesse + 4, height: groesse + 4)
                .blur(radius: 0.5)
            RoundedRectangle(cornerRadius: groesse * 0.3, style: .continuous).fill(Farbe.akzent)
                .frame(width: groesse, height: groesse)
                .shadow(color: Farbe.akzent.opacity(0.6), radius: 9)
            Image(systemName: "infinity").font(.system(size: groesse * 0.5, weight: .heavy)).foregroundStyle(Color(red: 0.1, green: 0.07, blue: 0.02))
        }
        .onAppear { if !ruhig { withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { winkel = 360 } } }
    }
}

/// Fortschritt: Bernstein → Pink mit wanderndem Schimmer (fxShimmer)
struct Fortschrittsbalken: View {
    var wert: Double          // 0-100
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var schimmer = false

    var body: some View {
        GeometryReader { g in
            let b = max(6, g.size.width * min(1, max(0, wert / 100)))
            ZStack(alignment: .leading) {
                Capsule().fill(Farbe.rand)
                Capsule().fill(Farbe.verlauf).frame(width: b)
                    .overlay(
                        LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 40).offset(x: schimmer ? b : -40)
                            .opacity(ruhig ? 0 : 1), alignment: .leading)
                    .clipShape(Capsule())
                    .shadow(color: Farbe.akzent.opacity(0.5), radius: 4)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: wert)
        .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { schimmer = true } }
    }
}

/// Statuspunkt: läuft = pulsierender Bernstein (fxPulse), wartet = gelb, fertig = grün, Fehler = rot
struct StatusPunkt: View {
    var a: Auftrag
    @State private var puls = false
    var body: some View {
        Circle().fill(farbe).frame(width: 8, height: 8)
            .overlay(Circle().stroke(farbe.opacity(puls ? 0 : 0.5), lineWidth: puls ? 7 : 0).scaleEffect(puls ? 1.8 : 1))
            .onAppear { if a.laeuft { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { puls = true } } }
    }
    var farbe: Color {
        if a.laeuft { return Farbe.akzent }
        if a.wartet { return Farbe.info }
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
