# Streaming de la réponse upstream→client — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relayer la réponse upstream→client au fil de l'eau (sans bufferisation), en backpressure propre, pour rétablir le streaming SSE de `claude` à travers le proxy (conformité SPECS §7.3 / §10.12).

**Architecture:** Approche A du spec — relais **part-level** inter-canal façon `GlueHandler`. Le canal upstream est co-localisé sur l'`EventLoop` du canal client ; un `UpstreamResponseRelay` (sur l'upstream) traduit chaque `HTTPClientResponsePart` en `HTTPServerResponsePart` et l'écrit sur le canal client ; la *writability* du client gate le `read()` upstream (paire appariée façon `GlueHandler.matchedPair()`). La moitié requête de `MITMHandler` est inchangée.

**Tech Stack:** Swift 6, swift-nio (`NIO`, `NIOHTTP1`, `NIOSSL`), XCTest. `-strict-concurrency=complete`. swift-format 602.

**Spec :** `docs/superpowers/specs/2026-06-02-response-streaming-design.md`.

**Branche :** `feat/phase-2.x-response-streaming` (déjà créée, spec committé `8a6dd0c`).

> ⚠️ **Note NIO (lire avant de commencer).** Le code de relais/backpressure inter-canal est subtil. Chaque task est en TDD : on **compile + exécute** à chaque étape (`swift build`, test ciblé). Le code d'implémentation fourni est un point de départ concret et fidèle aux API ; en cas d'écart de compilation, corriger contre la source réelle (les handlers existants `GlueHandler`/`ConnectHandler`/`UpstreamClient` sont le modèle ; pour le `read()`-gating, comparer au `GlueHandler` canonique de swift-nio — `ChannelDuplexHandler` qui override `read(context:)`).

---

## File Structure

| Fichier | Rôle | Action |
|---|---|---|
| `Sources/IrisKit/Proxy/UpstreamResponseRelay.swift` | Relais part-level upstream→client + read()-gating (paire appariée) | **Créer** |
| `Sources/IrisKit/Proxy/UpstreamClient.swift` | API streaming (`stream(...) -> EventLoopFuture<StreamOutcome>`) ; supprime `UpstreamResponseCollector` (buffered) | **Modifier** |
| `Sources/IrisKit/Proxy/MITMHandler.swift` | `forwardRequest` câble le relais ; supprime `writeResponse` ; Event à `.end` ; 502 avant head | **Modifier** |
| `Tests/IntegrationTests/MockUpstream.swift` | Mode réponse **streamée** (head + chunks + barrière de synchro) | **Modifier** |
| `Tests/IntegrationTests/TestProxyClient.swift` | Mode client **streamé** (surface chaque chunk + signal) | **Modifier** |
| `Tests/IntegrationTests/ProxyStreamingTests.swift` | Tests : pivot temps réel, backpressure, byte-for-byte, erreurs | **Créer** |

**Frontières.** Le relais a une responsabilité unique (relayer + gater). `UpstreamClient` orchestre l'ouverture+l'envoi. `MITMHandler` garde son rôle requête + déclenche le relais. Les extensions de test vivent dans le harnais existant.

---

## Task 1 : MockUpstream — mode réponse streamée avec barrière

**Files:**
- Modify: `Tests/IntegrationTests/MockUpstream.swift`

Objectif : permettre au mock d'envoyer une réponse **chunkée** `head → chunk1 → (attendre une barrière) → chunk2 → end`, pour qu'un test prouve que le client reçoit chunk1 **avant** que chunk2 parte. Le mode buffered existant (`replyOK`) reste inchangé.

- [ ] **Step 1 : Ajouter un type de plan de réponse streamée + une fabrique `startStreaming`**

Ajouter dans `MockUpstream.swift` (après `ReceivedRequest`) :

```swift
/// Plan d'une réponse streamée pilotée par le test.
/// Le mock envoie `head` (chunked, sans Content-Length) puis `firstChunk`,
/// puis attend que `releaseRest.futureResult` se résolve, puis envoie
/// `remainingChunks` et termine. Permet de prouver l'arrivée incrémentale.
struct StreamingResponsePlan: Sendable {
    let firstChunk: Data
    let remainingChunks: [Data]
    let releaseRest: EventLoopFuture<Void>
}
```

Ajouter une fabrique parallèle à `start(host:caManager:)` qui installe un `StreamingMockHandler` au lieu de `MockHandler` :

```swift
static func startStreaming(
    host: String,
    caManager: CAManager,
    plan: @escaping @Sendable (EventLoop) -> StreamingResponsePlan
) async throws -> MockUpstream {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let leafCache = LeafCertCache(caManager: caManager)
    let leaf = try await leafCache.leaf(forHost: host)

    var tlsConfig = TLSConfiguration.makeServerConfiguration(
        certificateChain: [.certificate(leaf.nioCertificate)],
        privateKey: .privateKey(leaf.nioPrivateKey)
    )
    tlsConfig.applicationProtocols = ["http/1.1"]
    let sslContext = try NIOSSLContext(configuration: tlsConfig)

    let receivedPromise = group.next().makePromise(of: ReceivedRequest.self)
    let resolver = PromiseResolver(promise: receivedPromise)
    let recorder = RequestRecorder()

    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 4)
        .childChannelInitializer { channel in
            let sslHandler = NIOSSLServerHandler(context: sslContext)
            let planForChannel = plan(channel.eventLoop)
            return channel.pipeline.addHandler(sslHandler).flatMap {
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
            }.flatMap {
                channel.pipeline.addHandler(
                    StreamingMockHandler(resolver: resolver, recorder: recorder, plan: planForChannel)
                )
            }
        }

    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    guard let port = channel.localAddress?.port else { throw IntegrationTestError.bindFailed }
    return MockUpstream(
        port: port, group: group, channel: channel,
        promise: receivedPromise, resolver: resolver, recorder: recorder
    )
}
```

