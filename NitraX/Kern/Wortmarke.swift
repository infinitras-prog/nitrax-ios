import SwiftUI

/// ✨ Animiertes NitraX-Logo wie am PC (hauptmenue.js): »Nitra« weiß mit wanderndem Glanz, das X zeichnet sich als
/// Neon-Strich (Cyan → Pink → Violett) selbst und flackert alle paar Sekunden kurz wie eine Leuchtröhre.
struct NXWortmarke: View {
    var hoehe: CGFloat = 46
    var untertitel = true
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var strichA: CGFloat = 0
    @State private var strichB: CGFloat = 0
    @State private var glanz = false
    @State private var flackern = 1.0

    private let xVerlauf = LinearGradient(colors: [Color(red: 0.13, green: 0.83, blue: 0.93), Color(red: 1, green: 0.24, blue: 0.94),
                                                    Color(red: 0.55, green: 0.36, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(alignment: .leading, spacing: hoehe * 0.06) {
            HStack(alignment: .lastTextBaseline, spacing: hoehe * 0.04) {
                wort
                kreuz.alignmentGuide(.lastTextBaseline) { d in d[.bottom] }
            }
            if untertitel {
                Text("NEURAL CREATIVE STUDIO")
                    .font(.system(size: max(9, hoehe * 0.2), weight: .semibold))
                    .kerning(hoehe * 0.075)
                    .foregroundStyle(Color(red: 0.67, green: 0.69, blue: 0.9))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("NitraX – Neural Creative Studio")
        .onAppear(perform: starten)
        .task { if !ruhig { await flackernLassen() } }          // endet von selbst, wenn das Logo verschwindet
    }

    private var schrift: some View {
        Text("Nitra").font(.system(size: hoehe, weight: .heavy)).kerning(-hoehe * 0.026)
    }

    private var wort: some View {
        schrift
            .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.79, green: 0.8, blue: 1)], startPoint: .top, endPoint: .bottom))
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: hoehe * 0.8)
                        .rotationEffect(.degrees(20))
                        .offset(x: glanz ? g.size.width + hoehe : -hoehe * 1.6)
                        .opacity(ruhig ? 0 : 1)
                }
                .mask(schrift)
            }
            .shadow(color: Color(red: 0.55, green: 0.36, blue: 1).opacity(0.35), radius: hoehe * 0.18)
    }

    private var kreuz: some View {
        let breite = hoehe * 0.74, hoch = hoehe * 0.68, dicke = hoehe * 0.165
        let stil = StrokeStyle(lineWidth: dicke, lineCap: .round)
        let striche = ZStack {
            Diagonale(fallend: true).trim(from: 0, to: strichA).stroke(xVerlauf, style: stil)
            Diagonale(fallend: false).trim(from: 0, to: strichB).stroke(xVerlauf, style: stil)
        }
        return ZStack {
            striche.blur(radius: hoehe * 0.16).opacity(0.9)          // Neon-Schein
            striche.blur(radius: hoehe * 0.05)
            striche
        }
        .frame(width: breite, height: hoch)
        .padding(.leading, dicke * 0.3)
        .opacity(flackern)
    }

    private func starten() {
        if ruhig { strichA = 1; strichB = 1; return }
        withAnimation(.timingCurve(0.6, 0, 0.2, 1, duration: 1.8)) { strichA = 1 }
        withAnimation(.timingCurve(0.6, 0, 0.2, 1, duration: 1.8).delay(0.3)) { strichB = 1 }
        withAnimation(.easeInOut(duration: 2.75).delay(1.2).repeatForever(autoreverses: false)) { glanz = true }
    }

    /// Leuchtröhren-Flackern wie hmFlackern (alle 8 s)
    private func flackernLassen() async {
        try? await Task.sleep(for: .seconds(2.2))
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(7.4))
            for (wert, ms) in [(0.5, 80), (1.0, 120), (0.7, 70), (1.0, 0)] {
                withAnimation(.linear(duration: 0.05)) { flackern = wert }
                if ms > 0 { try? await Task.sleep(for: .milliseconds(ms)) }
            }
        }
    }
}

private struct Diagonale: Shape {
    let fallend: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if fallend { p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) }
        else { p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)) }
        return p
    }
}
