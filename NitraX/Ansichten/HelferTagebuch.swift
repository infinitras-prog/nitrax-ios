import SwiftUI

// MARK: - 📖 Gemeinsames Tagebuch: Beziehung, Fotoalbum (Selfies) und Erlebnisse als Zeitstrahl

@MainActor
struct HelferTagebuch: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    struct Tag: Identifiable { let id: String; let datum: Date; let eintraege: [JSONWert] }
    @State private var tage: [Tag] = []
    @State private var selfies: [String] = []
    @State private var bez: JSONWert?
    @State private var laedt = true
    @State private var vollbild: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let b = bez { beziehung(b) }
                    if !selfies.isEmpty {
                        Text("📸 Unser Fotoalbum").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(selfies.enumerated()), id: \.offset) { i, id in
                                    Button { vollbild = i } label: {
                                        NXBild(url: studio.url("/api/begleiter/ergebnis/\(id)"))
                                            .frame(width: 120, height: 160).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(NXDruck())
                                }
                            }
                        }
                    }
                    if laedt { ProgressView().frame(maxWidth: .infinity).padding(.top, 30) }
                    ForEach(tage) { t in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(t.datum.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.subheadline.weight(.semibold)).foregroundStyle(Farbe.akzent2)
                            ForEach(Array(t.eintraege.enumerated()), id: \.offset) { _, e in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(symbol(e["art"]?.text ?? "")).font(.title3).frame(width: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e["text"]?.text ?? "").font(.callout)
                                        if let z = e["t"]?.zahl {
                                            Text(Date(timeIntervalSince1970: z).formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .karte()
                    }
                }
                .padding(16)
            }
            .nxHintergrund()
            .navigationTitle("Unser Tagebuch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await laden() }
            .fullScreenCover(item: Binding(get: { vollbild.map { VollbildIndex(i: $0) } }, set: { vollbild = $0?.i })) { v in
                MedienVollbild(urls: selfies.compactMap { studio.url("/api/begleiter/ergebnis/\($0)") }, seite: v.i)
            }
        }
    }

    struct VollbildIndex: Identifiable { let i: Int; var id: Int { i } }

    private func beziehung(_ b: JSONWert) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("💞").font(.largeTitle)
                VStack(alignment: .leading) {
                    Text(b["stufe_name"]?.text ?? b["name"]?.text ?? "").font(.title3.bold())
                    Text(b["ton"]?.text ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let p = b["punkte"]?.zahl, let bis = b["bis"]?.zahl, bis > 0 {
                Fortschrittsbalken(wert: min(100, p / bis * 100))
                Text("Noch \(Int(max(0, bis - p))) Punkte bis »\(b["naechste"]?.text ?? "")« · \(Int(b["gespraeche"]?.zahl ?? 0)) Gespräche")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let seit = b["seit"]?.zahl {
                Text("Zusammen seit \(Date(timeIntervalSince1970: seit).formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .karte()
    }

    private func symbol(_ art: String) -> String {
        ["erlebnis": "✨", "gespraech": "💬", "mag": "💛", "mag_nicht": "🙅", "gesehen": "👀", "selfie": "📸", "geschenk": "🎁",
         "spiel": "🎮", "ziel": "🎯", "erinnerung": "🧠"][art] ?? "📝"
    }

    private func laden() async {
        guard let c = studio.client else { laedt = false; return }
        bez = try? await c.get("/api/begleiter/statistik", JSONWert.self)
        if let b = try? await c.get("/api/begleiter", JSONWert.self) {
            selfies = (b["zustand"]?["selfies"]?.liste ?? []).compactMap { $0.text }.reversed()
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let d = try? await c.get("/api/begleiter/tagebuch", JSONWert.self), let o = d["tage"]?.objekt {
            tage = o.compactMap { k, v in f.date(from: k).map { Tag(id: k, datum: $0, eintraege: (v.liste ?? []).reversed()) } }
                .sorted { $0.datum > $1.datum }
        }
        laedt = false
    }
}
