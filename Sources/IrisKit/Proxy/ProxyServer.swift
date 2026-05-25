import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
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
        public var maxSubstitutionsPerMinute: Int
        public var onExfilAttempt: ExfilAttemptPolicy

        public init(
            listenHost: String = "127.0.0.1",
            listenPort: Int = 8888,
            allowedHosts: Set<String>,
            upstreamPort: Int = 443,
            upstreamTrustRoots: NIOSSLTrustRoots = .default,
            maxSubstitutionsPerMinute: Int = 60,
            onExfilAttempt: ExfilAttemptPolicy = .blockAndNotify
        ) {
            self.listenHost = listenHost
            self.listenPort = listenPort
            self.allowedHosts = allowedHosts
            self.upstreamPort = upstreamPort
            self.upstreamTrustRoots = upstreamTrustRoots
            self.maxSubstitutionsPerMinute = maxSubstitutionsPerMinute
            self.onExfilAttempt = onExfilAttempt
        }
    }

    public let configuration: Configuration
    public let logger: Logger
    public let eventRing: EventRing
    let placeholderEngine: PlaceholderEngine
    let exfilRuleEngine: ExfilRuleEngine
    let leafCertCache: LeafCertCache
    let upstreamClient: UpstreamClient

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var serverChannel: Channel?
    private let pauseFlag = NIOLockedValueBox<Bool>(false)

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
        self.exfilRuleEngine = ExfilRuleEngine(
            secretStore: secretStore,
            maxSubstitutionsPerMinute: configuration.maxSubstitutionsPerMinute
        )
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
                channel.eventLoop.makeCompletedFuture(withResultOf: {
                    // .forwardBytes so the TLS ClientHello that may arrive in
                    // the same TCP segment as the CONNECT request is preserved
                    // across the upgrade and reaches the freshly-installed TLS
                    // handler.
                    let decoder = ByteToMessageHandler(
                        HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
                    )
                    let encoder = HTTPResponseEncoder()
                    let connectHandler = ConnectHandler(
                        server: server,
                        plainDecoder: decoder,
                        plainEncoder: encoder
                    )
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(decoder)
                    try sync.addHandler(encoder)
                    try sync.addHandler(connectHandler)
                })
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

    // MARK: - Pause control (SPECS §13.2 daemon.pause / daemon.resume)

    /// When paused, `MITMHandler` skips placeholder substitution and forwards
    /// each request verbatim, emitting an `Event(.passThrough)`. The flag is
    /// guarded by a lock so it can be read from inbound NIO handlers without
    /// suspension.
    public var isPaused: Bool {
        pauseFlag.withLockedValue { $0 }
    }

    public func setPaused(_ paused: Bool) {
        pauseFlag.withLockedValue { $0 = paused }
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
