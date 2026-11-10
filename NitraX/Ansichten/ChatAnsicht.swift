import SwiftUI
import PhotosUI

// 0.5.30: Chat neu gestaltet – drei Agenten oben (Workflow, Code, Chat), Verlauf nach Tagen sortiert mit Filter und Suche,
// hochwertigere Blasen mit Agenten-Symbol, Werkzeug-Schritte als Chips, Code-Agent mit Freigabe direkt im Chat.

struct ChatKopf: Decodable, Identifiable, Hashable {
    var id: String
    var titel: String
    var art: String
    var geaendert: Double?
    var laeuft: Bool?
}

/// Die drei Agenten (Aussehen und Texte an einer Stelle)
enum ChatArt: String, CaseIterable, Identifiable {
    case werkstatt, code, chat
    var id: String { rawValue }

    init(_ art: String) { self = ChatArt(rawValue: art) ?? .chat }

    var name: String {
        switch self { case .werkstatt: return "Workflow-Agent"; case .code: return "Code-Agent"; case .chat: return "Chat" }
    }
    var kurz: String {
        switch self { case .werkstatt: return "Workflow"; case .code: return "Code"; case .chat: return "Chat" }
    }
    var untertitel: String {
        switch self {
        case .werkstatt: return "Videos, Bilder, Songs, Filme anlegen"
        case .code: return "Programmieren & NitraX erweitern"
        case .chat: return "Fragen, Ideen, Bilder"
        }
    }
    var symbol: String {
        switch self { case .werkstatt: return "wand.and.stars"; case .code: return "chevron.left.forwardslash.chevron.right"; case .chat: return "bubble.left.and.bubble.right.fill" }
    }
    var farben: [Color] {
        switch self {
        case .werkstatt: return [Farbe.akzent, Farbe.pink]
        case .code: return [Farbe.mint, Farbe.info]
        case .chat: return [Farbe.info, Farbe.pink]
        }
    }
    var verlauf: LinearGradient { LinearGradient(colors: farben, startPoint: .topLeading, endPoint: .bottomTrailing) }
    var platzhalter: String {
        switch self { case .werkstatt: return "Was soll entstehen?"; case .code: return "Was soll programmiert werden?"; case .chat: return "Nachricht" }
    }
    var leerText: String {
        switch self {
        case .werkstatt: return "Beschreib, was entstehen soll – der Agent plant, startet die Workflows, wartet und bessert selbst nach."
        case .code: return "Programmieren lassen – oder NitraX selbst erweitern: Sag einfach, was NitraX zusätzlich können soll. Er baut es sicher als Erweiterung. Jeden Schritt bestätigst du hier."
        case .chat: return "Frag, was du willst – mit 📷 auch zu einem Bild."
        }
    }
    var beispiele: [String] {
        switch self {
        case .werkstatt: return ["Mach aus meinem letzten Bild ein 10-s-Video mit Regen", "Erstell einen Song und ein Musikvideo dazu", "Ein Werbespot für Sneaker, 20 s, 9:16"]
        case .code: return ["NitraX soll mir jeden Morgen 5 Bildideen vorschlagen", "Bau eine Seite mit Farbpaletten zu einem Stichwort", "Ein kleines Browserspiel mit meiner Figur"]
        case .chat: return ["Gib mir 5 Ideen für ein Musikvideo", "Erklär mir den Unterschied zwischen LTX und Wan", "Schreib einen kurzen Songtext über Regen"]
        }
    }
}

