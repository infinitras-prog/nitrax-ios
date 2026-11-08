import SwiftUI

/// 🧠 Sprachmodelle vom PC: Liste der Chat-Modelle, Haupt-Sprachmodell, Prompt-Helfer.
enum ModellListe {
    struct Modell: Hashable, Identifiable {
        let id: String
        let name: String
        var sieht = false
        var denkt = false
        var zeile: String { name + (sieht ? " · 👁" : "") + (denkt ? " · 💭" : "") }
    }

    static func chat(_ c: NXClient) async -> [Modell] {
        guard let d = try? await c.get("/api/chat/modelle", JSONWert.self) else { return [] }
        return (d["modelle"]?.liste ?? []).compactMap { m in
            guard let n = m["name"]?.text else { return nil }
            return Modell(id: n, name: m["label"]?.text ?? n, sieht: m["vision"]?.wahr ?? false, denkt: m["denkt"]?.wahr ?? false)
        }
    }
}

/// Einstellungs-Abschnitt »Sprachmodelle« (Haupt-Sprachmodell der App + Prompt-Helfer)
@MainActor
struct ModellAbschnitt: View {
    @EnvironmentObject private var studio: Studio
    @State private var liste: [String] = []
    @State private var regie = ""
    @State private var wirklich = ""
    @State private var helferListe: [[String]] = []
    @State private var helferWahl = ""
    @State private var geladen = false

    var body: some View {
        Section {
            if !geladen {
                HStack { Text("Lade Modelle …").foregroundStyle(.secondary); Spacer(); ProgressView() }
            } else {
                Picker("Sprachmodell der App", selection: Binding(get: { regie.isEmpty ? wirklich : regie }, set: { neu in Task { await setzen(neu) } })) {
                    ForEach(liste, id: \.self) { Text($0).tag($0) }
                }
                if !helferListe.isEmpty {
                    Picker("🪄 Prompt-Helfer", selection: Binding(get: { helferWahl }, set: { neu in Task { await helferSetzen(neu) } })) {
                        ForEach(helferListe, id: \.self) { m in Text(m[1]).tag(m[0]) }
                    }
                }
            }
        } header: { Text("Sprachmodelle") } footer: {
            Text("Das Sprachmodell der App plant die Workflows (Agent, Regie, Autoprompt). Chat-Modelle wählst du im Chat oben rechts, das Modell des Helfers unter »Helfer anpassen«.")
        }
        .task { await laden() }
    }

    private func laden() async {
        guard let c = studio.client else { return }
        if let d = try? await c.get("/api/handy/modell", JSONWert.self) {
            liste = (d["liste"]?.liste ?? []).compactMap { $0.text }
            regie = d["regie"]?.text ?? ""
            wirklich = d["wirklich"]?.text ?? ""
            if !wirklich.isEmpty && !liste.contains(wirklich) { liste.insert(wirklich, at: 0) }
        }
        if let h = try? await c.get("/api/prompt/helfer/modelle", JSONWert.self) {
            helferListe = (h["modelle"]?.liste ?? []).compactMap { m in
                guard let id = m["id"]?.text, let l = m["label"]?.text else { return nil }
                return [id, l]
            }
            helferWahl = h["wahl"]?.text ?? ""
        }
        geladen = true
    }

    private func setzen(_ m: String) async {
        guard let c = studio.client else { return }
        do {
            let d = try await c.post("/api/handy/modell", ["regie": m])
            regie = d["regie"]?.text ?? m
            wirklich = d["wirklich"]?.text ?? m
            studio.meldung = "🧠 Sprachmodell: \(wirklich)"
        } catch { studio.meldung = error.localizedDescription }
    }

    private func helferSetzen(_ id: String) async {
        guard let c = studio.client else { return }
        do {
            _ = try await c.post("/api/prompt/helfer/modell", ["id": id])
            helferWahl = id
            studio.meldung = "🪄 Prompt-Helfer: \(helferListe.first { $0[0] == id }?[1] ?? id)"
        } catch { studio.meldung = error.localizedDescription }
    }
}