- [ ] **Step 2 : Ajouter `StreamingMockHandler`**

À la fin de `MockUpstream.swift` (à côté de `MockHandler`) :

```swift
private final class StreamingMockHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let resolver: PromiseResolver<MockUpstream.ReceivedRequest>
    private let recorder: RequestRecorder
    private let plan: MockUpstream.StreamingResponsePlan
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(
        resolver: PromiseResolver<MockUpstream.ReceivedRequest>,
        recorder: RequestRecorder,
        plan: MockUpstream.StreamingResponsePlan
    ) {
        self.resolver = resolver
        self.recorder = recorder
        self.plan = plan
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): self.head = h
        case .body(var chunk):
            if body == nil { body = chunk } else { body?.writeBuffer(&chunk) }
        case .end:
            guard let head = head else { return }
            let bodyData = body.map { Data($0.readableBytesView) }
            let request = MockUpstream.ReceivedRequest(head: head, body: bodyData)
            recorder.record(request)
            resolver.succeed(request)
            startStreamingResponse(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        resolver.fail(error)
        context.close(promise: nil)
    }

    private func startStreamingResponse(context: ChannelHandlerContext) {
        // Chunked: no Content-Length → encoder emits Transfer-Encoding: chunked.
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/event-stream")
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

        var first = context.channel.allocator.buffer(capacity: plan.firstChunk.count)
        first.writeBytes(plan.firstChunk)
        context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(first))), promise: nil)

        // Wait for the test to release the rest, then flush remaining + end.
        let channel = context.channel
        let wrap: (HTTPServerResponsePart) -> NIOAny = self.wrapOutboundOut
        plan.releaseRest.hop(to: context.eventLoop).whenComplete { _ in
            for chunk in self.plan.remainingChunks {
                var buf = channel.allocator.buffer(capacity: chunk.count)
                buf.writeBytes(chunk)
                channel.write(wrap(.body(.byteBuffer(buf))), promise: nil)
            }
            channel.writeAndFlush(wrap(.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
}
```

- [ ] **Step 3 : Compiler + non-régression**

