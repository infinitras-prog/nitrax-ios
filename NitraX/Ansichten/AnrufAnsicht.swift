import SwiftUI

/// 📞 Laufendes Telefonat mit dem Helfer (wenn die App offen ist; gesperrt zeigt iOS die eigene Anruf-Ansicht)
@MainActor
struct AnrufAnsicht: View {
    @ObservedObject var dienst: AnrufDienst
    @State private var puls = false
    @State private var portrait = HelferPortrait.bild

    var body: some View {
        ZStack {
            Hintergrund()
            if dienst.video, let url = dienst.helferURL {
                // 📹 Videoanruf: Helfer im Vollbild, du klein oben rechts
                VideoHelferWeb(url: url) { w in dienst.videoWeb = w }
                    .ignoresSafeArea()
                    .transition(.opacity)
                VStack {
                    HStack {
                        Spacer()
                        ZStack(alignment: .bottomTrailing) {
                            KameraVorschau(sitzung: dienst.augen.sitzung)
                                .frame(width: 112, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color(red: 0.13, green: 0.83, blue: 0.93).opacity(0.3 + 0.7 * Double(min(1, dienst.pegel * 1.6))), lineWidth: 2))
                            Button { dienst.augen.drehen() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.footnote).padding(7)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .padding(6)
                        }
                        .padding(.trailing, 16).padding(.top, 8)
                    }
                    Spacer()
                }
            }
            VStack(spacing: 18) {
                Spacer()
                if !dienst.video {
                ZStack {
                    // 🎙 du sprichst: Kreis leuchtet türkis mit deinem Pegel · 🔊 der Helfer spricht: warm im Bernstein-Ton
                    let p = CGFloat(dienst.pegel)
                    let farbe = dienst.helferSpricht ? Farbe.akzent : Color(red: 0.13, green: 0.83, blue: 0.93)
                    let an = dienst.helferSpricht ? 0.75 : min(1, p * 1.6)
                    Circle().fill(farbe.opacity(0.35 * an)).frame(width: 190, height: 190).blur(radius: 28)
                        .scaleEffect(1 + 0.25 * an)
                    Circle().stroke(Farbe.ring, lineWidth: 3).frame(width: 150, height: 150).scaleEffect(puls ? 1.12 : 1).opacity(puls ? 0.2 : 0.9)
                    Circle().stroke(farbe, lineWidth: 4).frame(width: 140, height: 140)
                        .opacity(0.25 + 0.75 * an).shadow(color: farbe, radius: 6 + 18 * an).scaleEffect(1 + 0.08 * an)
                    Circle().fill(Farbe.panel).frame(width: 130, height: 130)
                    if let portrait {
                        // 🖼 dein Helfer im Kontaktkreis
                        Image(uiImage: portrait).resizable().scaledToFill().frame(width: 130, height: 130).clipShape(Circle())
                    } else {
                        Image(systemName: dienst.helferSpricht ? "waveform" : "person.wave.2.fill").font(.system(size: 52))
                            .foregroundStyle(Farbe.akzent).symbolEffect(.variableColor.iterative, isActive: dienst.helferSpricht)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: dienst.pegel)
                .animation(.easeInOut(duration: 0.3), value: dienst.helferSpricht)
                .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { puls = true } }
                }
                Text(dienst.anrufer).font(.title.bold()).shadow(radius: dienst.video ? 6 : 0)
                if dienst.verbindet {
                    Text("Klingelt …").font(.title3).foregroundStyle(.secondary)
                        .phaseAnimator([0.45, 1.0]) { t, o in t.opacity(o) } animation: { _ in .easeInOut(duration: 0.8) }
                }
                if let seit = dienst.seit {
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        let s = Int(t.date.timeIntervalSince(seit))
                        Text(String(format: "%d:%02d", s / 60, s % 60)).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // 〰 deine Stimme als Welle
                AnrufWelle(werte: dienst.welle, aktiv: !dienst.stumm)
                    .frame(height: 90)
                    .padding(.horizontal, 30)
                if !dienst.untertitel.isEmpty {
                    // 💬 Untertitel: was du sagst (live) bzw. was sie gerade sagt
                    Text(dienst.untertitel)
                        .font(.callout.weight(dienst.untertitelSie ? .regular : .semibold))
                        .foregroundStyle(dienst.untertitelSie ? Color.white : Color(red: 0.55, green: 0.9, blue: 0.97))
                        .multilineTextAlignment(.center).lineLimit(3)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 24)
                        .animation(.easeOut(duration: 0.15), value: dienst.untertitel)
                }
                Text(dienst.stumm ? "Stumm" : dienst.helferSpricht ? "\(dienst.anrufer) spricht …" : "Ich höre zu …")
                    .font(.footnote).foregroundStyle(.secondary)
                    .animation(.easeInOut, value: dienst.helferSpricht)
                Spacer()
                HStack(spacing: 28) {
                    knopf(dienst.stumm ? "mic.slash.fill" : "mic.fill", "Stumm", an: dienst.stumm) { dienst.stummUmschalten() }
                    knopf(dienst.video ? "video.fill" : "video", "Video", an: dienst.video) { withAnimation(.easeInOut(duration: 0.35)) { dienst.videoUmschalten() } }
                    knopf(dienst.lautsprecher ? "speaker.wave.3.fill" : "speaker.fill", "Lautsprecher", an: dienst.lautsprecher) { dienst.lautsprecherUmschalten() }
                }
                Button { dienst.auflegen() } label: {
                    Image(systemName: "phone.down.fill").font(.title).foregroundStyle(.white)
                        .frame(width: 76, height: 76).background(Farbe.fehler, in: Circle())
                }
                .padding(.top, 10).padding(.bottom, 50)
            }
        }
    }

    private func knopf(_ symbol: String, _ titel: String, an: Bool, _ tun: @escaping () -> Void) -> some View {
        Button(action: tun) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2).frame(width: 68, height: 68)
                    .background(an ? Color.white : Color.white.opacity(0.12), in: Circle())
                    .foregroundStyle(an ? Color.black : Color.white)
                Text(titel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(NXDruck())
    }
}


/// Wellenbalken: die letzten ~1,6 s deines Mikrofonpegels, gespiegelt um die Mitte
struct AnrufWelle: View {
    let werte: [Float]
    let aktiv: Bool

    var body: some View {
        GeometryReader { g in
            let n = max(1, werte.count)
            let breite = g.size.width / CGFloat(n)
            HStack(alignment: .center, spacing: breite * 0.35) {
                ForEach(0..<n, id: \.self) { i in
                    let w = i < werte.count ? werte[i] : 0
                    let h = max(4, CGFloat(aktiv ? w : 0) * g.size.height * 1.15)
                    Capsule()
                        .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.83, blue: 0.93), Color(red: 0.55, green: 0.36, blue: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: breite * 0.65, height: min(g.size.height, h))
                        .opacity(0.35 + 0.65 * Double(i) / Double(n))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.linear(duration: 0.05), value: werte)
    }
}
