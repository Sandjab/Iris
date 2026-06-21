import XCTest

@testable import IrisKit

final class PluginManifestTests: XCTestCase {
    private func decode(_ json: String) throws -> PluginManifest {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(PluginManifest.self, from: Data(json.utf8))
    }

    func testDecodesFullManifest() throws {
        let m = try decode(
            #"""
            {
              "id": "org.example.header-tagger",
              "name": "Header Tagger",
              "version": "1.0.0",
              "description": "Tags POST /v1/* requests.",
              "api_version": 1,
              "executable": "bin/header-tagger",
              "hooks": [
                { "event": "on_request",
                  "match": { "hosts": ["api.anthropic.com"], "methods": ["POST"], "path_regex": "^/v1/" },
                  "mutates": true, "on_failure": "skip", "timeout_ms": 200 }
              ],
              "capabilities": { "network": [], "filesystem": ["scratch"] }
            }
            """#
        )
        XCTAssertEqual(m.id, "org.example.header-tagger")
        XCTAssertEqual(m.apiVersion, 1)
        XCTAssertEqual(m.executable, "bin/header-tagger")
        XCTAssertEqual(m.hooks.count, 1)
        XCTAssertEqual(m.hooks[0].event, .onRequest)
        XCTAssertEqual(m.hooks[0].onFailure, .skip)
        XCTAssertEqual(m.hooks[0].timeoutMs, 200)
        XCTAssertEqual(m.hooks[0].match.hosts, ["api.anthropic.com"])
        XCTAssertEqual(m.capabilities.filesystem, ["scratch"])
    }

    func testDefaultsForOmittedFields() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "0.1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ] }
            """#
        )
        XCTAssertEqual(m.description, "")
        XCTAssertEqual(m.hooks[0].mutates, false)
        XCTAssertEqual(m.hooks[0].onFailure, .skip)
        XCTAssertEqual(m.hooks[0].timeoutMs, 1000)
        XCTAssertTrue(m.capabilities.network.isEmpty)
        XCTAssertTrue(m.hooks[0].match.methods.isEmpty)
    }

    func testValidateRejectsPathTraversalId() throws {
        let m = try decode(
            #"""
            { "id": "../evil", "name": "E", "version": "1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ] }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateRejectsUnsupportedApiVersion() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 99, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ] }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.unsupportedApiVersion(99) = error else {
                return XCTFail("expected unsupportedApiVersion, got \(error)")
            }
        }
    }

    func testValidateRejectsAbsoluteExecutable() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "/bin/sh",
              "hooks": [ { "event": "on_request", "match": {} } ] }
            """#
        )
        XCTAssertThrowsError(try m.validate())
    }
}
