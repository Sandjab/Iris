import Combine
import Foundation
import IrisKit

@MainActor
public final class AppModel: ObservableObject {
    public enum Tab: String, Sendable, CaseIterable, Codable {
        case overview, logs, security, secrets, rules, settings
    }

    @Published public var daemonStatus: DaemonStatus = .connecting
    @Published public var events: [Event] = []
    @Published public var alerts: [Event] = []
    @Published public var secrets: [Secret] = []
    @Published public var rules: [MITMRule] = []
    @Published public var config: Config?
    @Published public var caTrusted: Bool?
    @Published public var daemonAutoStart: AutoStartStatus?
    @Published public var appAutoStart: AutoStartStatus?
    @Published public var unreadAlertCount: Int = 0
    @Published public var streamPaused: Bool = false
    /// Frozen copy of `events` captured when the Logs stream was paused. Lives on the
    /// model (not a view's `@State`) so the paused list survives tab switches.
    @Published public private(set) var pausedSnapshot: [Event] = []
    @Published public var logFilters: LogFilters = LogFilters()
    @Published public var focusedAlertID: UUID?
    @Published public var notificationsEnabled: Bool = true
    @Published public var selectedTab: Tab {
        didSet { defaults.set(selectedTab.rawValue, forKey: Self.tabKey) }
    }
    @Published public private(set) var lastAcknowledgedAt: Date?
    @Published public private(set) var shellConfigured: Bool?

    private let defaults: UserDefaults
    private let caInstaller: CATrustInstalling
    private let shellConfigurator: ShellConfiguring
    private let autoStart: AutoStartControlling
    private let mcpUnwrapper: MCPUnwrapping
    private let daemonLogPaths: [String]
    private static let tabKey = "io.iris.app.selectedTab"
    private static let ackKey = "io.iris.app.lastAcknowledgedAt"

    /// Daemon stdout/stderr log files. Kept in sync with `StandardOutPath` /
    /// `StandardErrorPath` in `packaging/io.iris.daemon.plist`; the uninstall flow
    /// removes them so nothing survives in world-readable `/tmp`.
    public static let defaultDaemonLogPaths = ["/tmp/irisd.out.log", "/tmp/irisd.err.log"]

    /// Max in-memory events ring size.
    public static let eventsCap: Int = 1000
    /// Max in-memory alerts ring size.
    public static let alertsCap: Int = 200

    public init(
        defaults: UserDefaults = .standard,
        caInstaller: CATrustInstalling = SystemCATrustInstaller(),
        shellConfigurator: ShellConfiguring = SystemShellConfigurator(),
        autoStart: AutoStartControlling = SystemAutoStartService(),
        mcpUnwrapper: MCPUnwrapping? = nil,
        daemonLogPaths: [String] = AppModel.defaultDaemonLogPaths
    ) {
        self.defaults = defaults
        self.caInstaller = caInstaller
        self.shellConfigurator = shellConfigurator
        self.autoStart = autoStart
        self.mcpUnwrapper = mcpUnwrapper ?? (try? SystemMCPUnwrapper()) ?? NoopMCPUnwrapper()
        self.daemonLogPaths = daemonLogPaths
        let storedTab = defaults.string(forKey: Self.tabKey).flatMap(Tab.init(rawValue:))
        self.selectedTab = storedTab ?? .overview
        if let ts = defaults.object(forKey: Self.ackKey) as? Date {
            self.lastAcknowledgedAt = ts
        }
    }

    public func markAllAlertsRead(now: Date = Date()) {
        lastAcknowledgedAt = now
        defaults.set(now, forKey: Self.ackKey)
        recomputeUnreadCount()
    }

    public func acknowledgeAlert(eventID: UUID) {
        guard let evt = alerts.first(where: { $0.id == eventID }) else { return }
        let bound = max(lastAcknowledgedAt ?? .distantPast, evt.timestamp)
        lastAcknowledgedAt = bound
        defaults.set(bound, forKey: Self.ackKey)
        recomputeUnreadCount()
    }

    /// Pause/resume the Logs live stream. Captures the snapshot on the transition into
    /// paused so the frozen list is owned by the model and survives view teardown.
    public func setStreamPaused(_ paused: Bool) {
        if paused && !streamPaused {
            pausedSnapshot = events
        }
        streamPaused = paused
    }

    public func togglePause(via admin: AdminCalling) async throws {
        let wasPaused: Bool
        switch daemonStatus {
        case .up(_, _, let paused): wasPaused = paused
        default: return
        }
        if wasPaused {
            try await admin.resume()
        } else {
            try await admin.pause()
        }
        if case .up(let s, let u, _) = daemonStatus {
            daemonStatus = .up(stats: s, uptime: u, paused: !wasPaused)
        }
    }

    func recomputeUnreadCount() {
        guard let cutoff = lastAcknowledgedAt else {
            unreadAlertCount = alerts.count
            return
        }
        unreadAlertCount = alerts.filter { $0.timestamp > cutoff }.count
    }