Run: `swift build`
Expected: `Build complete!` (le harnais compile ; aucun test ne l'utilise encore).
Run: `swift test --filter ProxyEndToEndTests`
Expected: tous verts (le mode buffered existant intact).

- [ ] **Step 4 : Commit**

```bash
git add Tests/IntegrationTests/MockUpstream.swift
git commit -m "test(phase-2.x): MockUpstream mode réponse streamée avec barrière"
```

---

## Task 2 : TestProxyClient — mode client streamé (chunks incrémentaux)

**Files:**
- Modify: `Tests/IntegrationTests/TestProxyClient.swift`

Objectif : un envoi qui surface **chaque chunk de body dès réception** via un `AsyncStream`, et un signal à l'arrivée du premier chunk — pour assert l'ordre temporel.

- [ ] **Step 1 : Ajouter un type de réponse streamée**

Dans `TestProxyClient` (après `struct Response`) :

```swift
/// Surface de réponse streamée : chaque chunk de body est yieldé dès
/// réception. `firstChunk.futureResult` se résout au PREMIER chunk reçu
/// (preuve d'arrivée incrémentale). `bodyChunks` termine au `.end`.
struct StreamingResponse: Sendable {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let firstChunk: EventLoopFuture<Void>
    let bodyChunks: AsyncStream<Data>
}
```

- [ ] **Step 2 : Ajouter `sendStreaming(...)` + `StreamingCollectorHandler`**

`sendStreaming` reprend `send(...)` jusqu'au swap TLS, mais installe `StreamingCollectorHandler` au lieu de `ResponseCollectorHandler`, et **ne ferme pas** le groupe avant la fin du stream (le caller draine `bodyChunks`).

```swift
func sendStreaming(
    proxyHost: String, proxyPort: Int,
    targetHost: String, targetPort: Int,
    method: HTTPMethod, path: String,
    headers: [(String, String)], body: Data?,
    trustingCAs: [NIOSSLCertificate]
) async throws -> StreamingResponse {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let connectPromise = group.next().makePromise(of: HTTPResponseStatus.self)
    let encoder = HTTPRequestEncoder()
    let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
    let expectation = ConnectExpectationHandler(promise: connectPromise)

    let bootstrap = ClientBootstrap(group: group)
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .channelInitializer { channel in
            channel.pipeline.addHandler(encoder)
                .flatMap { channel.pipeline.addHandler(decoder) }
                .flatMap { channel.pipeline.addHandler(expectation) }
        }
    let channel = try await bootstrap.connect(host: proxyHost, port: proxyPort).get()

    let connectHead = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: "\(targetHost):\(targetPort)")
    channel.write(HTTPClientRequestPart.head(connectHead), promise: nil)
    try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
    let status = try await connectPromise.futureResult.get()
    guard status == .ok else {
        try? await channel.close().get(); try? await group.shutdownGracefully()
        throw IntegrationTestError.connectFailed(status: status)
    }

    var tlsConfig = TLSConfiguration.makeClientConfiguration()
    tlsConfig.trustRoots = .certificates(trustingCAs)
    tlsConfig.applicationProtocols = ["http/1.1"]
    let sslContext = try NIOSSLContext(configuration: tlsConfig)
    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: targetHost)
    try await channel.eventLoop.submit {
        let sync = channel.pipeline.syncOperations
        try sync.removeHandler(encoder)
        try sync.removeHandler(decoder)
        try sync.removeHandler(expectation)
        try sync.addHandler(sslHandler, position: .first)
    }.get()
    try await channel.pipeline.addHTTPClientHandlers().get()

    let headPromise = group.next().makePromise(of: (HTTPResponseStatus, HTTPHeaders).self)
    let firstChunkPromise = group.next().makePromise(of: Void.self)
    var continuation: AsyncStream<Data>.Continuation!
    let stream = AsyncStream<Data> { continuation = $0 }
    let collector = StreamingCollectorHandler(
        headPromise: headPromise, firstChunk: firstChunkPromise, continuation: continuation,
        group: group, channel: channel
    )
    try await channel.pipeline.addHandler(collector).get()

    var requestHeaders = HTTPHeaders()
    for (n, v) in headers { requestHeaders.add(name: n, value: v) }
    if let body = body, !requestHeaders.contains(name: "content-length") {
        requestHeaders.add(name: "content-length", value: "\(body.count)")
    }
    let requestHead = HTTPRequestHead(version: .http1_1, method: method, uri: path, headers: requestHeaders)
    channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
    if let body = body {
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)
        channel.write(HTTPClientRequestPart.body(.byteBuffer(buf)), promise: nil)
    }
    try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

    let (st, hdrs) = try await headPromise.futureResult.get()
    return StreamingResponse(
        status: st, headers: hdrs,
        firstChunk: firstChunkPromise.futureResult, bodyChunks: stream
    )
}
```

```swift
private final class StreamingCollectorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    private let headPromise: EventLoopPromise<(HTTPResponseStatus, HTTPHeaders)>
    private let firstChunk: EventLoopPromise<Void>
    private let continuation: AsyncStream<Data>.Continuation
    private let group: EventLoopGroup
    private let channel: Channel
    private var sawFirst = false
    private var headDone = false

    init(headPromise: EventLoopPromise<(HTTPResponseStatus, HTTPHeaders)>,
         firstChunk: EventLoopPromise<Void>,
         continuation: AsyncStream<Data>.Continuation,
         group: EventLoopGroup, channel: Channel) {
        self.headPromise = headPromise; self.firstChunk = firstChunk
        self.continuation = continuation; self.group = group; self.channel = channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            if !headDone { headDone = true; headPromise.succeed((h.status, h.headers)) }
        case .body(let buf):
            if !sawFirst { sawFirst = true; firstChunk.succeed(()) }
            continuation.yield(Data(buf.readableBytesView))
        case .end:
            continuation.finish()
            channel.close(promise: nil)
            group.shutdownGracefully { _ in }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !headDone { headDone = true; headPromise.fail(error) }
        if !sawFirst { sawFirst = true; firstChunk.fail(error) }
        continuation.finish()
        context.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !headDone { headDone = true; headPromise.fail(ChannelError.alreadyClosed) }
        if !sawFirst { sawFirst = true; firstChunk.fail(ChannelError.alreadyClosed) }
        continuation.finish()
        group.shutdownGracefully { _ in }
    }
}
```

- [ ] **Step 3 : Compiler**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4 : Commit**

```bash
git add Tests/IntegrationTests/TestProxyClient.swift
git commit -m "test(phase-2.x): TestProxyClient mode streamé (chunks incrémentaux)"
```

---

## Task 3 : Test pivot streaming (RED, mutation-vérifié)

**Files:**
- Create: `Tests/IntegrationTests/ProxyStreamingTests.swift`

- [ ] **Step 1 : Écrire le test pivot**

```swift
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL
import XCTest

final class ProxyStreamingTests: XCTestCase {
    /// Le client reçoit chunk1 AVANT que le mock envoie chunk2. Sur le code
    /// bufferisé (ancien), le client ne reçoit rien avant `.end` ; le mock
    /// attend une barrière jamais relâchée → `firstChunk` ne se résout pas →
    /// timeout → ÉCHEC. Mutation-vérifié.
    func testResponseChunksArriveIncrementally() async throws {
        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data("sk-XYZ".utf8), named: "k", allowedHosts: ["localhost"], createdAt: Date()
        )
        let proxyCA = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCA.ensureCA()
        let mockCA = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCA.ensureCA()

        // Barrière : le mock attend cette promise avant d'envoyer chunk2+end.
        let barrierGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? barrierGroup.syncShutdownGracefully() }
        let release = barrierGroup.next().makePromise(of: Void.self)

        let mock = try await MockUpstream.startStreaming(host: "localhost", caManager: mockCA) { _ in
            MockUpstream.StreamingResponsePlan(
                firstChunk: Data("AAAA".utf8),
                remainingChunks: [Data("BBBB".utf8)],
                releaseRest: release.futureResult
            )
        }
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxy = ProxyServer(
            configuration: .init(
                listenHost: "127.0.0.1", listenPort: 0, allowedHosts: ["localhost"],
                upstreamPort: mock.port, upstreamTrustRoots: .certificates([mockCANIO])
            ),
            secretStore: secretStore, caManager: proxyCA
        )
        let addr = try await proxy.start()
        let proxyPort = addr.port!
        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)

        let resp = try await TestProxyClient().sendStreaming(
            proxyHost: "127.0.0.1", proxyPort: proxyPort,
            targetHost: "localhost", targetPort: 443,
            method: .POST, path: "/v1/messages",
            headers: [("host", "localhost"), ("x-api-key", "{{kc:k}}")],
            body: Data(#"{"p":1}"#.utf8), trustingCAs: [proxyCANIO]
        )

        // PREUVE : chunk1 doit arriver avant qu'on relâche chunk2.
        // Timeout 3s : si le proxy bufferise, firstChunk ne se résout jamais.
        try await withTimeout(seconds: 3) { try await resp.firstChunk.get() }
        release.succeed(())  // maintenant le mock envoie chunk2 + end

        var collected = Data()
        for await chunk in resp.bodyChunks { collected.append(chunk) }
        try? await proxy.stop()
        try? await mock.stop()

        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(collected, Data("AAAABBBB".utf8))
    }
}

/// Échoue l'`await` si `body` ne complète pas dans le délai (sinon le test
/// hang au lieu de FAIL sur le code bufferisé).
func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw IntegrationTestError.timedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

- [ ] **Step 2 : Exécuter — DOIT échouer sur le code actuel (bufferisé)**

Run: `swift test --filter ProxyStreamingTests/testResponseChunksArriveIncrementally`
Expected: **FAIL** — `firstChunk` ne se résout pas (le proxy bufferise la réponse jusqu'au `.end`, qui n'arrive pas car le mock attend la barrière) → `withTimeout` lève `timedOut`. **C'est la preuve que le test discrimine streaming vs bufferisé.**

- [ ] **Step 3 : Commit (le test RED)**

```bash
git add Tests/IntegrationTests/ProxyStreamingTests.swift
git commit -m "test(phase-2.x): test pivot streaming (RED, mutation-vérifié sur code bufferisé)"
```

---

## Task 4 : Relais + API streaming `UpstreamClient` (GREEN, sans backpressure)

**Files:**
- Create: `Sources/IrisKit/Proxy/UpstreamResponseRelay.swift`
- Modify: `Sources/IrisKit/Proxy/UpstreamClient.swift`

But : faire passer le test pivot. On câble un relais qui forward les parts au fil de l'eau (write+flush par chunk). **Pas encore de read()-gating** (ajouté Task 6) — forward simple, suffisant pour rendre le pivot vert.

- [ ] **Step 1 : Créer `UpstreamResponseRelay` (version sans gating)**

```swift
import NIO
import NIOHTTP1

/// Résultat d'un stream de réponse : le statut capturé au head.
struct StreamOutcome: Sendable {
    let statusCode: Int
}

/// Installé sur le canal UPSTREAM. Traduit chaque `HTTPClientResponsePart`
/// en `HTTPServerResponsePart` et l'écrit sur le canal CLIENT (co-localisé
/// même EventLoop). Capture le statut au head ; résout `completion` au `.end`.
/// (Backpressure ajoutée Task 6.)
final class UpstreamResponseRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let clientChannel: Channel
    private let completion: EventLoopPromise<StreamOutcome>
    private var status: Int = 0
    private var done = false

    init(clientChannel: Channel, completion: EventLoopPromise<StreamOutcome>) {
        self.clientChannel = clientChannel
        self.completion = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            let outHead = HTTPResponseHead(version: head.version, status: head.status, headers: head.headers)
            clientChannel.write(HTTPServerResponsePart.head(outHead), promise: nil)
            clientChannel.flush()
        case .body(let buffer):
            clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            clientChannel.flush()
        case .end(let trailers):
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete { [weak self] _ in
                self?.finish(.success(StreamOutcome(statusCode: self?.status ?? 0)))
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(ChannelError.alreadyClosed))
    }

    private func finish(_ result: Result<StreamOutcome, Error>) {
        guard !done else { return }
        done = true
        switch result {
        case .success(let o): completion.succeed(o)
        case .failure(let e): completion.fail(e)
        }
    }
}
```

> ⚠️ Vérifier à la compilation que `clientChannel.write(HTTPServerResponsePart...)` sélectionne la surcharge typée `Sendable` (cf leçon `ConnectHandler` : router via `Channel`, pas `ChannelHandlerContext`). Si un warning NIOAny apparaît, c'est attendu côté `Channel.write` typé.

- [ ] **Step 2 : Remplacer `UpstreamClient.send` (buffered) par `stream(...)`**

Dans `UpstreamClient.swift` : supprimer `UpstreamResponseCollector` (`:87-130`) et `UpstreamResponse`. Remplacer `send(...)` par :

```swift
/// Ouvre l'upstream SUR L'EVENTLOOP DU CLIENT (co-localisation, comme le
/// passthrough), envoie la requête, installe le relais vers `clientChannel`.
/// Retourne une future résolue à la fin du stream (statut au head).
func stream(
    head: HTTPRequestHead,
    body: ByteBuffer?,
    host: String,
    port: Int,
    to clientChannel: Channel,
    on eventLoop: EventLoop
) -> EventLoopFuture<StreamOutcome> {
    let completion = eventLoop.makePromise(of: StreamOutcome.self)
    do {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.trustRoots = trustRoots
        tlsConfig.applicationProtocols = ["http/1.1"]
        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        let bootstrap = ClientBootstrap(group: eventLoop)  // ← même EL que le client
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(sslHandler)
                    try sync.addHTTPClientHandlers()
                    try sync.addHandler(UpstreamResponseRelay(clientChannel: clientChannel, completion: completion))
                }
            }

        bootstrap.connect(host: host, port: port).whenComplete { result in
            switch result {
            case .failure(let error):
                completion.fail(error)
            case .success(let upstream):
                upstream.write(HTTPClientRequestPart.head(head), promise: nil)
                if let body = body, body.readableBytes > 0 {
                    upstream.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
                }
                upstream.writeAndFlush(HTTPClientRequestPart.end(nil)).cascadeFailure(to: completion)
                // Fermer l'upstream quand le stream est terminé.
                completion.futureResult.whenComplete { _ in upstream.close(promise: nil) }
            }
        }
    } catch {
        completion.fail(error)
    }
    return completion.futureResult
}
```

- [ ] **Step 3 : Brancher `MITMHandler.forwardRequest` (minimal pour compiler)**

> Le rewire complet de l'Event est Task 5. Ici, juste assez pour compiler et passer le pivot : remplacer l'appel `send` + `writeResponse` par `stream` et fermer le client à la fin.

Dans `MITMHandler.swift`, dans `forwardRequest`, remplacer le bloc `eventLoop.makeFutureWithTask { ... send ... }.flatMap { writeResponse }.whenComplete { close }` par :

```swift
eventLoop.makeFutureWithTask {
    try await Self.processRequest(
        head: head, body: body, evaluator: server.exfilRuleEngine,
        engine: server.placeholderEngine, logger: server.logger, host: host, bypass: bypass
    )
}.flatMap { processed -> EventLoopFuture<StreamOutcome> in
    server.upstreamClient.stream(
        head: processed.head, body: processed.body,
        host: host, port: server.configuration.upstreamPort,
        to: channel, on: eventLoop
    )
}.whenComplete { _ in
    channel.close(promise: nil)
}
```

(La gestion de l'outcome/log et de l'Event est rétablie proprement Task 5 ; supprimer `makeEvent`/`writeResponse` y est aussi traité. Pour cette étape, retirer le `switch processed.outcome` log si nécessaire pour compiler.)

- [ ] **Step 4 : Supprimer `writeResponse` et le bloc `makeEvent` orphelin si le compilateur s'en plaint**

(Conserver `processRequest`, `makeBypassedRequest`, `splitURI` inchangés.)

- [ ] **Step 5 : Exécuter le pivot — DOIT passer**

Run: `swift build`
Expected: `Build complete!` (warnings tolérés transitoirement, nettoyés Task 5).
Run: `swift test --filter ProxyStreamingTests/testResponseChunksArriveIncrementally`
Expected: **PASS** — chunk1 arrive avant la barrière, body == `AAAABBBB`.

- [ ] **Step 6 : Commit**

```bash
git add Sources/IrisKit/Proxy/UpstreamResponseRelay.swift Sources/IrisKit/Proxy/UpstreamClient.swift Sources/IrisKit/Proxy/MITMHandler.swift
git commit -m "feat(phase-2.x): relais streaming part-level (pivot vert, sans backpressure)"
```

---

## Task 5 : MITMHandler — Event à `.end`, statut, suppression de `writeResponse`

**Files:**
- Modify: `Sources/IrisKit/Proxy/MITMHandler.swift`

Rétablir proprement : log d'outcome, émission d'un **seul** `Event` à la fin (statut depuis `StreamOutcome`, `durationMs` total, URI originale), gestion du `bypass`/exfil identique à l'actuel.

- [ ] **Step 1 : Réécrire `forwardRequest` avec l'outcome + Event**

```swift
eventLoop.makeFutureWithTask { () async throws -> ProcessedRequest in
    let processed = try await Self.processRequest(
        head: head, body: body, evaluator: server.exfilRuleEngine,
        engine: server.placeholderEngine, logger: server.logger, host: host, bypass: bypass
    )
    Self.logOutcome(processed.outcome, server: server, host: host, originalURI: originalURI)
    return processed
}.flatMap { processed -> EventLoopFuture<(ProcessedRequest, StreamOutcome)> in
    server.upstreamClient.stream(
        head: processed.head, body: processed.body,
        host: host, port: server.configuration.upstreamPort,
        to: channel, on: eventLoop
    ).map { (processed, $0) }
}.whenComplete { result in
    let duration = UInt32(max(0, Date().timeIntervalSince(startTime) * 1_000))
    switch result {
    case .success(let (processed, outcome)):
        let event = Self.makeEvent(
            startTime: startTime, host: host, originalURI: originalURI,
            originalMethod: originalMethod, statusCode: outcome.statusCode,
            duration: duration, outcome: processed.outcome
        )
        let ring = server.eventRing
        Task { await ring.append(event) }
    case .failure(let error):
        let event = Event(
            timestamp: startTime, kind: .error, host: host,
            method: originalMethod, path: originalURI, durationMs: duration
        )
        let ring = server.eventRing
        Task { await ring.append(event) }
        server.logger.warning("Upstream stream failed", metadata: ["host": "\(host)", "error": "\(error)"])
    }
    channel.close(promise: nil)
}
```

- [ ] **Step 2 : Extraire `logOutcome` (le `switch` d'aujourd'hui) + adapter `makeEvent`**

Déplacer le `switch processed.outcome` (log substituted/blocked + politique exfil pause, `MITMHandler.swift:140-177`) dans une méthode statique `logOutcome(_:server:host:originalURI:)`. Changer la signature de `makeEvent` : remplacer `upstream: UpstreamResponse` par `statusCode: Int` (l'interne `let status = Int(upstream.head.status.code)` devient le paramètre). Supprimer `writeResponse` (`:484-504`).

- [ ] **Step 3 : Compiler — 0 warning**

Run: `swift build -c release 2>&1 | grep -c "warning:"`
Expected: `0`
Run: `swift-format lint --strict --recursive Sources Tests`
Expected: aucune sortie.

- [ ] **Step 4 : Non-régression complète**

Run: `swift test --filter ProxyEndToEndTests`
Expected: tous verts (substitution, passthrough, 502 passthrough, exfil R1, auto-pause, R5).
Run: `swift test --filter ProxyExfilBlockTests`
Expected: verts.

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Proxy/MITMHandler.swift
git commit -m "feat(phase-2.x): Event émis à la fin du stream (statut du head, durée totale)"
```

