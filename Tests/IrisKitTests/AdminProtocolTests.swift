import Foundation
import IrisKit
import XCTest

final class AdminProtocolTests: XCTestCase {

    func testRuleAddMethodRawValue() {
        XCTAssertEqual(AdminMethod.ruleAdd.rawValue, "rule.add")
        XCTAssertEqual(AdminMethod.ruleList.rawValue, "rule.list")
        XCTAssertEqual(AdminMethod.ruleDelete.rawValue, "rule.delete")
        XCTAssertEqual(AdminMethod.configReload.rawValue, "config.reload")
        XCTAssertEqual(AdminMethod.eventsClear.rawValue, "events.clear")
    }

    func testRuleHostParamsRoundTrip() throws {
        let original = RuleHostParams(host: "api.openai.com")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuleHostParams.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEventsClearResultUsesSnakeCase() throws {
        let result = EventsClearResult(deletedCount: 42)
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"deleted_count\":42"), "expected snake_case, got: \(json)")
    }

    func testConfigReloadResultIgnoredField() throws {
        let result = ConfigReloadResult(reloaded: true, ignored: ["broker.listen", "broker.events_listen"])
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ConfigReloadResult.self, from: data)
        XCTAssertTrue(decoded.reloaded)
        XCTAssertEqual(decoded.ignored, ["broker.listen", "broker.events_listen"])
    }

    func testCustomErrorCodes() {
        XCTAssertEqual(JSONRPCError.ruleProtected.code, -32010)
        XCTAssertEqual(JSONRPCError.ruleNotFound.code, -32011)
        XCTAssertEqual(JSONRPCError.configReloadFailed("x").code, -32012)
    }

}
