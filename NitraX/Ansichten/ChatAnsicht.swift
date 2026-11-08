import SwiftUI
import PhotosUI

struct ChatKopf: Decodable, Identifiable, Hashable {
    var id: String
    var titel: String
    var art: String
    var geaendert: Double?
    var laeuft: Bool?
}

struct ChatNachricht: Identifiable, Hashable {
    let id = UUID()
    var rolle: String
    var text: String
    var bilder: [String] = []
    var werkzeuge: [String] = []
    var auftraege: [String] = []
}

@MainActor
struct ChatListeAnsicht: View {
    @EnvironmentObject private var studio: Studio
    @State private var chats: [ChatKopf] = []
    @State private var pfad: [ChatKopf] = []
    @State private var laedt = false

    var body: some View {
        NavigationStack(path: $pfad) {
            List {
                Section {
                    Button { Task { await neu("werkstatt") } } label: {
                        Label("Neuer Auftrag an den Workflow-Agenten", systemImage: "wand.and.stars")
                    }
                    Button { Task { await neu("chat") } } label: {
                        Label("Neuer Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .listRowBackground(Farbe.karte)
                Section("Verlauf") {
                    ForEach(chats.filter { $0.art != "code" && $0.art != "desktop" && $0.art != "begleiter" }) { c in
                        NavigationLink(value: c) {
                            HStack {
                                Image(systemName: c.art == "werkstatt" ? "wand.and.stars" : "bubble.left").foregroundStyle(Farbe.akzent)
                                VStack(alignment: .leading) {
                                    Text(c.titel).lineLimit(1)
                                    if let g = c.geaendert, g > 0 {
                                        Text(Date(timeIntervalSince1970: g), style: .relative).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if c.laeuft == true { Spacer(); ProgressView().controlSize(.small) }
                            }
                        }
                        .swipeActions {
                            Button("Löschen", role: .destructive) { Task { await loeschen(c) } }
                        }
                    }
                }
                .listRowBackground(Farbe.karte)
            }
            .scrollContentBackground(.hidden)
            .nxHintergrund()
            .navigationTitle("Chat")
            .navigationDestination(for: ChatKopf.self) { ChatAnsicht(kopf: $0) }
            .refreshable { await laden() }
            .task { await laden() }
            .overlay { if laedt && chats.isEmpty { ProgressView() } }
        }
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
            let k = ChatKopf(id: id, titel: art == "werkstatt" ? "Neuer Auftrag" : "Neuer Chat", art: art)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { leser in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if nachrichten.isEmpty && !laeuft {
                            leerHinweis
                        }
                        ForEach(nachrichten) { n in Blase(n: n).id(n.id) }
                        if laeuft && !status.isEmpty {
                            Label(status, systemImage: "gearshape.2").font(.caption).foregroundStyle(.secondary).id("status")
                        }
                    }
                    .padding(14)
                }
                .onChange(of: nachrichten) { _, _ in
                    if let id = nachrichten.last?.id { withAnimation { leser.scrollTo(id, anchor: .bottom) } }
                }
            }
            eingabeLeiste
        }
        .nxHintergrund()
        .navigationTitle(kopf.titel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if laeuft {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stopp", systemImage: "stop.circle") { Task { await stoppen() } }
                }
            }
            // 🧠 Modell dieses Chats
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Modell", selection: Binding(get: { modell }, set: { neu in Task { await modellSetzen(neu) } })) {
                        Text("Standard der App").tag("")
                        ForEach(modelle) { Text($0.zeile).tag($0.id) }
                    }
                } label: {
                    Label(modell.isEmpty ? "Modell" : modell, systemImage: "cpu")
                }
            }
        }
        .task { await laden() }
        .onDisappear { aufgabe?.cancel() }
    }

    private var leerHinweis: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kopf.art == "werkstatt" ? "Workflow-Agent" : "Chat").font(.headline)
            Text(kopf.art == "werkstatt"
                 ? "Beschreib, was entstehen soll – z. B. »Mach aus diesem Foto ein 10-s-Video mit Regen« oder »Erstell einen Song und ein Musikvideo dazu«. Der Agent plant, startet die Workflows, wartet und bessert selbst nach."
                 : "Frag, was du willst – mit 📷 auch zu einem Bild.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .karte()
    }

    private var eingabeLeiste: some View {
        VStack(spacing: 8) {
            if !anhang.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(anhang, id: \.self) { n in
                            NXBild(url: studio.bildURL(n)).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture { anhang.removeAll { $0 == n } }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $fotos, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "photo.badge.plus").font(.title3)
                }
                TextField(kopf.art == "werkstatt" ? "Was soll entstehen?" : "Nachricht", text: $eingabe, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($fokus)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
                Button { senden() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(Farbe.verlauf)
                }
                .disabled(eingabe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && anhang.isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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

    private func laden() async {
        guard let c = studio.client, let d = try? await c.get("/api/chats/\(kopf.id)", JSONWert.self) else { return }
        nachrichten = (d["nachrichten"]?.liste ?? []).map { n in
            ChatNachricht(rolle: n["rolle"]?.text ?? "assistant", text: n["text"]?.text ?? "",
                          bilder: (n["bilder"]?.liste ?? []).compactMap { $0.text ?? $0["name"]?.text },
                          werkzeuge: (n["werkzeuge"]?.liste ?? []).compactMap { $0["name"]?.text },
                          auftraege: (n["auftraege"]?.liste ?? []).compactMap { $0.text })
        }
        if d["laeuft"]?.wahr == true { status = "Antwortet noch am PC …"; laeuft = true }
        modell = d["modell"]?.text ?? ""
        modelle = await ModellListe.chat(c)
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
        nachrichten.append(ChatNachricht(rolle: "user", text: text, bilder: bilder))
        nachrichten.append(ChatNachricht(rolle: "assistant", text: ""))
        laeuft = true
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
        default: break
        }
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

@MainActor
struct Blase: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var navigation: Navigation
    var n: ChatNachricht
    var istIch: Bool { n.rolle == "user" }

    var body: some View {
        HStack {
            if istIch { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                if !n.werkzeuge.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(n.werkzeuge.suffix(6).enumerated()), id: \.offset) { _, w in
                            Text(w).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                if !n.bilder.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(n.bilder, id: \.self) { b in
                                NXBild(url: studio.bildURL(b)).frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                if !n.text.isEmpty {
                    Text(LocalizedStringKey(n.text)).textSelection(.enabled)
                } else if !istIch && n.werkzeuge.isEmpty {
                    ProgressView().controlSize(.small)
                }
                ForEach(n.auftraege, id: \.self) { id in
                    Button { navigation.oeffne(auftrag: id) } label: {
                        Label(studio.stand.auftraege.first(where: { $0.id == id }).map { "\($0.artName): \(standText($0))" } ?? "Auftrag öffnen",
                              systemImage: "arrow.up.forward.square")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(istIch ? AnyShapeStyle(Farbe.verlauf) : AnyShapeStyle(Farbe.karte)))
            if !istIch { Spacer(minLength: 24) }
        }
    }
}
