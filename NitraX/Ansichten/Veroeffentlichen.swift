import SwiftUI
import UIKit

/// 📤 Gesamtplan 5b: Fertig zum Veröffentlichen – Format, Länge, Lautheit, Untertitel, Titelbild, Text + Hashtags (macht der PC)
@MainActor
struct VeroeffentlichenAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let auftragID: String
    @State private var plattform = "tiktok"
    @State private var untertitel = true
    @State private var sprache = "de"
    @State private var startet = false
    @State private var teilen: [URL] = []
    @State private var laedt: String?

    private var a: Auftrag? { studio.stand.auftraege.first { $0.id == auftragID } }
    private var eintraege: [JSONWert] { (a?.veroeffentlicht ?? []).reversed() }

    static let plattformen: [(String, String, String)] = [("tiktok", "TikTok", "9:16 · bis 10 min"), ("reels", "Instagram Reels", "9:16 · bis 90 s"),
                                                         ("shorts", "YouTube Shorts", "9:16 · bis 60 s"), ("youtube", "YouTube", "16:9")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Plattform", selection: $plattform) {
                        ForEach(Self.plattformen, id: \.0) { p in Text("\(p.1) · \(p.2)").tag(p.0) }
                    }
                    Toggle("Untertitel aus dem Ton einbrennen", isOn: $untertitel)
                    Picker("Sprache für Text & Hashtags", selection: $sprache) { Text("Deutsch").tag("de"); Text("Englisch").tag("en") }
                        .pickerStyle(.segmented)
                    Button { Task { await starten() } } label: {
                        HStack { Spacer(); if startet { ProgressView() } else { Label("Fertig machen", systemImage: "paperplane.fill").font(.headline) }; Spacer() }
                    }
                    .disabled(startet)
                } footer: {
                    Text("Der PC passt Format und Länge an, gleicht die Lautstärke an (-14 LUFS), macht ein Titelbild und schreibt Titel, Beschreibung und Hashtags. Das Original bleibt unverändert.")
                }
                ForEach(eintraege.indices, id: \.self) { i in
                    eintrag(eintraege[i])
                }
            }
            .scrollContentBackground(.hidden)
            .nxHintergrund()
            .navigationTitle("📤 Veröffentlichen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: Binding(get: { !teilen.isEmpty }, set: { if !$0 { teilen = [] } })) {
                TeilenBlatt(dateien: teilen).presentationDetents([.medium, .large])
            }
            .task { while !Task.isCancelled { if eintraege.contains(where: { $0["status"]?.text == "läuft" }) { await studio.aktualisieren() }; try? await Task.sleep(for: .seconds(3)) } }
        }
    }

    @ViewBuilder private func eintrag(_ e: JSONWert) -> some View {
        let st = e["status"]?.text ?? ""
        Section(e["name"]?.text ?? "") {
            if st == "läuft" {
                HStack { ProgressView(); Text(e["stufe"]?.text ?? "läuft …").font(.subheadline) }
            } else if st == "fehler" {
                Label(e["fehler"]?.text ?? "Fehler", systemImage: "exclamationmark.triangle").foregroundStyle(Farbe.fehler).font(.footnote)
            } else if let datei = e["datei"]?.text {
                HStack(alignment: .top, spacing: 12) {
                    if let c = e["cover"]?.text {
                        NXBild(url: studio.url("/api/export/" + c), modus: .fill).frame(width: 74, height: 110).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e["titel"]?.text ?? "").font(.subheadline.weight(.semibold))
                        Text(e["text"]?.text ?? "").font(.caption)
                        Text((e["hashtags"]?.liste ?? []).compactMap(\.text).joined(separator: " ")).font(.caption).foregroundStyle(Farbe.akzent)
                        if e["gekuerzt"]?.wahr == true { Text("auf \(Int(e["dauer"]?.zahl ?? 0)) s gekürzt").font(.caption2).foregroundStyle(Farbe.warn) }
                    }
                }
                Button { kopieren(e) } label: { Label("Text + Hashtags kopieren", systemImage: "doc.on.doc") }
                Button { Task { await holen(datei, sichern: false) } } label: {
                    Label(laedt == datei ? "Lädt …" : "Video teilen (z. B. an \(e["name"]?.text ?? "die App"))", systemImage: "square.and.arrow.up")
                }
                .disabled(laedt != nil)
                Button { Task { await holen(datei, sichern: true) } } label: { Label("In Fotos sichern", systemImage: "photo.badge.arrow.down") }
                    .disabled(laedt != nil)
            }
        }
    }

    private func starten() async {
        guard let c = studio.client else { return }
        startet = true
        defer { startet = false }
        do {
            _ = try await c.post("/api/jobs/\(auftragID)/veroeffentlichen", ["plattform": plattform, "untertitel": untertitel, "sprache": sprache])
            await studio.aktualisieren()
        } catch { studio.meldung = error.localizedDescription }
    }

    private func kopieren(_ e: JSONWert) {
        let tags = (e["hashtags"]?.liste ?? []).compactMap(\.text).joined(separator: " ")
        UIPasteboard.general.string = [e["titel"]?.text, e["text"]?.text, tags].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        studio.meldung = "📋 Text kopiert – beim Posten einfach einfügen"
    }

    private func holen(_ datei: String, sichern: Bool) async {
        guard let c = studio.client else { return }
        laedt = datei
        defer { laedt = nil }
        do {
            let u = try await Herunterladen.datei(c, pfad: "/api/export/" + datei, name: datei)
            if sichern { try await Herunterladen.inFotos(u, video: true); studio.meldung = "In Fotos gesichert" } else { teilen = [u] }
        } catch { studio.meldung = error.localizedDescription }
    }
}
