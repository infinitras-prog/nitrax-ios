import SwiftUI

/// ⏳ Warteschlange (Runde 2, Nr. 7): wartende Aufträge umsortieren (ziehen), vorziehen, zurückstellen, wieder einreihen,
/// abbrechen; ganze Warteschlange anhalten. Dazu für jeden Platz, wann er ungefähr drankommt.
@MainActor
struct WarteschlangeAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var info: JSONWert?
    @State private var bearbeiten: EditMode = .inactive
    @State private var abbrechen: Auftrag?

    private var laufend: [Auftrag] { studio.stand.auftraege.filter { $0.laeuft } }
    private var aktiv: [Auftrag] { studio.warteschlangeListe.filter { !$0.zurueckgestellt } }
    private var zurueck: [Auftrag] { studio.warteschlangeListe.filter { $0.zurueckgestellt } }
    private var pausiert: Bool { info?["pausiert"]?.wahr ?? false }

    /// wann jeder Wartende ungefähr anfängt (Restzeit der laufenden + Schätzungen davor)
    private var startIn: [String: Double] {
        var t = laufend.reduce(0.0) { $0 + max(0, $1.eta ?? 0) }
        var m: [String: Double] = [:]
        for a in aktiv { m[a.id] = t; t += max(30, a.eta ?? 120) }
        return m
    }

    var body: some View {
        List {
            if pausiert {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(pauseText, systemImage: "pause.circle.fill").foregroundStyle(Farbe.warn)
                        Button { Task { await studio.warteschlange(anhalten: false); await laden() } } label: {
                            Label("Warteschlange fortsetzen", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .listRowBackground(Farbe.karte)
            }
            if !laufend.isEmpty {
                Section("Läuft gerade") {
                    ForEach(laufend) { a in NavigationLink(value: a) { AuftragZeile(a: a) } }
                }
                .listRowBackground(Farbe.karte)
            }
            Section {
                if aktiv.isEmpty { Text("Nichts wartet").foregroundStyle(.secondary) }
                ForEach(Array(aktiv.enumerated()), id: \.element.id) { i, a in
                    NavigationLink(value: a) { zeile(a, platz: i + 1) }
                        .swipeActions(edge: .leading) {
                            if i > 0 {
                                Button { Task { await studio.stelle(a, zu: 0) } } label: { Label("Als Nächstes", systemImage: "arrow.up.to.line") }
                                    .tint(Farbe.akzent)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { abbrechen = a } label: { Label("Abbrechen", systemImage: "xmark") }
                            Button { Task { await studio.zurueckstellen(a, an: true) } } label: { Label("Zurückstellen", systemImage: "pause") }
                                .tint(Farbe.warn)
                        }
                        .contextMenu {
                            if i > 0 { Button { Task { await studio.stelle(a, zu: 0) } } label: { Label("Als Nächstes", systemImage: "arrow.up.to.line") } }
                            if i > 0 { Button { Task { await studio.stelle(a, zu: i - 1) } } label: { Label("Einen nach vorn", systemImage: "arrow.up") } }
                            if i < aktiv.count - 1 { Button { Task { await studio.stelle(a, zu: i + 1) } } label: { Label("Einen nach hinten", systemImage: "arrow.down") } }
                            Button { Task { await studio.zurueckstellen(a, an: true) } } label: { Label("Zurückstellen", systemImage: "pause") }
                            Button(role: .destructive) { abbrechen = a } label: { Label("Abbrechen", systemImage: "xmark") }
                        }
                }
                .onMove { von, nach in
                    guard let alt = von.first, aktiv.indices.contains(alt) else { return }
                    let a = aktiv[alt]
                    let neu = nach > alt ? nach - 1 : nach
                    guard neu != alt else { return }
                    Task { await studio.stelle(a, zu: neu) }
                }
            } header: {
                Text("Wartet · \(aktiv.count)")
            } footer: {
                Text("Nach rechts wischen = als Nächstes · nach links = zurückstellen oder abbrechen · »Ordnen« = ziehen. Zeiten sind Schätzungen aus deinen letzten Aufträgen.")
            }
            .listRowBackground(Farbe.karte)
            if !zurueck.isEmpty {
                Section {
                    ForEach(zurueck) { a in
                        NavigationLink(value: a) { AuftragZeile(a: a) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { abbrechen = a } label: { Label("Abbrechen", systemImage: "xmark") }
                                Button { Task { await studio.zurueckstellen(a, an: false) } } label: { Label("Einreihen", systemImage: "play") }
                                    .tint(Farbe.gut)
                            }
                            .contextMenu {
                                Button { Task { await studio.zurueckstellen(a, an: false) } } label: { Label("Wieder einreihen", systemImage: "play") }
                                Button(role: .destructive) { abbrechen = a } label: { Label("Abbrechen", systemImage: "xmark") }
                            }
                    }
                } header: { Text("⏸ Zurückgestellt") } footer: { Text("Bleibt liegen, bis du es wieder einreihst – es kommt dann hinten an.") }
                .listRowBackground(Farbe.karte)
            }
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .environment(\.editMode, $bearbeiten)
        .navigationTitle("Warteschlange")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(bearbeiten == .active ? "Fertig" : "Ordnen") {
                    withAnimation { bearbeiten = bearbeiten == .active ? .inactive : .active }
                }
                .disabled(aktiv.count < 2 && bearbeiten != .active)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(pausiert ? "Warteschlange fortsetzen" : "Warteschlange anhalten", systemImage: pausiert ? "play.fill" : "pause.fill") {
                        Task { await studio.warteschlange(anhalten: !pausiert); await laden() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("»\(abbrechen?.titel ?? "")« abbrechen?", isPresented: Binding(get: { abbrechen != nil }, set: { if !$0 { abbrechen = nil } }),
                            titleVisibility: .visible) {
            Button("Abbrechen", role: .destructive) { if let a = abbrechen { Task { await studio.abbrechen(a) } }; abbrechen = nil }
        }
        .refreshable { await studio.aktualisieren(); await laden() }
        .task(id: studio.warteschlangeListe.map(\.id).joined() + "\(laufend.count)") { await laden() }
    }

    private var pauseText: String {
        switch info?["grund"]?.text ?? "" {
        case "spiel": return "Angehalten – ein Spiel nutzt die Grafikkarte. Geht danach von selbst weiter."
        case "zeitplan": return "Angehalten – rechnet nur im eingestellten Zeitfenster."
        default: return "Warteschlange angehalten"
        }
    }

    private func zeile(_ a: Auftrag, platz: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(platz)").font(.caption.weight(.bold).monospacedDigit()).frame(width: 22, height: 22)
                .background(Farbe.akzent.opacity(platz == 1 ? 0.35 : 0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(a.titel).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(unterzeile(a)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func unterzeile(_ a: Auftrag) -> String {
        var t = a.artName + " · "
        t += pausiert ? "wartet (angehalten)" : "startet in ca. " + Zeit.dauer(startIn[a.id])
        if let e = a.eta { t += " · dauert ca. " + Zeit.dauer(e) }
        return t
    }

    private func laden() async {
        info = try? await studio.client?.get("/api/handy/schaetzung", JSONWert.self)
    }
}

/// ⏱ Zeitschätzung vor dem Start (Runde 2, Nr. 8): wie lange es ungefähr dauert und ob der PC frei ist
@MainActor
struct SchaetzungZeile: View {
    @EnvironmentObject private var studio: Studio
    let wf: String
    let laenge: Double?
    @State private var s: JSONWert?
    @State private var fehlt = false

    var body: some View {
        Group {
            if let s {
                Label(text(s), systemImage: symbol(s)).font(.footnote).foregroundStyle(farbe(s))
            } else {
                Label(fehlt ? "Dauer gerade nicht abschätzbar" : "Schätze die Dauer …", systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .task(id: "\(wf)|\(laenge ?? 0)") {
            try? await Task.sleep(for: .milliseconds(250))
            var pfad = "/api/handy/schaetzung?wf=" + (wf.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? wf)
            if let laenge { pfad += "&laenge=\(laenge)" }
            if let neu = try? await studio.client?.get(pfad, JSONWert.self) { withAnimation { s = neu } } else { fehlt = true }
        }
    }

    private func text(_ s: JSONWert) -> String {
        let dauer = s["dauer"]?.zahl, warten = s["warten"]?.zahl ?? 0, vor = Int(s["vor_dir"]?.zahl ?? 0)
        var t = dauer.map { "Dauert ca. \(Zeit.dauer($0))" } ?? "Noch keine Erfahrung mit diesem Workflow"
        if s["pausiert"]?.wahr == true {
            t += " · Warteschlange angehalten" + (s["grund"]?.text == "spiel" ? " (ein Spiel läuft)" : "") + " – startet, sobald es weitergeht"
        } else if vor > 0 {
            t += " · startet nach \(vor) \(vor == 1 ? "anderem" : "anderen") (in ca. \(Zeit.dauer(max(30, warten))))"
        } else {
            t += " · PC ist frei, startet sofort"
        }
        if let d = dauer, s["pausiert"]?.wahr != true {                     // 📅 fertig vor dem nächsten Termin?
            let fertig = Date().addingTimeInterval(d + (vor > 0 ? warten : 0))
            if let k = KalenderDienst.shared.naechster(bis: fertig.addingTimeInterval(45 * 60)) {
                let uhr = fertig.formatted(date: .omitted, time: .shortened)
                t += k.start > fertig ? " · fertig ca. \(uhr) – vor »\(k.titel)«" : " · wird erst nach Beginn von »\(k.titel)« fertig (ca. \(uhr))"
            }
        }
        if let f = s["fremd"]?.liste?.compactMap(\.text), !f.isEmpty, s["pausiert"]?.wahr != true {
            t += " · \(f.joined(separator: ", ")) läuft – kann langsamer werden"
        }
        return t
    }

    private func symbol(_ s: JSONWert) -> String {
        if s["pausiert"]?.wahr == true { return "pause.circle" }
        return Int(s["vor_dir"]?.zahl ?? 0) > 0 ? "hourglass" : "bolt.circle"
    }

    private func farbe(_ s: JSONWert) -> Color {
        if s["pausiert"]?.wahr == true { return Farbe.warn }
        return .secondary
    }
}