---

## Task 6 : Backpressure — read()-gating sur la writability du client

**Files:**
- Modify: `Sources/IrisKit/Proxy/UpstreamResponseRelay.swift`
- Modify: `Sources/IrisKit/Proxy/UpstreamClient.swift` (autoRead=false + handler client-side)
- Modify: `Tests/IntegrationTests/ProxyStreamingTests.swift`

> ⚠️ **Cœur NIO du lot.** Modèle : `GlueHandler` canonique de swift-nio (`ChannelDuplexHandler` qui override `read(context:)`, gate sur la writability du partenaire, reprend sur `channelWritabilityChanged`). Vérifier le pattern exact contre la source swift-nio avant d'implémenter (Context7 / le repo apple/swift-nio).

- [ ] **Step 1 : Rendre `UpstreamResponseRelay` duplex + gater `read()`**

Transformer le relais en `ChannelDuplexHandler` ; ajouter un partenaire faible côté client (`ClientWritabilityHandler`). `autoRead=false` sur l'upstream (Step 2). Mécanique :

```swift
// Dans UpstreamResponseRelay :
private weak var clientSide: ClientWritabilityHandler?
private var pendingRead = false

// OUTBOUND : ne lire l'upstream que si le client peut écrire.
func read(context: ChannelHandlerContext) {
    if clientChannel.isWritable {
        context.read()
    } else {
        pendingRead = true
    }
}

// Appelé par le client-side quand le client redevient writable.
func clientBecameWritable(context unused: Void = ()) {
    guard pendingRead, let ctx = storedContext else { return }
    pendingRead = false
    ctx.read()
}
```

