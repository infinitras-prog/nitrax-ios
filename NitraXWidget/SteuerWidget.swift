import WidgetKit
import SwiftUI
import AppIntents

/// 🔘 »NitraX Knöpfe«: 📞 Anrufen · 🎲 Variante vom letzten Ergebnis · ⏯ Warteschlange – direkt vom Homescreen
struct SteuerEintrag: TimelineEntry {
    let date: Date
    let s: Schnappschuss?
    let pausiert: Bool
    let meldung: String?
}

struct SteuerAnbieter: TimelineProvider {
    func placeholder(in context: Context) -> SteuerEintrag { SteuerEintrag(date: Date(), s: nil, pausiert: false, meldung: nil) }

    func getSnapshot(in context: Context, completion: @escaping (SteuerEintrag) -> Void) {
        completion(SteuerEintrag(date: Date(), s: Schnappschuss.laden(), pausiert: Gemeinsam.defaults.bool(forKey: "widget_pausiert"), meldung: nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SteuerEintrag>) -> Void) {
        Task {
            var pausiert = Gemeinsam.defaults.bool(forKey: "widget_pausiert")
            if let v = Verbindung.laden(), let s = try? await NXClient(v, zeitlimit: 8).get("/api/handy/schaetzung", JSONWert.self) {
                pausiert = s["pausiert"]?.wahr ?? false
                Gemeinsam.defaults.set(pausiert, forKey: "widget_pausiert")
            }
            let m = Gemeinsam.defaults.string(forKey: "widget_meldung")
            Gemeinsam.defaults.removeObject(forKey: "widget_meldung")
            let jetzt = Date()
            var e = [SteuerEintrag(date: jetzt, s: Schnappschuss.laden(), pausiert: pausiert, meldung: m)]
            if m != nil { e.append(SteuerEintrag(date: jetzt.addingTimeInterval(8), s: Schnappschuss.laden(), pausiert: pausiert, meldung: nil)) }
            completion(Timeline(entries: e, policy: .after(jetzt.addingTimeInterval(15 * 60))))
        }
    }
}

struct SteuerWidgetAnsicht: View {
    @Environment(\.widgetFamily) private var familie
    let e: SteuerEintrag

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NitraX").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                if let l = e.s?.laufend.first {
                    Text("\(Int(l.fortschritt)) %").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                } else if e.pausiert {
                    Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.orange)
                }
            }
            if let m = e.meldung {
                Text(m).font(.caption2).foregroundStyle(.white).lineLimit(2)
            }
            Spacer(minLength: 0)
            if familie == .systemSmall {
                VStack(spacing: 6) {
                    knopf(WidgetAnrufen(), "phone.fill", "Anrufen", .green)
                    HStack(spacing: 6) {
                        knopf(WidgetVariante(), "dice.fill", nil, .purple)
                        knopf(WidgetWarteschlange(), e.pausiert ? "play.fill" : "pause.fill", nil, .orange)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    knopf(WidgetAnrufen(), "phone.fill", "Anrufen", .green)
                    knopf(WidgetVariante(), "dice.fill", "Variante", .purple)
                    knopf(WidgetWarteschlange(), e.pausiert ? "play.fill" : "pause.fill", e.pausiert ? "Weiter" : "Anhalten", .orange)
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.07, green: 0.06, blue: 0.16), Color(red: 0.03, green: 0.03, blue: 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func knopf<I: AppIntent>(_ intent: I, _ symbol: String, _ titel: String?, _ farbe: Color) -> some View {
        Button(intent: intent) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if let titel { Text(titel).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .foregroundStyle(.white)
            .background(farbe.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct SteuerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NitraXKnoepfe", provider: SteuerAnbieter()) { e in SteuerWidgetAnsicht(e: e) }
            .configurationDisplayName("NitraX Knöpfe")
            .description("Anrufen, neue Variante, Warteschlange anhalten – ohne die App zu öffnen.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
