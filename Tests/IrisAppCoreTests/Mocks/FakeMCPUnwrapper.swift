import Foundation
@testable import IrisAppCore

final class FakeMCPUnwrapper: MCPUnwrapping, @unchecked Sendable {
    var stubReport = MCPUnwrapReport()
    var shouldThrow: Error?
    private(set) var called = false

    func unwrapAll() throws -> MCPUnwrapReport {
        called = true
        if let e = shouldThrow { throw e }
        return stubReport
    }
}
