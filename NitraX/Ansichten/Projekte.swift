import SwiftUI

/// 📁 Gesamtplan 5a: Projekt-Mappen – alles eines Vorhabens zusammen (Song, Film, Varianten, Notiz). Mehrteilige Aufträge des
/// Helfers bekommen ihre Mappe automatisch; ist eine Mappe »aktiv«, landen neue Aufträge darin (PC, Handy, Helfer).
struct ProjektInfo: Identifiable, Hashable {
    let id: String
    var name: String
    var notiz: String
    var erstellt: Double
    var vomHelfer: Bool
}

@MainActor
struct ProjekteAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var liste: [ProjektInfo] = []
    @State private var aktiv: String?
    @State private var neu = false
    @State private var name = ""

    var body: some View {
        List {
            if liste.isEmpty {
                Text("Noch keine Projekte. Mehrteilige Aufträge deines Helfers (»erst Song, dann Film …«) bekommen ihre Mappe automatisch – oder lege selbst eine an.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(liste.sorted { $0.erstellt > $1.erstellt }) { p in
                let jobs = studio.stand.auftraege.filter { $0.projekt == p.id }
                NavigationLink { ProjektMappe(projekt: p, aktiv: aktiv == p.id, neuLaden: { Task { await laden() } }) } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Farbe.karte)
                            if let a = jobs.first(where: { studio.vorschauURL($0) != nil }) { NXBild(url: studio.vorschauURL(a)) }
                            else { Image(systemName: "folder.fill").foregroundStyle(Farbe.akzent) }
                        }
                        .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if aktiv == p.id { Text("aktiv").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Farbe.akzent.opacity(0.25), in: Capsule()) }
                                if p.vomHelfer { Image(systemName: "person.wave.2.fill").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text("\(jobs.count) Ergebnis\(jobs.count == 1 ? "" : "se")" + (jobs.contains { $0.offen } ? " · läuft noch" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Farbe.karte)
            }
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle("📁 Projekte")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { neu = true } label: { Image(systemName: "folder.badge.plus") } } }
        .alert("Neues Projekt", isPresented: $neu) {
            TextField("Name", text: $name)
            Button("Anlegen") { Task { await anlegen() } }
            Button("Abbrechen", role: .cancel) { name = "" }
        } message: { Text("Es wird aktiv – neue Aufträge landen darin, bis du es wieder abschaltest.") }
        .task { await laden() }
        .refreshable { await laden() }
    }

    private func laden() async {
        guard let c = studio.client, let w = try? await c.get("/api/projekte", JSONWert.self) else { return }
        aktiv = w["aktiv"]?.text
        liste = (w["liste"]?.liste ?? []).compactMap { p in
            guard let id = p["id"]?.text else { return nil }
            return ProjektInfo(id: id, name: p["name"]?.text ?? "Projekt", notiz: p["notiz"]?.text ?? "", erstellt: p["erstellt"]?.zahl ?? 0,
                               vomHelfer: p["quelle"]?.text == "helfer")
        }
    }

    private func anlegen() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        name = ""
        guard !n.isEmpty, let c = studio.client else { return }
        _ = try? await c.post("/api/projekte", ["aktion": "neu", "name": n])
        studio.meldung = "📁 »\(n)« ist aktiv – neue Aufträge landen darin"
        await laden()
    }
}

