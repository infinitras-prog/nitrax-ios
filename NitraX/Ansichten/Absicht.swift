import SwiftUI

/// ✨ »Sag einfach, was du willst« (13.11.2026): ein Satz – getippt oder gesprochen – und die Regie am PC wählt den passenden
/// Workflow und füllt ihn vor. Danach öffnet sich das fertige Formular; man prüft nur noch und startet.
@MainActor
struct AbsichtKarte: View {
    @EnvironmentObject private var studio: Studio
    @State private var text = ""
    @State private var laeuft = false
    @State private var fehler: String?
    @State private var ziel: Ziel?
    @FocusState private var fokus: Bool
    struct Ziel: Identifiable, Hashable { let id = UUID(); let workflow: Workflow; let werte: [String: JSONWert]; let satz: String }

    private let beispiele = ["Mach aus meinem letzten Bild ein 10-Sekunden-Video mit Regen und Kamerafahrt",
                             "Ein Anime-Mädchen mit roten Haaren im Kirschblütenregen, 16:9",
                             "Ein ruhiger Lo-Fi-Song zum Lernen, instrumental, 2 Minuten",
                             "Verlängere mein letztes Video um 5 Sekunden und lass es als Loop enden"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.title3).foregroundStyle(Farbe.akzent)
                Text("Sag einfach, was du willst").font(.headline)
                Spacer()
            }
            HStack(alignment: .top, spacing: 8) {
                TextField("z. B. »" + beispiele[0] + "«", text: $text, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($fokus)
                    .submitLabel(.go)
                    .onSubmit { Task { await los() } }
                DiktierKnopf(text: $text)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(beispiele.dropFirst(), id: \.self) { b in
                        Button { text = b } label: { Text(b).font(.caption).lineLimit(1) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                }
            }
            Button {
                Task { await los() }
            } label: {
                HStack {
                    Spacer()
                    if laeuft { ProgressView().tint(.white); Text("Regie plant …").font(.subheadline.weight(.semibold)) }
                    else { Label("Vorbereiten", systemImage: "wand.and.stars").font(.subheadline.weight(.semibold)) }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Farbe.verlauf))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(laeuft || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
            if let fehler { Text(fehler).font(.footnote).foregroundStyle(Farbe.fehler) }
            Text("Die Regie wählt den Workflow und füllt alles vor – gestartet wird erst, wenn du es bestätigst.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .karte()
        .navigationDestination(item: $ziel) { z in
            WorkflowFormular(workflow: z.workflow, vorbelegung: z.werte)
                .safeAreaInset(edge: .top) {
                    if !z.satz.isEmpty {
                        Label(z.satz, systemImage: "sparkles").font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial)
                    }
                }
        }
    }

    private func los() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4, let c = studio.client, !laeuft else { return }
        fokus = false
        laeuft = true
        fehler = nil
        defer { laeuft = false }
        do {
            let r = try await c.post("/api/handy/absicht", ["text": t], zeit: 180)
            guard let wf = r["wf"]?.text, let w = studio.workflows?.workflows.first(where: { $0.id == wf }) else {
                fehler = "Dieser Workflow ist auf dem PC gerade nicht verfügbar."; return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ziel = Ziel(workflow: w, werte: r["felder"]?.objekt ?? [:], satz: r["satz"]?.text ?? "")
        } catch {
            fehler = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
