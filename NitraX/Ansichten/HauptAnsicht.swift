import SwiftUI
import AudioToolbox
import AppIntents

@MainActor
struct HauptAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    @State private var vorladen = false
    @State private var neuZeigen = false

    var body: some View {
        TabView(selection: $navigation.reiter) {
            StudioAnsicht()
                .tabItem { Label("Studio", systemImage: "sparkles") }
                .tag(Navigation.Reiter.studio)
            ErstellenAnsicht()
                .tabItem { Label("Erstellen", systemImage: "plus.square.on.square") }
                .tag(Navigation.Reiter.erstellen)
            AuftraegeAnsicht()
                .tabItem { Label("Aufträge", systemImage: "square.stack.3d.up") }
                .badge(studio.stand.auftraege.filter { $0.laeuft }.count)
                .tag(Navigation.Reiter.auftraege)
            ChatListeAnsicht()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(Navigation.Reiter.chat)
            HelferAnsicht()
                .tabItem { Label("Helfer", systemImage: "person.wave.2.fill") }
                .tag(Navigation.Reiter.helfer)
        }
        .modifier(SeitenleisteAufIPad())
        .sheet(isPresented: $neuZeigen, onDismiss: { WasIstNeu.gesehen() }) { WasIstNeu() }     // ✨ einmal je Version
        .task { try? await Task.sleep(for: .seconds(1.5)); if WasIstNeu.faellig { neuZeigen = true } }
        .overlay(alignment: .bottom) { MiniSpieler().padding(.bottom, 56) }      // 🎵 läuft Musik: kleine Leiste
        .animation(.spring(duration: 0.35), value: Musikspieler.shared.aktuell?.id)
        .background {
            // 🧍 Liste Nr. 10: Helfer-Figur 25 s nach dem Start unsichtbar vorladen -> der Helfer-Tab ist danach sofort da
            if vorladen, let url = AnrufDienst.shared.helferURL {
                VideoHelferWeb(url: url) { _ in }.frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            guard navigation.reiter != .helfer else { return }
            vorladen = true
            try? await Task.sleep(for: .seconds(25))
            vorladen = false
        }
        .overlay(alignment: .top) {
            if let m = studio.meldung {
                Text(m)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: m) {
                        try? await Task.sleep(for: .seconds(3.5))
                        withAnimation { studio.meldung = nil }
                    }
                    .onTapGesture { studio.meldung = nil }
            }
        }
        .animation(.spring(duration: 0.35), value: studio.meldung)
        // ✨ Fertig-Moment: Haptik + kurzes Aufleuchten, wenn ein Auftrag fertig wird
        .sensoryFeedback(.success, trigger: fertigZahl)
        .overlay {
            if leuchten {
                RadialGradient(colors: [Farbe.akzent2.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 500)
                    .ignoresSafeArea().allowsHitTesting(false).transition(.opacity)
            }
        }
        .onChange(of: fertigZahl) { alt, neu in
            guard neu > alt, alt > 0 else { return }
            FertigKlang.spielen()                                    // 🔔 kurzer NitraX-Klang (hält sich an den Lautlos-Schalter)
            withAnimation(.easeOut(duration: 0.3)) { leuchten = true }
            withAnimation(.easeIn(duration: 0.9).delay(0.4)) { leuchten = false }
        }
    }

    @State private var leuchten = false
    private var fertigZahl: Int { studio.stand.auftraege.filter { $0.fertig }.count }
}

