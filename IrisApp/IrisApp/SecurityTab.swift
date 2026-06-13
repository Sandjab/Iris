import IrisAppCore
import IrisKit
import SwiftUI

struct SecurityTab: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(alertsSummary(total: model.alerts.count, unread: model.unreadAlertCount))
                    .font(.callout)
                    .foregroundStyle(model.unreadAlertCount > 0 ? Color.red : Color.secondary)
                Spacer()
                Button("Mark all read") { model.markAllAlertsRead() }
                    .disabled(model.unreadAlertCount == 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            if model.alerts.isEmpty {
                GuidedEmptyState(
                    symbol: "checkmark.shield",
                    title: "No alerts",
                    message: "Exfiltration attempts will appear here."
                )
            } else {
                List(sortedAlerts) { event in
                    AlertRow(
                        event: event,
                        focused: event.id == model.focusedAlertID,
                        onQuarantine: { await quarantine(event) }
                    )
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
            let l = Self.severity(of: lhs)
            let r = Self.severity(of: rhs)
            if l != r { return l > r }
            return lhs.timestamp > rhs.timestamp
        }
    }

    /// Severity of an alert event, whether it carries an exfil `Alert` or a
    /// daemon-level `SystemAlert` (Phase 6.3a). Defaults to `.low` if neither.
    static func severity(of event: Event) -> IrisKit.Alert.Severity {
        event.alert?.severity ?? event.systemAlert?.severity ?? .low
    }

    private func quarantine(_ event: Event) async {
        guard let name = event.alert?.secretName, !name.isEmpty else { return }
        errorText = nil
        do {
            try await model.setQuarantined(name: name, quarantined: true, via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }
}

private struct AlertRow: View {
    let event: Event
    let focused: Bool
    let onQuarantine: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                severityChip
                if let alert = event.alert {
                    Text(alert.secretName).font(.callout.bold())
                    Text("→").foregroundStyle(.secondary)
                    Text(event.host).font(.callout)
                } else {
                    Text("Configuration").font(.callout.bold())
                }
                Spacer()
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                // Quarantine applies to a secret; a system alert has none.
                if let alert = event.alert {
                    Button {
                        Task { await onQuarantine() }
                    } label: {
                        Image(systemName: "lock.slash")
                    }
                    .buttonStyle(.borderless)
                    .help("Quarantine \(alert.secretName)")
                    .disabled(alert.secretName.isEmpty)
                }
            }
            if let snippet = event.alert?.snippet ?? event.systemAlert?.message {
                Text(snippet).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(focused ? Color.accentColor.opacity(0.15) : nil)
    }

    private var severityChip: some View {
        let severity = event.alert?.severity ?? event.systemAlert?.severity ?? .low
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
