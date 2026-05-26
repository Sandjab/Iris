import XCTest

@testable import IrisKit

final class OrderedJSONDocumentTests: XCTestCase {
    // MARK: - Round-trip basic types

    func testRoundTripScalars() throws {
        try assertRoundTrip(#""hello""#)
        try assertRoundTrip(#"42"#)
        try assertRoundTrip(#"3.14"#)
        try assertRoundTrip(#"true"#)
        try assertRoundTrip(#"false"#)
        try assertRoundTrip(#"null"#)
    }

    func testRoundTripEmptyObject() throws {
        try assertRoundTrip(#"{}"#)
    }

    func testRoundTripEmptyArray() throws {
        try assertRoundTrip(#"[]"#)
    }

    // MARK: - Key order preservation

    func testKeyOrderPreservedInRoundTrip() throws {
        let input = #"""
            {
              "zeta": 1,
              "alpha": 2,
              "mike": 3
            }
            """#
        let doc = try OrderedJSONDocument.parse(input)
        let serialized = OrderedJSONDocument.serialize(doc)
        // Find positions of keys in serialized output
        let zetaIdx = serialized.range(of: "\"zeta\"")!.lowerBound
        let alphaIdx = serialized.range(of: "\"alpha\"")!.lowerBound
        let mikeIdx = serialized.range(of: "\"mike\"")!.lowerBound
        XCTAssertLessThan(zetaIdx, alphaIdx)
        XCTAssertLessThan(alphaIdx, mikeIdx)
    }

    func testKeyOrderPreservedNested() throws {
        let input = #"""
            {
              "outer": {
                "z": 1,
                "a": 2
              }
            }
            """#
        let doc = try OrderedJSONDocument.parse(input)
        let out = OrderedJSONDocument.serialize(doc)
        XCTAssertLessThan(out.range(of: "\"z\"")!.lowerBound, out.range(of: "\"a\"")!.lowerBound)
    }

    // MARK: - Nested + arrays

    func testNestedObjectInArray() throws {
        let input = #"""
            {
              "list": [
                { "name": "a" },
                { "name": "b" }
              ]
            }
            """#
        let doc = try OrderedJSONDocument.parse(input)
        let out = OrderedJSONDocument.serialize(doc)
        XCTAssertTrue(out.contains("\"name\""))
        XCTAssertTrue(out.contains("\"a\""))
        XCTAssertTrue(out.contains("\"b\""))
    }

    // MARK: - Escapes + unicode

    func testStringEscapes() throws {
        let input = #""hello\nworld\t\"quoted\"""#
        let doc = try OrderedJSONDocument.parse(input)
        let out = OrderedJSONDocument.serialize(doc)
        // Round-trip: parse should preserve the unescaped value, serializer should re-escape.
        let reparsed = try OrderedJSONDocument.parse(out)
        XCTAssertEqual(OrderedJSONDocument.serialize(reparsed), out)
    }

    func testUnicodeEscape() throws {
        let input = #""étoile""#
        let doc = try OrderedJSONDocument.parse(input)
        // Either accept the escaped form or the literal form on serialize — both are valid JSON.
        let out = OrderedJSONDocument.serialize(doc)
        let reparsed = try OrderedJSONDocument.parse(out)
        XCTAssertEqual(OrderedJSONDocument.serialize(reparsed), out)
    }

    // MARK: - Number types

    func testIntegerPreservedAsInteger() throws {
        let input = #"42"#
        let doc = try OrderedJSONDocument.parse(input)
        let out = OrderedJSONDocument.serialize(doc)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "42")
        // Should NOT become "42.0"
        XCTAssertFalse(out.contains("."))
    }

    func testFloatPreservedWithFraction() throws {
        let input = #"3.14"#
        let doc = try OrderedJSONDocument.parse(input)
        let out = OrderedJSONDocument.serialize(doc)
        XCTAssertTrue(out.contains("3.14"))
    }

    func testLargeInteger() throws {
        let input = #"9223372036854775807"#  // Int64.max
        let doc = try OrderedJSONDocument.parse(input)
        let out = OrderedJSONDocument.serialize(doc)
        XCTAssertTrue(out.contains("9223372036854775807"))
    }

    // MARK: - Whitespace tolerance (parse) + canonical format (serialize)

    func testWhitespaceTolerance() throws {
        let input = "{\n  \"a\":1,\n  \"b\":2\n}\n"
        XCTAssertNoThrow(try OrderedJSONDocument.parse(input))
    }

    func testSerializerEmits2SpaceIndentTrailingNewline() throws {
        let doc = try OrderedJSONDocument.parse(#"{"a":1,"b":[1,2]}"#)
        let out = OrderedJSONDocument.serialize(doc)
        XCTAssertTrue(out.hasSuffix("\n"))
        // Indented form
        XCTAssertTrue(out.contains("  \"a\""))
    }

    // MARK: - Error cases

    func testRejectsTrailingComma() {
        XCTAssertThrowsError(try OrderedJSONDocument.parse(#"{"a": 1,}"#))
        XCTAssertThrowsError(try OrderedJSONDocument.parse(#"[1, 2,]"#))
    }

    func testRejectsComment() {
        XCTAssertThrowsError(try OrderedJSONDocument.parse(#"{"a": 1} // comment"#))
        XCTAssertThrowsError(try OrderedJSONDocument.parse(#"{ /* hi */ "a": 1 }"#))
    }

    func testRejectsBareValue() {
        // JSON requires a value; empty doc invalid
        XCTAssertThrowsError(try OrderedJSONDocument.parse(""))
        XCTAssertThrowsError(try OrderedJSONDocument.parse("   "))
    }

    func testRejectsDuplicateKeys() {
        // Strict mode: duplicate keys are invalid per RFC 8259 §4.
        XCTAssertThrowsError(try OrderedJSONDocument.parse(#"{"a": 1, "a": 2}"#))
    }

    // MARK: - Mutation API

    func testSetValueAtPathPreservesOrder() throws {
        let input = #"""
            {
              "mcpServers": {
                "alpha": {
                  "command": "node",
                  "args": []
                }
              }
            }
            """#
        var doc = try OrderedJSONDocument.parse(input)
        try doc.setValue(
            .object([("HTTPS_PROXY", .string("http://localhost:8080"))]),
            atPath: ["mcpServers", "alpha", "env"]
        )
        let out = OrderedJSONDocument.serialize(doc)
        XCTAssertTrue(out.contains("\"env\""))
        XCTAssertTrue(out.contains("\"HTTPS_PROXY\""))
        // command must still come before args
        XCTAssertLessThan(out.range(of: "\"command\"")!.lowerBound, out.range(of: "\"args\"")!.lowerBound)
    }

    // MARK: - JSONC mode

    func testCommentPositionsEmptyOnStrictParse() throws {
        let doc = try OrderedJSONDocument.parse("{\"a\":1}")
        XCTAssertTrue(doc.commentPositions.isEmpty)
    }

    func testParseOptionsStrictIsDefault() throws {
        // Default options = strict. Comment must still throw.
        XCTAssertThrowsError(try OrderedJSONDocument.parse("// x\n{}")) { error in
            guard case OrderedJSONError.commentNotAllowed = error else {
                return XCTFail("expected commentNotAllowed, got \(error)")
            }
        }
    }

    func testParseOptionsJSONCAcceptsLineComment() throws {
        let doc = try OrderedJSONDocument.parse("// header\n{}", options: .jsonc)
        XCTAssertEqual(doc.root, .object([]))
        XCTAssertEqual(doc.commentPositions.count, 1)
        XCTAssertEqual(doc.commentPositions[0].line, 1)
        XCTAssertEqual(doc.commentPositions[0].column, 1)
        XCTAssertEqual(doc.commentPositions[0].kind, .lineComment)
    }

    // MARK: - Helpers

    private func assertRoundTrip(_ input: String, file: StaticString = #file, line: UInt = #line) throws {
        let doc = try OrderedJSONDocument.parse(input)
        let serialized = OrderedJSONDocument.serialize(doc)
        let reparsed = try OrderedJSONDocument.parse(serialized)
        XCTAssertEqual(
            OrderedJSONDocument.serialize(reparsed),
            serialized,
            file: file,
            line: line
        )
    }
}
