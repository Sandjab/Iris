import NIOCore
import NIOEmbedded
import XCTest

@testable import IrisKit

final class FrameCodecTests: XCTestCase {

    // MARK: - Encoder

    func testEncoderPrependsBigEndianLength() throws {
        let channel = EmbeddedChannel(handler: MessageToByteHandler(JSONRPCFrameEncoder()))
        defer { _ = try? channel.finish() }

        var payload = channel.allocator.buffer(capacity: 4)
        payload.writeString("ping")

        try channel.writeOutbound(payload)
        var out = try XCTUnwrap(try channel.readOutbound(as: ByteBuffer.self))
        let length = try XCTUnwrap(out.readInteger(endianness: .big, as: UInt32.self))
        XCTAssertEqual(length, 4)
        XCTAssertEqual(out.readString(length: 4), "ping")
    }

    func testEncoderEmptyPayloadStillFramedWithZeroLength() throws {
        let channel = EmbeddedChannel(handler: MessageToByteHandler(JSONRPCFrameEncoder()))
        defer { _ = try? channel.finish() }

        let payload = channel.allocator.buffer(capacity: 0)
        try channel.writeOutbound(payload)
        var out = try XCTUnwrap(try channel.readOutbound(as: ByteBuffer.self))
        let length = try XCTUnwrap(out.readInteger(endianness: .big, as: UInt32.self))
        XCTAssertEqual(length, 0)
        XCTAssertEqual(out.readableBytes, 0)
    }

    // MARK: - Decoder happy path

    func testDecoderDeliversCompleteFrame() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(JSONRPCFrameDecoder()))
        defer { _ = try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 8)
        buffer.writeInteger(UInt32(4), endianness: .big)
        buffer.writeString("ping")

        try channel.writeInbound(buffer)
        var received = try XCTUnwrap(try channel.readInbound(as: ByteBuffer.self))
        XCTAssertEqual(received.readString(length: received.readableBytes), "ping")
    }

    func testDecoderDeliversTwoBackToBackFrames() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(JSONRPCFrameDecoder()))
        defer { _ = try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeInteger(UInt32(2), endianness: .big)
        buffer.writeString("ab")
        buffer.writeInteger(UInt32(3), endianness: .big)
        buffer.writeString("cde")

        try channel.writeInbound(buffer)
        var first = try XCTUnwrap(try channel.readInbound(as: ByteBuffer.self))
        var second = try XCTUnwrap(try channel.readInbound(as: ByteBuffer.self))
        XCTAssertEqual(first.readString(length: first.readableBytes), "ab")
        XCTAssertEqual(second.readString(length: second.readableBytes), "cde")
    }

    func testDecoderWaitsForFullPayloadWhenHeaderArrivesFirst() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(JSONRPCFrameDecoder()))
        defer { _ = try? channel.finish() }

        // Header only — must not produce anything yet.
        var header = channel.allocator.buffer(capacity: 4)
        header.writeInteger(UInt32(5), endianness: .big)
        try channel.writeInbound(header)
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))

        // Partial payload — still not enough.
        var partial = channel.allocator.buffer(capacity: 3)
        partial.writeString("hel")
        try channel.writeInbound(partial)
        XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))

        // Remaining bytes complete the frame.
        var tail = channel.allocator.buffer(capacity: 2)
        tail.writeString("lo")
        try channel.writeInbound(tail)
        var got = try XCTUnwrap(try channel.readInbound(as: ByteBuffer.self))
        XCTAssertEqual(got.readString(length: got.readableBytes), "hello")
    }

    func testDecoderHandlesSingleByteDrip() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(JSONRPCFrameDecoder()))
        defer { _ = try? channel.finish() }

        var full = channel.allocator.buffer(capacity: 12)
        full.writeInteger(UInt32(8), endianness: .big)
        full.writeString("abcdefgh")
        let bytes = full.readBytes(length: full.readableBytes) ?? []

        for byte in bytes {
            var slice = channel.allocator.buffer(capacity: 1)
            slice.writeInteger(byte)
            try channel.writeInbound(slice)
        }
        var got = try XCTUnwrap(try channel.readInbound(as: ByteBuffer.self))
        XCTAssertEqual(got.readString(length: got.readableBytes), "abcdefgh")
    }

    // MARK: - Decoder limits

    func testDecoderRejectsOversizedFrame() {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(JSONRPCFrameDecoder(maxFrameSize: 16)))
        defer { _ = try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 4)
        buffer.writeInteger(UInt32(64), endianness: .big)

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            guard let framing = error as? JSONRPCFrameError else {
                return XCTFail("expected JSONRPCFrameError, got \(error)")
            }
            XCTAssertEqual(framing, .oversizedFrame(declared: 64, maximum: 16))
        }
    }

    // MARK: - Round trip

    func testRoundTripEncoderThenDecoder() throws {
        let encoder = EmbeddedChannel(handler: MessageToByteHandler(JSONRPCFrameEncoder()))
        defer { _ = try? encoder.finish() }
        let decoder = EmbeddedChannel(handler: ByteToMessageHandler(JSONRPCFrameDecoder()))
        defer { _ = try? decoder.finish() }

        let request = JSONRPCRequest(method: "daemon.status", id: .integer(1))
        let json = try JSONRPCCoder.makeEncoder().encode(request)
        var payload = encoder.allocator.buffer(capacity: json.count)
        payload.writeBytes(json)

        try encoder.writeOutbound(payload)
        let wire = try XCTUnwrap(try encoder.readOutbound(as: ByteBuffer.self))
        try decoder.writeInbound(wire)

        var recovered = try XCTUnwrap(try decoder.readInbound(as: ByteBuffer.self))
        let recoveredBytes = recovered.readBytes(length: recovered.readableBytes) ?? []
        let decoded = try JSONRPCCoder.makeDecoder().decode(
            JSONRPCRequest.self,
            from: Data(recoveredBytes)
        )
        XCTAssertEqual(decoded, request)
    }
}
