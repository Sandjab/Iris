import Foundation

/// Les deux services auto-démarrables. `daemon` = LaunchAgent `irisd` ;
/// `app` = la menu-bar app comme login-item.
public enum AutoStartTarget: Sendable, CaseIterable, Hashable {
    case daemon
    case app
}

/// État maison (pas `SMAppService.Status`) : garde IrisAppCore testable sans
/// dépendre du contexte bundle, exactement comme `AppModel.caTrusted: Bool?`.
public enum AutoStartStatus: Sendable, Equatable {
    /// Enregistré et éligible à tourner.
    case enabled
    /// Enregistré mais l'utilisateur doit autoriser en Réglages Système.
    case requiresApproval
    /// Non enregistré (off).
    case notRegistered
    /// Plist/bundle introuvable (anomalie de packaging).
    case notFound
    /// État illisible (cas `@unknown` futur).
    case unknown
}

/// Seam sur `SMAppService` (API in-process, non testable hors bundle installé).
/// Production : `SystemAutoStartService`. Tests : `FakeAutoStartService`.
public protocol AutoStartControlling: Sendable {
    func status(_ target: AutoStartTarget) -> AutoStartStatus
    func register(_ target: AutoStartTarget) throws
    func unregister(_ target: AutoStartTarget) throws
    func openLoginItemsSettings()
}
