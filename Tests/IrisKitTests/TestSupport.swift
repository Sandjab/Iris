import XCTest

/// Asserts that an async expression throws. Shared helper (moved here from the
/// former RuntimeRulesStoreTests when that file was removed in Phase 6.3a).
func assertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "Expected throw" : message(), file: file, line: line)
    } catch {
        // expected
    }
}
