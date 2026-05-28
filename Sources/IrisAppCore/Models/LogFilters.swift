import Foundation
import IrisKit

public struct LogFilters: Sendable, Equatable {
    public var kinds: Set<Event.Kind>
    public var host: String
    public var search: String

    public init(kinds: Set<Event.Kind> = [], host: String = "", search: String = "") {
        self.kinds = kinds
        self.host = host
        self.search = search
    }

    public func matches(_ event: Event) -> Bool {
        if !kinds.isEmpty && !kinds.contains(event.kind) { return false }
        let hostQuery = host.trimmingCharacters(in: .whitespaces)
        if !hostQuery.isEmpty,
            event.host.range(of: hostQuery, options: .caseInsensitive) == nil
        {
            return false
        }
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            let hayHost = event.host.range(of: needle, options: .caseInsensitive) != nil
            let hayPath = event.path.range(of: needle, options: .caseInsensitive) != nil
            let haySecret = event.substitutedSecrets.contains {
                $0.range(of: needle, options: .caseInsensitive) != nil
            }
            if !(hayHost || hayPath || haySecret) { return false }
        }
        return true
    }
}
