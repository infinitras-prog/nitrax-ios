import WidgetKit
import SwiftUI

struct StandEintrag: TimelineEntry {
    let date: Date
    let s: Schnappschuss?
}

private let beispiel = Schnappschuss(
    zeit: Date(), erreichbar: true,
    laufend: [.init(id: "x", titel: "Sonnenaufgang am See", art: "Video", symbol: "play.rectangle", status: "läuft",
                    fortschritt: 62, stufe: "Teil 2/3 · MiniMax H3", rest: 140)],
    wartend: 2,
    zuletztFertig: .init(id: "y", titel: "Morgenspaziergang", art: "Song", symbol: "music.note", status: "fertig",
                         fortschritt: 100, stufe: "", rest: nil),
    gpu: 97)

struct StandAnbieter: TimelineProvider {
    func placeholder(in context: Context) -> StandEintrag { StandEintrag(date: Date(), s: beispiel) }

    func getSnapshot(in context: Context, completion: @escaping (StandEintrag) -> Void) {
        completion(StandEintrag(date: Date(), s: context.isPreview ? beispiel : (Schnappschuss.laden() ?? beispiel)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StandEintrag>) -> Void) {
        Task {
            var s = Schnappschuss.laden()
            if let v = Verbindung.laden() {
                let c = NXClient(v, zeitlimit: 8)
                if let st = try? await c.stand() {
                    let neu = Schnappschuss.aus(st)
                    neu.speichern()
                    s = neu
                } else {
                    s?.erreichbar = false
                }
            }
            let laeuft = !(s?.laufend.isEmpty ?? true)
            let jetzt = Date()
            guard laeuft, let s else {
                completion(Timeline(entries: [StandEintrag(date: jetzt, s: s)], policy: .after(jetzt.addingTimeInterval(30 * 60))))
                return
            }
            // 📈 läuft etwas: jede Minute ein hochgerechneter Stand (eine Stunde lang), neu abrufen nach ~3 min
            let eintraege = (0..<60).map { i -> StandEintrag in
                let d = jetzt.addingTimeInterval(Double(i) * 60)
                return StandEintrag(date: d, s: s.hochgerechnet(an: d))
            }
            completion(Timeline(entries: eintraege, policy: .after(jetzt.addingTimeInterval(3 * 60))))
        }
    }
}

struct StandWidgetAnsicht: View {
    @Environment(\.widgetFamily) private var familie
    let e: StandEintrag

    private let akzent = Color(red: 0.49, green: 0.55, blue: 1.0)
    private let akzent2 = Color(red: 0.78, green: 0.42, blue: 1.0)

    var body: some View {
        Group {
            switch familie {
            case .accessoryCircular: kreis
            case .accessoryRectangular: rechteck
            case .accessoryInline: Text(inlineText)
            case .systemMedium: mittel
            default: klein
            }
        }
        .widgetURL(URL(string: "nitrax://auftrag/" + (e.s?.laufend.first?.id ?? e.s?.zuletztFertig?.id ?? "")))
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.07, green: 0.06, blue: 0.16), Color(red: 0.03, green: 0.03, blue: 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var inlineText: String {
        guard let s = e.s else { return "NitraX" }
        if let l = s.laufend.first { return "\(Int(l.fortschritt)) % · \(l.titel)" }
        return s.wartend > 0 ? "\(s.wartend) warten" : "NitraX bereit"
    }

    private func ring(_ wert: Double, dicke: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: dicke)
            Circle().trim(from: 0, to: min(1, max(0.02, wert / 100)))
                .stroke(LinearGradient(colors: [akzent, akzent2], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: dicke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    private var kreis: some View {
        Gauge(value: (e.s?.laufend.first?.fortschritt ?? 0) / 100) {
            Image(systemName: "sparkles")
        } currentValueLabel: {
            Text(e.s?.laufend.first.map { "\(Int($0.fortschritt))" } ?? "–")
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rechteck: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let l = e.s?.laufend.first {
                Text(l.titel).font(.headline).lineLimit(1)
                Text("\(Int(l.fortschritt)) % · noch \(Zeit.dauer(l.rest))").font(.caption)
                ProgressView(value: l.fortschritt / 100)
            } else {
                Text("NitraX").font(.headline)
                Text(e.s?.zuletztFertig.map { "✓ \($0.titel)" } ?? "Alles ruhig").font(.caption).lineLimit(2)
            }
        }
    }

    private var klein: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(akzent)
                Text("NitraX").font(.caption.weight(.bold))
                Spacer()
                Circle().fill((e.s?.erreichbar ?? false) ? Color.green : Color.orange).frame(width: 7, height: 7)
            }
            if let l = e.s?.laufend.first {
                ZStack {
                    ring(l.fortschritt, dicke: 7)
                    VStack(spacing: 0) {
                        Text("\(Int(l.fortschritt))").font(.title2.bold()).monospacedDigit()
                        Text("%").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 66, height: 66)
                .frame(maxWidth: .infinity)
                Text(l.titel).font(.caption.weight(.semibold)).lineLimit(1)
            } else {
                Spacer()
                if let f = e.s?.zuletztFertig {
                    Label("fertig", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                    Text(f.titel).font(.footnote.weight(.semibold)).lineLimit(2)
                } else {
                    Text(e.s == nil ? "In der App verbinden" : "Alles ruhig").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var mittel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(akzent)
                Text("NitraX Studio").font(.caption.weight(.bold))
                Spacer()
                if let g = e.s?.gpu { Text("GPU \(g) %").font(.caption2).foregroundStyle(.secondary) }
                if (e.s?.wartend ?? 0) > 0 { Text("· \(e.s?.wartend ?? 0) warten").font(.caption2).foregroundStyle(.secondary) }
            }
            if let lauf = e.s?.laufend, !lauf.isEmpty {
                ForEach(lauf.prefix(2), id: \.self) { l in
                    Link(destination: URL(string: "nitrax://auftrag/\(l.id)")!) {
                        HStack(spacing: 10) {
                            ring(l.fortschritt, dicke: 4).frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.titel).font(.caption.weight(.semibold)).lineLimit(1)
                                Text("\(Int(l.fortschritt)) % · \(l.stufe)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(Zeit.dauer(l.rest)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Spacer()
                Text(e.s == nil ? "Öffne NitraX und verbinde deinen PC." : "Gerade rechnet nichts.").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let f = e.s?.zuletztFertig {
                Label("Zuletzt: \(f.titel)", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }
}

struct StandWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NitraXStand", provider: StandAnbieter()) { e in
            StandWidgetAnsicht(e: e)
        }
        .configurationDisplayName("NitraX Studio")
        .description("Laufende Aufträge, Fortschritt und das zuletzt Fertige.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct NitraXWidgets: WidgetBundle {
    var body: some Widget {
        StandWidget()
        HelferWidget()
        AuftragLiveWidget()
        HelferSteuerung()
        SteuerWidget()
    }
}
