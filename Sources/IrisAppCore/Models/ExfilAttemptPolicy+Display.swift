import IrisKit

/// Human-readable label for the exfil policy Picker (Settings window). UI-only —
/// the daemon and CLI keep using `rawValue` (block_only / block_and_notify / …).
public func displayName(for policy: ExfilAttemptPolicy) -> String {
    switch policy {
    case .blockOnly: return "Block only"
    case .blockAndNotify: return "Block & notify"
    case .blockNotifyPause: return "Block, notify & pause"
    }
}