/// Symbol-Kachel eines Agenten
struct AgentKachel: View {
    let art: ChatArt
    var groesse: CGFloat = 38
    var body: some View {
        RoundedRectangle(cornerRadius: groesse * 0.3, style: .continuous)
            .fill(art.verlauf)
            .frame(width: groesse, height: groesse)
            .overlay(Image(systemName: art.symbol).font(.system(size: groesse * 0.42, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: art.farben[0].opacity(0.35), radius: groesse * 0.2, y: groesse * 0.08)
    }
}

/// Schritt des Code-Agenten (Datei schreiben, Befehl …) – mit Freigabe
struct CodeSchritt: Identifiable, Hashable {
    var id: Int { n }
    var n: Int
    var beschreibung: String
    var status: String
    var vid: String?
    var details: String

    init?(_ w: JSONWert) {
        guard let n = w["n"]?.zahl else { return nil }
        self.n = Int(n)
        beschreibung = w["beschreibung"]?.text ?? w["werkzeug"]?.text ?? "Schritt"
        status = w["status"]?.text ?? ""
        vid = w["vid"]?.text
        details = w["details"]?.text ?? w["grund"]?.text ?? ""
    }
    var wartet: Bool { status == "wartet" && vid != nil }
}

/// Plan des Code-Agenten (Checkliste, 10.11.2026)
struct PlanSchritt: Hashable {
    var text: String
    var status: String

    static func liste(_ w: JSONWert?) -> [PlanSchritt] {
        (w?["schritte"]?.liste ?? []).compactMap { x in
            guard let t = x["text"]?.text, !t.isEmpty else { return nil }
            return PlanSchritt(text: t, status: x["status"]?.text ?? "offen")
        }
    }
}

struct ChatNachricht: Identifiable, Hashable {
    let id = UUID()
    var rolle: String
    var text: String
    var bilder: [String] = []
    var werkzeuge: [String] = []
    var auftraege: [String] = []
    var code: [CodeSchritt] = []
    var denken = ""
    var plan: [PlanSchritt] = []
    var planFrage = false
    var geaendert = 0
}

@MainActor
struct ChatListeAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var chats: [ChatKopf] = []
    @State private var pfad: [ChatKopf] = []
    @State private var laedt = false
    @State private var filter = "alle"
    @State private var suche = ""

    private var sichtbar: [ChatKopf] {
        chats.filter { ["werkstatt", "code", "chat"].contains($0.art) }
            .filter { filter == "alle" || $0.art == filter }
            .filter { suche.isEmpty || $0.titel.localizedCaseInsensitiveContains(suche) }
            .sorted { ($0.geaendert ?? 0) > ($1.geaendert ?? 0) }
    }

    /// Verlauf nach Tagen: Heute, Gestern, Diese Woche, Älter
    private var gruppen: [(String, [ChatKopf])] {
        let k = Calendar.current
        var g: [String: [ChatKopf]] = [:]
        for c in sichtbar {
            let d = Date(timeIntervalSince1970: c.geaendert ?? 0)
            let name = k.isDateInToday(d) ? "Heute" : k.isDateInYesterday(d) ? "Gestern"
                : (Date().timeIntervalSince(d) < 7 * 86400 ? "Diese Woche" : "Älter")
            g[name, default: []].append(c)
        }
        return ["Heute", "Gestern", "Diese Woche", "Älter"].compactMap { n in g[n].map { (n, $0) } }
    }

    var body: some View {
        NavigationStack(path: $pfad) {
            List {
                Section {
                    HStack(spacing: 10) {
                        ForEach(ChatArt.allCases) { a in
                            Button { Task { await neu(a.rawValue) } } label: { agentKarte(a) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Neu starten").font(.caption.weight(.semibold)).textCase(nil)
                }

                Section {
                    Picker("Filter", selection: $filter) {
                        Text("Alle").tag("alle")
                        ForEach(ChatArt.allCases) { Text($0.kurz).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                if !laedt && sichtbar.isEmpty {
                    Section {
                        Text(suche.isEmpty ? "Noch keine Gespräche – oben einen Agenten wählen." : "Nichts gefunden.")
                            .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                    .listRowBackground(Color.clear)
                }

                ForEach(gruppen, id: \.0) { gruppe in
                    Section {
                        ForEach(gruppe.1) { c in
                            NavigationLink(value: c) { zeile(c) }
                                .listRowBackground(Farbe.karte)
                                .swipeActions {
                                    Button("Löschen", role: .destructive) { Task { await loeschen(c) } }
                                }
                        }
                    } header: {
                        Text(gruppe.0).font(.caption.weight(.semibold)).textCase(nil)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .nxHintergrund()
            .navigationTitle("Chat")
            .searchable(text: $suche, prompt: "Gespräche durchsuchen")
            .navigationDestination(for: ChatKopf.self) { ChatAnsicht(kopf: $0) }
            .refreshable { await laden() }
            .task { await laden() }
            .overlay { if laedt && chats.isEmpty { ProgressView() } }
        }
    }

    private func agentKarte(_ a: ChatArt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentKachel(art: a, groesse: 34)
            Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(a.untertitel).font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Farbe.panel2.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [a.farben[0].opacity(0.55), Farbe.rand.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        )
        .contentShape(Rectangle())
    }

    private func zeile(_ c: ChatKopf) -> some View {
        let a = ChatArt(c.art)
        return HStack(spacing: 12) {
            AgentKachel(art: a, groesse: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.titel).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(a.name)
                    if let g = c.geaendert, g > 0 {
                        Text("·")
                        Text(Date(timeIntervalSince1970: g), style: .relative)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if c.laeuft == true {
                HStack(spacing: 4) {
                    Circle().fill(Farbe.gut).frame(width: 7, height: 7)
                    Text("läuft").font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Farbe.gut.opacity(0.15), in: Capsule())
                .foregroundStyle(Farbe.gut)
            }
        }
        .padding(.vertical, 3)
    }

    private func laden() async {
        guard let c = studio.client else { return }
        laedt = true
        defer { laedt = false }
        if let l = try? await c.get("/api/chats", [ChatKopf].self) { chats = l }
    }

    private func neu(_ art: String) async {
        guard let c = studio.client else { return }
        do {
            let r = try await c.post("/api/chats", ["art": art])
            guard let id = r["id"]?.text else { return }
            let titel = art == "werkstatt" ? "Neuer Auftrag" : art == "code" ? "Neue Code-Aufgabe" : "Neuer Chat"
            let k = ChatKopf(id: id, titel: titel, art: art, geaendert: Date().timeIntervalSince1970)
            chats.insert(k, at: 0)
            pfad = [k]
        } catch { studio.meldung = error.localizedDescription }
    }

    private func loeschen(_ k: ChatKopf) async {
        _ = try? await studio.client?.post("/api/chats/\(k.id)/loeschen")
        chats.removeAll { $0.id == k.id }
    }
}

@MainActor
struct ChatAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    let kopf: ChatKopf
    @State private var nachrichten: [ChatNachricht] = []
    @State private var eingabe = ""
    @State private var anhang: [String] = []
    @State private var fotos: [PhotosPickerItem] = []
    @State private var laeuft = false
    @State private var status = ""
    @State private var aufgabe: Task<Void, Never>?
    @State private var modell = ""
    @State private var modelle: [ModellListe.Modell] = []
    @FocusState private var fokus: Bool
    @State private var seit = Date()
    @State private var verfolgen: Task<Void, Never>?
    @State private var titel: String?
    @State private var unterbrochen: String?

    private var art: ChatArt { ChatArt(kopf.art) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { leser in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if nachrichten.isEmpty && !laeuft {
                            leerHinweis
                        }
                        ForEach(nachrichten) { n in
                            Blase(n: n, art: art, aktiv: laeuft && n.id == nachrichten.last?.id,
                                  entscheiden: { s, e in Task { await entscheiden(s, e) } }).id(n.id)
                        }
                        if let u = unterbrochen, !laeuft {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label("Unterbrochen", systemImage: "pause.circle.fill").font(.caption.weight(.bold)).foregroundStyle(Farbe.warn)
                                    Text(u).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Button {
                                    unterbrochen = nil
                                    eingabe = "Mach da weiter, wo du aufgehört hast."
                                    senden()
                                } label: { Label("Weitermachen", systemImage: "play.fill").font(.caption.weight(.semibold)) }
                                    .buttonStyle(.borderedProminent).tint(Farbe.warn)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Farbe.warn.opacity(0.1)))
                            .padding(.leading, 36)
                        }
                        if laeuft {
                            ArbeitsZeile(status: status.isEmpty ? "arbeitet …" : status, seit: seit, farbe: art.farben[0])
                                .padding(.leading, 36)
                                .id("status")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: nachrichten) { _, _ in
                    if let id = nachrichten.last?.id { withAnimation(.easeOut(duration: 0.25)) { leser.scrollTo(id, anchor: .bottom) } }
                }
            }
            eingabeLeiste
        }
        .nxHintergrund()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    AgentKachel(art: art, groesse: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(titel ?? kopf.titel).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(laeuft ? "arbeitet …" : art.name).font(.caption2).foregroundStyle(laeuft ? Farbe.gut : .secondary)
                    }
                }
            }
            if laeuft {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stopp", systemImage: "stop.circle.fill") { Task { await stoppen() } }.tint(Farbe.fehler)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Modell", selection: Binding(get: { modell }, set: { neu in Task { await modellSetzen(neu) } })) {
                        Text("Standard der App").tag("")
                        ForEach(modelle) { Text($0.zeile).tag($0.id) }
                    }
                } label: {
                    Image(systemName: "cpu")
                }
            }
        }
        .task { await laden() }
        .onDisappear { aufgabe?.cancel(); verfolgen?.cancel() }
    }

    private var leerHinweis: some View {
        VStack(spacing: 14) {
            AgentKachel(art: art, groesse: 64)
                .padding(.top, 24)
            Text(art.name).font(.title3.weight(.bold))
            Text(art.leerText).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(art.beispiele, id: \.self) { b in
                    Button { eingabe = b; fokus = true } label: {
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(art.farben[0])
                            Text(b).font(.footnote).multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Farbe.panel2.opacity(0.85)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Farbe.rand.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private var eingabeLeiste: some View {
        VStack(spacing: 8) {
            if !anhang.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(anhang, id: \.self) { n in
                            NXBild(url: studio.bildURL(n)).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.white, .black.opacity(0.6)).padding(2)
                                }
                                .onTapGesture { anhang.removeAll { $0 == n } }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $fotos, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(art.platzhalter, text: $eingabe, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($fokus)
                        .padding(.vertical, 9)
                    DiktierKnopf(text: $eingabe).padding(.bottom, 6)
                }
                .padding(.leading, 14).padding(.trailing, 8)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(fokus ? art.farben[0].opacity(0.6) : Farbe.rand.opacity(0.6), lineWidth: 1))
                Button { senden() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(art.verlauf))
                        .opacity(leer ? 0.4 : 1)
                }
                .disabled(leer)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .onChange(of: fotos) { _, items in
            guard !items.isEmpty, let c = studio.client else { return }
            Task {
                for it in items {
                    if let d = try? await it.loadTransferable(type: Data.self) {
                        let jpeg = UIImage(data: d)?.jpegData(compressionQuality: 0.9) ?? d
                        if let r = try? await c.hochladen("/api/chat/upload", daten: jpeg, dateiname: "iphone.jpg", typ: "image/jpeg"),
                           let n = r["name"]?.text { anhang.append(n) }
                    }
                }
                fotos = []
            }
        }
    }

    private var leer: Bool { eingabe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && anhang.isEmpty }

    private func laden() async {
        guard let c = studio.client, let d = try? await c.get("/api/chats/\(kopf.id)", JSONWert.self) else { return }
        nachrichten = (d["nachrichten"]?.liste ?? []).map { n in
            ChatNachricht(rolle: n["rolle"]?.text ?? "assistant", text: n["text"]?.text ?? "",
                          bilder: (n["bilder"]?.liste ?? []).compactMap { $0.text ?? $0["name"]?.text },
                          werkzeuge: (n["werkzeuge"]?.liste ?? []).compactMap { $0["name"]?.text },
                          auftraege: (n["auftraege"]?.liste ?? []).compactMap { $0.text },
                          code: (n["code"]?.liste ?? []).compactMap(CodeSchritt.init),
                          denken: n["denken"]?.text ?? "",
                          plan: PlanSchritt.liste(n["plan"]),
                          planFrage: n["plan"]?["frage"]?.wahr ?? false,
                          geaendert: n["aenderungen"]?.objekt?.count ?? 0)
        }
        if let t = d["titel"]?.text, !t.isEmpty { titel = t }
        if let u = d["unterbrochen"]?.objekt {
            let g = Int(u["gesamt"]?.zahl ?? 0), f = Int(u["fertig"]?.zahl ?? 0)
            unterbrochen = (g > 0 ? "Plan \(f)/\(g) · " : "") + (u["zuletzt"]?.text ?? "")
        } else { unterbrochen = nil }
        if let o = d["offen"], let s = CodeSchritt(o) { codeSchritt(s) }
        if d["laeuft"]?.wahr == true {
            if !laeuft { seit = Date() }
            laeuft = true
            if status.isEmpty { status = "arbeitet am PC …" }
            if let o = d["offen"], let s = CodeSchritt(o) { status = s.wartet ? "wartet auf deine Freigabe" : s.beschreibung }
            nachverfolgen()
        }
        modell = d["modell"]?.text ?? ""
        if modelle.isEmpty { modelle = await ModellListe.chat(c) }
    }

    /// Läuft die Antwort am PC, ohne dass dieses Gerät den Strom hält: alle 2 s den Stand holen, bis sie fertig ist
    private func nachverfolgen() {
        guard aufgabe == nil, verfolgen == nil else { return }
        verfolgen = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let c = studio.client, let d = try? await c.get("/api/chats/\(kopf.id)", JSONWert.self) else { continue }
                let fertig = d["laeuft"]?.wahr != true
                await laden()
                if fertig { laeuft = false; status = ""; break }
            }
            verfolgen = nil
        }
    }

    private func modellSetzen(_ m: String) async {
        guard let c = studio.client else { return }
        modell = m
        if !m.isEmpty { _ = try? await c.post("/api/chats/\(kopf.id)/aendern", ["modell": m]) }
        studio.meldung = "🧠 " + (m.isEmpty ? "Standard der App" : m)
    }

    private func senden() {
        let text = eingabe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = studio.client, !text.isEmpty || !anhang.isEmpty else { return }
        let bilder = anhang
        eingabe = ""
        anhang = []
        fokus = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        nachrichten.append(ChatNachricht(rolle: "user", text: text, bilder: bilder))
        nachrichten.append(ChatNachricht(rolle: "assistant", text: ""))
        laeuft = true
        seit = Date()
        verfolgen?.cancel(); verfolgen = nil
        status = "denkt nach …"
        var body: [String: Any] = ["text": text, "bilder": bilder,
                                   "werkzeuge": ["bild": true, "gedaechtnis": true, "denken": "kurz", "web": true]]
        if !modell.isEmpty { body["modell"] = modell }
        aufgabe = Task {
            do {
                for try await ev in c.strom("/api/chats/\(kopf.id)/senden", body) {
                    verarbeiten(ev)
                }
            } catch {
                if !Task.isCancelled { anhaengen("\n\n⚠ " + error.localizedDescription) }
            }
            laeuft = false
            status = ""
            aufgabe = nil
            await studio.aktualisieren()
        }
    }

    private func verarbeiten(_ ev: JSONWert) {
        switch ev["t"]?.text ?? "" {
        case "text": anhaengen(ev["d"]?.text ?? "")
        case "zurueck":
            let n = Int(ev["n"]?.zahl ?? 0)
            if var l = nachrichten.last, l.rolle == "assistant", n > 0 {
                l.text = String(l.text.dropLast(min(n, l.text.count)))
                nachrichten[nachrichten.count - 1] = l
            }
        case "werkzeug":
            let d = ev["d"]?.text ?? ""
            status = d
            if !d.hasPrefix("⏳"), var l = nachrichten.last, l.rolle == "assistant" {
                l.werkzeuge.append(d)
                nachrichten[nachrichten.count - 1] = l
            }
        case "code":
            if let w = ev["d"], let s = CodeSchritt(w) {
                codeSchritt(s)
                status = s.wartet ? "wartet auf deine Freigabe" : s.beschreibung
                if s.wartet { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            }
        case "denken":
            if var l = nachrichten.last, l.rolle == "assistant" {
                l.denken += ev["d"]?.text ?? ""
                nachrichten[nachrichten.count - 1] = l
            }
            status = "denkt nach …"
        case "status", "hinweis": status = ev["d"]?.text ?? status
        case "bild":
            if let n = ev["name"]?.text, var l = nachrichten.last, l.rolle == "assistant" {
                l.bilder.append(n)
                nachrichten[nachrichten.count - 1] = l
            }
        case "auftrag":
            if let id = ev["id"]?.text, var l = nachrichten.last, l.rolle == "assistant" {
                if !l.auftraege.contains(id) { l.auftraege.append(id) }
                nachrichten[nachrichten.count - 1] = l
            }
        case "fehler": anhaengen("\n\n⚠ " + (ev["d"]?.text ?? "Fehler"))
        case "plan":
            if var l = nachrichten.last, l.rolle == "assistant" {
                l.plan = PlanSchritt.liste(ev["d"])
                l.planFrage = ev["d"]?["frage"]?.wahr ?? false
                nachrichten[nachrichten.count - 1] = l
            }
        case "titel":
            if let t = ev["d"]?.text, !t.isEmpty { titel = t }
        default: break
        }
    }

    /// Code-Schritt in die letzte Antwort einsortieren (gleiche Nummer = aktualisieren)
    private func codeSchritt(_ s: CodeSchritt) {
        guard var l = nachrichten.last, l.rolle == "assistant" else {
            nachrichten.append(ChatNachricht(rolle: "assistant", text: "", code: [s]))
            return
        }
        if let i = l.code.firstIndex(where: { $0.n == s.n }) { l.code[i] = s } else { l.code.append(s) }
        nachrichten[nachrichten.count - 1] = l
    }

    private func entscheiden(_ s: CodeSchritt, _ e: String) async {
        guard let c = studio.client, let vid = s.vid else { return }
        do {
            _ = try await c.post("/api/chats/\(kopf.id)/work", ["vid": vid, "entscheidung": e])
            var neu = s
            neu.status = e == "nein" ? "abgelehnt" : "läuft"
            if e == "immer" { studio.meldung = "✓ Dieser Chat fragt nicht mehr nach – Sperren und Ordnergrenze bleiben" }
            neu.vid = nil
            codeSchritt(neu)
        } catch { studio.meldung = error.localizedDescription }
    }

    private func anhaengen(_ t: String) {
        guard !t.isEmpty else { return }
        if var l = nachrichten.last, l.rolle == "assistant" {
            l.text += t
            nachrichten[nachrichten.count - 1] = l
        }
    }

    private func stoppen() async {
        _ = try? await studio.client?.post("/api/chats/\(kopf.id)/stopp")
        aufgabe?.cancel()
        laeuft = false
    }
}

/// »arbeitet«-Zeile: was gerade passiert + wie lange schon (damit man nie rätselt, ob überhaupt etwas läuft)
struct ArbeitsZeile: View {
    let status: String
    let seit: Date
    let farbe: Color
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { kontext in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(farbe)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Text(Zeit.dauer(kontext.date.timeIntervalSince(seit))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().stroke(farbe.opacity(0.35), lineWidth: 1))
        }
    }
}

/// drei pulsierende Punkte (»schreibt …«)
struct TippPunkte: View {
    @State private var an = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                    .opacity(an ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: an)
            }
        }
        .onAppear { an = true }
    }
}

