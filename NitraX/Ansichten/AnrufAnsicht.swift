import SwiftUI

/// 📞 Laufendes Telefonat mit dem Helfer (wenn die App offen ist; gesperrt zeigt iOS die eigene Anruf-Ansicht)
@MainActor
struct AnrufAnsicht: View {
    @ObservedObject var dienst: AnrufDienst
    @State private var puls = false

    var body: some View {
        ZStack {
            Hintergrund()
            VStack(spacing: 18) {
                Spacer()
                ZStack {
                    Circle().stroke(Farbe.ring, lineWidth: 3).frame(width: 150, height: 150).scaleEffect(puls ? 1.12 : 1).opacity(puls ? 0.2 : 0.9)
                    Circle().fill(Farbe.panel).frame(width: 130, height: 130)
                    Image(systemName: "person.wave.2.fill").font(.system(size: 52)).foregroundStyle(Farbe.akzent)
                }
                .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { puls = true } }
                Text(dienst.anrufer).font(.title.bold())
                if let seit = dienst.seit {
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        let s = Int(t.date.timeIntervalSince(seit))
                        Text(String(format: "%d:%02d", s / 60, s % 60)).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 40) {
                    knopf(dienst.stumm ? "mic.slash.fill" : "mic.fill", "Stumm", an: dienst.stumm) { dienst.stummUmschalten() }
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