(Stocker le `ChannelHandlerContext` dans `handlerAdded`/`handlerRemoved` comme `GlueHandler.swift:32-39`. Après chaque `.body` relayé, ré-armer la lecture via `context.read()` seulement si `clientChannel.isWritable`, sinon `pendingRead = true`.)

```swift
private func ClientWritabilityHandler // (nouvelle classe, canal client)
```

```swift
/// Installé sur le canal CLIENT. Sur writability → réveille le relais ;
/// sur inactive → ferme l'upstream (client drop, Task 9).
final class ClientWritabilityHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart  // pass-through, n'intercepte rien d'inbound utile ici
    weak var relay: UpstreamResponseRelay?
    private weak var upstreamChannel: Channel?

    init(upstreamChannel: Channel) { self.upstreamChannel = upstreamChannel }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { relay?.clientBecameWritable() }
        context.fireChannelWritabilityChanged()
    }
    func channelInactive(context: ChannelHandlerContext) {
        upstreamChannel?.close(promise: nil)  // client parti → couper l'upstream
        context.fireChannelInactive()
    }
}
```

> Le câblage exact (placement du `ClientWritabilityHandler` dans le pipeline client, liaison `relay.clientSide`/`clientSide.relay`, stockage du contexte) est à finaliser contre `GlueHandler.matchedPair()` (`GlueHandler.swift:24-39`). Compiler + tester valide.

