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
    @AppStorage("fertig_klang") private var fertigKlang = true
    @AppStorage("echo_aec") private var echoAEC = false
    @AppStorage("stimme_strom") private var stimmeStrom = false
    @AppStorage("spar_modus") private var sparModus = "auto"
    @State private var ruheAn = Ruhezeit.an
    @State private var ruheVon = EinstellungenAnsicht.datum(Ruhezeit.von)
    @State private var ruheBis = EinstellungenAnsicht.datum(Ruhezeit.bis)

    static func datum(_ s: String) -> Date {
        let t = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: t.first ?? 22, minute: t.count > 1 ? t[1] : 0, second: 0, of: Date()) ?? Date()
    }
    static func text(_ d: Date) -> String { d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }

    private func ruheSpeichern() {
        Ruhezeit.setzen(an: ruheAn, von: Self.text(ruheVon), bis: Self.text(ruheBis))
        if let c = studio.client { Task { await Ruhezeit.senden(c) } }
    }
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
                    NavigationLink { VerbindungsDoktor() } label: { Label("Verbindung prüfen", systemImage: "stethoscope") }
                    NavigationLink { GeraeteAnsicht() } label: { Label("Geräte & Schlüssel", systemImage: "lock.shield") }
                    NavigationLink { SelbsttestAnsicht() } label: {
                        HStack {
                            Label("Selbsttest", systemImage: "checklist")
                            Spacer()
                            let t = Selbsttest.shared
                            if t.probleme > 0 { Text("\(t.probleme) Problem\(t.probleme == 1 ? "" : "e")").font(.caption).foregroundStyle(Farbe.fehler) }
                            else if !t.punkte.isEmpty { Text("in Ordnung").font(.caption).foregroundStyle(Farbe.gut) }
                        }
                    }
                } header: { Text("PC-Verbindung") } footer: {
                    Text("Die App nimmt automatisch die erste erreichbare Adresse – zu Hause das WLAN, unterwegs Tailscale.")
                }

                Section("Mitteilungen") {
                    Toggle("Bei fertigen Aufträgen und Nachrichten vom Helfer", isOn: $mitteilungen)
                    Toggle("🔇 Echo-Unterdrückung im Anruf (experimentell)", isOn: $echoAEC)
                    Toggle("⚡ Ihre Stimme sofort abspielen (experimentell)", isOn: $stimmeStrom)
                    Toggle("🔔 Klang, wenn ein Auftrag fertig wird", isOn: $fertigKlang)
                        .onChange(of: fertigKlang) { _, an in if an { FertigKlang.spielen() } }
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

                Section {
                    Toggle("Ruhezeiten", isOn: $ruheAn)
                    if ruheAn {
                        DatePicker("Von", selection: $ruheVon, displayedComponents: .hourAndMinute)
                        DatePicker("Bis", selection: $ruheBis, displayedComponents: .hourAndMinute)
                    }
                } header: { Text("🌙 Ruhezeiten") } footer: {
                    Text("Dann keine Meldungen und keine Anrufe vom Helfer, fertige Aufträge kommen leise. Anrufe, die du selbst für eine Uhrzeit bestellt hast (»ruf mich um 7 an«), klingeln trotzdem.")
                }
                .onChange(of: ruheAn) { _, _ in ruheSpeichern() }
                .onChange(of: ruheVon) { _, _ in ruheSpeichern() }
                .onChange(of: ruheBis) { _, _ in ruheSpeichern() }

                Section {
                    Picker("📶 Sparmodus", selection: $sparModus) {
                        Text("Automatisch (Mobilfunk)").tag("auto")
                        Text("Immer").tag("an")
                        Text("Aus").tag("aus")
                    }
                } footer: {
                    Text("Kleinere Vorschaubilder, Videos erst beim Antippen, kein Vorladen der Offline-Galerie, Helfer mit 30 statt 60 Bildern pro Sekunde – schont Akku und Datenvolumen.")
                }

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
