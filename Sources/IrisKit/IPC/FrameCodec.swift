import Foundation
import NIOCore

// MARK: - Errors

public enum JSONRPCFrameError: Error, Equatable {
    case oversizedFrame(declared: Int, maximum: Int)
    case malformedHeader
}

// MARK: - Decoder

/// Inbound side of the SPECS §13.1 framing: `[4-byte BE uint32 length][JSON]`.
/// Emits the JSON payload as a `ByteBuffer` slice; downstream handlers decode
/// it as a `JSONRPCRequest` / `JSONRPCResponse`.
public final class JSONRPCFrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = ByteBuffer

    /// 1 MiB. Admin requests carry secret values which are tiny in practice,
    /// but stay well below `UInt32.max` to keep a hostile peer from
    /// allocating a multi-GiB buffer.
    public static let defaultMaxFrameSize: Int = 1 << 20

    private let maxFrameSize: Int

    public init(maxFrameSize: Int = JSONRPCFrameDecoder.defaultMaxFrameSize) {
        self.maxFrameSize = maxFrameSize
    }

    public func decode(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        guard buffer.readableBytes >= 4 else { return .needMoreData }
        guard
            let length32 = buffer.getInteger(
                at: buffer.readerIndex,
                endianness: .big,
                as: UInt32.self
            )
        else {
            // readableBytes >= 4 was just checked, so this is unreachable
            // unless the NIO contract changes. Treat as malformed.
            throw JSONRPCFrameError.malformedHeader
        }
        let length = Int(length32)
        guard length <= maxFrameSize else {
            throw JSONRPCFrameError.oversizedFrame(declared: length, maximum: maxFrameSize)
        }
        guard buffer.readableBytes >= 4 + length else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let payload = buffer.readSlice(length: length) else {
            // Same reason as above: defensive only.
            throw JSONRPCFrameError.malformedHeader
        }
        context.fireChannelRead(self.wrapInboundOut(payload))
        return .continue
    }

    public func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        // Drain any complete frame still in the buffer. Partial trailing
        // frames at EOF are dropped — the connection is going away.
        while buffer.readableBytes >= 4 {
            if try decode(context: context, buffer: &buffer) == .needMoreData {
                return .needMoreData
            }
        }
        return .needMoreData
    }
}

// MARK: - Encoder

public final class JSONRPCFrameEncoder: MessageToByteEncoder {
    public typealias OutboundIn = ByteBuffer

    public init() {}

    public func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
        let length = data.readableBytes
        guard length <= Int(UInt32.max) else {
            throw JSONRPCFrameError.oversizedFrame(
                declared: length,
                maximum: Int(UInt32.max)
            )
        }
        out.reserveCapacity(out.writerIndex + 4 + length)
        out.writeInteger(UInt32(length), endianness: .big)
        var input = data
        out.writeBuffer(&input)
    }
}
