import Foundation

@testable import IrisAppCore

/// In-memory `AutoStartControlling` : statut scriptable par cible, journal des
/// appels register/unregister, et `shouldThrow` pour simuler un échec.
/// `@unchecked Sendable` : `_calls`/`_statuses` sont écrits depuis le `Task.detached`
/// d'AppModel et lus depuis le thread de test, donc les deux côtés prennent le NSLock.
/// `shouldThrow` est posé avant qu'aucune tâche ne soit lancée (happens-before suffit,
/// pas de protection par lock nécessaire).
final class FakeAutoStartService: AutoStartControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _statuses: [AutoStartTarget: AutoStartStatus] = [:]
    var shouldThrow: Error?

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func setStatus(_ status: AutoStartStatus, for target: AutoStartTarget) {
        lock.lock()
        _statuses[target] = status
        lock.unlock()
    }

    func status(_ target: AutoStartTarget) -> AutoStartStatus {
        lock.lock()
        defer { lock.unlock() }
        return _statuses[target] ?? .notRegistered
    }

    func register(_ target: AutoStartTarget) throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        _calls.append("register(\(target))")
        _statuses[target] = .enabled
        lock.unlock()
    }

    func unregister(_ target: AutoStartTarget) throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        _calls.append("unregister(\(target))")
        _statuses[target] = .notRegistered
        lock.unlock()
    }

    func openLoginItemsSettings() {
        lock.lock()
        _calls.append("openLoginItemsSettings")
        lock.unlock()
    }
}