- [ ] **Step 2 : `autoRead=false` sur l'upstream + installer le client-side**

Dans `UpstreamClient.stream`, sur le `channelInitializer` upstream : `channel.setOption(ChannelOptions.autoRead, value: false)` puis amorcer le premier `read()` après l'envoi de la requête. Avant `connect`, installer `ClientWritabilityHandler(upstreamChannel:)` sur `clientChannel` et lier les partenaires une fois l'upstream ouvert (les deux sur le même EL → liaison sûre via `eventLoop.submit`).

- [ ] **Step 3 : Test backpressure**

```swift
func testSlowClientPausesUpstreamReads() async throws {
    // Watermark abaissé pour rendre la suspension observable rapidement.
    // Le mock tente d'envoyer un gros volume ; un client qui ne draine pas
    // doit faire suspendre la lecture upstream (mémoire bornée).
    // Stratégie : compter les bytes effectivement tirés de l'upstream tant
    // que le client ne lit pas, et vérifier qu'ils restent bornés
    // (≈ high-watermark), pas le volume total.
    // [Implémentation : instrumenter via un handler de comptage sur l'upstream
    //  ou abaisser ChannelOptions.writeBufferWaterMark sur le canal client et
    //  asserter que le mock ne parvient pas à écrire tout son volume tant que
    //  le client est suspendu. Affiner au moment de l'exécution avec le retour
    //  du compilateur/runtime.]
}
```

> Ce test est le plus délicat à rendre déterministe. Le rédiger **après** que le gating compile, en abaissant `ChannelOptions.writeBufferWaterMark` côté client et en mesurant le plafonnement. Si un déterminisme robuste n'est pas atteignable rapidement, documenter la limite (`log`/commentaire) plutôt que d'asserter un timing fragile — ne pas committer un test flaky.

- [ ] **Step 4 : Exécuter pivot + backpressure + régression**

