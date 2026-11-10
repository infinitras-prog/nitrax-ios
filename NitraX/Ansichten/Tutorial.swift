import SwiftUI
import AVKit

/// 🎓 Gesamtplan 4b: Klick-Tutorial je Workflow – Feld für Feld erklärt (mit Beispiel), dann echter Testlauf zum
/// Live-Mitverfolgen (jede Phase in Alltagssprache) bis zum ersten Ergebnis. Inhalte kommen vom PC (tutorial.py).
struct TutorialDaten {
    struct Schritt { let feld: String; let label: String; let text: String; let beispiel: JSONWert?; var test = false }
    let name: String
    let intro: String
    let dauer: String
    let schritte: [Schritt]
    let test: [String: JSONWert]
    let fertig: String
    let danach: String
    let fehlt: (text: String, wf: String)?
    let phasen: [(NSRegularExpression, String)]

    init?(_ w: JSONWert) {
        guard let n = w["name"]?.text else { return nil }
        name = n
        intro = w["intro"]?.text ?? ""
        dauer = w["dauer"]?.text ?? ""
        schritte = (w["schritte"]?.liste ?? []).compactMap { s in
            guard let f = s["feld"]?.text else { return nil }
            let b = s["beispiel"]
            return Schritt(feld: f, label: s["label"]?.text ?? f, text: s["text"]?.text ?? "", beispiel: (b == nil || b == .nichts) ? nil : b,
                           test: s["test"]?.wahr ?? false)
        }
        test = w["test"]?.objekt ?? [:]
        fertig = w["fertig"]?.text ?? "Geschafft!"
        danach = w["danach"]?.text ?? ""
        if let f = w["fehlt"], let t = f["text"]?.text { fehlt = (t, f["wf"]?.text ?? "") } else { fehlt = nil }
        phasen = (w["phasen"]?.liste ?? []).compactMap { p in
            guard let m = p["muster"]?.text, let r = try? NSRegularExpression(pattern: m, options: [.caseInsensitive]) else { return nil }
            return (r, p["text"]?.text ?? "")
        }
    }

    func phase(_ stage: String) -> String? {
        let b = NSRange(stage.startIndex..., in: stage)
        return phasen.first { $0.0.firstMatch(in: stage, range: b) != nil }?.1
    }

    static func laden(_ c: NXClient, wf: String) async throws -> TutorialDaten {
        let w = try await c.get("/api/handy/tutorial?wf=" + wf, JSONWert.self)
        guard let t = TutorialDaten(w) else { throw NXFehler.antwort }
        return t
    }
}

