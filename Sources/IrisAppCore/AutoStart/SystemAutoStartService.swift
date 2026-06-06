import Foundation
import ServiceManagement

public struct SystemAutoStartService: AutoStartControlling {
    public init() {}
    public func status(_ target: AutoStartTarget) -> AutoStartStatus { .unknown }
    public func register(_ target: AutoStartTarget) throws {}
    public func unregister(_ target: AutoStartTarget) throws {}
    public func openLoginItemsSettings() {}
}
