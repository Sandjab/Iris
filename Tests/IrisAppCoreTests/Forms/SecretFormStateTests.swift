import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class SecretFormStateTests: XCTestCase {
    func testAddRequiresValidNameValueAndHost() {
        let f = SecretFormState(mode: .add)
        XCTAssertFalse(f.canSubmit)  // all empty
        f.name = "tok en"  // space invalid
        f.value = "v"
        f.hostsInput = "api.example.com"
        XCTAssertNotNil(f.validationError)  // bad name
        f.name = "anthropic_api_key"
        XCTAssertNil(f.validationError)  // now valid
        XCTAssertTrue(f.canSubmit)
    }

    func testAddRejectsEmptyHosts() {
        let f = SecretFormState(mode: .add)
        f.name = "tok"
        f.value = "v"
        f.hostsInput = "   "
        XCTAssertEqual(f.validationError, "At least one allowed host is required.")
    }

    func testAddRejectsEmptyValue() {
        let f = SecretFormState(mode: .add)
        f.name = "tok"
        f.hostsInput = "api.example.com"
        XCTAssertEqual(f.validationError, "Value is required.")
    }

    func testHostsParseTrimDedup() {
        let f = SecretFormState(mode: .add)
        f.hostsInput = "a.com, b.com  a.com\nc.com"
        XCTAssertEqual(f.hosts, ["a.com", "b.com", "c.com"])
    }

    func testHostsRejectsMalformed() {
        let f = SecretFormState(mode: .add)
        f.name = "tok"
        f.value = "v"
        f.hostsInput = "a.com, -bad-"
        XCTAssertEqual(f.validationError, "Invalid host: -bad-")
    }

    func testEditPrefillsHostsAndLocksName() {
        let s = Secret(name: "tok", allowedHosts: ["a.com", "b.com"], createdAt: .distantPast)
        let f = SecretFormState(mode: .edit(existing: s))
        XCTAssertEqual(f.name, "tok")
        XCTAssertEqual(f.hosts, ["a.com", "b.com"])
        XCTAssertNil(f.validationError)  // value not required in edit
    }

    func testRotateRequiresValueOnly() {
        let s = Secret(name: "tok", allowedHosts: ["a.com"], createdAt: .distantPast)
        let f = SecretFormState(mode: .rotate(existing: s))
        XCTAssertEqual(f.name, "tok")
        XCTAssertFalse(f.canSubmit)  // empty value
        f.value = "newval"
        XCTAssertTrue(f.canSubmit)
    }

    func testValueDataPreservesBytes() {
        let f = SecretFormState(mode: .add)
        f.value = "abç"
        XCTAssertEqual(f.valueData, Data("abç".utf8))
    }
}
