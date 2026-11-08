import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 🧍 Stimmungs-Widget (Home- und Sperrbildschirm)

struct HelferEintrag: TimelineEntry {
    let date: Date
    let h: HelferStand?
    var bild: UIImage? = HelferEintrag.selfie()

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
        completion(Timeline(entries: [HelferEintrag(date: Date(), h: HelferStand.laden())], policy: .after(Date().addingTimeInterval(30 * 60))))
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
                    Gauge(value: e.h?.fortschritt ?? 0) { Text("") } currentValueLabel: { Text(e.h?.emoji ?? "🧍").font(.title3) }
                        .gaugeStyle(.accessoryCircularCapacity)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(e.h?.emoji ?? "🧍") \(e.h?.name ?? "Helfer")").font(.headline).lineLimit(1)
                    Text(e.h.map { "\($0.stimmungText) · \($0.stufe)" } ?? "Tippen zum Reden").font(.caption).lineLimit(1)
                    Text("Tippen und losreden").font(.caption2).foregroundStyle(.secondary)
                }
            case .accessoryInline:
                Text("\(e.h?.emoji ?? "🧍") \(e.h?.name ?? "Helfer") \(e.h?.stimmungText ?? "")")
            case .systemMedium:
                HStack(spacing: 12) {
                    if let b = e.bild {
                        Image(uiImage: b).resizable().scaledToFill().frame(width: 110).frame(maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(e.h?.emoji ?? "🧍") \(e.h?.name ?? "Dein Helfer")").font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(e.h?.stimmungText ?? "Öffne NitraX").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        if let h = e.h {
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
                        Text(e.h?.emoji ?? "🧍").font(.system(size: 34))
                        Spacer()
                        Image(systemName: "waveform").foregroundStyle(.white.opacity(0.8))
                    }
                    Text(e.h?.name ?? "Dein Helfer").font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(e.h?.stimmungText ?? "Öffne NitraX").font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    if let h = e.h {
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
