import WidgetKit
import SwiftUI
import ActivityKit

/// Live Activity: Sperrbildschirm + Dynamic Island eines laufenden Auftrags
struct AuftragLiveWidget: Widget {
    private let akzent = Color(red: 0.49, green: 0.55, blue: 1.0)
    private let akzent2 = Color(red: 0.78, green: 0.42, blue: 1.0)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AuftragAttribute.self) { ctx in
            sperrbildschirm(ctx.attributes, ctx.state)
                .activityBackgroundTint(Color(red: 0.05, green: 0.05, blue: 0.11).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "nitrax://auftrag/\(ctx.attributes.id)"))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: ctx.attributes.symbol).font(.title2).foregroundStyle(akzent).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(prozent(ctx.state)).font(.title2.bold()).monospacedDigit().foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ctx.attributes.titel).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        balken(ctx.state.fortschritt)
                        HStack {
                            Text(ctx.state.stufe).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            if let r = ctx.state.rest, ctx.state.status == "läuft" {
                                Text("noch \(Zeit.dauer(r))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: fertig(ctx.state) ? "checkmark.circle.fill" : ctx.attributes.symbol)
                    .foregroundStyle(fertig(ctx.state) ? .green : akzent)
            } compactTrailing: {
                Text(prozent(ctx.state)).font(.caption2.bold()).monospacedDigit().foregroundStyle(akzent)
            } minimal: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.03, ctx.state.fortschritt / 100))
                        .stroke(akzent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .padding(2)
            }
            .widgetURL(URL(string: "nitrax://auftrag/\(ctx.attributes.id)"))
            .keylineTint(akzent)
        }
    }

    private func fertig(_ z: AuftragAttribute.ContentState) -> Bool { z.status == "fertig" }

    private func prozent(_ z: AuftragAttribute.ContentState) -> String {
        if fertig(z) { return "✓" }
        if z.status == "fehler" { return "!" }
        return "\(Int(z.fortschritt)) %"
    }

    private func balken(_ wert: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(LinearGradient(colors: [akzent, akzent2], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, g.size.width * min(1, wert / 100)))
            }
        }
        .frame(height: 7)
    }

    private func sperrbildschirm(_ a: AuftragAttribute, _ z: AuftragAttribute.ContentState) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: [akzent.opacity(0.35), akzent2.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                Image(systemName: fertig(z) ? "checkmark" : a.symbol).font(.title3.bold()).foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(a.titel).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Text(prozent(z)).font(.headline).monospacedDigit().foregroundStyle(akzent)
                }
                balken(fertig(z) ? 100 : z.fortschritt)
                HStack {
                    Text(fertig(z) ? "\(a.art) fertig – antippen zum Ansehen" : z.status == "fehler" ? "Fehlgeschlagen" : z.stufe)
                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Spacer()
                    if let r = z.rest, z.status == "läuft" {
                        Text("noch \(Zeit.dauer(r))").font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .padding(16)
    }
}