@MainActor
struct ProjektMappe: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let projekt: ProjektInfo
    let aktiv: Bool
    let neuLaden: () -> Void
    @State private var notiz = ""
    @State private var istAktiv = false
    @State private var umbenennen = false
    @State private var neuerName = ""
    @State private var loeschen = false

    private var jobs: [Auftrag] { studio.stand.auftraege.filter { $0.projekt == projekt.id }.sorted { $0.created > $1.created } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: Binding(get: { istAktiv }, set: { an in Task { await aktivSetzen(an) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aktives Projekt").font(.subheadline.weight(.semibold))
                        Text("Neue Aufträge (PC, Handy, Helfer) landen automatisch hier").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .karte()
                VStack(alignment: .leading, spacing: 6) {
                    Text("📝 Notiz").font(.subheadline.weight(.semibold))
                    TextField("Worum geht es in diesem Projekt?", text: $notiz, axis: .vertical).lineLimit(2...8)
                        .onSubmit { Task { await notizSpeichern() } }
                    if notiz != projekt.notiz { Button("Notiz speichern") { Task { await notizSpeichern() } }.font(.caption) }
                }
                .karte()
                Text("\(jobs.count) Ergebnis\(jobs.count == 1 ? "" : "se")").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(jobs) { a in
                        NavigationLink(value: a) {
                            BibliothekKachel(a: a).overlay(alignment: .bottomTrailing) {
                                if a.offen { ProgressView().padding(6) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
        .nxHintergrund()
        .navigationTitle(projekt.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { neuerName = projekt.name; umbenennen = true } label: { Label("Umbenennen", systemImage: "pencil") }
                    Button(role: .destructive) { loeschen = true } label: { Label("Projekt auflösen", systemImage: "folder.badge.minus") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Umbenennen", isPresented: $umbenennen) {
            TextField("Name", text: $neuerName)
            Button("Speichern") { Task { await aendern(["aktion": "umbenennen", "id": projekt.id, "name": neuerName]) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Projekt auflösen? Die Ergebnisse bleiben erhalten, sie sind dann nur »ohne Projekt«.", isPresented: $loeschen, titleVisibility: .visible) {
            Button("Auflösen", role: .destructive) { Task { await aendern(["aktion": "loeschen", "id": projekt.id]); dismiss() } }
        }
        .onAppear { notiz = projekt.notiz; istAktiv = aktiv }
    }

    private func aendern(_ body: [String: Any]) async {
        guard let c = studio.client else { return }
        do { _ = try await c.post("/api/projekte", body); neuLaden(); await studio.aktualisieren() }
        catch { studio.meldung = error.localizedDescription }
    }

    private func aktivSetzen(_ an: Bool) async {
        istAktiv = an
        await aendern(["aktion": "aktiv", "id": an ? projekt.id : ""])
        studio.meldung = an ? "📁 Neue Aufträge landen in »\(projekt.name)«" : "Kein aktives Projekt mehr"
    }

    private func notizSpeichern() async {
        await aendern(["aktion": "notiz", "id": projekt.id, "notiz": notiz])
        studio.meldung = "📝 Notiz gespeichert"
    }
}

/// Im Auftrag: einem Projekt zuordnen
@MainActor
struct ProjektZuordnen: View {
    @EnvironmentObject private var studio: Studio
    let auftrag: Auftrag
    @State private var liste: [(String, String)] = []

    var body: some View {
        Menu {
            ForEach(liste.indices, id: \.self) { i in
                Button { Task { await setzen(liste[i].0) } } label: {
                    Label(liste[i].1, systemImage: auftrag.projekt == liste[i].0 ? "checkmark" : "folder")
                }
            }
            if auftrag.projekt != nil {
                Button(role: .destructive) { Task { await setzen("") } } label: { Label("Aus dem Projekt nehmen", systemImage: "folder.badge.minus") }
            }
        } label: {
            Label(liste.first { $0.0 == auftrag.projekt }.map { "📁 " + $0.1 } ?? "📁 Zu Projekt", systemImage: "folder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large)
        .task {
            guard let c = studio.client, let w = try? await c.get("/api/projekte", JSONWert.self) else { return }
            liste = (w["liste"]?.liste ?? []).compactMap { p in p["id"]?.text.map { ($0, p["name"]?.text ?? "Projekt") } }
        }
    }

    private func setzen(_ pid: String) async {
        guard let c = studio.client else { return }
        do {
            _ = try await c.post("/api/jobs/\(auftrag.id)/projekt", ["projekt": pid.isEmpty ? NSNull() as Any : pid as Any])
            studio.meldung = pid.isEmpty ? "Aus dem Projekt genommen" : "📁 Zugeordnet"
            await studio.aktualisieren()
        } catch { studio.meldung = error.localizedDescription }
    }
}