/// Die Leiste unten im Formular: Einführung -> Feld 1 … n -> »Starten«
@MainActor
struct TutorialLeiste: View {
    let t: TutorialDaten
    @Binding var schritt: Int                        // 0 = Einführung, 1…n = Felder, n+1 = Starten
    let einsetzen: (TutorialDaten.Schritt) -> Void
    let beenden: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tutorial · \(t.name)", systemImage: "graduationcap.fill").font(.caption.weight(.bold)).foregroundStyle(Farbe.akzent)
                Spacer()
                Text("\(min(schritt, t.schritte.count + 1))/\(t.schritte.count + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button { beenden() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
            if schritt == 0 {
                Text(t.intro).font(.subheadline)
                if !t.dauer.isEmpty { Text("⏱ Test dauert \(t.dauer)").font(.caption).foregroundStyle(.secondary) }
                if let f = t.fehlt { Label(f.text, systemImage: "info.circle").font(.caption).foregroundStyle(Farbe.warn) }
            } else if schritt <= t.schritte.count {
                let s = t.schritte[schritt - 1]
                Text(s.label).font(.subheadline.weight(.semibold))
                Text(s.text).font(.subheadline)
                if s.beispiel != nil {
                    Button { einsetzen(s) } label: { Label("Beispiel einsetzen", systemImage: "wand.and.stars") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Text("Alles ausgefüllt! Tippe jetzt unten auf »Starten« – danach kannst du live mitverfolgen, was der PC macht.")
                    .font(.subheadline)
            }
            HStack {
                if schritt > 0 { Button("Zurück") { withAnimation { schritt -= 1 } }.buttonStyle(.bordered) }
                Spacer()
                if schritt <= t.schritte.count {
                    Button(schritt == 0 ? "Los geht's" : "Weiter") { withAnimation(.snappy) { schritt += 1 } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Farbe.akzent.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

/// Live mitverfolgen: Fortschritt + was gerade passiert (in Alltagssprache) bis zum ersten Ergebnis
@MainActor
struct TutorialLive: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    @Environment(\.dismiss) private var dismiss
    let t: TutorialDaten
    let ids: [String]
    @State private var start = Date()
    @State private var verlauf: [String] = []

    private var auftraege: [Auftrag] { ids.compactMap { id in studio.stand.auftraege.first { $0.id == id } } }
    private var a: Auftrag? { auftraege.first { !$0.fertig } ?? auftraege.first }
    private var fertig: Bool { !auftraege.isEmpty && auftraege.allSatisfy { $0.fertig || $0.gescheitert } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let a {
                        if fertig && a.fertig {
                            ergebnis(a)
                        } else if a.gescheitert {
                            Label("Das hat leider nicht geklappt: \(a.fehler ?? a.status)", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Farbe.fehler).karte()
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(a.laeuft ? "Läuft" : "Wartet").font(.headline)
                                    Spacer()
                                    TimelineView(.periodic(from: .now, by: 1)) { z in
                                        Text(Zeit.dauer(z.date.timeIntervalSince(start))).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                                Fortschrittsbalken(wert: a.progress)
                                Text(a.stage).font(.caption).foregroundStyle(.secondary)
                                if a.laeuft { LiveZwischenbild(auftrag: a.id).frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 14)) }
                            }
                            .karte()
                            if let p = t.phase(a.stage) {
                                Label(p, systemImage: "lightbulb.fill").font(.subheadline).foregroundStyle(.primary).karte()
                                    .transition(.opacity)
                                    .id(p)
                            }
                        }
                    } else {
                        ProgressView("Auftrag wird angelegt …").frame(maxWidth: .infinity)
                    }
                    if !verlauf.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bisher passiert").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(verlauf.indices, id: \.self) { i in
                                Label(verlauf[i], systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .karte()
                    }
                }
                .padding(16)
                .animation(.easeInOut, value: a?.stage)
            }
            .nxHintergrund()
            .navigationTitle("🎓 " + t.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(fertig ? "Fertig" : "Im Hintergrund") { dismiss() } } }
            .onChange(of: a?.stage ?? "") { alt, _ in
                if let p = t.phase(alt), verlauf.last != p { verlauf.append(p) }
            }
            .task { while !Task.isCancelled { await studio.aktualisieren(); try? await Task.sleep(for: .seconds(2)) } }
        }
    }

