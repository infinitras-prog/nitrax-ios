import SwiftUI

/// ⏰ Routinen: dein Helfer meldet sich zu festen Zeiten – Anruf oder Mitteilung, mit Briefing (was fertig wurde, was läuft)
/// und/oder eigenem Text. Läuft am PC (begleiter.routinen_pruefen), auch wenn die App zu ist.
struct Routine: Identifiable, Hashable, Codable {
    var id = UUID().uuidString.prefix(8).lowercased()
    var name = "Morgen-Briefing"
    var zeit = "07:30"
    var tage: [Int] = [0, 1, 2, 3, 4]                  // 0 = Montag … 6 = Sonntag
    var art = "anruf"                                  // anruf | mitteilung
    var briefing = true
    var text = ""
    var an = true

    var datum: Date {
        get {
            let t = zeit.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: t.first ?? 7, minute: t.last ?? 30, second: 0, of: Date()) ?? Date()
        }
        set { zeit = newValue.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    }

    var tageText: String {
        if tage.count == 7 { return "täglich" }
        if tage == [0, 1, 2, 3, 4] { return "werktags" }
        if tage == [5, 6] { return "am Wochenende" }
        return tage.map { Routine.kurz[$0] }.joined(separator: ", ")
    }
    static let kurz = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    var json: [String: Any] { ["id": id, "name": name, "zeit": zeit, "tage": tage, "art": art, "briefing": briefing, "text": text, "an": an] }

    init() {}
    init?(_ w: JSONWert) {
        guard let i = w["id"]?.text else { return nil }
        id = i
        name = w["name"]?.text ?? "Routine"
        zeit = w["zeit"]?.text ?? "07:30"
        tage = (w["tage"]?.liste ?? []).compactMap { $0.zahl.map { Int($0) } }
        art = w["art"]?.text ?? "mitteilung"
        briefing = w["briefing"]?.wahr ?? true
        text = w["text"]?.text ?? ""
        an = w["an"]?.wahr ?? true
    }
}

@MainActor
struct RoutinenAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State private var liste: [Routine] = []
    @State private var laedt = true
    @State private var bearbeiten: Routine?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if laedt { ProgressView().frame(maxWidth: .infinity) }
                    if !laedt && liste.isEmpty {
                        Text("Noch keine Routine. Zum Beispiel: werktags um 7:30 ruft dein Helfer an und sagt dir, was über Nacht fertig geworden ist.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach($liste) { $r in
                        Button { bearbeiten = r } label: {
                            HStack(spacing: 12) {
                                Image(systemName: r.art == "anruf" ? "phone.fill" : "bell.fill")
                                    .foregroundStyle(r.an ? Farbe.akzent : .secondary).frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).font(.headline).foregroundStyle(r.an ? .primary : .secondary)
                                    Text("\(r.zeit) Uhr · \(r.tageText)" + (r.briefing ? " · Briefing" : "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $r.an).labelsHidden().onChange(of: r.an) { _, _ in Task { await sichern() } }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions { Button("Löschen", role: .destructive) { liste.removeAll { $0.id == r.id }; Task { await sichern() } } }
                    }
                } footer: {
                    Text("Routinen laufen am PC – auch wenn die App zu ist. Anrufe klingeln auf dem iPhone.")
                }
                Section {
                    Button { bearbeiten = Routine() } label: { Label("Neue Routine", systemImage: "plus.circle.fill") }
                    Menu {
                        Button("☀️ Morgen-Briefing (werktags 7:30, Anruf)") { vorlage("Morgen-Briefing", "07:30", [0, 1, 2, 3, 4], "anruf", true, "") }
                        Button("🌙 Gute-Nacht (täglich 22:30)") { vorlage("Gute Nacht", "22:30", Array(0...6), "mitteilung", true, "Schlaf gut – ich pass auf deine Aufträge auf.") }
                        Button("💧 Wasser trinken (täglich 15:00)") { vorlage("Wasser trinken", "15:00", Array(0...6), "mitteilung", false, "Zeit für ein Glas Wasser!") }
                        Button("📊 Wochenrückblick (Sonntag 18:00, Anruf)") { vorlage("Wochenrückblick", "18:00", [6], "anruf", true, "Lass uns kurz auf deine Woche schauen.") }
                    } label: { Label("Vorlage verwenden", systemImage: "wand.and.stars") }
                }
            }
            .scrollContentBackground(.hidden)
            .nxHintergrund()
            .navigationTitle("Routinen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(item: $bearbeiten) { r in
                RoutineBearbeiten(routine: r) { neu in
                    if let i = liste.firstIndex(where: { $0.id == neu.id }) { liste[i] = neu } else { liste.append(neu) }
                    Task { await sichern() }
                }
            }
            .task { await laden() }
        }
    }

    private func vorlage(_ n: String, _ z: String, _ t: [Int], _ a: String, _ b: Bool, _ text: String) {
        var r = Routine(); r.name = n; r.zeit = z; r.tage = t; r.art = a; r.briefing = b; r.text = text
        bearbeiten = r
    }

    private func laden() async {
        defer { laedt = false }
        guard let c = studio.client, let w = try? await c.get("/api/begleiter/routinen", JSONWert.self) else { return }
        liste = (w["routinen"]?.liste ?? []).compactMap(Routine.init)
    }

    private func sichern() async {
        guard let c = studio.client else { return }
        do {
            let w = try await c.post("/api/begleiter/routinen", ["routinen": liste.map(\.json)])
            liste = (w["routinen"]?.liste ?? []).compactMap(Routine.init)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { studio.meldung = error.localizedDescription }
    }
}

@MainActor
struct RoutineBearbeiten: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine
    let fertig: (Routine) -> Void
    @State private var vorschau: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $routine.name) }
                Section("Wann") {
                    DatePicker("Uhrzeit", selection: $routine.datum, displayedComponents: .hourAndMinute)
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { t in
                            let an = routine.tage.contains(t)
                            Button(Routine.kurz[t]) {
                                if an { routine.tage.removeAll { $0 == t } } else { routine.tage.append(t); routine.tage.sort() }
                            }
                            .font(.caption.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(an ? AnyShapeStyle(Farbe.verlauf) : AnyShapeStyle(Farbe.karte), in: Capsule())
                            .foregroundStyle(an ? .white : .primary)
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Wie") {
                    Picker("Art", selection: $routine.art) {
                        Label("Anruf", systemImage: "phone.fill").tag("anruf")
                        Label("Mitteilung", systemImage: "bell.fill").tag("mitteilung")
                    }
                    .pickerStyle(.segmented)
                    Toggle("Briefing: was fertig wurde, was läuft", isOn: $routine.briefing)
                    TextField("Eigener Text (optional)", text: $routine.text, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Button { Task { await testen() } } label: { Label("Vorschau: was würde sie jetzt sagen?", systemImage: "text.bubble") }
                    if let vorschau { Text(vorschau).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { fertig(routine); dismiss() }.disabled(routine.tage.isEmpty || (!routine.briefing && routine.text.isEmpty))
                }
            }
        }
    }

    private func testen() async {
        guard let c = studio.client else { return }
        vorschau = (try? await c.post("/api/begleiter/routinen/test", ["briefing": routine.briefing, "text": routine.text]))?["text"]?.text ?? "PC nicht erreichbar"
    }
}
