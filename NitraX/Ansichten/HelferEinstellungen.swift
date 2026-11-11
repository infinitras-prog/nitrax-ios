import SwiftUI

/// ⚙ Helfer anpassen (wie am PC): Name, Persönlichkeit, Stimme, Über mich, Sprechen, Verhalten, Augen.
/// Aussehen, PC-Steuerung und Desktop-Funktionen bleiben am PC (der PC lässt sie vom Handy aus nicht ändern).
@MainActor
struct HelferEinstellungen: View, Equatable {
    // 11.11.2026: die Helfer-Ansicht dahinter zeichnet sich ständig neu (Mikrofon-Pegel, Kamera) – das darf dieses Formular
    // nicht mitreißen (offene Auswahl schloss sich, Liste sprang nach oben). Eingaben ändern sich nie -> immer »gleich«.
    nonisolated static func == (a: HelferEinstellungen, b: HelferEinstellungen) -> Bool { true }
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    var gespeichert: () -> Void

    @AppStorage("helfer_augen") private var augenIPhone = true
    @State private var laedt = true
    @State private var speichert = false
    @State private var fehler: String?
    @State private var e: [String: JSONWert] = [:]
    @State private var original: [String: JSONWert] = [:]
    @State private var arten: [[String]] = []
    @State private var stimmen: [[String]] = []
    @State private var modelle: [ModellListe.Modell] = []

    var body: some View {
        NavigationStack {
            Form {
                if laedt {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Section("Wer ist sie?") {
                        LabeledContent("Name") { TextField("Name", text: text("name")).multilineTextAlignment(.trailing) }
                        Picker("Persönlichkeit", selection: text("art")) {
                            ForEach(arten, id: \.self) { a in Text(a.count > 1 ? a[1] : a[0]).tag(a[0]) }
                        }
                        Picker("Stimme", selection: text("stimme")) {
                            Text("Standard").tag("")
                            ForEach(stimmen, id: \.self) { s in Text(s[1]).tag(s[0]) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Über mich").font(.subheadline)
                            TextField("Vorlieben, Eigenheiten, Hintergrund …", text: text("ueber_mich"), axis: .vertical).lineLimit(3...8)
                        }
                    }
                    Section {
                        Picker("Denkt mit", selection: text("modell")) {
                            Text("Standard der App").tag("")
                            ForEach(modelle) { Text($0.zeile).tag($0.id) }
                        }
                        Picker("Sieht mit (Kamera, Bilder)", selection: text("modell_sehen")) {
                            Text("automatisch").tag("")
                            ForEach(modelle.filter { $0.sieht }) { Text($0.zeile).tag($0.id) }
                        }
                    } header: { Text("Modell") } footer: {
                        Text("Kleinere Modelle antworten schneller, größere klüger. 👁 = kann Bilder sehen, 💭 = denkt vorher nach (langsamer).")
                    }
                    Section("Sprechen") {
                        Toggle("Spricht laut", isOn: schalter("sprechen"))
                        LabeledContent("Lautstärke") {
                            Slider(value: zahl("lautstaerke", 0.9), in: 0.1...1).frame(maxWidth: 180)
                        }
                        Picker("Redet von selbst", selection: text("plaudern")) {
                            Text("still").tag("still"); Text("normal").tag("normal"); Text("gesprächig").tag("gespraechig")
                        }
                        .pickerStyle(.segmented)
                        Toggle("Echte Emotionsstimme (langsamer)", isOn: schalter("emotion_stimme"))
                    }
                    Section("Verhalten") {
                        Toggle("Fertige Werke kommentieren", isOn: schalter("kommentieren"))
                        Toggle("Nächste Schritte vorschlagen", isOn: schalter("vorschlaege"))
                        Toggle("Mimik spiegeln", isOn: schalter("mimik"))
                        Toggle("Überraschungen", isOn: schalter("ueberraschungen"))
                        Toggle("Beziehung darf romantisch werden", isOn: schalter("romanze"))
                    }
                    Section {
                        Toggle("👁 iPhone-Kamera als Augen", isOn: $augenIPhone)
                        Toggle("👁 PC-Webcam als Augen", isOn: schalter("augen"))
                    } header: { Text("Augen") } footer: {
                        Text("Die Bilder bleiben im Arbeitsspeicher und werden nicht gespeichert. Aussehen, PC-Steuerung und Desktop-Funktionen stellst du am PC ein.")
                    }
                }
            }
            .navigationTitle("Helfer anpassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if speichert { ProgressView() } else { Button("Sichern") { Task { await sichern() } }.disabled(laedt) }
                }
            }
            .alert("Helfer", isPresented: Binding(get: { fehler != nil }, set: { if !$0 { fehler = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(fehler ?? "") }
            .task { await laden() }
        }
    }

    private func text(_ k: String) -> Binding<String> { Binding(get: { e[k]?.text ?? "" }, set: { e[k] = .text($0) }) }
    private func schalter(_ k: String) -> Binding<Bool> { Binding(get: { e[k]?.wahr ?? false }, set: { e[k] = .wahr($0) }) }
    private func zahl(_ k: String, _ standard: Double) -> Binding<Double> { Binding(get: { e[k]?.zahl ?? standard }, set: { e[k] = .zahl($0) }) }

    private func laden() async {
        guard let c = studio.client else { return }
        do {
            let d = try await c.get("/api/begleiter", JSONWert.self)
            e = d["einst"]?.objekt ?? [:]
            original = e
            arten = (d["persoenlichkeiten"]?.liste ?? []).compactMap { $0.liste?.compactMap { $0.text } }.filter { !$0.isEmpty }
            modelle = await ModellListe.chat(c)
            for k in ["modell", "modell_sehen"] {             // gewähltes Modell fehlt in der Liste -> trotzdem anzeigen
                if let w = e[k]?.text, !w.isEmpty, !modelle.contains(where: { $0.id == w }) { modelle.insert(.init(id: w, name: w), at: 0) }
            }
            if let s = try? await c.get("/api/anruf/stimmen", JSONWert.self) {
                let vorlagen = (s["vorlagen"]?.liste ?? []).compactMap { v -> [String]? in
                    guard let id = v["id"]?.text, let n = v["name"]?.text else { return nil }
                    return [id, n + (v["text"]?.text.map { " · " + $0 } ?? "")]
                }
                let eigene = (s["bibliothek"]?.liste ?? []).compactMap { v -> [String]? in
                    guard let id = v["id"]?.text, let n = v["name"]?.text else { return nil }
                    return [id, "📚 " + n]
                }
                stimmen = vorlagen + eigene
                // gewählte Stimme fehlt in der Liste (z. B. gelöscht) -> trotzdem anzeigen
                if let w = e["stimme"]?.text, !w.isEmpty, !stimmen.contains(where: { $0[0] == w }) { stimmen.insert([w, w], at: 0) }
            }
        } catch { fehler = error.localizedDescription }
        laedt = false
    }

    private func sichern() async {
        guard let c = studio.client else { return }
        var aenderung: [String: Any] = [:]
        for (k, v) in e where original[k] != v { aenderung[k] = v.roh }
        guard !aenderung.isEmpty else { dismiss(); return }
        speichert = true
        defer { speichert = false }
        do {
            _ = try await c.post("/api/begleiter/einst", aenderung)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            gespeichert()
            dismiss()
        } catch { fehler = error.localizedDescription }
    }
}
