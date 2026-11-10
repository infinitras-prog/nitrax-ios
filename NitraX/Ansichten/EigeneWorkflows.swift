import SwiftUI
import UniformTypeIdentifiers

/// 🧩 Eigene Workflows (Masterplan C13, 10.11.2026): im Code-Agenten gebaute Workflows teilen (Datei, z. B. per AirDrop an einen
/// anderen NitraX-Nutzer), importieren (*.nxerw oder ComfyUI-Workflow *.json), ein-/ausschalten und deinstallieren.
/// Bauen und ändern macht der Code-Agent (Chat → Code) – hier wird nur verwaltet.
struct EigenerWorkflowEintrag: Identifiable, Hashable {
    let id: String
    var name: String
    var beschreibung: String
    var symbol: String
    var aktiv: Bool
    var status: String
    var istWorkflow: Bool
    var probelaufOK: Bool?

    init(_ w: JSONWert) {
        id = w["id"]?.text ?? ""
        name = w["name"]?.text ?? id
        beschreibung = w["beschreibung"]?.text ?? ""
        symbol = w["symbol"]?.text ?? "🧩"
        aktiv = w["aktiv"]?.wahr ?? false
        status = w["status"]?.text ?? "aus"
        istWorkflow = w["workflow"]?.wahr ?? false
        probelaufOK = w["probelauf"]?["ok"]?.wahr
    }

    var statusText: String {
        switch status { case "läuft": return "bereit"; case "schläft": return "schläft"; case "fehler": return "Fehler"; default: return "aus" }
    }
}

