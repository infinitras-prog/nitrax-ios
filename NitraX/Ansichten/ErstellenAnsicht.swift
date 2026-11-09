import SwiftUI

@MainActor
struct ErstellenAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var kategorie = "video"

    private var liste: [Workflow] { (studio.workflows?.workflows ?? []).filter { $0.kat == kategorie } }
    private var kategorien: [[String]] {
        let k = studio.workflows?.kategorien ?? []
        return k.isEmpty ? [["video", "Video", "🎬"], ["bild", "Bild", "🎨"], ["audio", "Audio", "🎵"]] : k
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    FotoStartKarte()                                         // 📷 aufnehmen, zuschneiden, Workflow wählen
                    VorlagenLeiste()
                    FavoritenVorlagen()                                      // ❤ eigene Lieblingsergebnisse als Vorlage
                    Picker("Kategorie", selection: $kategorie) {
                        ForEach(kategorien, id: \.self) { k in Text((k.count > 2 ? k[2] + " " : "") + (k.count > 1 ? k[1] : k[0])).tag(k[0]) }
                    }
                    .pickerStyle(.segmented)

                    if kategorie == "video" {
                        NavigationLink { StoryboardListe() } label: {
                            HStack(spacing: 12) {
                                Text("🎞").font(.system(size: 26)).frame(width: 44, height: 44).background(Circle().fill(Farbe.akzent.opacity(0.16)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Storyboard-Editor").font(.subheadline.weight(.semibold))
                                    Text("Kurzfilm Szene für Szene planen – Ort, Handlung, Dialog, Kamera, Figuren").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .karte()
                        }
                        .buttonStyle(.plain)
                    }

                    if studio.workflows == nil {
                        ProgressView("Workflows werden geladen …").padding(.top, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(liste) { w in
                            NavigationLink { WorkflowFormular(workflow: w) } label: { WorkflowKachel(w: w) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .nxHintergrund()
            .navigationTitle("Erstellen")
            .refreshable { await studio.workflowsLaden(neu: true) }
            .task { await studio.workflowsLaden() }
        }
    }
}

@MainActor
struct WorkflowKachel: View {
    var w: Workflow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(w.glyph).font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Farbe.akzent.opacity(0.16)))
            Text(w.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            Text(w.text).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .karte()
    }
}

/// Formular eines Workflows - Felder kommen vom PC (handy_wf.py), Start über /api/handy/start
@MainActor
struct WorkflowFormular: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    @Environment(\.dismiss) private var dismiss
    let workflow: Workflow
    var vorbelegung: [String: JSONWert] = [:]
    @State private var werte: [String: JSONWert] = [:]
    @State private var startet = false
    @State private var startZeit = Date()
    @State private var fehler: String?
    @ObservedObject private var uploads = UploadStand.shared

    var body: some View {
        Form {
            Section {
                Text(workflow.text).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(workflow.felder) { f in
                Section {
                    FeldEditor(feld: f, workflow: workflow, wert: Binding(get: { werte[f.name] }, set: { werte[f.name] = $0 }), alle: werte)
                } header: {
                    if f.art != "schalter" { Text(f.label + (f.pflicht ? " *" : "")) }
                }
            }
            Section {
                SchaetzungZeile(wf: workflow.id, laenge: ["laenge", "sekunden", "dauer"].lazy.compactMap { werte[$0]?.zahl }.first)   // ⏱
                Button {
                    Task { await starten() }
                } label: {
                    HStack {
                        Spacer()
                        if startet {
                            HStack(spacing: 10) {
                                ProgressView().tint(.white)
                                TimelineView(.periodic(from: .now, by: 1)) { t in
                                    Text(statusText(Int(t.date.timeIntervalSince(startZeit))))
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                }
                            }
                        } else { Label("Starten", systemImage: "sparkles").font(.headline) }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Farbe.verlauf)
                .foregroundStyle(.white)
                .disabled(startet)
                if let fehler { Text(fehler).font(.footnote).foregroundStyle(Farbe.fehler) }
            }
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle(workflow.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vorbelegen() }
        .onChange(of: werte) { _, w in entwurfSichern(w) }
        .toolbar {
            if entwurfDa {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { entwurfVerwerfen() } label: { Label("Entwurf verwerfen", systemImage: "arrow.counterclockwise") }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// »Bitte warten …« mit dem, was gerade passiert
    private func statusText(_ sek: Int) -> String {
        if uploads.laeuft > 0 {
            if let p = uploads.prozent, p < 0.999 { return "Bitte warten – Hochladen \(Int(p * 100)) %" }
            return "Bitte warten – Datei wird verarbeitet …"
        }
        if sek < 3 { return "Bitte warten – wird an den PC übergeben …" }
        if sek < 20 { return "Bitte warten – PC bereitet vor … \(sek) s" }
        return "Bitte warten – PC plant den Auftrag (KI) … \(sek) s"
    }

    /// 📝 Entwurf: alles, was du eingegeben hast (auch Texte und Medien), bleibt – auch wenn die App beendet wird
    @State private var entwurfDa = false
    private var entwurfSchluessel: String { "entwurf-\(workflow.id)" }

    private func entwurfSichern(_ w: [String: JSONWert]) {
        guard vorbelegung.isEmpty else { return }
        if w.values.allSatisfy({ $0.istLeer }) { Gemeinsam.defaults.removeObject(forKey: entwurfSchluessel); return }
        if let d = try? JSONEncoder().encode(w) { Gemeinsam.defaults.set(d, forKey: entwurfSchluessel) }
    }

    private func entwurfVerwerfen() {
        Gemeinsam.defaults.removeObject(forKey: entwurfSchluessel)
        entwurfDa = false
        werte = [:]
        vorbelegen()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func vorbelegen() {
        if vorbelegung.isEmpty, werte.isEmpty, let d = Gemeinsam.defaults.data(forKey: entwurfSchluessel),
           let w = try? JSONDecoder().decode([String: JSONWert].self, from: d), !w.isEmpty {
            werte = w
            entwurfDa = true
            return
        }
        let gemerkt = Gemeinsam.defaults.dictionary(forKey: "formular-\(workflow.id)") as? [String: Data] ?? [:]
        for f in workflow.felder where werte[f.name] == nil {
            if let d = gemerkt[f.name], let w = try? JSONDecoder().decode(JSONWert.self, from: d),
               ["wahl", "schalter", "zahl", "stimme", "bildmodell"].contains(f.art) {
                werte[f.name] = w                                   // Einstellungen vom letzten Mal (nicht Texte/Medien)
            } else if let w = f.wert {
                werte[f.name] = w
            }
        }
        for (k, v) in vorbelegung { werte[k] = v }          // z. B. »▶ Animieren« aus einem fertigen Bild
    }

    private func merken() {
        var m: [String: Data] = [:]
        for (k, v) in werte { if let d = try? JSONEncoder().encode(v) { m[k] = d } }
        Gemeinsam.defaults.set(m, forKey: "formular-\(workflow.id)")
    }

    private func starten() async {
        fehler = nil
        for f in workflow.felder where f.pflicht && (werte[f.name]?.istLeer ?? true) {
            fehler = "Bitte »\(f.label)« ausfüllen"
            return
        }
        guard let c = studio.client else { return }
        startet = true
        startZeit = Date()
        defer { startet = false }
        // ⏳ erst warten, bis Bilder/Videos/Audio fertig beim PC sind
        while uploads.laeuft > 0 { try? await Task.sleep(for: .milliseconds(200)) }
        do {
            var felder: [String: Any] = [:]
            for (k, v) in werte { felder[k] = v.alsAny }
            let r = try await c.post("/api/handy/start", ["wf": workflow.id, "felder": felder], zeit: 900)
            merken()
            Gemeinsam.defaults.removeObject(forKey: entwurfSchluessel)          // gestartet -> Entwurf erledigt
            let text = r["meldung"]?.text?.components(separatedBy: "\n").first ?? "Gestartet"
            studio.meldung = "✓ " + String(text.prefix(120))
            await studio.aktualisieren()
            navigation.reiter = .auftraege
            dismiss()
        } catch NXFehler.keineVerbindung {
            // 📮 PC nicht erreichbar: merken, startet von selbst, sobald er wieder da ist
            var felder: [String: Any] = [:]
            for (k, v) in werte { felder[k] = v.alsAny }
            Postausgang.merken(wf: workflow.id, name: workflow.name, felder: felder)
            Gemeinsam.defaults.removeObject(forKey: entwurfSchluessel)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            studio.meldung = "📮 PC gerade nicht erreichbar – »\(workflow.name)« startet automatisch, sobald er wieder da ist"
            dismiss()
        } catch {
            fehler = error.localizedDescription
        }
    }
}

extension JSONWert {
    /// für JSONSerialization
    var alsAny: Any {
        switch self {
        case .text(let t): return t
        case .zahl(let z): return z
        case .wahr(let b): return b
        case .liste(let l): return l.map(\.alsAny)
        case .objekt(let o): return o.mapValues(\.alsAny)
        case .nichts: return NSNull()
        }
    }
}


/// ❤ Deine Favoriten als Vorlage mit Bild: antippen -> »Das will ich auch« = gleiche Einstellungen, neuer Zufall
@MainActor
struct FavoritenVorlagen: View {
    @EnvironmentObject private var studio: Studio
    @State private var gewaehlt: Auftrag?

    private var favoriten: [Auftrag] {
        Array(studio.stand.auftraege.filter { $0.fav && $0.fertig && $0.wiederholbar }
            .sorted { ($0.finished ?? 0) > ($1.finished ?? 0) }.prefix(20))
    }

    var body: some View {
        if !favoriten.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("❤ Deine Favoriten als Vorlage").font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(favoriten) { a in
                            Button { gewaehlt = a } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    BibliothekKachel(a: a).frame(width: 110, height: 110)
                                    Text(a.titel).font(.caption2).lineLimit(1).frame(width: 110, alignment: .leading)
                                }
                            }
                            .buttonStyle(NXDruck())
                        }
                    }
                }
            }
            .confirmationDialog(gewaehlt?.titel ?? "", isPresented: Binding(get: { gewaehlt != nil }, set: { if !$0 { gewaehlt = nil } }),
                                titleVisibility: .visible) {
                Button("✨ Das will ich auch (neue Variante)") { if let a = gewaehlt { Task { await nochmal(a) } } }
            } message: { Text("Gleiche Einstellungen, neuer Zufall – das Ergebnis wird ähnlich, aber ein Einzelstück.") }
        }
    }

    private func nochmal(_ a: Auftrag) async {
        guard let c = studio.client else { return }
        do {
            _ = try await c.post("/api/handy/start", ["wf": "_variante", "felder": ["id": a.id]], zeit: 120)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            studio.meldung = "✨ Läuft – ähnlich wie »\(a.titel)«"
            await studio.aktualisieren()
        } catch { studio.meldung = error.localizedDescription }
    }
}