    public var lastEventTimestamp: Date? {
        events.map(\.timestamp).max()
    }

    public func ingest(_ event: Event) {
        ingestInto(&events, event: event, cap: Self.eventsCap)
        // Both exfil alerts and daemon-level system alerts (e.g. degraded boot
        // after config corruption, Phase 6.3a) surface in the Security tab.
        if event.kind == .exfilBlocked || event.kind == .systemAlert {
            ingestInto(&alerts, event: event, cap: Self.alertsCap)
            recomputeUnreadCount()
        }
    }

    public func ingestBatch(_ batch: [Event]) {
        for event in batch { ingest(event) }
    }

    private func ingestInto(_ ring: inout [Event], event: Event, cap: Int) {
        if let idx = ring.firstIndex(where: { $0.id == event.id }) {
            ring[idx] = event
            return
        }
        ring.insert(event, at: 0)
        if ring.count > cap {
            ring.removeLast(ring.count - cap)
        }
    }

    // MARK: - Secrets / Rules CRUD (Phase 6.2)
    // All mutations go through admin RPC, then re-fetch the list (SPECS §15.4 — no optimistic update).

    public func refreshSecrets(via admin: AdminCalling) async throws {
        secrets = try await admin.listSecrets().sorted { $0.name < $1.name }
    }

    public func refreshRules(via admin: AdminCalling) async throws {
        rules = try await admin.listRules().sorted { $0.host < $1.host }
    }

    public func addSecret(
        name: String,
        allowedHosts: [String],
        value: Data,
        via admin: AdminCalling
    ) async throws {
        _ = try await admin.addSecret(name: name, allowedHosts: allowedHosts, value: value)
        try await refreshSecrets(via: admin)
    }

    public func updateSecret(
        name: String,
        allowedHosts: [String],
        via admin: AdminCalling
    ) async throws {
        _ = try await admin.updateSecret(name: name, allowedHosts: allowedHosts)
        try await refreshSecrets(via: admin)
    }

    public func rotateSecret(name: String, value: Data, via admin: AdminCalling) async throws {
        _ = try await admin.rotateSecret(name: name, value: value)
        try await refreshSecrets(via: admin)
    }

    public func deleteSecret(name: String, via admin: AdminCalling) async throws {
        try await admin.deleteSecret(name: name)
        try await refreshSecrets(via: admin)
    }

    public func setQuarantined(name: String, quarantined: Bool, via admin: AdminCalling) async throws {
        _ = try await admin.setQuarantined(name: name, quarantined: quarantined)
        try await refreshSecrets(via: admin)
    }

    public func addRule(host: String, via admin: AdminCalling) async throws {
        _ = try await admin.addRule(host: host)
        try await refreshRules(via: admin)
    }

    public func deleteRule(host: String, via admin: AdminCalling) async throws {
        try await admin.deleteRule(host: host)
        try await refreshRules(via: admin)
    }

    // MARK: - Config / CA (Phase 6.3b)

    public func loadConfig(via admin: AdminCalling) async throws {
        config = try await admin.fetchConfig()
    }

    @discardableResult
    public func setConfig(
        _ updates: [ConfigSetParams.Update],
        via admin: AdminCalling
    ) async throws -> ConfigSetResult {
        let result = try await admin.setConfig(updates: updates)
        try await loadConfig(via: admin)
        return result
    }

    public func refreshCATrust(via admin: AdminCalling) async throws {
        caTrusted = try await admin.isCATrusted()
    }

    public func reloadConfig(via admin: AdminCalling) async throws {
        _ = try await admin.reloadConfig()
        try await loadConfig(via: admin)
    }

    public func configFilePath(via admin: AdminCalling) async throws -> String {
        try await admin.configPath()
    }

    public func installCA(via admin: AdminCalling) async throws {
        if caTrusted == true { return }  // idempotent: skip the auth prompt
        let path = try await admin.caExportPath()
        let installer = caInstaller
        try await Task.detached { try installer.install(pemPath: path) }.value
        try await refreshCATrust(via: admin)
    }

    public func uninstallCA(via admin: AdminCalling) async throws {
        if caTrusted == false { return }
        let path = try await admin.caExportPath()
        let installer = caInstaller
        try await Task.detached { try installer.uninstall(pemPath: path) }.value
        try await refreshCATrust(via: admin)
    }

    // MARK: - Shell config (Phase install-completion)

    public func refreshShellConfigured() async {
        let cfg = shellConfigurator
        let installed = await Task.detached { cfg.isInstalled() }.value
        shellConfigured = installed
    }

    public func configureShell() async throws {
        let cfg = shellConfigurator
        try await Task.detached { try cfg.install() }.value
        await refreshShellConfigured()
    }

