import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOSSL

/// Top-level orchestrator for the local MITM forward proxy.
///
/// Phase 2 deliberately omits:
/// - `allowed_hosts` scoping (Phase 4)
/// - exfiltration detection (Phase 4)
/// - admin RPC / SSE (Phase 3)
/// - request body size cap, gzip, HTTP/2 (Phase 2.x / SPECS §7.5–7.6)
public final class ProxyServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var listenHost: String
        public var listenPort: Int
        public var allowedHosts: Set<String>
        public var upstreamPort: Int
        public var upstreamTrustRoots: NIOSSLTrustRoots

        public init(
            listenHost: String = "127.0.0.1",
            listenPort: Int = 8888,
            allowedHosts: Set<String>,
            upstreamPort: Int = 443,
            upstreamTrustRoots: NIOSSLTrustRoots = .default
        ) {
            self.listenHost = listenHost
            self.listenPort = listenPort
            self.allowedHosts = allowedHosts
            self.upstreamPort = upstreamPort
            self.upstreamTrustRoots = upstreamTrustRoots
        }
    }

    public let configuration: Configuration
    public let logger: Logger
    public let eventRing: EventRing
    let placeholderEngine: PlaceholderEngine
    let leafCertCache: LeafCertCache
    let upstreamClient: UpstreamClient

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var serverChannel: Channel?

    public init(
        configuration: Configuration,
        secretStore: any SecretStore,
        caManager: CAManager,
        group: EventLoopGroup? = nil,
        logger: Logger = Logger(label: "io.iris.proxy")
    ) {
        self.configuration = configuration
        self.logger = logger
        self.eventRing = EventRing()
        self.placeholderEngine = PlaceholderEngine(secretStore: secretStore)
        self.leafCertCache = LeafCertCache(caManager: caManager)
        if let group = group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            self.ownsGroup = true
        }
        self.upstreamClient = UpstreamClient(
            group: self.group,
            trustRoots: configuration.upstreamTrustRoots,
            logger: logger
        )
    }

    /// Binds the listener and returns the bound socket address.
    public func start() async throws -> SocketAddress {
        let server = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // .forwardBytes so the TLS ClientHello that may arrive in the
                // same TCP segment as the CONNECT request is preserved across
                // the upgrade and reaches the freshly-installed TLS handler.
                let decoder = ByteToMessageHandler(
                    HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
                )
                let encoder = HTTPResponseEncoder()
                let connectHandler = ConnectHandler(
                    server: server,
                    plainDecoder: decoder,
                    plainEncoder: encoder
                )
                return channel.pipeline.addHandler(decoder)
                    .flatMap { channel.pipeline.addHandler(encoder) }
                    .flatMap { channel.pipeline.addHandler(connectHandler) }
            }

        let channel =
            try await bootstrap
            .bind(host: configuration.listenHost, port: configuration.listenPort)
            .get()
        self.serverChannel = channel
        guard let address = channel.localAddress else {
            throw ProxyError.bindReportedNoAddress
        }
        logger.info(
            "Proxy bound",
            metadata: [
                "address": "\(address)",
                "allowed_hosts": "\(configuration.allowedHosts.sorted())",
            ]
        )
        return address
    }

    public func stop() async throws {
        if let channel = serverChannel {
            try await channel.close().get()
        }
        serverChannel = nil
        if ownsGroup {
            try await group.shutdownGracefully()
        }
    }
}

public enum ProxyError: Error, LocalizedError {
    case bindReportedNoAddress

    public var errorDescription: String? {
        switch self {
        case .bindReportedNoAddress:
            return "Server channel bound but reported no local address"
        }
    }
}
