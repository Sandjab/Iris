import Foundation

@testable import IrisAppCore

/// In-memory `AutoStartControlling` : statut scriptable par cible, journal des
/// appels register/unregister, et `shouldThrow` pour simuler un échec.
/// `@unchecked Sendable` : l'état est protégé par NSLock — register/unregister
/// sont appelés depuis le `Task.detached` d'AppModel, les lectures depuis le test.
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
