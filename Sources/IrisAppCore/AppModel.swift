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

    private let defaults: UserDefaults
    private let caInstaller: CATrustInstalling
    private static let tabKey = "io.iris.app.selectedTab"
    private static let ackKey = "io.iris.app.lastAcknowledgedAt"

    /// Max in-memory events ring size.
    public static let eventsCap: Int = 1000
    /// Max in-memory alerts ring size.
    public static let alertsCap: Int = 200

    public init(
        defaults: UserDefaults = .standard,
        caInstaller: CATrustInstalling = SystemCATrustInstaller()
    ) {
        self.defaults = defaults
        self.caInstaller = caInstaller
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
}
