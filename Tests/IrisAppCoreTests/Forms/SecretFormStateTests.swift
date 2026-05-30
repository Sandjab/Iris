import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class SecretFormStateTests: XCTestCase {
    func testPristineAddShowsHintNoErrorAndCannotSubmit() {
        let f = SecretFormState(mode: .add)
        XCTAssertFalse(f.canSubmit)
        XCTAssertNil(f.displayError)  // no alarming message on an untouched form
        XCTAssertEqual(f.incompleteHint, "Enter a name, a value, and at least one allowed host.")
    }

    func testAddMalformedNameShowsErrorOnceTyped() {
        let f = SecretFormState(mode: .add)
        f.name = "bad name"  // non-empty but invalid → error surfaces
        XCTAssertEqual(f.displayError, "Name must match [a-zA-Z0-9_-], 1–64 chars.")
        XCTAssertFalse(f.canSubmit)
    }

    func testAddCompleteIsSubmittableWithNoErrorOrHint() {
        let f = SecretFormState(mode: .add)
        f.name = "anthropic_api_key"
        f.value = "v"
        f.hostsInput = "api.example.com"
        XCTAssertNil(f.displayError)
        XCTAssertNil(f.incompleteHint)
        XCTAssertTrue(f.canSubmit)
    }

    func testAddEmptyValueShowsHintNotError() {
        let f = SecretFormState(mode: .add)
        f.name = "tok"
        f.hostsInput = "api.example.com"
        XCTAssertNil(f.displayError)  // empty value is "incomplete", not "malformed"
        XCTAssertEqual(f.incompleteHint, "Enter a name, a value, and at least one allowed host.")
        XCTAssertFalse(f.canSubmit)
    }

    func testAddEmptyHostsShowsHintNotError() {
        let f = SecretFormState(mode: .add)
        f.name = "tok"
        f.value = "v"
        f.hostsInput = "   "
        XCTAssertNil(f.displayError)
        XCTAssertNotNil(f.incompleteHint)
        XCTAssertFalse(f.canSubmit)
    }

    func testHostsParseTrimDedup() {
        let f = SecretFormState(mode: .add)
        f.hostsInput = "a.com, b.com  a.com\nc.com"
        XCTAssertEqual(f.hosts, ["a.com", "b.com", "c.com"])
    }

    func testMalformedHostShowsError() {
        let f = SecretFormState(mode: .add)
        f.name = "tok"
        f.value = "v"
        f.hostsInput = "a.com, -bad-"
        XCTAssertEqual(f.displayError, "Invalid host: -bad-")
        XCTAssertNil(f.incompleteHint)  // a malformed host suppresses the neutral hint
        XCTAssertFalse(f.canSubmit)
    }

    func testEditPrefillsHostsAndIsSubmittable() {
        let s = Secret(name: "tok", allowedHosts: ["a.com", "b.com"], createdAt: .distantPast)
        let f = SecretFormState(mode: .edit(existing: s))
        XCTAssertEqual(f.name, "tok")
        XCTAssertEqual(f.hosts, ["a.com", "b.com"])
        XCTAssertNil(f.displayError)
        XCTAssertNil(f.incompleteHint)
        XCTAssertTrue(f.canSubmit)
    }

    func testEditClearedHostsShowsHint() {
        let s = Secret(name: "tok", allowedHosts: ["a.com"], createdAt: .distantPast)
        let f = SecretFormState(mode: .edit(existing: s))
        f.hostsInput = ""
        XCTAssertNil(f.displayError)
        XCTAssertEqual(f.incompleteHint, "Enter at least one allowed host.")
        XCTAssertFalse(f.canSubmit)
    }

    func testRotateRequiresValueOnly() {
        let s = Secret(name: "tok", allowedHosts: ["a.com"], createdAt: .distantPast)
        let f = SecretFormState(mode: .rotate(existing: s))
        XCTAssertEqual(f.name, "tok")
        XCTAssertFalse(f.canSubmit)
        XCTAssertNil(f.displayError)
        XCTAssertEqual(f.incompleteHint, "Enter a new value.")
        f.value = "newval"
        XCTAssertTrue(f.canSubmit)
        XCTAssertNil(f.incompleteHint)
    }

    func testValueDataPreservesBytes() {
        let f = SecretFormState(mode: .add)
        f.value = "abç"
        XCTAssertEqual(f.valueData, Data("abç".utf8))
    }
}
