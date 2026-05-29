import IrisAppCore
import IrisKit
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()
            BannersStack()
            Picker("Tab", selection: $model.selectedTab) {
                Text("Overview").tag(AppModel.Tab.overview)
                Text("Logs").tag(AppModel.Tab.logs)
                Text("Security").tag(AppModel.Tab.security)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            Group {
                switch model.selectedTab {
                case .overview: OverviewTab()
                case .logs: LogsTab()
                case .security: SecurityTab()
                }
            }
        }
        .frame(width: 480, height: 600)
    }
}

private struct BannersStack: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if case .down(let reason) = model.daemonStatus {
                banner(
                    text: reasonText(reason),
                    color: .red,
                    cta: "Retry",
                    action: {}  // No-op: SyncCoordinator reconnects automatically each backoff tick.
                )
            }
            if !model.notificationsEnabled {
                banner(
                    text: "Notifications disabled. Enable in System Settings → Notifications → Iris.",
                    color: .orange,
                    cta: nil,
                    action: nil
                )
            }
        }
    }

    private func reasonText(_ reason: IrisAppCore.DaemonStatus.DownReason) -> String {
        switch reason {
        case .notRunning: return "Daemon stopped. Restart via launchctl or relaunch Iris."
        case .rpcError(let msg): return "Daemon unreachable: \(msg)"
        }
    }

    @ViewBuilder
    private func banner(text: String, color: Color, cta: String?, action: (() -> Void)?) -> some View {
        HStack {
            Text(text).font(.callout)
            Spacer()
            if let cta, let action {
                Button(cta, action: action).buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(color.opacity(0.15))
    }
}

private struct HeaderBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: model.daemonStatus)
            StatusLabel(status: model.daemonStatus)
            Spacer()
            if case .up(_, _, let paused) = model.daemonStatus {
                Button(paused ? "Resume" : "Pause") {
                    // togglePause is async; fire-and-forget for UI responsiveness.
                    // The AdminClient is recreated per call (cheap: just a socket path).
                    Task { try? await model.togglePause(via: makeAdmin()) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func makeAdmin() -> AdminCalling {
        AdminClient(socketPath: defaultAdminSocketPath())
    }
}

private struct StatusDot: View {
    let status: IrisAppCore.DaemonStatus

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .up(_, _, let paused): return paused ? .orange : .green
        case .down: return .red
        case .connecting: return .gray
        }
    }
}

private struct StatusLabel: View {
    let status: IrisAppCore.DaemonStatus

    var body: some View {
        switch status {
        case .up(_, let uptime, let paused):
            Text("\(paused ? "Paused" : "Up") • \(formatUptime(uptime))")
                .font(.callout.monospacedDigit())
        case .down:
            Text("Daemon down").foregroundStyle(.red).font(.callout)
        case .connecting:
            Text("Connecting…").font(.callout)
        }
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
