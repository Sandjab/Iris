import Foundation
import ServiceManagement

/// Production `AutoStartControlling` : pont vers `SMAppService` (macOS 13+).
/// Non testée unitairement — `SMAppService` lit le bundle courant et l'état
/// `launchd`, indisponibles hors app installée. Couverte par le smoke poste.
public struct SystemAutoStartService: AutoStartControlling {
    /// Doit correspondre au plist embarqué dans `Contents/Library/LaunchAgents/`
    /// par `packaging/build-pkg.sh`.
    private static let daemonPlistName = "io.iris.daemon.plist"

    public init() {}

    private func service(for target: AutoStartTarget) -> SMAppService {
        switch target {
        case .daemon: return SMAppService.agent(plistName: Self.daemonPlistName)
        case .app: return SMAppService.mainApp
        }
    }

    public func status(_ target: AutoStartTarget) -> AutoStartStatus {
        switch service(for: target).status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public func register(_ target: AutoStartTarget) throws {
        try service(for: target).register()
    }

    public func unregister(_ target: AutoStartTarget) throws {
        try service(for: target).unregister()
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