    public func unconfigureShell() async throws {
        let cfg = shellConfigurator
        try await Task.detached { try cfg.uninstall() }.value
        await refreshShellConfigured()
    }

    // MARK: - Auto-start (Phase 7)

    public func refreshAutoStart() {
        daemonAutoStart = autoStart.status(.daemon)
        appAutoStart = autoStart.status(.app)
    }

    public func setAutoStart(_ target: AutoStartTarget, enabled: Bool) async throws {
        let current: AutoStartStatus?
        switch target {
        case .daemon: current = daemonAutoStart
        case .app: current = appAutoStart
        }
        // Idempotent : ne pas re-register/unregister un service déjà dans l'état voulu
        // (calque de `if caTrusted == true { return }`).
        if enabled, current == .enabled { return }
        if !enabled, current == .notRegistered { return }
        let service = autoStart
        try await Task.detached {
            if enabled {
                try service.register(target)
            } else {
                try service.unregister(target)
            }
        }.value
        refreshAutoStart()
    }

    public func openLoginItemsSettings() {
        autoStart.openLoginItemsSettings()
    }

    // MARK: - Uninstall (Temps 2)

    /// Orchestrates the in-app uninstall. Strict order (I1): the daemon RPC runs
    /// first, while irisd is alive and holds the Keychain ACL; unregister last,
    /// which stops the daemon and releases the bundle lock. Each step is isolated:
    /// a failure is recorded and the next step still runs (Rule 12 — fail loud).
    public func uninstall(deleteSecrets: Bool, via admin: AdminCalling) async -> UninstallReport {
        var report = UninstallReport()

        // 1. Keychain via daemon (must precede unregister).
        report.steps.append(.rpc)
        do {
            let r = try await admin.uninstall(deleteSecrets: deleteSecrets)
            report.caKeyDeleted = r.caKeyDeleted
            report.secretsDeleted = r.secretsDeleted
        } catch {
            report.failures.append(.init(step: .rpc, message: "\(error)"))
        }

        // 2. Trust store (admin prompt) — idempotent: only attempt removal when the
        // CA is actually trusted (mirrors `uninstallCA`). Otherwise there's nothing
        // to remove and `security remove-trusted-cert` exits non-zero, surfacing a
        // spurious "Could not complete: ca".
        report.steps.append(.ca)
        do {
            if try await admin.isCATrusted() {
                let path = try await admin.caExportPath()
                let installer = caInstaller
                try await Task.detached { try installer.uninstall(pemPath: path) }.value
            }
        } catch {
            report.failures.append(.init(step: .ca, message: "\(error)"))
        }

        // 3. MCP unwrap.
        report.steps.append(.mcp)
        do {
            let unwrapper = mcpUnwrapper
            let r = try await Task.detached { try unwrapper.unwrapAll() }.value
            report.mcpRestored = r.restored
        } catch {
            report.failures.append(.init(step: .mcp, message: "\(error)"))
        }

        // 4. Shell block.
        report.steps.append(.shell)
        do {
            let cfg = shellConfigurator
            try await Task.detached { try cfg.uninstall() }.value
        } catch {
            report.failures.append(.init(step: .shell, message: "\(error)"))
        }

        // 5. Auto-start (last — releases the bundle lock).
        report.steps.append(.unregisterDaemon)
        do {
            let service = autoStart
            try await Task.detached { try service.unregister(.daemon) }.value
        } catch {
            report.failures.append(.init(step: .unregisterDaemon, message: "\(error)"))
        }
        report.steps.append(.unregisterApp)
        do {
            let service = autoStart
            try await Task.detached { try service.unregister(.app) }.value
        } catch {
            report.failures.append(.init(step: .unregisterApp, message: "\(error)"))
        }

        // 6. Daemon logs (last — the daemon is now stopped, so it won't recreate them).
        // They live in world-readable /tmp; a clean uninstall leaves nothing behind.
        report.steps.append(.logs)
        let fileManager = FileManager.default
        for path in daemonLogPaths where fileManager.fileExists(atPath: path) {
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                report.failures.append(.init(step: .logs, message: "\(error)"))
            }
        }

        return report
    }
}

// MARK: - UninstallReport

public struct UninstallReport: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case rpc, ca, mcp, shell, unregisterDaemon, unregisterApp, logs
    }
    public struct Failure: Sendable, Equatable {
        public let step: Step
        public let message: String
    }
    /// Steps actually attempted, in execution order (I1 lives here).
    public var steps: [Step] = []
    public var failures: [Failure] = []
    public var caKeyDeleted = false
    public var secretsDeleted = 0
    public var mcpRestored: [String] = []
}

// MARK: - NoopMCPUnwrapper

/// Used when the wrapped-paths manifest can't be located at launch; the
/// uninstall flow then simply restores nothing rather than crashing.
struct NoopMCPUnwrapper: MCPUnwrapping {
    func unwrapAll() throws -> MCPUnwrapReport { MCPUnwrapReport() }
}
