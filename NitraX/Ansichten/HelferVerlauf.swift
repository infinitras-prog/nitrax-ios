import SwiftUI

/// 🕘 Frühere Gespräche mit dem Helfer: ansehen und an einem alten Gespräch weiterreden
@MainActor
struct HelferVerlauf: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let neuLaden: () -> Void
    @State private var chats: [Eintrag] = []
    @State private var laedt = true
    @State private var aktiv: String?

    struct Eintrag: Identifiable, Hashable {
        let id: String
        let titel: String
        let geaendert: Date
        let anzahl: Int
        var notiz = ""                                  // 📝 Gesprächsnotiz (Telefonate)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Task { await wechseln(nil) } } label: {
                        Label("Neues Gespräch beginnen", systemImage: "plus.bubble.fill").foregroundStyle(Farbe.akzent)
                    }
                }
                Section("Frühere Gespräche") {
                    if laedt { ProgressView().frame(maxWidth: .infinity) }
                    if !laedt && chats.isEmpty { Text("Noch keine Gespräche").foregroundStyle(.secondary) }
                    ForEach(chats) { c in
                        NavigationLink { VerlaufDetail(eintrag: c, aktiv: c.id == aktiv) { Task { await wechseln(c.id) } } } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(c.geaendert.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                        .font(.subheadline.weight(.semibold))
                                    if c.id == aktiv { Text("aktuell").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Farbe.akzent.opacity(0.25), in: Capsule()) }
                                }
                                if c.titel.hasPrefix("📞") { Text(c.titel).font(.footnote.weight(.medium)).lineLimit(1) }
                                if !c.notiz.isEmpty { Text("📝 " + c.notiz).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                else { Text("\(c.anzahl) Nachrichten").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .nxHintergrund()
            .navigationTitle("Gesprächsverlauf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await laden() }
        }
    }

    private func laden() async {
        defer { laedt = false }
        guard let c = studio.client else { return }
        aktiv = try? await c.post("/api/begleiter/chat", [:])["id"]?.text
        guard let d = try? await c.roh("/api/chats"), let w = try? JSONDecoder().decode(JSONWert.self, from: d) else { return }
        chats = (w.liste ?? []).compactMap { x in
            guard x["art"]?.text == "begleiter", let id = x["id"]?.text else { return nil }
            let titel = x["titel"]?.text ?? ""
            if titel.hasPrefix("🧪") { return nil }                       // Testgespräche nicht zeigen
            let n = Int(x["n"]?.zahl ?? 0)
            guard n > 0 else { return nil }
            return Eintrag(id: id, titel: titel, geaendert: Date(timeIntervalSince1970: x["geaendert"]?.zahl ?? 0), anzahl: n,
                           notiz: x["notiz"]?.text ?? "")
        }
        .sorted { $0.geaendert > $1.geaendert }
    }

    private func wechseln(_ id: String?) async {
        guard let c = studio.client else { return }
        var body: [String: Any] = ["neu": true]
        if let id { body = ["id": id] }
        _ = try? await c.post("/api/begleiter/chat", body)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        studio.meldung = id == nil ? "Neues Gespräch – der Helfer fängt frisch an" : "Altes Gespräch wieder aufgenommen"
        neuLaden()
        dismiss()
    }
}

private struct VerlaufDetail: View {
    @EnvironmentObject private var studio: Studio
    let eintrag: HelferVerlauf.Eintrag
    let aktiv: Bool
    let weiter: () -> Void
    @State private var zeilen: [Zeile] = []
    @State private var notiz: (text: String, punkte: [String])?

    struct Zeile: Identifiable { let id: Int; let ich: Bool; let text: String }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let n = notiz {
                    // 📝 Gesprächsnotiz nach dem Telefonat
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Gesprächsnotiz", systemImage: "note.text").font(.subheadline.weight(.semibold)).foregroundStyle(Farbe.akzent)
                        Text(n.text).font(.callout)
                        ForEach(n.punkte, id: \.self) { p in Text("• " + p).font(.callout).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .karte()
                    .padding(.bottom, 6)
                }
                ForEach(zeilen) { z in
                    HStack {
                        if z.ich { Spacer(minLength: 40) }
                        Text(z.text).font(.callout).padding(10)
                            .background(z.ich ? AnyShapeStyle(Farbe.verlauf) : AnyShapeStyle(Farbe.karte), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                        if !z.ich { Spacer(minLength: 40) }
                    }
                }
            }
            .padding(16)
        }
        .nxHintergrund()
        .navigationTitle(eintrag.geaendert.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !aktiv {
                Button(action: weiter) { Label("Hier weiterreden", systemImage: "bubble.left.and.bubble.right.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(16)
            }
        }
        .task { await laden() }
    }

    private func laden() async {
        guard let c = studio.client, let d = try? await c.roh("/api/chats/\(eintrag.id)"),
              let w = try? JSONDecoder().decode(JSONWert.self, from: d) else { return }
        var i = 0
        if let n = w["notiz"], let t = n["text"]?.text, !t.isEmpty {
            notiz = (t, (n["punkte"]?.liste ?? []).compactMap(\.text))
        }
        zeilen = (w["nachrichten"]?.liste ?? []).compactMap { n in
            let rolle = n["rolle"]?.text ?? ""
            guard rolle == "user" || rolle == "assistant" else { return nil }
            var t = n["text"]?.text ?? ""
            // Lage-/Seh-Zusätze der App und Gefühls-Tags ausblenden
            while t.hasPrefix("("), let e = t.firstIndex(of: ")") { t = String(t[t.index(after: e)...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            t = t.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            i += 1
            return Zeile(id: i, ich: rolle == "user", text: t)
        }
    }
}
