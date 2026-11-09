import SwiftUI

/// 👗 Runde 2, Nr. 13: Aussehen des Helfers am iPhone – Outfits und Frisuren aus deiner Sammlung (NitraX Store am PC)
/// anziehen (wird wie am PC gespeichert), ↩ zurück, und der Hintergrund hinter ihr im Helfer-Tab.
@MainActor
struct HelferAussehen: View {
    @EnvironmentObject private var studio: Studio
    @ObservedObject var bruecke: HelferBruecke
    @Environment(\.dismiss) private var dismiss
    @AppStorage("helfer_hintergrund") private var hintergrund = ""
    @State private var teile: [Teil] = []
    @State private var laedt = true
    @State private var vorher = false
    @State private var alt = false                // PC-Programm kennt das noch nicht
    @State private var zieht: String?

    struct Teil: Identifiable { let id: String; let name: String; let art: String; let farben: [Color] }

    private let spalten = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("🎨 Hintergrund").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            hgKachel("", "Standard")
                            ForEach(VideoHintergrund.alle.indices, id: \.self) { i in hgKachel(VideoHintergrund.alle[i].0, VideoHintergrund.alle[i].1) }
                        }
                    }
                    if laedt {
                        ProgressView("Garderobe wird geladen …").frame(maxWidth: .infinity).padding(.top, 20)
                    } else if alt {
                        Label("Das PC-Programm ist älter als die App – bitte NitraX am PC aktualisieren, dann geht Umziehen auch hier.",
                              systemImage: "desktopcomputer").font(.footnote).foregroundStyle(Farbe.warn)
                    } else {
                        if vorher {
                            Button { Task { await zurueck() } } label: { Label("Vorheriges Aussehen", systemImage: "arrow.uturn.backward") }
                                .buttonStyle(.bordered)
                        }
                        abschnitt("👗 Outfits", teile.filter { $0.art == "outfit" })
                        abschnitt("💇 Frisuren", teile.filter { $0.art == "frisur" })
                        if teile.isEmpty {
                            Text("Noch nichts in deiner Sammlung. Outfits und Frisuren holst du am PC: NitraX Store → 🧍 KI-Helfer.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Neue Outfits und Frisuren holst du am PC im NitraX Store (🧍 KI-Helfer). Gespeichert wird wie am PC – sie trägt es überall.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .nxHintergrund()
            .navigationTitle("Aussehen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await laden() }
        }
    }

    @ViewBuilder private func abschnitt(_ titel: String, _ liste: [Teil]) -> some View {
        if !liste.isEmpty {
            Text(titel).font(.headline)
            LazyVGrid(columns: spalten, spacing: 10) {
                ForEach(liste) { t in
                    Button { Task { await anziehen(t) } } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(LinearGradient(colors: verlauf(t), startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(height: 64)
                                if zieht == t.id { ProgressView().tint(.white) }
                                else { Text(t.art == "outfit" ? "👗" : "💇").font(.title) }
                            }
                            Text(t.name).font(.caption.weight(.medium)).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        }
                        .padding(8)
                        .background(Farbe.karte, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(NXDruck())
                    .disabled(zieht != nil)
                }
            }
        }
    }

    private func verlauf(_ t: Teil) -> [Color] {
        if t.farben.isEmpty { return [Farbe.akzent.opacity(0.4), Farbe.karte] }
        if t.farben.count == 1 { return [t.farben[0], t.farben[0].opacity(0.5)] }
        return t.farben
    }

    private func hgKachel(_ id: String, _ name: String) -> some View {
        let an = hintergrund == id
        return Button {
            withAnimation(.easeInOut(duration: 0.35)) { hintergrund = id }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 6) {
                Group {
                    if id.isEmpty { Hintergrund() } else { VideoHintergrund.ansicht(id) }
                }
                .frame(width: 70, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(an ? Farbe.akzent : .white.opacity(0.15), lineWidth: an ? 3 : 1))
                Text(name).font(.caption2).lineLimit(1).foregroundStyle(an ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func laden() async {
        defer { laedt = false }
        for _ in 0..<40 where !bruecke.bereit { try? await Task.sleep(for: .milliseconds(250)) }
        guard let d = await bruecke.garderobe() else { alt = true; return }
        vorher = d["vorher"] as? Bool ?? false
        teile = (d["teile"] as? [[String: Any]] ?? []).compactMap { t in
            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            return Teil(id: id, name: name, art: t["art"] as? String ?? "outfit", farben: (t["farben"] as? [String] ?? []).compactMap(Self.farbe))
        }
    }

    private func anziehen(_ t: Teil) async {
        zieht = t.id
        defer { zieht = nil }
        if await bruecke.anziehen(t.id) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            vorher = true
            HelferPortrait.holen(aus: bruecke.web)                     // 🖼 neues Bild für den Anrufkreis
            studio.meldung = "👗 \(t.name) – steht ihr!"
        } else {
            studio.meldung = "Umziehen ging gerade nicht – ist der Helfer geladen?"
        }
    }

    private func zurueck() async {
        if await bruecke.zurueck() {
            vorher = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            try? await Task.sleep(for: .seconds(1.5))
            HelferPortrait.holen(aus: bruecke.web)
        }
    }

    /// »#rrggbb« -> Farbe
    static func farbe(_ hex: String) -> Color? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
