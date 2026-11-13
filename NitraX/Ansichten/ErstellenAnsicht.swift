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
                    NavigationLink { TutorialUebersicht() } label: {             // 🎓 Einführungen
                        HStack(spacing: 12) {
                            Text("🎓").font(.system(size: 26)).frame(width: 44, height: 44).background(Circle().fill(Farbe.akzent.opacity(0.16)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tutorials").font(.subheadline.weight(.semibold))
                                Text("Jeder Workflow Schritt für Schritt – mit echtem Testlauf zum Mitverfolgen").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .karte()
                    }
                    .buttonStyle(.plain)
                    AbsichtKarte()                                           // ✨ ein Satz -> fertig vorbereiteter Workflow
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

                    if kategorie == "eigene" {                                  // 🧩 eigene Workflows teilen/importieren
                        NavigationLink { EigeneWorkflowsAnsicht() } label: {
                            HStack(spacing: 12) {
                                Text("🧩").font(.system(size: 26)).frame(width: 44, height: 44).background(Circle().fill(Farbe.akzent.opacity(0.16)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Eigene verwalten").font(.subheadline.weight(.semibold))
                                    Text("Teilen, importieren (auch ComfyUI), ein- und ausschalten").font(.caption).foregroundStyle(.secondary)
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
    var tutorialStart = false                          // 🎓 gleich mit der Einführung beginnen
    @State private var werte: [String: JSONWert] = [:]
    @State private var tutorial: TutorialDaten?
    @State private var tutSchritt = 0
    @State private var tutLaedt = false
    @State private var tutLive: LiveZiel?
    struct LiveZiel: Identifiable { let id = UUID(); let ids: [String] }

    /// gerade erklärtes Feld (für Hervorheben + Hinscrollen)
    private var tutFeld: String? {
        guard let t = tutorial else { return nil }
        if tutSchritt >= 1 && tutSchritt <= t.schritte.count { return t.schritte[tutSchritt - 1].feld }
        return tutSchritt > t.schritte.count ? "nx-start" : nil
    }

    private func tutorialStarten() async {
        guard let c = studio.client, !tutLaedt else { return }
        tutLaedt = true
        defer { tutLaedt = false }
        do {
            let t = try await TutorialDaten.laden(c, wf: workflow.id)
            for (k, v) in t.test { werte[k] = v }                       // schnelle Test-Einstellungen
            for s in t.schritte where s.test { if let b = s.beispiel { werte[s.feld] = b } }
            withAnimation(.snappy) { tutorial = t; tutSchritt = 0 }
        } catch { fehler = "Tutorial nicht verfügbar: \(error.localizedDescription)" }
    }
    @State private var startet = false
    @State private var startZeit = Date()
    @State private var fehler: String?
    @ObservedObject private var uploads = UploadStand.shared
    @State private var varianten = 1                    // 🎲 mehrere auf einmal (Runde 3, Nr. 5)

    var body: some View {
        ScrollViewReader { blick in
        Form {
            Section {
                Text(workflow.text).font(.footnote).foregroundStyle(.secondary)
                if tutorial == nil {
                    Button { Task { await tutorialStarten() } } label: {
                        Label(tutLaedt ? "Tutorial lädt …" : "🎓 Tutorial mit Testlauf", systemImage: "graduationcap")
                    }
                    .font(.footnote)
                }
            }
            ForEach(hauptFelder) { f in
                Section {
                    FeldEditor(feld: f, workflow: workflow, wert: Binding(get: { werte[f.name] }, set: { werte[f.name] = $0 }), alle: werte)
                        .listRowBackground(tutFeld == f.name ? Farbe.akzent.opacity(0.22) : nil)
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let titel = abschnittTitel(f) {                 // 🗂 neuer Abschnitt beginnt
                            Text(titel).font(.headline).foregroundStyle(Farbe.akzent).textCase(nil).padding(.top, 6)
                        }
                        if f.art != "schalter" { Text(f.label + (f.pflicht ? " *" : "")) }
                    }
                }
                .id(f.name)
            }
            // ⚙︎ 13.11.2026: Profi-Einstellungen (Schritte, CFG, Sampler, VAE, Hires, Detailer, Seed …) eingeklappt
            if !profiFelder.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $profiOffen) {
                        ForEach(profiFelder) { f in
                            VStack(alignment: .leading, spacing: 6) {
                                if f.art != "schalter" { Text(f.label).font(.caption).foregroundStyle(.secondary) }
                                FeldEditor(feld: f, workflow: workflow, wert: Binding(get: { werte[f.name] }, set: { werte[f.name] = $0 }), alle: werte)
                            }
                            .padding(.vertical, 4)
                            .id(f.name)
                        }
                    } label: {
                        Label("Profi-Einstellungen (" + String(profiFelder.count) + ")", systemImage: "slider.horizontal.3")
                    }
                }
            }
            Section {
                Stepper(value: $varianten, in: 1...4) {
                    Label(varianten == 1 ? "Eine Variante" : "\(varianten) Varianten auf einmal – danach vergleichen", systemImage: "square.grid.2x2")
                        .font(.subheadline)
                }
            } footer: {
                if varianten > 1 { Text("Gleiche Eingaben, jedes Mal ein anderer Zufall. Die Rechenzeit vervielfacht sich.") }
            }
            Section {
                if geaendert > 0 {                                         // 🧾 13.11.2026: Überblick vor dem Start
                    HStack {
                        Label(geaendert == 1 ? "1 Einstellung geändert" : String(geaendert) + " Einstellungen geändert", systemImage: "slider.horizontal.3")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Zurücksetzen") { zuruecksetzen() }.font(.footnote)
                    }
                }
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
                .overlay { if tutFeld == "nx-start" { RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2).padding(-4) } }
                if let fehler { Text(fehler).font(.footnote).foregroundStyle(Farbe.fehler) }
            }
            .id("nx-start")
            if tutorial != nil { Color.clear.frame(height: 260).listRowBackground(Color.clear) }    // Platz für die Einführung
        }
        .onChange(of: tutSchritt) { _, _ in
            if let f = tutFeld { withAnimation(.easeInOut(duration: 0.35)) { blick.scrollTo(f, anchor: .top) } }
        }
        }
        .safeAreaInset(edge: .bottom) {
            if let t = tutorial {
                TutorialLeiste(t: t, schritt: $tutSchritt, einsetzen: { s in
                    if let b = s.beispiel { werte[s.feld] = b; UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                }, beenden: { withAnimation { tutorial = nil } })
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: tutSchritt) { alt, neu in
            // »Weiter« ohne Eingabe: leeres Feld bekommt das Beispiel (sonst klappt der Testlauf nicht)
            guard let t = tutorial, neu > alt, alt >= 1, alt <= t.schritte.count else { return }
            let s = t.schritte[alt - 1]
            if (werte[s.feld]?.istLeer ?? true), let b = s.beispiel { werte[s.feld] = b }
        }
        .fullScreenCover(item: $tutLive) { z in
            if let t = tutorial { TutorialLive(t: t, ids: z.ids) } else { EmptyView() }
        }
        .task { if tutorialStart && tutorial == nil { await tutorialStarten() } }
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
        .searchable(text: $suche, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Einstellung suchen")
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
               ["wahl", "schalter", "zahl", "stimme", "bildmodell"].contains(f.art),
               !f.name.hasPrefix("eigen_") {                        // 🎬 eigenes Modell: Wahl kommt vom PC (geteilt)
                werte[f.name] = w                                   // Einstellungen vom letzten Mal (nicht Texte/Medien)
            } else if let w = f.wert {
                werte[f.name] = w
            }
        }
        for (k, v) in vorbelegung { werte[k] = v }          // z. B. »▶ Animieren« aus einem fertigen Bild
    }

    /// 🎬 Feld mit »fuer«: nur zeigen, wenn das andere Feld (z. B. Modell) passt
    private func sichtbar(_ f: Feld) -> Bool {
        guard let ziel = f.fuerFeld, !f.fuerWerte.isEmpty else { return true }
        let wert = werte[ziel]?.text ?? workflow.felder.first { $0.name == ziel }?.wert?.text ?? ""
        return f.fuerWerte.contains(wert)
    }

    @State private var profiOffen = false
    @State private var suche = ""
    private var profiFelder: [Feld] { workflow.felder.filter { sichtbar($0) && $0.gruppe == "profi" && passtZurSuche($0) } }
    private var hauptFelder: [Feld] { workflow.felder.filter { sichtbar($0) && $0.gruppe == nil && passtZurSuche($0) } }

    /// 🔎 Einstellung suchen (Beschriftung oder Abschnitt)
    private func passtZurSuche(_ f: Feld) -> Bool {
        let s = suche.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return true }
        return f.label.lowercased().contains(s) || (f.abschnitt ?? "").lowercased().contains(s)
    }

    /// 🗂 Überschrift, wenn mit diesem Feld ein neuer Abschnitt beginnt
    private func abschnittTitel(_ f: Feld) -> String? {
        guard let a = f.abschnitt, !a.isEmpty else { return nil }
        let liste = hauptFelder
        guard let i = liste.firstIndex(where: { $0.name == f.name }) else { return nil }
        if i == 0 { return a }
        return liste[i - 1].abschnitt == a ? nil : a
    }

    /// 🧾 Einstellungen, die vom Standard abweichen (ohne Texte und Medien)
    private var geaenderteFelder: [Feld] {
        workflow.felder.filter { f in
            guard ["wahl", "schalter", "zahl"].contains(f.art), let std = f.wert, let jetzt = werte[f.name] else { return false }
            return std != jetzt
        }
    }
    private var geaendert: Int { geaenderteFelder.count }
    private func zuruecksetzen() {
        for f in geaenderteFelder { if let std = f.wert { werte[f.name] = std } }
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
            if tutorial != nil {                                           // 🎓 Testlauf: live mitverfolgen statt wegspringen
                let ids = (r["auftraege"]?.liste ?? []).compactMap(\.text)
                TutorialUebersicht.erledigt(workflow.id)
                await studio.aktualisieren()
                tutLive = LiveZiel(ids: ids)
                return
            }
            if varianten > 1 {                                                  // 🎲 weitere Varianten, danach vergleichen
                var ids = (r["auftraege"]?.liste ?? []).compactMap(\.text)
                for _ in 1..<varianten {
                    if let w = try? await c.post("/api/handy/start", ["wf": workflow.id, "felder": felder], zeit: 900) {
                        ids += (w["auftraege"]?.liste ?? []).compactMap(\.text)
                    }
                }
                VergleichGruppen.neu(name: workflow.name, ids: ids)
            }
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
