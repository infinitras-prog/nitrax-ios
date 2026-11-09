import SwiftUI

/// 🔐 Runde 3, Nr. 4: welche Geräte greifen zu, einzelne sperren, Schlüssel erneuern (alle anderen müssen neu scannen –
/// dieses iPhone bekommt den neuen Schlüssel direkt)
@MainActor
struct GeraeteAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var geraete: [JSONWert] = []
    @State private var laedt = true
    @State private var neuFrage = false
    @State private var fehler: String?

    var body: some View {
        List {
            Section {
                if laedt { ProgressView().frame(maxWidth: .infinity) }
                ForEach(geraete.indices, id: \.self) { i in
                    let g = geraete[i]
                    let gesperrt = g["gesperrt"]?.wahr ?? false, dieses = g["dieses"]?.wahr ?? false
                    HStack(spacing: 12) {
                        Image(systemName: gesperrt ? "lock.fill" : (dieses ? "iphone.gen3" : "iphone"))
                            .foregroundStyle(gesperrt ? Farbe.fehler : (dieses ? Farbe.gut : .secondary)).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((g["name"]?.text ?? "Gerät") + (dieses ? " · dieses" : "")).font(.subheadline.weight(.semibold))
                            Text(unterzeile(g)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if !dieses, let id = g["id"]?.text {
                            Button(gesperrt ? "Entsperren" : "Sperren", role: gesperrt ? nil : .destructive) { Task { await sperren(id, an: !gesperrt) } }
                        }
                    }
                }
            } header: { Text("Geräte mit der NitraX-App") } footer: {
                Text("Wischen zum Sperren. Browser und die Android-App erscheinen hier nicht – die sperrst du mit »Schlüssel erneuern«.")
            }
            .listRowBackground(Farbe.karte)
            Section {
                Button(role: .destructive) { neuFrage = true } label: { Label("Schlüssel erneuern", systemImage: "key.fill") }
                if let fehler { Text(fehler).font(.footnote).foregroundStyle(Farbe.fehler) }
            } footer: {
                Text("Z. B. wenn ein Handy verloren ging: Danach kommt nur noch dieses iPhone rein – alle anderen müssen den QR-Code am PC neu scannen.")
            }
            .listRowBackground(Farbe.karte)
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle("Geräte & Schlüssel")
        .navigationBarTitleDisplayMode(.inline)
        .task { await laden() }
        .refreshable { await laden() }
        .confirmationDialog("Neuen Schlüssel erzeugen? Alle anderen Geräte (auch Browser und Android) müssen dann den QR-Code neu scannen.",
                            isPresented: $neuFrage, titleVisibility: .visible) {
            Button("Schlüssel erneuern", role: .destructive) { Task { await erneuern() } }
        }
    }

    private func unterzeile(_ g: JSONWert) -> String {
        var t: [String] = []
        if let z = g["t"]?.zahl { t.append("zuletzt " + Date(timeIntervalSince1970: z).formatted(.relative(presentation: .named))) }
        if let ip = g["ip"]?.text, !ip.isEmpty { t.append(ip) }
        if g["gesperrt"]?.wahr == true { t.append("gesperrt") }
        return t.joined(separator: " · ")
    }

    private func laden() async {
        defer { laedt = false }
        guard let c = studio.client else { return }
        do { geraete = try await c.get("/api/handy/geraete", JSONWert.self)["geraete"]?.liste ?? [] }
        catch { fehler = error.localizedDescription }
    }

    private func sperren(_ id: String, an: Bool) async {
        guard let c = studio.client else { return }
        do {
            geraete = try await c.post("/api/handy/geraete/sperren", ["id": id, "an": an])["geraete"]?.liste ?? geraete
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { fehler = error.localizedDescription }
    }

    private func erneuern() async {
        guard let c = studio.client else { return }
        do {
            let r = try await c.post("/api/handy/schluessel_neu")
            guard let k = r["schluessel"]?.text, !k.isEmpty else { throw NXFehler.antwort }
            studio.schluesselSetzen(k)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            studio.meldung = "🔐 Neuer Schlüssel – andere Geräte müssen neu scannen"
            await laden()
        } catch { fehler = error.localizedDescription }
    }
}
