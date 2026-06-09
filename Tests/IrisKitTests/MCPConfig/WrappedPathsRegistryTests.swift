import XCTest
@testable import IrisKit

final class WrappedPathsRegistryTests: XCTestCase {
    private func makeManifestURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-reg-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("wrapped-paths.json")
    }

    func testAddDedupesAndListReturnsInsertionOrder() throws {
        let reg = WrappedPathsRegistry(manifestURL: makeManifestURL())
        try reg.add("/a/.mcp.json")
        try reg.add("/b/.mcp.json")
        try reg.add("/a/.mcp.json")  // duplicate
        XCTAssertEqual(try reg.list(), ["/a/.mcp.json", "/b/.mcp.json"])
    }

    func testRemove() throws {
        let reg = WrappedPathsRegistry(manifestURL: makeManifestURL())
        try reg.add("/a/.mcp.json")
        try reg.add("/b/.mcp.json")
        try reg.remove("/a/.mcp.json")
        XCTAssertEqual(try reg.list(), ["/b/.mcp.json"])
    }

    func testListIsEmptyWhenManifestAbsent() throws {
        let reg = WrappedPathsRegistry(manifestURL: makeManifestURL())
        XCTAssertEqual(try reg.list(), [])
    }

    func testListThrowsOnCorruptManifest() throws {
        let url = makeManifestURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not valid json".utf8).write(to: url)
        let reg = WrappedPathsRegistry(manifestURL: url)
        // Présent mais corrompu → erreur, pas un `[]` silencieux qui écraserait
        // les autres chemins au prochain add/remove.
        XCTAssertThrowsError(try reg.list()) { error in
            guard case WrappedPathsRegistry.RegistryError.corruptManifest = error else {
                return XCTFail("expected corruptManifest, got \(error)")
            }
        }
    }
}
