import IrisAppCore
import IrisKit
import SwiftUI

struct SecurityTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.unreadAlertCount) unread")
                    .font(.callout)
                    .foregroundStyle(model.unreadAlertCount > 0 ? Color.red : Color.secondary)
                Spacer()
                Button("Mark all read") { model.markAllAlertsRead() }
                    .disabled(model.unreadAlertCount == 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if model.alerts.isEmpty {
                Spacer()
                Text("No alerts.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(sortedAlerts) { event in
                    AlertRow(event: event, focused: event.id == model.focusedAlertID)
                }
                .listStyle(.plain)
            }
        }
        // Clear the notification-driven highlight once the user leaves this tab,
        // so a previously clicked alert is not left highlighted indefinitely.
        .onDisappear { model.focusedAlertID = nil }
    }

    private var sortedAlerts: [Event] {
        model.alerts.sorted { lhs, rhs in
            if let l = lhs.alert, let r = rhs.alert, l.severity != r.severity {
                return l.severity > r.severity
            }
            return lhs.timestamp > rhs.timestamp
        }
    }
}

private struct AlertRow: View {
    let event: Event
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                severityChip
                Text(event.alert?.secretName ?? "").font(.callout.bold())
                Text("→").foregroundStyle(.secondary)
                Text(event.host).font(.callout)
                Spacer()
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let snippet = event.alert?.snippet {
                Text(snippet).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(focused ? Color.accentColor.opacity(0.15) : nil)
    }

    private var severityChip: some View {
        let severity = event.alert?.severity ?? .low
        return Text(severity.rawValue.uppercased()).font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color(for: severity).opacity(0.2))
            .foregroundStyle(color(for: severity))
            .clipShape(Capsule())
    }

    private func color(for severity: IrisKit.Alert.Severity) -> Color {
        switch severity {
        case .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        }
    }
}