@MainActor
struct Blase: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    var n: ChatNachricht
    var art: ChatArt = .chat
    var aktiv = false
    var entscheiden: (CodeSchritt, String) -> Void = { _, _ in }
    @State private var schritteOffen = false
    @State private var gedankenOffen = false
    var istIch: Bool { n.rolle == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if istIch { Spacer(minLength: 48) } else { AgentKachel(art: art, groesse: 28).padding(.top, 2) }
            VStack(alignment: istIch ? .trailing : .leading, spacing: 8) {
                if !n.denken.isEmpty { gedanken }
                if !n.werkzeuge.isEmpty { werkzeugChips }
                if !n.plan.isEmpty { planListe }
                if !n.code.isEmpty { codeListe }
                if n.geaendert > 0 && !aktiv {
                    Label("\(n.geaendert) \(n.geaendert == 1 ? "Datei" : "Dateien") geändert – Stellen einzeln zurücknehmen am PC",
                          systemImage: "doc.badge.clock")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !n.bilder.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(n.bilder, id: \.self) { b in
                                NXBild(url: studio.bildURL(b)).frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                }
                if !n.text.isEmpty {
                    Text(LocalizedStringKey(n.text))
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(istIch ? Color.white : Color.primary)
                        .background(blasenHintergrund)
                } else if !istIch && n.werkzeuge.isEmpty && n.code.isEmpty {
                    TippPunkte().padding(.horizontal, 14).padding(.vertical, 12).background(blasenHintergrund)
                }
                ForEach(n.auftraege, id: \.self) { id in
                    Button { navigation.oeffne(auftrag: id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles.rectangle.stack").foregroundStyle(Farbe.akzent)
                            Text(studio.stand.auftraege.first(where: { $0.id == id }).map { "\($0.artName): \(standText($0))" } ?? "Auftrag öffnen")
                                .font(.caption.weight(.semibold)).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Farbe.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Farbe.akzent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !istIch { Spacer(minLength: 20) }
        }
    }

    @ViewBuilder private var blasenHintergrund: some View {
        if istIch {
            UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous)
                .fill(art.verlauf)
        } else {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
                .fill(Farbe.panel2.opacity(0.92))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
                    .stroke(Farbe.rand.opacity(0.7), lineWidth: 1))
        }
    }

    /// 💭 Gedanken des Modells: während es läuft die letzten Zeilen live, danach zum Aufklappen
    private var gedanken: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { gedankenOffen.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").foregroundStyle(art.farben[0])
                    Text(aktiv ? "denkt …" : "Gedanken").font(.caption.weight(.semibold))
                    if aktiv { TippPunkte() }
                    Spacer()
                    Image(systemName: gedankenOffen ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if gedankenOffen || aktiv {
                Text(gedankenOffen ? n.denken : String(n.denken.suffix(280)))
                    .font(.caption2).italic().foregroundStyle(.secondary)
                    .lineLimit(gedankenOffen ? nil : 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    /// Werkzeug-Schritte als kompakte Chips (aufklappbar, wenn es viele sind)
    private var werkzeugChips: some View {
        let liste = schritteOffen ? n.werkzeuge : Array(n.werkzeuge.suffix(3))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(liste.enumerated()), id: \.offset) { _, w in
                Text(w).font(.caption2).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .foregroundStyle(.secondary)
            }
            if n.werkzeuge.count > 3 {
                Button(schritteOffen ? "Weniger" : "+ \(n.werkzeuge.count - 3) weitere Schritte") { withAnimation { schritteOffen.toggle() } }
                    .font(.caption2.weight(.semibold)).tint(art.farben[0])
            }
        }
    }

    /// Code-Agent: Plan als Checkliste (»Passt der Plan?« – einfach antworten)
    private var planListe: some View {
        let fertig = n.plan.filter { $0.status == "fertig" }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Plan", systemImage: "list.bullet.clipboard").font(.caption.weight(.bold))
                Spacer()
                Text("\(fertig)/\(n.plan.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(fertig), total: Double(max(1, n.plan.count))).tint(art.farben[0])
            ForEach(Array(n.plan.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: p.status == "fertig" ? "checkmark.circle.fill" : p.status == "läuft" ? "circle.dotted.circle"
                          : p.status == "problem" ? "exclamationmark.triangle.fill" : p.status == "übersprungen" ? "minus.circle" : "circle")
                        .foregroundStyle(p.status == "fertig" ? Farbe.gut : p.status == "läuft" ? art.farben[0]
                                         : p.status == "problem" ? Farbe.fehler : Color.secondary)
                        .font(.caption)
                    Text(p.text).font(.caption).strikethrough(p.status == "übersprungen")
                        .foregroundStyle(p.status == "fertig" ? Color.secondary : Color.primary)
                }
            }
            if n.planFrage && fertig == 0 && !aktiv {
                Text("Passt der Plan? Antworte einfach – z. B. »passt« oder was anders sein soll.")
                    .font(.caption2.weight(.semibold)).foregroundStyle(art.farben[0])
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(art.farben[0].opacity(n.planFrage && fertig == 0 ? 0.5 : 0.15)))
    }

    /// Code-Agent: Schritte mit Status, wartende mit Freigabe
    private var codeListe: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(n.code) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if s.status == "läuft" {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: symbol(s.status)).foregroundStyle(farbe(s.status)).font(.caption)
                        }
                        Text(s.beschreibung).font(.caption.weight(.medium)).lineLimit(2)
                    }
                    if s.wartet {
                        if !s.details.isEmpty {
                            Text(s.details).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                        }
                        HStack(spacing: 8) {
                            Button { entscheiden(s, "ja") } label: { Label("Erlauben", systemImage: "checkmark").font(.caption.weight(.semibold)) }
                                .buttonStyle(.borderedProminent).tint(Farbe.gut)
                            Button { entscheiden(s, "nein") } label: { Label("Ablehnen", systemImage: "xmark").font(.caption.weight(.semibold)) }
                                .buttonStyle(.bordered).tint(Farbe.fehler)
                        }
                        Button { entscheiden(s, "immer") } label: {
                            Label("Für diese Sitzung immer erlauben", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Farbe.gut)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(s.wartet ? Farbe.akzent.opacity(0.12) : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(s.wartet ? Farbe.akzent.opacity(0.5) : Color.clear, lineWidth: 1))
            }
        }
    }

    private func symbol(_ st: String) -> String {
        switch st {
        case "ausgeführt": return "checkmark.circle.fill"
        case "läuft": return "arrow.triangle.2.circlepath"
        case "wartet", "vorschau": return "hand.raised.fill"
        case "abgelehnt", "gesperrt", "gestoppt": return "xmark.octagon.fill"
        case "fehler": return "exclamationmark.triangle.fill"
        default: return "circle.dotted"
        }
    }

    private func farbe(_ st: String) -> Color {
        switch st {
        case "ausgeführt": return Farbe.gut
        case "wartet", "vorschau", "läuft": return Farbe.akzent
        case "abgelehnt", "gesperrt", "gestoppt", "fehler": return Farbe.fehler
        default: return .secondary
        }
    }
}