@MainActor
struct EigeneWorkflowsAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var liste: [EigenerWorkflowEintrag] = []
    @State private var laedt = true
    @State private var importieren = false
    @State private var arbeitet: String?
    @State private var teilen: [URL] = []
    @State private var loeschen: EigenerWorkflowEintrag?

    var body: some View {
        List {
            Section {
                Text("Eigene Workflows baut der Code-Agent (Chat → Code: »Bau mir …«). Hier teilst du sie als Datei, importierst Workflows von anderen oder ComfyUI-Workflows (API-Format) und schaltest sie ein oder aus.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            if !laedt && liste.isEmpty {
                Text("Noch keine eigenen Workflows.").foregroundStyle(.secondary).listRowBackground(Farbe.karte)
            }
            ForEach(liste) { e in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text(e.symbol).font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.subheadline.weight(.semibold))
                            Text(e.beschreibung).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(e.statusText).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                            .background((e.status == "läuft" ? Farbe.gut : e.status == "fehler" ? Farbe.fehler : Color.secondary).opacity(0.18), in: Capsule())
                    }
                    if let ok = e.probelaufOK {
                        Text(ok ? "✅ Probelauf bestanden" : "❌ Probelauf fehlgeschlagen").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button { Task { await exportieren(e) } } label: {
                            Label(arbeitet == e.id ? "…" : "Teilen", systemImage: "square.and.arrow.up").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        Button { Task { await schalten(e) } } label: {
                            Label(e.aktiv ? "Aus" : "Ein", systemImage: e.aktiv ? "pause.circle" : "checkmark.shield").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button(role: .destructive) { loeschen = e } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                    }
                    .disabled(arbeitet != nil)
                }
                .padding(.vertical, 4)
                .listRowBackground(Farbe.karte)
            }
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle("🧩 Eigene Workflows")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { importieren = true } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
            }
        }
        .fileImporter(isPresented: $importieren, allowedContentTypes: [.json, .zip, .data], allowsMultipleSelection: false) { erg in
            if case .success(let urls) = erg, let u = urls.first { Task { await importierenDatei(u) } }
        }
        .sheet(isPresented: Binding(get: { !teilen.isEmpty }, set: { if !$0 { teilen = [] } })) {
            TeilenBlatt(dateien: teilen).presentationDetents([.medium, .large])
        }
        .confirmationDialog("»\(loeschen?.name ?? "")« deinstallieren? Er landet im Papierkorb der Erweiterungen am PC und lässt sich zurückholen.",
                            isPresented: Binding(get: { loeschen != nil }, set: { if !$0 { loeschen = nil } }), titleVisibility: .visible) {
            Button("Deinstallieren", role: .destructive) { if let e = loeschen { Task { await aktion(["aktion": "loeschen", "id": e.id]) } } }
        }
        .task { await laden() }
        .refreshable { await laden() }
    }

    private func laden() async {
        guard let c = studio.client else { return }
        if let w = try? await c.get("/api/erweiterungen", JSONWert.self) {
            liste = (w["liste"]?.liste ?? []).map(EigenerWorkflowEintrag.init)
        }
        laedt = false
    }

    private func aktion(_ body: [String: Any]) async {
        guard let c = studio.client else { return }
        do {
            let r = try await c.post("/api/erweiterungen", body, zeit: 180)
            if let l = r["liste"]?.liste { liste = l.map(EigenerWorkflowEintrag.init) }
            await studio.workflowsLaden(neu: true)
        } catch { studio.meldung = error.localizedDescription }
    }

    private func schalten(_ e: EigenerWorkflowEintrag) async {
        guard let c = studio.client else { return }
        arbeitet = e.id
        defer { arbeitet = nil }
        do {
            let r = try await c.post("/api/erweiterungen", ["aktion": e.aktiv ? "deaktivieren" : "aktivieren", "id": e.id], zeit: 180)
            if let l = r["liste"]?.liste { liste = l.map(EigenerWorkflowEintrag.init) }
            if !e.aktiv {
                if !(r["erlauben_noetig"]?.liste ?? []).isEmpty { studio.meldung = "Dieser Workflow braucht deine Erlaubnis – bitte am PC im Store einschalten" }
                else if r["aktiv"]?.wahr == true { studio.meldung = "✓ \(e.name) ist eingeschaltet" }
                else { studio.meldung = "Einschalten ging nicht: " + (r["pruefung"]?["fehler"]?.text ?? "Prüfung nicht bestanden") }
            }
            await studio.workflowsLaden(neu: true)
        } catch { studio.meldung = error.localizedDescription }
    }

    private func exportieren(_ e: EigenerWorkflowEintrag) async {
        guard let c = studio.client else { return }
        arbeitet = e.id
        defer { arbeitet = nil }
        do {
            let name = e.name.replacingOccurrences(of: "/", with: "-") + ".nxerw"
            let u = try await Herunterladen.datei(c, pfad: "/api/erweiterungen/export?id=" + e.id, name: name)
            teilen = [u]
        } catch { studio.meldung = error.localizedDescription }
    }

    private func importierenDatei(_ u: URL) async {
        guard let c = studio.client else { return }
        let zugriff = u.startAccessingSecurityScopedResource()
        defer { if zugriff { u.stopAccessingSecurityScopedResource() } }
        guard let daten = try? Data(contentsOf: u) else { studio.meldung = "Datei lässt sich nicht lesen"; return }
        let comfy = u.pathExtension.lowercased() == "json"
        do {
            let r = try await c.hochladen(comfy ? "/api/erweiterungen/comfy_import" : "/api/erweiterungen/import", daten: daten,
                                          dateiname: u.lastPathComponent, typ: comfy ? "application/json" : "application/zip")
            let name = r["name"]?.text ?? u.lastPathComponent
            let fehlt = (r["fehlt_knoten"]?.liste ?? []).count + (r["fehlt_modelle"]?.liste ?? []).count
            studio.meldung = fehlt > 0 ? "»\(name)« importiert – es fehlen noch \(fehlt) Teile (Details im Store am PC)"
                : "✓ »\(name)« importiert – zum Benutzen »Ein« tippen"
            if let l = r["liste"]?.liste { liste = l.map(EigenerWorkflowEintrag.init) }
        } catch { studio.meldung = error.localizedDescription }
    }
}