    @ViewBuilder private func ergebnis(_ a: Auftrag) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Fertig nach \(Zeit.dauer(Date().timeIntervalSince(start)))", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Farbe.gut)
            if a.hatVideo, let u = studio.url("/api/video/\(a.id)") {
                VideoPlayer(player: AVPlayer(url: u)).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
            } else if let v = studio.vorschauURL(a) {
                NXBild(url: v, modus: .fit).frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text(t.fertig).font(.subheadline)
            Button { navigation.oeffne(auftrag: a.id); dismiss() } label: {
                Label("Ergebnis öffnen", systemImage: "arrow.right.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .karte()
        .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}

/// 🎓 Übersicht aller Einführungen (Erstellen-Tab)
@MainActor
struct TutorialUebersicht: View {
    @EnvironmentObject private var studio: Studio
    @AppStorage("tutorial_erledigt") private var erledigtRoh = ""

    var body: some View {
        List {
            Section {
                Text("Jedes Tutorial erklärt den Workflow Schritt für Schritt, setzt Beispiele ein und macht einen echten Testlauf – den du live mitverfolgst, bis dein erstes Ergebnis da ist.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            ForEach(studio.workflows?.kategorien ?? [], id: \.self) { k in
                let liste = (studio.workflows?.workflows ?? []).filter { $0.kat == k.first }
                if !liste.isEmpty {
                    Section((k.count > 2 ? k[2] + " " : "") + (k.count > 1 ? k[1] : k[0])) {
                        ForEach(liste) { w in
                            NavigationLink { WorkflowFormular(workflow: w, tutorialStart: true) } label: {
                                HStack(spacing: 12) {
                                    Text(w.glyph).font(.title3).frame(width: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(w.name).font(.subheadline.weight(.semibold))
                                        Text(w.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    if erledigtRoh.split(separator: ",").contains(Substring(w.id)) {
                                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Farbe.gut)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Farbe.karte)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle("🎓 Tutorials")
        .navigationBarTitleDisplayMode(.inline)
        .task { await studio.workflowsLaden() }
    }

    static func erledigt(_ wf: String) {
        var l = Set((UserDefaults.standard.string(forKey: "tutorial_erledigt") ?? "").split(separator: ",").map(String.init))
        l.insert(wf)
        UserDefaults.standard.set(l.sorted().joined(separator: ","), forKey: "tutorial_erledigt")
    }
}

/// ✨ »Was ist neu« – einmal nach jedem Update
@MainActor
struct WasIstNeu: View {
    @Environment(\.dismiss) private var dismiss
    static let version = "0.5.32"
    static let punkte: [(String, String, String)] = [
        ("puzzlepiece.extension.fill", "Eigene Workflows", "Was du im Code-Agenten baust, erscheint unter Erstellen → 🧩 Eigene – mit Formular, Fortschritt und Ergebnis wie jeder andere Workflow."),
        ("graduationcap.fill", "»Tutorial« statt »Einführung«", "Die Schritt-für-Schritt-Hilfe mit echtem Testlauf heißt jetzt überall Tutorial."),
        ("checkmark.seal.fill", "Für diese Sitzung immer erlauben", "Der Code-Agent fragt in diesem Chat nicht mehr nach. Die harten Sperren (Löschen, System) und die Ordnergrenze bleiben."),
        ("waveform.path", "Immer sehen, was passiert", "Gedanken live, laufender Schritt mit Zeit, Fortschritt auch nach dem Wiederöffnen eines laufenden Chats."),
        ("bubble.left.and.bubble.right.fill", "Chat neu gestaltet", "Drei Agenten oben zum Starten, Verlauf nach Tagen sortiert mit Filter und Suche, schönere Blasen und Beispiel-Ideen zum Antippen."),
        ("chevron.left.forwardslash.chevron.right", "Code-Agent auf dem iPhone", "Programmieren lassen oder NitraX erweitern – jeden Schritt bestätigst du direkt im Chat mit »Erlauben«."),
        ("music.note", "Musik-Player repariert", "Songs spielen wieder – jetzt als AAC vom PC, rund 8× weniger Daten unterwegs. Klappt ein Titel nicht, steht der Grund im Player."),
        ("puzzlepiece.extension.fill", "NitraX selbst erweitern", "Im Code-Agenten einfach schreiben, was NitraX zusätzlich können soll – er baut es sicher als Erweiterung (eigener Ordner, geprüft, mit Rückgängig)."),
        ("globe", "NitraX auf Englisch", "Ist dein iPhone auf Englisch gestellt, spricht die App Englisch – oder einzeln: iOS-Einstellungen → NitraX → Sprache."),
        ("checklist", "Helfer-Pläne zuverlässiger", "»Mach ein Bild und daraus ein GIF«: der Helfer plant den nötigen Zwischenschritt (Video) selbst, und Sofort-Ergebnisse wie GIFs zählen als fertig."),
        ("graduationcap.fill", "Tutorials für jeden Workflow", "Erstellen → 🎓 Tutorials: Schritt für Schritt erklärt, mit Beispielen und echtem Testlauf, den du live mitverfolgst."),
        ("hammer.fill", "Die Werkstatt zeigt, was sie tut", "Auf der Startseite siehst du, woran sie gerade arbeitet – z. B. »Regie plant: 4 von 13 Szenen«."),
        ("list.number", "Mehrschritt-Aufträge", "»Erst Song, dann Film, dann …« – dein Helfer arbeitet Schritt für Schritt, meldet jeden Schritt und macht nach Neustarts weiter."),
        ("paperplane.fill", "Fertig zum Veröffentlichen", "Bei jedem Video: TikTok, Reels, Shorts oder YouTube – Format, Länge, Lautstärke, Untertitel, Titelbild, Text und Hashtags macht der PC."),
        ("folder.fill", "Projekt-Mappen", "Aufträge → 📁: Song, Film und Varianten eines Vorhabens zusammen, mit Notiz. Mehrteilige Helfer-Aufträge bekommen ihre Mappe automatisch."),
        ("waveform.path.ecg", "Systemzustand", "Einstellungen → Systemzustand: Grafikkarte, Aufträge, Werkstatt, Datensicherung, letzte Fehler auf einen Blick."),
        ("externaldrive.badge.checkmark", "Tägliche Datensicherung", "Chats, Helfer, Stimmen und Einstellungen werden täglich gesichert (7 Stände)."),
        ("antenna.radiowaves.left.and.right", "Unterwegs schneller", "Viel weniger Daten pro Abfrage, und die App merkt sich den Tailscale-Weg selbst."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.punkte.indices, id: \.self) { i in
                        let p = Self.punkte[i]
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: p.0).font(.title2).foregroundStyle(Farbe.akzent).frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.1).font(.headline)
                                Text(p.2).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .nxHintergrund()
            .navigationTitle("Neu in \(Self.version)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Los geht's") { dismiss() } } }
        }
    }

    /// einmal je Version zeigen
    static var faellig: Bool {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard v == version, UserDefaults.standard.string(forKey: "wasistneu_gesehen") != v else { return false }
        return true
    }
    static func gesehen() {
        UserDefaults.standard.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", forKey: "wasistneu_gesehen")
    }
}
