import SwiftUI

/// 🎲 Runde 3, Nr. 5: mehrere Varianten auf einmal – nebeneinander vergleichen, die besten behalten (❤), Rest löschen
enum VergleichGruppen {
    struct Gruppe: Codable, Identifiable, Hashable { var id: String; var name: String; var ids: [String]; var t: Double }
    private static let schluessel = "vergleich_gruppen"

    static var alle: [Gruppe] {
        guard let d = Gemeinsam.defaults.data(forKey: schluessel), let g = try? JSONDecoder().decode([Gruppe].self, from: d) else { return [] }
        return g
    }

    static func speichern(_ g: [Gruppe]) {
        if let d = try? JSONEncoder().encode(Array(g.suffix(20))) { Gemeinsam.defaults.set(d, forKey: schluessel) }
    }

    static func neu(name: String, ids: [String]) {
        guard ids.count > 1 else { return }
        speichern(alle + [Gruppe(id: UUID().uuidString, name: name, ids: ids, t: Date().timeIntervalSince1970)])
    }

    static func weg(_ id: String) { speichern(alle.filter { $0.id != id }) }
}

/// Karten »4 Varianten fertig – vergleichen« oben in den Aufträgen
@MainActor
struct VergleichKarten: View {
    @EnvironmentObject private var studio: Studio
    @State private var gruppen = VergleichGruppen.alle

    var body: some View {
        ForEach(gruppen) { g in
            let auftraege = g.ids.compactMap { id in studio.stand.auftraege.first { $0.id == id } }
            let fertig = auftraege.filter(\.fertig).count
            if !auftraege.isEmpty {
                NavigationLink { VergleichAnsicht(ids: g.ids, gruppe: g.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2.fill").foregroundStyle(Farbe.akzent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("🎲 \(auftraege.count) Varianten · \(g.name)").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(fertig == auftraege.count ? "Alle fertig – jetzt vergleichen" : "\(fertig) von \(auftraege.count) fertig")
                                .font(.caption).foregroundStyle(fertig == auftraege.count ? Farbe.gut : .secondary)
                        }
                    }
                }
                .listRowBackground(Farbe.karte)
                .swipeActions { Button("Ausblenden") { VergleichGruppen.weg(g.id); gruppen = VergleichGruppen.alle } }
            }
        }
        .onAppear { gruppen = VergleichGruppen.alle }
    }
}

@MainActor
struct VergleichAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    var gruppe: String?
    @State private var behalten: Set<String> = []
    @State private var gross: Auftrag?
    @State private var frage = false
    @State private var arbeitet = false

    private var liste: [Auftrag] { ids.compactMap { id in studio.stand.auftraege.first { $0.id == id } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tippe an, was du behalten willst · lange drücken = groß ansehen").font(.footnote).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(liste) { a in
                        let an = behalten.contains(a.id)
                        ZStack {
                            if a.fertig { BibliothekKachel(a: a, gross: true) }
                            else {
                                RoundedRectangle(cornerRadius: 10).fill(Farbe.karte).aspectRatio(1, contentMode: .fit)
                                    .overlay { VStack(spacing: 6) { ProgressView(); Text("\(Int(a.progress)) %").font(.caption2) } }
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: an ? "heart.fill" : "heart").font(.title3).foregroundStyle(an ? .pink : .white)
                                .shadow(radius: 3).padding(8)
                        }
                        .overlay { if an { RoundedRectangle(cornerRadius: 10).stroke(.pink, lineWidth: 3) } }
                        .scaleEffect(an ? 0.97 : 1)
                        .animation(.snappy(duration: 0.2), value: an)
                        .onTapGesture {
                            guard a.fertig else { return }
                            if an { behalten.remove(a.id) } else { behalten.insert(a.id) }
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        .onLongPressGesture { if a.fertig { gross = a } }
                    }
                }
            }
            .padding(12)
            .padding(.bottom, 80)
        }
        .nxHintergrund()
        .navigationTitle("Vergleichen")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            HStack(spacing: 12) {
                Button("Alle behalten") { abschliessen() }.buttonStyle(.bordered)
                Button(role: .destructive) { frage = true } label: {
                    if arbeitet { ProgressView() } else { Text("\(behalten.count) behalten, Rest löschen") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(behalten.isEmpty || arbeitet || liste.contains { !$0.fertig && !$0.gescheitert })
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .confirmationDialog("\(liste.count - behalten.count) Varianten löschen? Sie landen am PC im Papierkorb. Behaltene werden Favoriten.",
                            isPresented: $frage, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { Task { await aufraeumen() } }
        }
        .fullScreenCover(item: $gross) { a in
            MedienVollbild(urls: (0..<max(1, a.bilderAnzahl)).compactMap { studio.url(a.bilderAnzahl > 0 ? "/api/img/file/\(a.id)/\($0)" : "/api/begleiter/ergebnis/\(a.id)") }, seite: 0)
        }
    }

    private func aufraeumen() async {
        guard let c = studio.client else { return }
        arbeitet = true
        defer { arbeitet = false }
        for a in liste {
            if behalten.contains(a.id) {
                if !a.fav { _ = try? await c.post("/api/jobs/\(a.id)/favorite") }
            } else {
                _ = try? await c.post("/api/jobs/\(a.id)/delete-files")
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        studio.meldung = "❤ \(behalten.count) behalten, Rest im Papierkorb"
        await studio.aktualisieren()
        abschliessen()
    }

    private func abschliessen() {
        if let gruppe { VergleichGruppen.weg(gruppe) }
        dismiss()
    }
}
