import Foundation

/// Security-tab header text. Always pairs the TOTAL with the unread count so a list
/// of (read) alerts never looks empty behind a bare "0 unread" (V5).
public func alertsSummary(total: Int, unread: Int) -> String {
    let noun = total == 1 ? "alert" : "alerts"
    return "\(total) \(noun) • \(unread) unread"
}
