import IrisAppCore
import IrisKit
import SwiftUI

struct OverviewTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                countersSection
                activitySection
                Divider()
                recentSection
            }
            .padding(12)
        }
    }

    @ViewBuilder private var countersSection: some View {
        let stats = currentStats()
        VStack(alignment: .leading, spacing: 4) {
            Text("Since daemon start").font(.headline)
            HStack(spacing: 20) {
                counter(label: "Requests", value: stats.reqTotal, style: .volume)
                counter(label: "Substituted", value: stats.subTotal, style: .volume)
                counter(label: "Blocked", value: stats.exfilBlockedTotal, style: .incident(.red))
                counter(label: "Errors", value: stats.errorsTotal, style: .incident(.orange))
            }
        }
    }

    private enum CounterStyle {
        case volume
        case incident(Color)
    }

    private func counter(label: String, value: UInt64, style: CounterStyle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            switch style {
            case .volume:
                Text("\(value)").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                Text(label).font(.caption2).foregroundStyle(.tertiary)
            case .incident(let color):
                Text("\(value)").font(.title2.bold().monospacedDigit()).foregroundStyle(color)
                Text(label).font(.caption.weight(.medium))
            }
        }
    }

    private func currentStats() -> DaemonStats {
        if case .up(let stats, _, _) = model.daemonStatus { return stats }
        return .zero
    }

    @ViewBuilder private var activitySection: some View {
        let series = ActivitySeries.buckets(from: model.events, count: 12)
        if !series.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity (recent)").font(.headline)
                Sparkline(values: series)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private struct Sparkline: View {
        let values: [Int]

        var body: some View {
            let peak = max(values.max() ?? 0, 1)
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor.opacity(0.45))
                            .frame(height: max(1, geo.size.height * CGFloat(v) / CGFloat(peak)))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent events").font(.headline)
            if model.events.isEmpty {
                Text("No events yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(Array(model.events.prefix(8))) { event in
                    EventRow(event: event)
                }
            }
        }
    }
}

struct EventRow: View {
    let event: Event

    var body: some View {
        HStack(spacing: 8) {
            Text(timeString(event.timestamp)).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            kindBadge
            Text(event.host).font(.callout)
            Text(event.path).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
    }

    private var kindBadge: some View {
        Text(event.kind.rawValue).font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2)).foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch event.kind {
        case .substituted: return .green
        case .passThrough: return .gray
        case .noMatch: return .gray
        case .exfilBlocked: return .red
        case .error: return .orange
        case .systemAlert: return .red
        }
    }

    private func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
