import SwiftUI
import LocalAuthentication

/// 🔒 Face ID: wer NitraX öffnet, muss sich ausweisen (Einstellung, aus = Standard). Sperrt beim Wechsel in den Hintergrund.
@MainActor
final class Sperre: ObservableObject {
    @AppStorage("faceid_an") var an = false
    @Published var gesperrt = false

    init() { gesperrt = an }

    func hintergrund() { if an { gesperrt = true } }

    func entsperren() async {
        guard gesperrt else { return }
        let ctx = LAContext()
        var fehler: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &fehler) else { gesperrt = false; return }
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "NitraX entsperren")) == true {
            gesperrt = false
        }
    }
}

struct SperrAnsicht: View {
    @ObservedObject var sperre: Sperre
    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.047, blue: 0.071).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "faceid").font(.system(size: 54)).foregroundStyle(Farbe.verlauf)
                Text("NitraX ist gesperrt").font(.headline)
                Button("Entsperren") { Task { await sperre.entsperren() } }.buttonStyle(.borderedProminent)
            }
        }
        .task { await sperre.entsperren() }
    }
}
