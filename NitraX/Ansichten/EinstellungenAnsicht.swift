import SwiftUI

@MainActor
struct EinstellungenAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State private var scannen = false
    @State private var mitteilungen = Benachrichtigungen.an
    @State private var trennenFrage = false
    @State private var push: Push.Stand?
    @State private var testLaeuft = false
    @AppStorage("faceid_an") private var faceID = false
    @State private var live = LiveAktivitaeten.an

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(studio.verbindung?.adressen ?? [], id: \.self) { a in
                        HStack {
                            Image(systemName: a.hasPrefix("https") ? "lock.shield" : "wifi")
                                .foregroundStyle(a == studio.client?.aktuelleBasis ? Farbe.gut : .secondary)
                            Text(a).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                            if a == studio.client?.aktuelleBasis { Spacer(); Text("aktiv").font(.caption).foregroundStyle(Farbe.gut) }
                        }
                    }
                    Button { scannen = true } label: { Label("Weitere Adresse scannen (z. B. Tailscale)", systemImage: "qrcode.viewfinder") }
                } header: { Text("PC-Verbindung") } footer: {
                    Text("Die App nimmt automatisch die erste erreichbare Adresse – zu Hause das WLAN, unterwegs Tailscale.")
                }

                Section("Mitteilungen") {
                    Toggle("Bei fertigen Aufträgen und Nachrichten vom Helfer", isOn: $mitteilungen)
                        .onChange(of: mitteilungen) { _, an in Benachrichtigungen.an = an }
                    if Push.token == nil {
                        Label("Noch nicht für Sofort-Push angemeldet", systemImage: "bell.slash").foregroundStyle(Farbe.warn)
                        Button("Mitteilungen erlauben") { Benachrichtigungen.erlaubnisHolen() }
                    } else if let p = push, p.eingerichtet {
                        Label("Sofort-Push aktiv · \(p.geraete.count) Gerät\(p.geraete.count == 1 ? "" : "e") am PC", systemImage: "bell.badge.fill")
                            .foregroundStyle(Farbe.gut)
                        Button {
                            Task {
                                guard let c = studio.client else { return }
                                testLaeuft = true
                                defer { testLaeuft = false }
                                do { studio.meldung = try await Push.test(c) ? "🔔 Test-Push unterwegs" : "Apple hat den Push abgelehnt" }
                                catch { studio.meldung = error.localizedDescription }
                            }
                        } label: { testLaeuft ? AnyView(ProgressView()) : AnyView(Text("Test-Push senden")) }
                    } else if push != nil {
                        Label("Am PC noch einrichten: NitraX → Einstellungen → Handy → iPhone-Push", systemImage: "desktopcomputer")
                            .font(.footnote)
                    }
                    Text(Push.aktiv ? "Der PC schickt Mitteilungen sofort – auch wenn die App zu ist."
                                    : "Ohne Sofort-Push schaut iOS im Hintergrund etwa alle 15–60 Minuten nach – solange die App offen ist, sofort.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .task { if let c = studio.client { push = await Push.stand(c) } }

                Section("iPhone") {
                    Picker("App-Symbol", selection: Binding(get: { UIApplication.shared.alternateIconName ?? "" }, set: { neu in
                        UIApplication.shared.setAlternateIconName(neu.isEmpty ? nil : neu) { _ in }
                    })) {
                        Text("✨ Original").tag("")
                        Text("🌈 Neon").tag("AppIcon-Neon")
                        Text("🌑 Dunkel").tag("AppIcon-Dunkel")
                    }
                    Toggle("Mit Face ID schützen", isOn: $faceID)
                    Toggle("Live-Aktivität (Sperrbildschirm & Dynamic Island)", isOn: $live)
                        .onChange(of: live) { _, an in LiveAktivitaeten.an = an }
                }

                ModellAbschnitt()

                Section("Studio") {
                    Button(studio.angehalten ? "Warteschlange fortsetzen" : "Warteschlange anhalten") {
                        Task { await studio.warteschlange(anhalten: !studio.angehalten) }
                    }
                    if let g = studio.stand.gpuName { LabeledContent("Grafikkarte", value: g) }
                }

                Section {
                    Button("Verbindung trennen", role: .destructive) { trennenFrage = true }
                } footer: {
                    Text("NitraX \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: $scannen) {
                QRScanner { text in
                    scannen = false
                    if let v = Verbindung.ausLink(text) { studio.verbinden(v); studio.meldung = "Adresse ergänzt" }
                }
                .ignoresSafeArea()
            }
            .confirmationDialog("Verbindung zum PC trennen? Zum Wiederverbinden den QR-Code neu scannen.", isPresented: $trennenFrage, titleVisibility: .visible) {
                Button("Trennen", role: .destructive) { studio.trennen(); dismiss() }
            }
        }
    }
}
