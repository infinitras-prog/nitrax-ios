import SwiftUI

/// 🩺 Gesamtplan 5c: alles Wichtige auf einen Blick – Grafikkarte, was geladen ist, Aufträge, Werkstatt, Sicherung,
/// letzte Fehler und Anrufe. Aktualisiert sich alle 5 s.
@MainActor
struct SystemzustandAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var z: JSONWert?
    @State private var fehler: String?
    @State private var sichert = false

    var body: some View {
        List {
            if let fehler { Section { Label(fehler, systemImage: "exclamationmark.triangle").foregroundStyle(Farbe.warn) } }
            if let z {
                Section("Grafikkarte") {
                    zeile("Auslastung", z["gpu"]?["util"]?.zahl.map { "\(Int($0)) %" } ?? "–")
                    zeile("Speicher", Self.vram(z))
                    let fremd = z["fremd"]?.liste?.compactMap(\.text) ?? []
                    zeile("Fremde Programme", fremd.isEmpty ? "keine" : fremd.joined(separator: ", "), warn: !fremd.isEmpty)
                }
                Section("Geladen") {
                    zeile("Engine", z["engine"]?.wahr == true ? "läuft" : "aus", warn: z["engine"]?.wahr != true)
                    let sm = z["sprachmodell"]
                    zeile("Sprachmodell", sm?["laeuft"]?.wahr == true ? "\(sm?["modell"]?.text ?? "?") · \(sm?["grafikkarte"]?.wahr == true ? "Grafikkarte" : "Prozessor")" : "nicht geladen")
                    zeile("Anrufstimme", z["stimme_geladen"]?.wahr == true ? "geladen" : "nicht geladen")
                    zeile("Regie rechnet", z["regie_rechnet"]?.wahr == true ? "ja" : "nein")
                }
                Section("Aufträge") {
                    let a = z["auftraege"]
                    zeile("Laufen / warten", "\(Int(a?["laufen"]?.zahl ?? 0)) / \(Int(a?["warten"]?.zahl ?? 0))")
                    zeile("Fehler (24 h)", "\(Int(a?["fehler_24h"]?.zahl ?? 0))", warn: (a?["fehler_24h"]?.zahl ?? 0) > 0)
                    if z["warteschlange_pausiert"]?.wahr == true { zeile("Warteschlange", "angehalten (\(z["pause_grund"]?.text ?? ""))", warn: true) }
                    let st = z["stichworte"]
                    zeile("Bildinhalte beschrieben", "\(Int(st?["beschrieben"]?.zahl ?? 0)) von \(Int(st?["bilder"]?.zahl ?? 0))")
                }
                Section("Werkstatt") {
                    if let t = z["werkstatt"]?["arbeit"]?["text"]?.text { zeile("Arbeitet gerade", t) } else { zeile("Arbeitet gerade", "nichts") }
                    if let p = z["werkstatt"]?["plan"], let s = p["status"]?.text {
                        zeile("Mehrschritt-Plan", "Schritt \(Int(p["aktuell"]?.zahl ?? 0) + 1)/\(Int(p["schritte"]?.zahl ?? 0)) · \(s)", warn: s == "fehler")
                    }
                    if let k = z["werkstatt"]?["kette"], let s = k["status"]?.text {
                        zeile("Kette »\(k["titel"]?.text ?? "")«", s + (k["fehler"]?.text.map { " – " + $0 } ?? ""), warn: s == "fehler")
                    }
                }
                Section("Datensicherung") {
                    let s = z["sicherung"]
                    zeile("Zuletzt", s?["zuletzt"]?.zahl.map { Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)) } ?? "noch nie",
                          warn: (s?["zuletzt"]?.zahl ?? 0) < Date().timeIntervalSince1970 - 2 * 86400)
                    zeile("Stände", "\(Int(s?["anzahl"]?.zahl ?? 0)) von 7" + (s?["neueste_mb"]?.zahl.map { String(format: " · %.0f MB", $0) } ?? ""))
                    Button { Task { await sichern() } } label: { if sichert { ProgressView() } else { Label("Jetzt sichern", systemImage: "externaldrive.badge.checkmark") } }
                        .disabled(sichert)
                    if let p = z["platte"], let f = p["frei_gb"]?.zahl { zeile("Platte frei", "\(Int(f)) GB", warn: f < 50) }
                }
                if let r = z["ruhezeit"], r["an"]?.wahr == true {
                    Section("Ruhezeit") { zeile("\(r["von"]?.text ?? "") – \(r["bis"]?.text ?? "")", r["aktiv"]?.wahr == true ? "gerade aktiv" : "nicht aktiv") }
                }
                let fe = z["handy_fehler"]?.liste?.compactMap(\.text) ?? []
                if !fe.isEmpty {
                    Section("Letzte Meldungen vom Handy") { ForEach(fe.indices, id: \.self) { Text(fe[$0]).font(.caption2.monospaced()).lineLimit(3) } }
                }
                let an = z["anrufe"]?.liste?.compactMap(\.text) ?? []
                if !an.isEmpty { Section("Letzte Anrufe") { ForEach(an.indices, id: \.self) { Text(an[$0]).font(.caption.monospaced()) } } }
            } else if fehler == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .nxHintergrund()
        .navigationTitle("Systemzustand")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await laden()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    static func vram(_ z: JSONWert) -> String {
        guard let v = z["gpu"]?["vram"]?.zahl, let g = z["gpu"]?["vram_total"]?.zahl else { return "–" }
        return String(format: "%.1f / %.0f GB", v, g)
    }

    private func zeile(_ titel: String, _ wert: String, warn: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(titel)
            Spacer(minLength: 12)
            Text(wert).foregroundStyle(warn ? Farbe.warn : .secondary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func laden() async {
        guard let c = studio.client else { return }
        do { z = try await c.get("/api/system/zustand", JSONWert.self); fehler = nil }
        catch NXFehler.server(let code, _) where code == 403 || code == 404 { fehler = "Das PC-Programm ist älter als die App – bitte NitraX am PC aktualisieren." }
        catch { fehler = error.localizedDescription }
    }

    private func sichern() async {
        guard let c = studio.client else { return }
        sichert = true
        defer { sichert = false }
        do {
            let r = try await c.post("/api/sicherung/jetzt", [:], zeit: 300)
            studio.meldung = "💾 Gesichert: \(r["name"]?.text ?? "")"
            await laden()
        } catch { studio.meldung = error.localizedDescription }
    }
}

/// 🛠 Gesamtplan 1a am iPhone: was die Werkstatt im Hintergrund gerade tut (Filmplanung, Schritte eines Plans …)
@MainActor
struct WerkstattKarte: View {
    @EnvironmentObject private var studio: Studio
    @State private var w: JSONWert?

    var body: some View {
        Group {
            if let a = w?["arbeit"], let t = a["text"]?.text, !t.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView().tint(Farbe.akzent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("🛠 Die Werkstatt arbeitet").font(.subheadline.weight(.semibold))
                        Text(t).font(.caption).foregroundStyle(.secondary)
                        if let seit = a["seit"]?.zahl {
                            Text("seit " + Date(timeIntervalSince1970: seit).formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let p = w?["plan"], p["status"]?.text == "laeuft", let sch = p["schritte"]?.liste {
                            let i = Int(p["aktuell"]?.zahl ?? 0)
                            Text("Plan: Schritt \(i + 1) von \(sch.count)").font(.caption2.weight(.semibold)).foregroundStyle(Farbe.akzent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .karte()
            } else if let p = w?["plan"], p["status"]?.text == "fehler" {
                Label("Ein Mehrschritt-Auftrag ist hängen geblieben: \(p["fehler"]?.text ?? "") – sag dem Helfer »mach weiter«.",
                      systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Farbe.warn).karte()
            }
        }
        .task {
            while !Task.isCancelled {
                if let c = studio.client { w = try? await c.get("/api/begleiter/werkstatt", JSONWert.self) }
                try? await Task.sleep(for: .seconds(w?["arbeit"] != nil ? 5 : 15))
            }
        }
    }
}
