import Combine
import Foundation
import IrisKit

@MainActor
public final class AppModel: ObservableObject {
    public enum Tab: String, Sendable, CaseIterable, Codable {
        case overview, logs, security
    }

    @Published public var daemonStatus: DaemonStatus = .connecting
    @Published public var events: [Event] = []
    @Published public var alerts: [Event] = []
    @Published public var unreadAlertCount: Int = 0
    @Published public var streamPaused: Bool = false
    @Published public var logFilters: LogFilters = LogFilters()
    @Published public var focusedAlertID: UUID?
    @Published public var notificationsEnabled: Bool = true
    @Published public var selectedTab: Tab {
        didSet { defaults.set(selectedTab.rawValue, forKey: Self.tabKey) }
    }
    @Published public private(set) var lastAcknowledgedAt: Date?

    private let defaults: UserDefaults
    private static let tabKey = "io.iris.app.selectedTab"
    private static let ackKey = "io.iris.app.lastAcknowledgedAt"

    /// Max in-memory events ring size.
    public static let eventsCap: Int = 1000
    /// Max in-memory alerts ring size.
    public static let alertsCap: Int = 200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    func recomputeUnreadCount() {
        guard let cutoff = lastAcknowledgedAt else {
            unreadAlertCount = alerts.count
            return
        }
        unreadAlertCount = alerts.filter { $0.timestamp > cutoff }.count
    }
}
