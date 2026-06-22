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
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateRejectsPathTraversalExecutable() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 1,
              "executable": "bin/../../../etc/passwd",
              "hooks": [ { "event": "on_request", "match": {} } ] }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateRejectsEmptyName() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "", "version": "1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ] }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateRejectsEmptyVersion() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ] }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateRejectsMalformedNetworkCapability() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ],
              "capabilities": { "network": ["api.example.com"], "filesystem": [] } }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateRejectsNonNumericPort() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ],
              "capabilities": { "network": ["api.example.com:https"], "filesystem": [] } }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateRejectsUnknownFilesystemCapability() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ],
              "capabilities": { "network": [], "filesystem": ["/etc"] } }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateAcceptsWellFormedNetworkCapability() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ],
              "capabilities": { "network": ["api.example.com:443"], "filesystem": ["scratch"] } }
            """#
        )
        XCTAssertNoThrow(try m.validate())
    }

    func testValidateRejectsBareIPv6Host() throws {
        // "::1" splits on the last colon into host ":" + port "1" — a malformed
        // host:port. Bare (unbracketed) IPv6 is rejected; the valid form is
        // bracketed ([::1]:443).
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ],
              "capabilities": { "network": ["::1"], "filesystem": [] } }
            """#
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateAcceptsBracketedIPv6Host() throws {
        let m = try decode(
            #"""
            { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
              "hooks": [ { "event": "on_request", "match": {} } ],
              "capabilities": { "network": ["[::1]:443"], "filesystem": [] } }
            """#
        )
        XCTAssertNoThrow(try m.validate())
    }

    func testDecodesOnCompleteHook() throws {
        let json = """
            {"id":"org.x.sink","name":"Sink","version":"1.0.0","api_version":1,
             "executable":"bin/sink",
             "hooks":[{"event":"on_complete","match":{"hosts":["api.anthropic.com"],"status":[500,502]},
                       "timeout_ms":1000}]}
            """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        try manifest.validate()
        XCTAssertEqual(manifest.hooks.count, 1)
        XCTAssertEqual(manifest.hooks[0].event, .onComplete)
        XCTAssertEqual(manifest.hooks[0].match.status, [500, 502])
    }
}
