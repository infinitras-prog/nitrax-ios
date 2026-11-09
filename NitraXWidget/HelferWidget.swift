import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 🧍 Stimmungs-Widget (Home- und Sperrbildschirm)

struct HelferEintrag: TimelineEntry {
    let date: Date
    let h: HelferStand?
    var bild: UIImage? = HelferEintrag.selfie()
    /// 🖼 ihr Gesicht (Porträt aus der App) und was sie gerade für dich tut
    var gesicht: UIImage? = Gemeinsam.defaults.data(forKey: "helfer_portrait").flatMap { UIImage(data: $0) }
    var auftrag: Schnappschuss? = Schnappschuss.laden()

    /// arbeitet gerade (Titel, Prozent) – Fortschritt aus der Restzeit hochgerechnet
    var arbeit: (String, Double)? {
        guard let s = auftrag?.hochgerechnet(an: date), let l = s.laufend.first else { return nil }
        return (l.titel, l.fortschritt)
    }
    /// vor kurzem fertig geworden (30 min) -> sie freut sich
    var stolz: String? {
        guard let s = auftrag, s.laufend.isEmpty, let f = s.zuletztFertig, date.timeIntervalSince(s.zeit) < 1800 else { return nil }
        return f.titel
    }
    var laune: String {
        if let a = arbeit { return "arbeitet · \(Int(a.1)) %" }
        if stolz != nil { return "freut sich – fertig! 🎉" }
        return h?.stimmungText ?? "Tippen zum Reden"
    }

    static func selfie() -> UIImage? {
        guard let o = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Gemeinsam.gruppe) else { return nil }
        return UIImage(contentsOfFile: o.appendingPathComponent("helfer_selfie.jpg").path)
    }
}

struct HelferAnbieter: TimelineProvider {
    func placeholder(in context: Context) -> HelferEintrag {
        HelferEintrag(date: Date(), h: HelferStand(name: "Nyra", stufe: "Freunde", stimmung: 0.8, punkte: 30, bis: 45, gespraeche: 12, zeit: Date()))
    }
    func getSnapshot(in context: Context, completion: @escaping (HelferEintrag) -> Void) {
        completion(HelferEintrag(date: Date(), h: HelferStand.laden() ?? placeholder(in: context).h))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HelferEintrag>) -> Void) {
        let h = HelferStand.laden(), jetzt = Date()
        let laeuft = !(Schnappschuss.laden()?.laufend.isEmpty ?? true)
        // läuft ein Auftrag: jede Minute ein hochgerechneter Stand (ihr Kopf zeigt den Fortschritt)
        let eintraege = laeuft ? (0..<30).map { HelferEintrag(date: jetzt.addingTimeInterval(Double($0) * 60), h: h) } : [HelferEintrag(date: jetzt, h: h)]
        completion(Timeline(entries: eintraege, policy: .after(jetzt.addingTimeInterval(laeuft ? 5 * 60 : 30 * 60))))
    }
}

struct HelferWidgetAnsicht: View {
    @Environment(\.widgetFamily) private var familie
    let e: HelferEintrag

    var body: some View {
        Group {
            switch familie {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    if let a = e.arbeit {
                        Gauge(value: a.1 / 100) { Text("") } currentValueLabel: { Text("\(Int(a.1))").font(.title3.monospacedDigit()) }
                            .gaugeStyle(.accessoryCircularCapacity)
                    } else {
                        Gauge(value: e.h?.fortschritt ?? 0) { Text("") } currentValueLabel: { Text(e.stolz != nil ? "🎉" : (e.h?.emoji ?? "🧍")).font(.title3) }
                            .gaugeStyle(.accessoryCircularCapacity)
                    }
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(e.h?.emoji ?? "🧍") \(e.h?.name ?? "Helfer")").font(.headline).lineLimit(1)
                    Text(e.laune).font(.caption).lineLimit(1)
                    if let a = e.arbeit { ProgressView(value: a.1 / 100); Text(a.0).font(.caption2).lineLimit(1) }
                    else if let f = e.stolz { Text("✓ " + f).font(.caption2).lineLimit(1) }
                    else { Text("Tippen und losreden").font(.caption2).foregroundStyle(.secondary) }
                }
            case .accessoryInline:
                Text("\(e.h?.emoji ?? "🧍") \(e.h?.name ?? "Helfer") \(e.laune)")
            case .systemMedium:
                HStack(spacing: 12) {
                    if let b = e.gesicht ?? e.bild {
                        Image(uiImage: b).resizable().scaledToFill().frame(width: 110).frame(maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(e.h?.emoji ?? "🧍") \(e.h?.name ?? "Dein Helfer")").font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(e.laune).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        if let a = e.arbeit {
                            ProgressView(value: a.1 / 100).tint(Color(red: 0.13, green: 0.83, blue: 0.93))
                            Text(a.0).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        } else if let f = e.stolz {
                            Text("✓ " + f).font(.caption2).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        } else if let h = e.h {
                            ProgressView(value: h.fortschritt).tint(Color(red: 0.91, green: 0.64, blue: 0.24))
                            Text("\(h.stufe) · \(h.gespraeche) Gespräche").font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer(minLength: 0)
                        Label("Tippen und losreden", systemImage: "waveform").font(.caption2).foregroundStyle(.white.opacity(0.8))
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let g = e.gesicht {
                            Image(uiImage: g).resizable().scaledToFill().frame(width: 46, height: 46).clipShape(Circle())
                                .overlay(Circle().stroke(e.arbeit != nil ? Color(red: 0.13, green: 0.83, blue: 0.93) : Color(red: 0.91, green: 0.64, blue: 0.24), lineWidth: 2))
                        } else {
                            Text(e.h?.emoji ?? "🧍").font(.system(size: 34))
                        }
                        Spacer()
                        Image(systemName: "waveform").foregroundStyle(.white.opacity(0.8))
                    }
                    Text(e.h?.name ?? "Dein Helfer").font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(e.laune).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    if let a = e.arbeit {
                        ProgressView(value: a.1 / 100).tint(Color(red: 0.13, green: 0.83, blue: 0.93))
                        Text(a.0).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    } else if let h = e.h {
                        ProgressView(value: h.fortschritt).tint(Color(red: 1, green: 0.45, blue: 0.75))
                        Text("\(h.stufe) · \(h.gespraeche) Gespräche").font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
            }
        }
        .widgetURL(URL(string: "nitrax://helfer?hoeren=1"))
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.09, blue: 0.05), Color(red: 0.05, green: 0.06, blue: 0.075)], startPoint: .top, endPoint: .bottom)
                if familie == .systemSmall, let b = e.bild {
                    Image(uiImage: b).resizable().scaledToFill().opacity(0.55)
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }
}

struct HelferWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NitraXHelfer", provider: HelferAnbieter()) { e in HelferWidgetAnsicht(e: e) }
            .configurationDisplayName("Dein Helfer")
            .description("Wie es deinem Helfer geht – antippen und sofort mit ihm reden.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - 🎛 Kontrollzentrum / Sperrbildschirm / Aktionstaste (iOS 18)

struct HelferSteuerung: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.infinitras.nitrax.helfer-steuerung") {
            ControlWidgetButton(action: HelferOeffnenIntent()) {
                Label("Mit Helfer sprechen", systemImage: "person.wave.2.fill")
            }
        }
        .displayName("Mit Helfer sprechen")
        .description("Öffnet deinen NitraX-Helfer, der sofort zuhört.")
    }
}