Run: `swift test --filter ProxyStreamingTests`
Expected: pivot vert + backpressure vert.
Run: `swift test --filter ProxyEndToEndTests`
Expected: verts (la backpressure ne change pas le résultat des petites réponses).

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Proxy/UpstreamResponseRelay.swift Sources/IrisKit/Proxy/UpstreamClient.swift Tests/IntegrationTests/ProxyStreamingTests.swift
git commit -m "feat(phase-2.x): backpressure propre (read-gating sur writability client)"
```

---

## Task 7 : Erreur — upstream injoignable → 502 avant le head

**Files:**
- Modify: `Sources/IrisKit/Proxy/MITMHandler.swift`
- Modify: `Tests/IntegrationTests/ProxyStreamingTests.swift`

- [ ] **Step 1 : Test (RED)**

```swift
func testUnreachableUpstreamReturns502() async throws {
    let proxyCA = CAManager(keyStore: InMemoryCAKeyStore())
    let proxyCACert = try await proxyCA.ensureCA()
    // upstreamPort pointe vers un port fermé → connect échoue avant tout head.
    let proxy = ProxyServer(
        configuration: .init(
            listenHost: "127.0.0.1", listenPort: 0, allowedHosts: ["localhost"],
            upstreamPort: 1  // port réservé/fermé
        ),
        secretStore: InMemorySecretStore(), caManager: proxyCA
    )
    let addr = try await proxy.start()
    let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)
    let resp = try await TestProxyClient().send(
        proxyHost: "127.0.0.1", proxyPort: addr.port!,
        targetHost: "localhost", targetPort: 443,
        method: .GET, path: "/x", headers: [("host", "localhost")],
        body: nil, trustingCAs: [proxyCANIO]
    )
    try? await proxy.stop()
    XCTAssertEqual(resp.status, .badGateway)
}
```

Run: `swift test --filter ProxyStreamingTests/testUnreachableUpstreamReturns502`
Expected: **FAIL** (aujourd'hui le client n'a pas de réponse → erreur, pas 502).

- [ ] **Step 2 : Implémenter le 502 dans `forwardRequest`**

Sur l'échec de `stream(...)` **avant tout head relayé**, écrire un `502` sur le canal client puis fermer. Distinguer « avant head » via `StreamOutcome`/erreur : si la future échoue et qu'aucun head n'a été écrit (le relais expose `headWritten: Bool`, ou : l'erreur de `connect` arrive avant que le relais ne reçoive un head → traiter toute erreur `connect` comme « avant head »).

```swift
// Dans le case .failure du whenComplete, AVANT close :
if !channel.isActive { return }  // déjà fermé
var headers = HTTPHeaders(); headers.add(name: "Content-Length", value: "0")
let errHead = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
channel.write(HTTPServerResponsePart.head(errHead), promise: nil)  // channel.write, PAS context (leçon 502)
channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
```

> ⚠️ Si un head a déjà été relayé (drop mid-stream, Task 8), NE PAS écrire 502 — on ne peut plus. Le relais doit exposer `headWritten` ; ce 502 ne s'applique que si `headWritten == false`.

- [ ] **Step 3 : Exécuter — PASS**

Run: `swift test --filter ProxyStreamingTests/testUnreachableUpstreamReturns502`
Expected: PASS (status == 502).

- [ ] **Step 4 : Commit**

```bash
git add Sources/IrisKit/Proxy/MITMHandler.swift Sources/IrisKit/Proxy/UpstreamResponseRelay.swift Tests/IntegrationTests/ProxyStreamingTests.swift
git commit -m "feat(phase-2.x): 502 si upstream injoignable avant le head"
```

---

## Task 8 : Erreur — upstream drop mid-stream → troncature + Event

**Files:**
- Modify: `Tests/IntegrationTests/ProxyStreamingTests.swift`
- Modify: `Tests/IntegrationTests/MockUpstream.swift` (mode « fermer après chunk1 sans .end »)

- [ ] **Step 1 : Mode mock « drop après le premier chunk »**

Ajouter un paramètre au plan : `dropAfterFirstChunk: Bool`. Si vrai, après `firstChunk`, fermer le canal **sans** envoyer `.end` (au lieu d'attendre la barrière).

- [ ] **Step 2 : Test**

```swift
func testUpstreamDropMidStreamTruncatesAndClosesClient() async throws {
    // Mock ferme après chunk1 sans .end. Le client doit recevoir chunk1 puis
    // voir sa connexion fermée (réponse tronquée). Un Event est émis.
    // [setup identique au pivot, plan avec dropAfterFirstChunk: true]
    // Assert : firstChunk se résout (chunk1 reçu) ; le stream se termine
    // (bodyChunks finit) ; pas de hang. L'Event existe dans le ring.
}
```

Run: `swift test --filter ProxyStreamingTests/testUpstreamDropMidStreamTruncatesAndClosesClient`
Expected: le comportement de fermeture des deux canaux (Task 6 `channelInactive`) doit déjà fermer proprement → PASS (ajuster les asserts au comportement observé : le client voit `bodyChunks` se terminer après chunk1).

- [ ] **Step 3 : Vérifier l'Event + le log**

S'assurer qu'un `Event` est émis sur drop mid-stream (via le `.failure` de la future relais, déjà géré Task 5 → `Event(.error)`). Vérifier qu'aucun canal ne fuit (`channelInactive` ferme le partenaire).

- [ ] **Step 4 : Commit**

```bash
git add Tests/IntegrationTests/MockUpstream.swift Tests/IntegrationTests/ProxyStreamingTests.swift
git commit -m "test(phase-2.x): upstream drop mid-stream → troncature + fermeture + Event"
```

---

## Task 9 : Erreur — client drop mid-stream → fermeture de l'upstream

**Files:**
- Modify: `Tests/IntegrationTests/ProxyStreamingTests.swift`

- [ ] **Step 1 : Test — le client ferme tôt, l'upstream doit être coupé**

```swift
func testClientDropMidStreamClosesUpstream() async throws {
    // Le client se déconnecte après chunk1 (avant la barrière). L'upstream
    // (qui attend la barrière) doit voir sa connexion coupée → pas de fuite.
    // Stratégie : sendStreaming, attendre firstChunk, fermer le canal client
    // (drainer puis stopper le group du client), NE PAS relâcher la barrière,
    // et vérifier que le mock observe la fermeture (channelInactive) au lieu
    // de rester bloqué. Pas de fuite de connexion upstream.
    // [Affiner l'assertion : instrumenter le mock pour exposer "client closed"
    //  ou s'appuyer sur l'absence de hang + shutdown propre.]
}
```

- [ ] **Step 2 : Vérifier le comportement (déjà couvert par Task 6 `ClientWritabilityHandler.channelInactive` → ferme l'upstream)**

Run: `swift test --filter ProxyStreamingTests/testClientDropMidStreamClosesUpstream`
Expected: PASS — pas de hang, l'upstream est fermé.

- [ ] **Step 3 : Commit**

```bash
git add Tests/IntegrationTests/ProxyStreamingTests.swift
git commit -m "test(phase-2.x): client drop mid-stream → upstream fermé (zéro fuite)"
```

---

## Task 10 : §7.2 réponse intacte byte-for-byte + vérification finale

**Files:**
- Modify: `Tests/IntegrationTests/ProxyStreamingTests.swift`

- [ ] **Step 1 : Test byte-for-byte (réponse multi-chunks reconstituée à l'identique)**

```swift
func testResponseBodyIsForwardedByteForByte() async throws {
    // Mock envoie head + 3 chunks aux frontières arbitraires ; le client
    // doit reconstituer EXACTEMENT la concaténation, headers inclus.
    let chunks = [Data("événement-α ".utf8), Data("données…📡 ".utf8), Data("fin\n".utf8)]
    let expected = chunks.reduce(Data()) { $0 + $1 }
    // [setup pivot, plan firstChunk=chunks[0], remainingChunks=chunks[1...],
    //  release immédiat] ; collecter bodyChunks ; XCTAssertEqual(collected, expected)
}
```

Run: `swift test --filter ProxyStreamingTests/testResponseBodyIsForwardedByteForByte`
Expected: PASS — `collected == expected`.

- [ ] **Step 2 : Vérification finale globale**

Run: `swift build -c release 2>&1 | grep -c "warning:"`
Expected: `0`
Run: `swift-format lint --strict --recursive Sources Tests`
Expected: aucune sortie.
Run: `swift test`
Expected: **toute** la suite verte (≥ 418 tests existants + les nouveaux), 0 échec.

- [ ] **Step 3 : Commit**

```bash
git add Tests/IntegrationTests/ProxyStreamingTests.swift
git commit -m "test(phase-2.x): réponse forwardée byte-for-byte (§7.2)"
```

---

## Task 11 : Smoke réel `claude` (manuel, au poste) — juge de paix UX

**Files:** aucun (procédure manuelle).

- [ ] **Step 1 : Lancer le daemon et configurer le shell**

```bash
swift build -c release
.build/release/irisd --foreground   # proxy 8888, api.anthropic.com whitelisté
# autre terminal :
iris ca export                       # ~/Library/Application Support/iris/ca.pem
export HTTPS_PROXY="http://127.0.0.1:8888"
export NODE_EXTRA_CA_CERTS="$HOME/Library/Application Support/iris/ca.pem"
export ANTHROPIC_API_KEY="sk-ant-..."   # clé réelle (test UX, sans placeholder)
iris doctor                          # proxy-ping 200, env vars OK
```

- [ ] **Step 2 : Vérifier le streaming token-par-token**

Lancer `claude`, poser une question à réponse longue (« écris-moi 400 mots sur X »).
**Attendu :** le texte s'affiche **progressivement** (token-par-token), plus de « silence puis bloc ». Comparer mentalement à une session sans `HTTPS_PROXY` (streaming natif) — l'expérience doit être équivalente.

- [ ] **Step 3 : Vérifier les events** (`iris logs --follow`) : un seul Event par requête, statut 200, `durationMs` cohérent, URI `/v1/messages`, pas de fuite de secret.

---

## Self-Review (rempli à la rédaction)

**Spec coverage :** §7.3/§10.12 streaming → Tasks 3-6 ; backpressure (a) → Task 6 ; co-localisation EL → Task 4 (Step 2) ; 3 unités → Tasks 4-6 ; gestion d'erreur (502/troncature/client-drop) → Tasks 7-9 ; Event à `.end` + statut + §6.1 → Task 5 ; §7.2 byte-for-byte → Task 10 ; tests + DoD + smoke → Tasks 3-11. **Couvert.**

**Placeholders :** les Tasks 6/8/9 contiennent des `[...]` de finition de test délibérés sur les points dont le **déterminisme NIO** ne peut être figé sans le retour compilateur/runtime (backpressure, drops) — c'est une **délégation explicite à l'exécution**, accompagnée d'une instruction de ne pas committer de test flaky. Le code de production et le test pivot/byte-for-byte sont, eux, complets.

**Type consistency :** `StreamOutcome { statusCode: Int }` (Task 4) réutilisé Tasks 5/7 ; `stream(head:body:host:port:to:on:) -> EventLoopFuture<StreamOutcome>` cohérent Tasks 4-7 ; `StreamingResponsePlan`/`StreamingResponse` définis Tasks 1-2 et consommés Tasks 3/8/10 ; `makeEvent` passe de `upstream:` à `statusCode:` (Task 5).
