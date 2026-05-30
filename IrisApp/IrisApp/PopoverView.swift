import IrisAppCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(admin: admin)
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
                // No CTA: the SyncCoordinator reconnects automatically on a backoff timer, so a
                // "Retry" button would be a no-op (confusing). The banner is informational only.
                banner(text: reasonText(reason), color: .red, cta: nil, action: nil)
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
    let admin: AdminCalling

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: model.daemonStatus)
            StatusLabel(status: model.daemonStatus)
            Spacer()
            if case .up(_, _, let paused) = model.daemonStatus {
                Button(paused ? "Resume" : "Pause") {
                    // togglePause is async; fire-and-forget for UI responsiveness.
                    // Reuses the app-wide admin client (no per-click EventLoopGroup).
                    Task { try? await model.togglePause(via: admin) }
                }
                .buttonStyle(.bordered)
            }
        }
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