@MainActor
struct StudioAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    @State private var einstellungen = false
    @State private var wartendeFrage = false
    @AppStorage("siri_tipp") private var siriTipp = true

    private var laufend: [Auftrag] { studio.stand.auftraege.filter { $0.laeuft } }
    private var wartend: [Auftrag] { studio.stand.auftraege.filter { $0.wartet } }
    private var zuletzt: [Auftrag] {
        Array(studio.stand.auftraege.filter { $0.fertig }.sorted { ($0.finished ?? 0) > ($1.finished ?? 0) }.prefix(8))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NXWortmarke(hoehe: 50)                              // ✨ animiertes Logo wie am PC
                        .padding(.leading, 6).padding(.top, 2).padding(.bottom, 4)
                    BuehneKarte()
                    pcKarte
                    WerkstattKarte()                               // 🛠 Hintergrundarbeit sichtbar
                    SiriTipView(intent: HelferGespraech(), isVisible: $siriTipp).siriTipViewStyle(.dark)
                    if !studio.stand.fremd.isEmpty { spielHinweis }
                    if !laufend.isEmpty || !wartend.isEmpty { warteschlange }
                    if !zuletzt.isEmpty { zuletztFertig }
                    schnellstart
                }
                .padding(16)
            }
            .nxHintergrund()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Logo mit kreisendem Lichtrand wie am PC
                ToolbarItem(placement: .topBarTrailing) {
                    Button { einstellungen = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $einstellungen) { EinstellungenAnsicht() }
            .refreshable { await studio.aktualisieren() }
            .navigationDestination(for: Auftrag.self) { AuftragDetail(auftrag: $0) }
        }
    }

    private var pcKarte: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(studio.erreichbar ? Farbe.gut.opacity(0.18) : Farbe.fehler.opacity(0.18)).frame(width: 46, height: 46)
                Image(systemName: studio.erreichbar ? "desktopcomputer" : "wifi.exclamationmark")
                    .foregroundStyle(studio.erreichbar ? Farbe.gut : Farbe.fehler)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(studio.erreichbar ? "PC verbunden" : "PC nicht erreichbar").font(.headline)
                if studio.erreichbar {
                    Text(gpuText).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("1. NitraX am PC gestartet?  2. PC wach (nicht im Standby)?  3. Gleiches WLAN – unterwegs Tailscale an?")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !studio.erreichbar {
                // 🩺 warum? (Netz, Adresse, Schlüssel, Firewall …)
                NavigationLink { VerbindungsDoktor() } label: {
                    Image(systemName: "stethoscope").font(.headline).padding(10).background(Farbe.karte, in: Circle())
                }
                .buttonStyle(.plain)
                // 🔄 sofort neu suchen (WLAN-Adresse und Tailscale)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { _ = await studio.client?.basisFinden(); await studio.aktualisieren() }
                } label: { Image(systemName: "arrow.clockwise").font(.headline).padding(10).background(Farbe.karte, in: Circle()) }
                .buttonStyle(.plain)
            }
        }
        .karte()
    }

    private var gpuText: String {
        var t = studio.stand.engineBereit ? "Engine bereit" : "Engine startet …"
        if let g = studio.stand.gpuAuslastung { t += " · GPU \(g) %" }
        if let v = studio.stand.vram, let vg = studio.stand.vramGesamt { t += String(format: " · %.1f/%.0f GB", v, vg) }
        return t
    }

    private var spielHinweis: some View {
        Label("Am PC läuft gerade \(studio.stand.fremd.joined(separator: ", ")) – Aufträge warten, bis die Grafikkarte frei ist.",
              systemImage: "gamecontroller")
            .font(.footnote)
            .foregroundStyle(Farbe.warn)
            .karte()
    }

    private var warteschlange: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Läuft gerade").font(.title3.bold())
                Spacer()
                Menu {
                    Button(studio.angehalten ? "Warteschlange fortsetzen" : "Warteschlange anhalten",
                           systemImage: studio.angehalten ? "play.fill" : "pause.fill") {
                        Task { await studio.warteschlange(anhalten: !studio.angehalten) }
                    }
                    if studio.stand.auftraege.filter({ $0.nieGestartet }).count >= 1 {
                        Button("Wartende abbrechen", systemImage: "xmark.circle", role: .destructive) { wartendeFrage = true }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            }
            ForEach(laufend) { a in
                NavigationLink(value: a) { LaufKarte(a: a) }.buttonStyle(.plain)
            }
            if !wartend.isEmpty {
                Text("\(wartend.count) in der Warteschlange").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("\(studio.stand.auftraege.filter { $0.nieGestartet }.count) wartende Aufträge abbrechen? Der laufende rechnet weiter, nichts wird gelöscht.",
                            isPresented: $wartendeFrage, titleVisibility: .visible) {
            Button("Wartende abbrechen", role: .destructive) {
                Task { let n = await studio.wartendeAbbrechen(); studio.meldung = "\(n) wartende Aufträge abgebrochen" }
            }
        }
    }

    private var zuletztFertig: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zuletzt fertig").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(zuletzt) { a in
                        NavigationLink(value: a) {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    NXBild(url: studio.vorschauURL(a))
                                    if studio.vorschauURL(a) == nil { Image(systemName: a.symbol).font(.title) }
                                }
                                .frame(width: 150, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Text(a.titel).font(.caption.weight(.medium)).lineLimit(1).frame(width: 150, alignment: .leading)
                                Text(a.artName).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var schnellstart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schnell erstellen").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(["i2v", "x-t2i", "x-track", "x-music"], id: \.self) { id in
                    if let w = studio.workflows?.workflows.first(where: { $0.id == id }) {
                        NavigationLink { WorkflowFormular(workflow: w) } label: {
                            HStack {
                                Text(w.glyph).font(.title2)
                                Text(w.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .karte()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await studio.workflowsLaden() }
    }
}

@MainActor
struct LaufKarte: View {
    @EnvironmentObject private var studio: Studio
    var a: Auftrag
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                NXBild(url: studio.vorschauURL(a))
                if studio.vorschauURL(a) == nil { Image(systemName: a.symbol) }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(a.titel).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(standText(a)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Fortschrittsbalken(wert: a.progress)
            }
        }
        .karte()
    }
}


/// 🔔 NitraX-Klang beim Fertig-Moment (Systemton: leise, beachtet den Lautlos-Schalter, abschaltbar)
enum FertigKlang {
    private static let id: SystemSoundID? = {
        guard let u = Bundle.main.url(forResource: "fertig", withExtension: "wav") else { return nil }
        var i: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(u as CFURL, &i) == noErr ? i : nil
    }()

    static func spielen() {
        guard UserDefaults.standard.object(forKey: "fertig_klang") as? Bool ?? true, !Ruhezeit.aktiv(), let id else { return }
        AudioServicesPlaySystemSound(id)
    }
}


/// 🖥 iPad: Tabs werden zur Seitenleiste wie am PC (iOS 18+), iPhone bleibt bei der Tab-Leiste
struct SeitenleisteAufIPad: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.tabViewStyle(.sidebarAdaptable) } else { content }
    }
}
