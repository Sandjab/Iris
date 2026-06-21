import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class AppModelPluginsTests: XCTestCase {
    private func makeModel() -> AppModel {
        AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    // MARK: - Helpers

    private func makePlugin(id: String, order: Int, enabled: Bool = false) -> Plugin {
        let manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            executable: "plugin",
            hooks: [PluginHook(event: .onRequest, match: HookMatch())]
        )
        return Plugin(
            manifest: manifest,
            enabled: enabled,
            order: order,
            approvedCapabilities: nil,
            pinnedHash: "hash",
            hashMatches: true
        )
    }

    // MARK: - refreshPlugins

    func testRefreshPluginsSortsByOrderAscending() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        // Seed out of order: 2, 0, 1
        admin.stubPlugins = [
            makePlugin(id: "c", order: 2),
            makePlugin(id: "a", order: 0),
            makePlugin(id: "b", order: 1),
        ]
        try await model.refreshPlugins(via: admin)
        XCTAssertEqual(model.plugins.map(\.order), [0, 1, 2])
        XCTAssertEqual(model.plugins.map(\.manifest.id), ["a", "b", "c"])
    }

    // MARK: - installPlugin

    func testInstallPluginRecordsCallsThenRefetches() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        try await model.installPlugin(path: "/tmp/testplugin", via: admin)
        XCTAssertEqual(admin.calls, ["installPlugin(/tmp/testplugin)", "listPlugins"])
        XCTAssertEqual(model.plugins.count, 1)
        XCTAssertEqual(model.plugins.first?.manifest.id, "testplugin")
        XCTAssertFalse(model.plugins.first?.enabled ?? true)
    }

    // MARK: - enablePlugin

    func testEnablePluginRecordsCallsThenRefetches() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.stubPlugins = [makePlugin(id: "myplugin", order: 0, enabled: false)]
        try await model.enablePlugin(id: "myplugin", via: admin)
        XCTAssertEqual(admin.calls, ["enablePlugin(myplugin)", "listPlugins"])
        XCTAssertTrue(model.plugins.first { $0.manifest.id == "myplugin" }?.enabled ?? false)
    }

    // MARK: - disablePlugin

    func testDisablePluginRecordsCallsThenRefetches() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.stubPlugins = [makePlugin(id: "myplugin", order: 0, enabled: true)]
        try await model.disablePlugin(id: "myplugin", via: admin)
        XCTAssertEqual(admin.calls, ["disablePlugin(myplugin)", "listPlugins"])
        XCTAssertFalse(model.plugins.first { $0.manifest.id == "myplugin" }?.enabled ?? true)
    }

    // MARK: - removePlugin

    func testRemovePluginRecordsCallsThenRefetches() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.stubPlugins = [
            makePlugin(id: "alpha", order: 0),
            makePlugin(id: "beta", order: 1),
        ]
        try await model.removePlugin(id: "alpha", via: admin)
        XCTAssertEqual(admin.calls, ["removePlugin(alpha)", "listPlugins"])
        XCTAssertNil(model.plugins.first { $0.manifest.id == "alpha" })
        XCTAssertEqual(model.plugins.count, 1)
    }

    // MARK: - reorderPlugin

    func testReorderPluginRecordsCallsThenRefetches() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.stubPlugins = [
            makePlugin(id: "first", order: 0),
            makePlugin(id: "second", order: 1),
            makePlugin(id: "third", order: 2),
        ]
        // Move "third" to index 0
        try await model.reorderPlugin(id: "third", index: 0, via: admin)
        XCTAssertEqual(admin.calls, ["reorderPlugin(third,0)", "listPlugins"])
        XCTAssertEqual(model.plugins.map(\.manifest.id), ["third", "first", "second"])
        XCTAssertEqual(model.plugins.map(\.order), [0, 1, 2])
    }

    // MARK: - Error path

    func testErrorPropagatesAndLeavesPluginsUnchanged() async throws {
        let model = makeModel()
        let admin = FakeAdminCalling()
        admin.shouldThrow = JSONRPCError(code: -32099, message: "plugin not found")
        do {
            try await model.installPlugin(path: "/tmp/testplugin", via: admin)
            XCTFail("expected throw")
        } catch let e as JSONRPCError {
            XCTAssertEqual(e.code, -32099)
        }
        XCTAssertTrue(model.plugins.isEmpty)
    }
}
