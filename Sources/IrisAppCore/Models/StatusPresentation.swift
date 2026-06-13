import Foundation

/// Semantic tint for the daemon-state glyph. Mapped to a concrete SwiftUI colour
/// in the view layer (keeps SwiftUI out of the testable core).
public enum StatusTint: Sendable, Equatable {
    case up, paused, down, connecting
}

/// An SF Symbol whose SHAPE (not only colour) encodes the daemon state — fixes the
/// colour-only `StatusDot` (R4) and stays legible for colour-blind users.
public struct StatusGlyph: Sendable, Equatable {
    public let symbolName: String
    public let tint: StatusTint
}

public func statusGlyph(for status: DaemonStatus) -> StatusGlyph {
    switch status {
    case .up(_, _, let paused):
        return paused
            ? StatusGlyph(symbolName: "pause.circle.fill", tint: .paused)
            : StatusGlyph(symbolName: "checkmark.circle.fill", tint: .up)
    case .down:
        return StatusGlyph(symbolName: "exclamationmark.triangle.fill", tint: .down)
    case .connecting:
        return StatusGlyph(symbolName: "circle.dotted", tint: .connecting)
    }
}
