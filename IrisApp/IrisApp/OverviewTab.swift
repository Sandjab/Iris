import IrisAppCore
import IrisKit
import SwiftUI

struct OverviewTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                countersSection
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
            HStack(spacing: 24) {
                counter(label: "Requests", value: stats.reqTotal)
                counter(label: "Substituted", value: stats.subTotal)
                counter(label: "Blocked", value: stats.exfilBlockedTotal)
                counter(label: "Errors", value: stats.errorsTotal)
            }
        }
    }

    private func currentStats() -> DaemonStats {
        if case .up(let stats, _, _) = model.daemonStatus { return stats }
        return .zero
    }

    private func counter(label: String, value: UInt64) -> some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent events").font(.headline)
            if model.events.isEmpty {
                Text("No events yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(Array(model.events.prefix(5))) { event in
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
        }
    }

    private func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
