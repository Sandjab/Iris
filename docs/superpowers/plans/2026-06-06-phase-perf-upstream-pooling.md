# Phase perf — Pool de connexions upstream — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Réutiliser les connexions TLS vers l'upstream via un pool keep-alive par-EventLoop keyed par host, pour supprimer le re-handshake upstream par requête (~18 ms de surcoût mesuré).

**Architecture:** Un `UpstreamConnectionPool` par EventLoop (état confiné à son EL mono-thread, zéro lock), pré-alloués à l'init et stockés dans un dict immuable porté par `UpstreamClient`. Le pool reçoit une **factory de connexion injectée** (raffinement de spec §5.1 : découple le pool de TLS/HTTP, testable sur TCP nu). `UpstreamClient.stream()` fait `acquire` → installe un relais frais → écrit la requête → `release` à la fin. `UpstreamResponseRelay` devient `RemovableChannelHandler`, se retire à `.end`, et calcule un drapeau `reusable` (framing HTTP/1.1 réutilisable). Le client reste 1-req/conn (`MITMHandler` inchangé).

**Tech Stack:** Swift 5.9+, swift-nio (`EventLoop`, `Channel`, `ClientBootstrap`, `Scheduled`, `RemovableChannelHandler`), swift-nio-ssl, `swift-testing`/XCTest selon les suites existantes.

**Spec:** `docs/superpowers/specs/2026-06-06-phase-perf-upstream-pooling-design.md`

---

## File Structure

| Fichier | Rôle | Action |
| --- | --- | --- |
| `Sources/IrisKit/Proxy/UpstreamConnectionPool.swift` | Pool idle par-EL (acquire/release/idle-timeout/cap/staleness/shutdown) | **Créer** |
| `Sources/IrisKit/Proxy/UpstreamResponseRelay.swift` | `RemovableChannelHandler` + `StreamOutcome.reusable` | Modifier |
| `Sources/IrisKit/Proxy/UpstreamClient.swift` | Dict de pools par-EL ; `stream()` via acquire/release + retry-once ; `shutdown()` | Modifier |
| `Sources/IrisKit/Proxy/ProxyServer.swift` | Appel `upstreamClient.shutdown()` au `stop()` | Modifier |
| `Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift` | Tests unitaires pool (factory + serveur TCP compteur local) | **Créer** |
| `Tests/IntegrationTests/PoolingMockUpstream.swift` | Mock upstream **keep-alive** + compteur de connexions acceptées | **Créer** |
| `Tests/IntegrationTests/ProxyPoolingTests.swift` | Réutilisation / retry-once / framing non réutilisable de bout en bout | **Créer** |

Constantes prod (en tête de `UpstreamConnectionPool.swift`) : `maxIdlePerHost = 4`, `idleTimeout = .seconds(30)`. Injectables via l'init pour les tests.

---

## Task 1: `UpstreamConnectionPool` — acquire / release (réutilisation + cap)

**Files:**
- Create: `Sources/IrisKit/Proxy/UpstreamConnectionPool.swift`
- Test: `Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift`

- [ ] **Step 1: Write the failing test**

Le test utilise un serveur TCP local trivial qui **compte les connexions acceptées** et garde les connexions ouvertes, et une factory qui ouvre une connexion TCP nue (pas de TLS — le pool est agnostique au contenu).

```swift
import NIO
import XCTest
@testable import IrisKit

final class UpstreamConnectionPoolTests: XCTestCase {
    // Serveur TCP local qui garde les connexions ouvertes et compte les accepts.
    final class CountingServer: @unchecked Sendable {
        let channel: Channel
        let group: EventLoopGroup
        private let counter = NIOLockedValueBox<Int>(0)
        var acceptCount: Int { counter.withLockedValue { $0 } }
        var port: Int { channel.localAddress!.port! }

        static func start(on group: EventLoopGroup) throws -> CountingServer {
            let counter = NIOLockedValueBox<Int>(0)
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelInitializer { _ in
                    counter.withLockedValue { $0 += 1 }
                    return group.next().makeSucceededVoidFuture()
                }
            let ch = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
            return CountingServer(channel: ch, group: group, counter: counter)
        }
        private init(channel: Channel, group: EventLoopGroup, counter: NIOLockedValueBox<Int>) {
            self.channel = channel; self.group = group; self.counter = counter
        }
        func stop() throws { try channel.close().wait() }
    }

    func makeFactory(loop: EventLoop) -> UpstreamConnectionPool.ConnectionFactory {
        return { host, port in
            ClientBootstrap(group: loop).connect(host: host, port: port)
        }
    }

    func testReleaseThenAcquireReusesSameChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let server = try CountingServer.start(on: group)
        defer { try? server.stop() }

        let pool = UpstreamConnectionPool(
            eventLoop: loop,
            makeConnection: makeFactory(loop: loop),
            maxIdlePerHost: 4,
            idleTimeout: .seconds(30)
        )

        // acquire #1 → ouvre une connexion (accept == 1)
        let c1 = try loop.flatSubmit { pool.acquire(host: "127.0.0.1", port: server.port) }.wait()
        loop.execute { pool.release(host: "127.0.0.1", channel: c1, reusable: true) }
        // acquire #2 → réutilise la même (accept reste 1)
        let c2 = try loop.flatSubmit { pool.acquire(host: "127.0.0.1", port: server.port) }.wait()

        XCTAssertTrue(c1 === c2, "la connexion doit être réutilisée")
        XCTAssertEqual(server.acceptCount, 1, "une seule connexion TCP doit avoir été acceptée")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UpstreamConnectionPoolTests/testReleaseThenAcquireReusesSameChannel`
Expected: FAIL — `cannot find 'UpstreamConnectionPool' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Logging
import NIO

/// Pool de connexions upstream idle, **un par EventLoop**. Tout l'état est touché
/// uniquement sur `eventLoop` (mono-thread) → aucun lock. Clé = host : une
/// connexion ne sert jamais un autre host (le serverHostname TLS est figé à la
/// création par la factory). Spec §5.1/§7.
final class UpstreamConnectionPool: @unchecked Sendable {
    typealias ConnectionFactory = @Sendable (_ host: String, _ port: Int) -> EventLoopFuture<Channel>

    private struct Pooled {
        let channel: Channel
        var idleTask: Scheduled<Void>?
    }

    private let eventLoop: EventLoop
    private let makeConnection: ConnectionFactory
    private let maxIdlePerHost: Int
    private let idleTimeout: TimeAmount
    private var idle: [String: [Pooled]] = [:]
    private var shuttingDown = false

    init(
        eventLoop: EventLoop,
        makeConnection: @escaping ConnectionFactory,
        maxIdlePerHost: Int = 4,
        idleTimeout: TimeAmount = .seconds(30)
    ) {
        self.eventLoop = eventLoop
        self.makeConnection = makeConnection
        self.maxIdlePerHost = maxIdlePerHost
        self.idleTimeout = idleTimeout
    }

    /// Dépile une connexion idle vivante pour `host`, sinon en ouvre une neuve.
    func acquire(host: String, port: Int) -> EventLoopFuture<Channel> {
        eventLoop.assertInEventLoop()
        while var list = idle[host], !list.isEmpty {
            let pooled = list.removeLast()
            idle[host] = list
            pooled.idleTask?.cancel()
            if pooled.channel.isActive {
                return eventLoop.makeSucceededFuture(pooled.channel)
            }
            // connexion morte → on la jette et on continue (staleness, Task 3)
        }
        return makeConnection(host, port)
    }

    /// Rend une connexion au pool si réutilisable et sous le cap, sinon la ferme.
    func release(host: String, channel: Channel, reusable: Bool) {
        eventLoop.assertInEventLoop()
        guard reusable, !shuttingDown, channel.isActive else {
            channel.close(promise: nil)
            return
        }
        var list = idle[host] ?? []
        guard list.count < maxIdlePerHost else {
            channel.close(promise: nil)
            return
        }
        let task = eventLoop.scheduleTask(in: idleTimeout) { [weak self] in
            self?.expire(host: host, channel: channel)
        }
        list.append(Pooled(channel: channel, idleTask: task))
        idle[host] = list
    }

    private func expire(host: String, channel: Channel) {
        eventLoop.assertInEventLoop()
        remove(host: host, channel: channel)
        channel.close(promise: nil)
    }

    private func remove(host: String, channel: Channel) {
        guard var list = idle[host] else { return }
        list.removeAll { $0.channel === channel }
        idle[host] = list.isEmpty ? nil : list
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UpstreamConnectionPoolTests/testReleaseThenAcquireReusesSameChannel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Proxy/UpstreamConnectionPool.swift Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift
git commit -m "feat(phase-perf): UpstreamConnectionPool acquire/release with reuse"
```

---

## Task 2: cap dépassé → fermeture au release

**Files:**
- Modify: `Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testReleaseBeyondCapClosesConnection() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let loop = group.next()
    let server = try CountingServer.start(on: group)
    defer { try? server.stop() }

    let pool = UpstreamConnectionPool(
        eventLoop: loop, makeConnection: makeFactory(loop: loop),
        maxIdlePerHost: 2, idleTimeout: .seconds(30)
    )

    // Ouvre 3 connexions distinctes, puis release les 3 (cap = 2).
    var chans: [Channel] = []
    for _ in 0..<3 {
        chans.append(try loop.flatSubmit { pool.acquire(host: "127.0.0.1", port: server.port) }.wait())
    }
    for c in chans { loop.execute { pool.release(host: "127.0.0.1", channel: c, reusable: true) } }
    // Laisse l'EL traiter les release/close.
    try loop.submit {}.wait()
    try loop.scheduleTask(in: .milliseconds(50)) {}.futureResult.wait()

    let active = chans.filter { $0.isActive }.count
    XCTAssertEqual(active, 2, "seules `cap` connexions sont gardées, la 3e est fermée")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UpstreamConnectionPoolTests/testReleaseBeyondCapClosesConnection`
Expected: PASS déjà (le cap est implémenté en Task 1). Si FAIL, corriger `release`.

> Note : ce comportement est couvert par Task 1 step 3. Cette tâche ajoute le **test de régression** explicite (CLAUDE.md §7).

- [ ] **Step 3: Commit**

```bash
git add Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift
git commit -m "test(phase-perf): pool closes connections beyond per-host cap"
```

---

## Task 3: staleness — une connexion idle morte est sautée à l'acquire

**Files:**
- Modify: `Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testAcquireSkipsDeadIdleConnection() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let loop = group.next()
    let server = try CountingServer.start(on: group)
    defer { try? server.stop() }

    let pool = UpstreamConnectionPool(
        eventLoop: loop, makeConnection: makeFactory(loop: loop),
        maxIdlePerHost: 4, idleTimeout: .seconds(30)
    )

    let c1 = try loop.flatSubmit { pool.acquire(host: "127.0.0.1", port: server.port) }.wait()
    loop.execute { pool.release(host: "127.0.0.1", channel: c1, reusable: true) }
    try c1.close().wait()  // simule une connexion fermée pendant qu'elle est idle

    // acquire suivant : la connexion idle est inactive → en ouvre une neuve.
    let c2 = try loop.flatSubmit { pool.acquire(host: "127.0.0.1", port: server.port) }.wait()
    XCTAssertFalse(c1 === c2)
    XCTAssertTrue(c2.isActive)
    XCTAssertEqual(server.acceptCount, 2, "une nouvelle connexion a été ouverte")
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter UpstreamConnectionPoolTests/testAcquireSkipsDeadIdleConnection`
Expected: PASS (la boucle `while` de `acquire` saute `!isActive` — Task 1 step 3).

- [ ] **Step 3: Commit**

```bash
git add Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift
git commit -m "test(phase-perf): pool skips dead idle connection on acquire"
```

---

## Task 4: idle-timeout + shutdown

**Files:**
- Modify: `Sources/IrisKit/Proxy/UpstreamConnectionPool.swift`
- Modify: `Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift`

- [ ] **Step 1: Write the failing test (idle-timeout + shutdown)**

```swift
func testIdleConnectionClosedAfterTimeout() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let loop = group.next()
    let server = try CountingServer.start(on: group)
    defer { try? server.stop() }

    let pool = UpstreamConnectionPool(
        eventLoop: loop, makeConnection: makeFactory(loop: loop),
        maxIdlePerHost: 4, idleTimeout: .milliseconds(80)  // délai court injecté
    )
    let c1 = try loop.flatSubmit { pool.acquire(host: "127.0.0.1", port: server.port) }.wait()
    loop.execute { pool.release(host: "127.0.0.1", channel: c1, reusable: true) }
    // Attend > idleTimeout.
    try loop.scheduleTask(in: .milliseconds(200)) {}.futureResult.wait()
    XCTAssertFalse(c1.isActive, "la connexion idle est fermée après le timeout")
}

func testShutdownClosesAllIdle() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let loop = group.next()
    let server = try CountingServer.start(on: group)
    defer { try? server.stop() }

    let pool = UpstreamConnectionPool(
        eventLoop: loop, makeConnection: makeFactory(loop: loop),
        maxIdlePerHost: 4, idleTimeout: .seconds(30)
    )
    let c1 = try loop.flatSubmit { pool.acquire(host: "127.0.0.1", port: server.port) }.wait()
    loop.execute { pool.release(host: "127.0.0.1", channel: c1, reusable: true) }
    try loop.flatSubmit { pool.shutdown() }.wait()
    XCTAssertFalse(c1.isActive)
}
```

- [ ] **Step 2: Run to verify idle-timeout passes, shutdown fails**

Run: `swift test --filter UpstreamConnectionPoolTests/testShutdownClosesAllIdle`
Expected: FAIL — `value of type 'UpstreamConnectionPool' has no member 'shutdown'`.

- [ ] **Step 3: Add `shutdown()`**

Ajouter dans `UpstreamConnectionPool` :

```swift
    /// Ferme toutes les connexions idle. Appelé à l'arrêt du daemon.
    func shutdown() -> EventLoopFuture<Void> {
        eventLoop.flatSubmit {
            self.shuttingDown = true
            let all = self.idle.values.flatMap { $0 }
            self.idle.removeAll()
            let closes = all.map { pooled -> EventLoopFuture<Void> in
                pooled.idleTask?.cancel()
                return pooled.channel.close()
            }
            return EventLoopFuture.andAllComplete(closes, on: self.eventLoop)
        }
    }
```

- [ ] **Step 4: Run both tests**

Run: `swift test --filter UpstreamConnectionPoolTests`
Expected: PASS (toutes les méthodes du pool).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Proxy/UpstreamConnectionPool.swift Tests/IrisKitTests/Proxy/UpstreamConnectionPoolTests.swift
git commit -m "feat(phase-perf): pool idle-timeout + shutdown"
```

---

## Task 5: `UpstreamResponseRelay` — `RemovableChannelHandler` + drapeau `reusable`

**Files:**
- Modify: `Sources/IrisKit/Proxy/UpstreamResponseRelay.swift`
- Test: `Tests/IrisKitTests/Proxy/RelayReusabilityTests.swift` (créer)

Objectif : `StreamOutcome` porte `reusable: Bool`, calculé à partir de la réponse (framing HTTP/1.1 réutilisable). Le relais devient retirable du pipeline.

- [ ] **Step 1: Write the failing test (pure logic of reusability)**

On teste la fonction de décision isolée (statique, sans channel) pour la garder déterministe.

```swift
import NIOHTTP1
import XCTest
@testable import IrisKit

final class RelayReusabilityTests: XCTestCase {
    private func head(_ version: HTTPVersion, _ pairs: [(String, String)]) -> HTTPResponseHead {
        var h = HTTPHeaders(); for (n, v) in pairs { h.add(name: n, value: v) }
        return HTTPResponseHead(version: version, status: .ok, headers: h)
    }

    func testReusableWithContentLength() {
        XCTAssertTrue(UpstreamResponseRelay.isReusable(head(.http1_1, [("content-length", "2")])))
    }
    func testReusableWithChunked() {
        XCTAssertTrue(UpstreamResponseRelay.isReusable(head(.http1_1, [("transfer-encoding", "chunked")])))
    }
    func testNotReusableWithConnectionClose() {
        XCTAssertFalse(UpstreamResponseRelay.isReusable(head(.http1_1, [("content-length", "2"), ("connection", "close")])))
    }
    func testNotReusableWithoutDefiniteFraming() {
        XCTAssertFalse(UpstreamResponseRelay.isReusable(head(.http1_1, [])))  // close-delimited
    }
    func testNotReusableHTTP10() {
        XCTAssertFalse(UpstreamResponseRelay.isReusable(head(.http1_0, [("content-length", "2")])))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RelayReusabilityTests`
Expected: FAIL — `type 'UpstreamResponseRelay' has no member 'isReusable'`.

- [ ] **Step 3: Implement `isReusable` + extend `StreamOutcome` + track on head**

Dans `UpstreamResponseRelay.swift`, modifier `StreamOutcome` et le handler :

```swift
struct StreamOutcome: Sendable {
    let statusCode: Int
    let reusable: Bool
}
```

Ajouter la fonction de décision (statique, testable) et conformer `RemovableChannelHandler` :

```swift
final class UpstreamResponseRelay: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    // ... typealias / init inchangés ...
    private var reusable = false

    /// HTTP/1.1 keep-alive réutilisable ⟺ version 1.1, pas de `Connection: close`,
    /// et framing délimité (Content-Length OU chunked). Sinon close-delimited → non.
    static func isReusable(_ head: HTTPResponseHead) -> Bool {
        guard head.version == .http1_1 else { return false }
        let connectionTokens = head.headers[canonicalForm: "connection"].map { $0.lowercased() }
        if connectionTokens.contains("close") { return false }
        let hasContentLength = head.headers.contains(name: "content-length")
        let isChunked = head.headers[canonicalForm: "transfer-encoding"]
            .map { $0.lowercased() }.contains("chunked")
        return hasContentLength || isChunked
    }
```

Dans `channelRead` au cas `.head` : `reusable = Self.isReusable(head)` (juste après `headWritten.value = true`). Au cas `.end` (succès) : `self.finish(.success(StreamOutcome(statusCode: self.status, reusable: self.reusable)))`. Sur échec/`channelInactive`/`errorCaught` : `reusable` reste `false`, donc `finish(.failure(...))` (UpstreamClient traitera l'échec comme non réutilisable).

- [ ] **Step 4: Run reusability tests**

Run: `swift test --filter RelayReusabilityTests`
Expected: PASS.

- [ ] **Step 5: Run the existing proxy suites (no regression on StreamOutcome change)**

Run: `swift test --filter ProxyStreamingTests` puis `swift test --filter ProxyEndToEndTests`
Expected: PASS (le champ `reusable` est additif ; les call-sites de `UpstreamClient` seront mis à jour en Task 6 — si la compilation casse ici, c'est attendu : faire Task 6 dans le même commit logique).

> Si Task 5 ne compile pas seule à cause des call-sites `StreamOutcome` dans `UpstreamClient`, enchaîner directement Task 6 et committer les deux ensemble.

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/Proxy/UpstreamResponseRelay.swift Tests/IrisKitTests/Proxy/RelayReusabilityTests.swift
git commit -m "feat(phase-perf): relay computes reusable flag + becomes removable"
```

---

## Task 6: `UpstreamClient.stream()` — pool acquire/release + retry-once

**Files:**
- Modify: `Sources/IrisKit/Proxy/UpstreamClient.swift`

`UpstreamClient` détient un dict immuable `[ObjectIdentifier(EventLoop): UpstreamConnectionPool]` construit à l'init, et `stream()` acquiert/relâche au lieu d'ouvrir/fermer.

- [ ] **Step 1: Rewrite `UpstreamClient`**

```swift
import Logging
import NIO
import NIOHTTP1
import NIOSSL

final class UpstreamClient: @unchecked Sendable {
    private let group: EventLoopGroup
    private let trustRoots: NIOSSLTrustRoots
    private let logger: Logger
    private let pools: [ObjectIdentifier: UpstreamConnectionPool]

    init(group: EventLoopGroup, trustRoots: NIOSSLTrustRoots, logger: Logger) {
        self.group = group
        self.trustRoots = trustRoots
        self.logger = logger

        // Un pool par EventLoop, pré-alloué (dict immuable après init → lecture
        // cross-EL safe). La factory ouvre une connexion TLS+HTTP1.1 fraîche,
        // co-localisée sur l'EL du pool (invariance « relais sans hop »).
        var pools: [ObjectIdentifier: UpstreamConnectionPool] = [:]
        for loop in group.makeIterator() {
            let factory: UpstreamConnectionPool.ConnectionFactory = { host, port in
                Self.openConnection(host: host, port: port, on: loop, trustRoots: trustRoots)
            }
            pools[ObjectIdentifier(loop)] = UpstreamConnectionPool(
                eventLoop: loop, makeConnection: factory
            )
        }
        self.pools = pools
    }

    /// Ouvre une connexion TLS + HTTP/1.1 vers l'upstream (SANS relais : le relais
    /// par-requête est ajouté à l'emprunt par `stream`). Co-localisée sur `loop`.
    private static func openConnection(
        host: String, port: Int, on loop: EventLoop, trustRoots: NIOSSLTrustRoots
    ) -> EventLoopFuture<Channel> {
        do {
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.trustRoots = trustRoots
            tls.applicationProtocols = ["http/1.1"]
            let ctx = try NIOSSLContext(configuration: tls)
            return ClientBootstrap(group: loop)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture(withResultOf: {
                        let ssl = try NIOSSLClientHandler(context: ctx, serverHostname: host)
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(ssl)
                        try sync.addHTTPClientHandlers()
                    })
                }
                .connect(host: host, port: port)
        } catch {
            return loop.makeFailedFuture(error)
        }
    }

    /// Acquiert une connexion (poolée ou neuve), installe un relais frais, écrit la
    /// requête, streame la réponse, puis relâche la connexion. Retry-once si la
    /// connexion poolée est morte AVANT toute réponse.
    func stream(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        host: String,
        port: Int,
        to clientChannel: Channel,
        on eventLoop: EventLoop,
        headWritten: NIOLoopBoundBox<Bool>
    ) -> EventLoopFuture<StreamOutcome> {
        guard let pool = pools[ObjectIdentifier(eventLoop)] else {
            return eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
        }
        return attempt(
            pool: pool, head: head, body: body, host: host, port: port,
            to: clientChannel, on: eventLoop, headWritten: headWritten, allowRetry: true
        )
    }

    private func attempt(
        pool: UpstreamConnectionPool,
        head: HTTPRequestHead, body: ByteBuffer?, host: String, port: Int,
        to clientChannel: Channel, on eventLoop: EventLoop,
        headWritten: NIOLoopBoundBox<Bool>, allowRetry: Bool
    ) -> EventLoopFuture<StreamOutcome> {
        pool.acquire(host: host, port: port).flatMap { upstream -> EventLoopFuture<StreamOutcome> in
            let completion = eventLoop.makePromise(of: StreamOutcome.self)

            // Backpressure : relais frais sur l'upstream + writability handler sur le client.
            let box = UpstreamChannelBox()
            box.channel = upstream
            let clientSide = ClientWritabilityHandler(upstream: box)
            let relay = UpstreamResponseRelay(
                clientChannel: clientChannel, completion: completion, headWritten: headWritten
            )
            do {
                try clientChannel.pipeline.syncOperations.addHandler(clientSide)
                try upstream.pipeline.syncOperations.addHandler(relay)
            } catch {
                completion.fail(error)
                return completion.futureResult
            }

            guard clientChannel.isActive else {
                upstream.close(promise: nil)
                completion.fail(ChannelError.alreadyClosed)
                return completion.futureResult
            }
            upstream.write(HTTPClientRequestPart.head(head), promise: nil)
            if let body = body, body.readableBytes > 0 {
                upstream.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
            }
            upstream.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { _ in
                upstream.close(promise: nil)  // → relay.channelInactive résout completion une fois
            }

            // À la fin : retirer le relais, puis relâcher (réutilisable ou close).
            completion.futureResult.whenComplete { result in
                let removeFuture = upstream.pipeline.removeHandler(relay)
                switch result {
                case .success(let outcome):
                    removeFuture.whenComplete { _ in
                        pool.release(host: host, channel: upstream, reusable: outcome.reusable)
                    }
                case .failure:
                    removeFuture.whenComplete { _ in
                        pool.release(host: host, channel: upstream, reusable: false)
                    }
                }
            }
            return completion.futureResult
        }.flatMapError { error in
            // Retry-once : connexion poolée morte AVANT toute réponse (headWritten==false).
            if allowRetry, !headWritten.value {
                return self.attempt(
                    pool: pool, head: head, body: body, host: host, port: port,
                    to: clientChannel, on: eventLoop, headWritten: headWritten, allowRetry: false
                )
            }
            return eventLoop.makeFailedFuture(error)
        }
    }

    /// Ferme toutes les connexions idle de tous les pools.
    func shutdown() -> EventLoopFuture<Void> {
        let futures = pools.values.map { $0.shutdown() }
        return EventLoopFuture.andAllComplete(futures, on: group.next())
    }
}
```

> Note retrait du relais : `UpstreamResponseRelay` est désormais `RemovableChannelHandler` (Task 5), donc `pipeline.removeHandler(relay)` est valide. La connexion rendue au pool n'a plus que `NIOSSLClientHandler` + HTTP client handlers — prête pour un relais frais au prochain `acquire`.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: SUCCEEDED (les call-sites `StreamOutcome` sont cohérents avec Task 5).

- [ ] **Step 3: Run existing proxy suites (non-régression)**

Run: `swift test --filter ProxyEndToEndTests && swift test --filter ProxyStreamingTests && swift test --filter ProxyExfilBlockTests && swift test --filter ProxySubstitutionUsageTests`
Expected: PASS — comportement fonctionnel identique (les mocks ferment après réponse → `reusable:false`/connexion morte → release ferme, comme avant).

- [ ] **Step 4: Commit**

```bash
git add Sources/IrisKit/Proxy/UpstreamClient.swift
git commit -m "feat(phase-perf): UpstreamClient streams via per-EL pool + retry-once"
```

---

## Task 7: `ProxyServer.stop()` ferme les pools

**Files:**
- Modify: `Sources/IrisKit/Proxy/ProxyServer.swift`

- [ ] **Step 1: Locate `stop()` and the channel teardown**

Run: `grep -n "func stop\|serverChannel\|shutdownGracefully\|func shutdown" Sources/IrisKit/Proxy/ProxyServer.swift`
Expected : repère la méthode d'arrêt (fermeture du `serverChannel` + shutdown du group si `ownsGroup`).

- [ ] **Step 2: Add the pool shutdown before group shutdown**

Dans la méthode d'arrêt de `ProxyServer`, **avant** de fermer le group (et après avoir fermé le `serverChannel`), insérer :

```swift
        try await upstreamClient.shutdown().get()
```

(Si `stop()` n'est pas `async`, l'appeler via le pattern d'arrêt existant — calquer sur la façon dont `serverChannel?.close()` est attendu dans la même méthode.)

- [ ] **Step 3: Build + run hot-reload suite (touche le cycle de vie ProxyServer)**

Run: `swift build && swift test --filter ProxyServerHotReloadTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/IrisKit/Proxy/ProxyServer.swift
git commit -m "feat(phase-perf): ProxyServer closes upstream pools on stop"
```

---

## Task 8: Test d'intégration — réutilisation (2 requêtes ⇒ 1 connexion)

**Files:**
- Create: `Tests/IntegrationTests/PoolingMockUpstream.swift`
- Create: `Tests/IntegrationTests/ProxyPoolingTests.swift`

Le `MockUpstream` existant ferme après chaque réponse (`MockHandler.replyOK` → `context.close`). Il faut un mock **keep-alive** (Content-Length, pas de close) qui **compte les connexions acceptées**.

- [ ] **Step 1: Write `PoolingMockUpstream`**

```swift
import Foundation
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL

/// Mock upstream TLS keep-alive : répond `200 OK` (Content-Length, SANS fermer)
/// à chaque requête sur la même connexion, et compte les connexions acceptées.
/// `closeAfterFirstResponse` simule une connexion idle tuée par le serveur.
final class PoolingMockUpstream: @unchecked Sendable {
    let port: Int
    private let group: EventLoopGroup
    private let channel: Channel
    private let accepts = NIOLockedValueBox<Int>(0)
    var acceptCount: Int { accepts.withLockedValue { $0 } }

    private init(port: Int, group: EventLoopGroup, channel: Channel, accepts: NIOLockedValueBox<Int>) {
        self.port = port; self.group = group; self.channel = channel; self.accepts = accepts
    }

    static func start(
        host: String, caManager: CAManager,
        connectionHeaderClose: Bool = false,
        closeAfterFirstResponse: Bool = false
    ) async throws -> PoolingMockUpstream {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let leaf = try await LeafCertCache(caManager: caManager).leaf(forHost: host)
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(leaf.nioCertificate)],
            privateKey: .privateKey(leaf.nioPrivateKey)
        )
        tls.applicationProtocols = ["http/1.1"]
        let ctx = try NIOSSLContext(configuration: tls)
        let accepts = NIOLockedValueBox<Int>(0)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                accepts.withLockedValue { $0 += 1 }
                let ssl = NIOSSLServerHandler(context: ctx)
                return channel.pipeline.addHandler(ssl).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                }.flatMap {
                    channel.pipeline.addHandler(KeepAliveHandler(
                        connectionClose: connectionHeaderClose,
                        closeAfterFirst: closeAfterFirstResponse
                    ))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = ch.localAddress?.port else { throw IntegrationTestError.bindFailed }
        return PoolingMockUpstream(port: port, group: group, channel: ch, accepts: accepts)
    }

    func stop() async throws {
        try await channel.close().get()
        try await group.shutdownGracefully()
    }

    private final class KeepAliveHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        private let connectionClose: Bool
        private let closeAfterFirst: Bool
        private var served = 0
        init(connectionClose: Bool, closeAfterFirst: Bool) {
            self.connectionClose = connectionClose; self.closeAfterFirst = closeAfterFirst
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .end = unwrapInboundIn(data) else { return }
            served += 1
            var headers = HTTPHeaders()
            headers.add(name: "content-length", value: "2")
            if connectionClose { headers.add(name: "connection", value: "close") }
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: 2); buf.writeString("OK")
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            let shouldClose = connectionClose || (closeAfterFirst && served == 1)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                if shouldClose { context.close(promise: nil) }
            }
        }
    }
}
```

- [ ] **Step 2: Write the failing reuse test**

Calquer le harnais existant (`ProxyEndToEndTests`) pour démarrer un `ProxyServer` éphémère, un CA, et un `TestProxyClient`. Le client envoie **deux requêtes séquentielles** (chacune rouvre côté client — normal, 1-req/conn).

```swift
import Foundation
import NIOHTTP1
import XCTest
@testable import IrisKit

final class ProxyPoolingTests: XCTestCase {
    func testTwoSequentialRequestsReuseOneUpstreamConnection() async throws {
        let host = "api.anthropic.com"
        let harness = try await ProxyTestHarness.start(host: host)  // helper existant ou inline
        defer { Task { try? await harness.stop() } }
        let mock = try await PoolingMockUpstream.start(host: host, caManager: harness.caManager)
        defer { Task { try? await mock.stop() } }
        await harness.pointUpstream(to: mock.port)  // upstreamPort = mock.port

        let client = TestProxyClient()
        for _ in 0..<2 {
            let resp = try await client.send(
                proxyHost: "127.0.0.1", proxyPort: harness.proxyPort,
                targetHost: host, targetPort: 443,
                method: .GET, path: "/v1/x", headers: [], body: nil,
                trustingCAs: [harness.caCertificate]
            )
            XCTAssertEqual(resp.status, .ok)
        }
        // Laisse l'EL traiter le release de la 1re connexion avant la 2e acquire.
        XCTAssertEqual(mock.acceptCount, 1, "les 2 requêtes réutilisent UNE connexion upstream")
    }
}
```

> Détail d'intégration : `ProxyServer` cible `configuration.upstreamPort`. Réutiliser le helper de démarrage des `ProxyEndToEndTests` (même `Configuration` avec `upstreamPort = mock.port`, host whitelisté, CA de test). Si ce helper n'est pas factorisé, l'inliner ici en copiant le `setUp` de `ProxyEndToEndTests`.

- [ ] **Step 3: Run to verify it fails (pre-pool baseline would be acceptCount==2)**

Run: `swift test --filter ProxyPoolingTests/testTwoSequentialRequestsReuseOneUpstreamConnection`
Expected: PASS avec le pool (acceptCount == 1). Si FAIL avec `acceptCount == 2`, le release/acquire ne réutilise pas → déboguer Task 6 (le relais doit être retiré et la connexion réellement rendue avant la 2e requête).

- [ ] **Step 4: Commit**

```bash
git add Tests/IntegrationTests/PoolingMockUpstream.swift Tests/IntegrationTests/ProxyPoolingTests.swift
git commit -m "test(phase-perf): two sequential requests reuse one upstream connection"
```

---

## Task 9: Test d'intégration — retry-once (connexion idle tuée)

**Files:**
- Modify: `Tests/IntegrationTests/ProxyPoolingTests.swift`

- [ ] **Step 1: Write the failing test**

Le mock ferme la connexion **après la 1ʳᵉ réponse** (`closeAfterFirstResponse: true`). La 2ᵉ requête dépile une connexion morte → `acquire` la saute / `attempt` retry-once → la requête **réussit** (pas d'erreur 502).

```swift
    func testRetryOnceWhenPooledConnectionDied() async throws {
        let host = "api.anthropic.com"
        let harness = try await ProxyTestHarness.start(host: host)
        defer { Task { try? await harness.stop() } }
        let mock = try await PoolingMockUpstream.start(
            host: host, caManager: harness.caManager, closeAfterFirstResponse: true
        )
        defer { Task { try? await mock.stop() } }
        await harness.pointUpstream(to: mock.port)

        let client = TestProxyClient()
        let r1 = try await client.send(proxyHost: "127.0.0.1", proxyPort: harness.proxyPort,
            targetHost: host, targetPort: 443, method: .GET, path: "/a", headers: [], body: nil,
            trustingCAs: [harness.caCertificate])
        XCTAssertEqual(r1.status, .ok)
        // La connexion #1 est maintenant morte côté serveur. La 2e requête doit
        // quand même réussir (retry-once sur une connexion neuve).
        let r2 = try await client.send(proxyHost: "127.0.0.1", proxyPort: harness.proxyPort,
            targetHost: host, targetPort: 443, method: .GET, path: "/b", headers: [], body: nil,
            trustingCAs: [harness.caCertificate])
        XCTAssertEqual(r2.status, .ok, "la 2e requête réussit via retry-once")
        XCTAssertEqual(mock.acceptCount, 2, "une nouvelle connexion a été ouverte pour la 2e")
    }
```

- [ ] **Step 2: Run**

Run: `swift test --filter ProxyPoolingTests/testRetryOnceWhenPooledConnectionDied`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/IntegrationTests/ProxyPoolingTests.swift
git commit -m "test(phase-perf): retry-once when pooled upstream connection died"
```

---

## Task 10: Test d'intégration — framing non réutilisable (`Connection: close`)

**Files:**
- Modify: `Tests/IntegrationTests/ProxyPoolingTests.swift`

- [ ] **Step 1: Write the failing test**

Le mock répond `Connection: close` → le relais calcule `reusable=false` → la connexion n'est pas poolée → 2 connexions observées.

```swift
    func testConnectionCloseResponseIsNotPooled() async throws {
        let host = "api.anthropic.com"
        let harness = try await ProxyTestHarness.start(host: host)
        defer { Task { try? await harness.stop() } }
        let mock = try await PoolingMockUpstream.start(
            host: host, caManager: harness.caManager, connectionHeaderClose: true
        )
        defer { Task { try? await mock.stop() } }
        await harness.pointUpstream(to: mock.port)

        let client = TestProxyClient()
        for path in ["/a", "/b"] {
            let r = try await client.send(proxyHost: "127.0.0.1", proxyPort: harness.proxyPort,
                targetHost: host, targetPort: 443, method: .GET, path: path, headers: [], body: nil,
                trustingCAs: [harness.caCertificate])
            XCTAssertEqual(r.status, .ok)
        }
        XCTAssertEqual(mock.acceptCount, 2, "Connection: close ⇒ pas de réutilisation")
    }
```

- [ ] **Step 2: Run**

Run: `swift test --filter ProxyPoolingTests/testConnectionCloseResponseIsNotPooled`
Expected: PASS.

- [ ] **Step 3: Run the full suite + lint**

Run: `swift test`
Expected: PASS (toutes les suites, ≥ 462 + nouveaux tests).
Run: `swift-format lint --strict --recursive Sources Tests`
Expected: aucune sortie.

- [ ] **Step 4: Commit**

```bash
git add Tests/IntegrationTests/ProxyPoolingTests.swift
git commit -m "test(phase-perf): Connection: close response is not pooled"
```

---

## Task 11: Mesure de gain (manuelle, au poste)

**Files:** aucun (vérification empirique, à consigner dans la PR).

- [ ] **Step 1: Rebuild + signer irisd, relancer le daemon** (cf. mémoire 8b : signer APRÈS le dernier build, ne plus rebuilder).

- [ ] **Step 2: Rejouer le harnais curl** (baseline TTFB ~38 ms, cf. spec §2) :

```bash
CA="$HOME/Library/Application Support/iris/ca.pem"
URL="https://api.anthropic.com/v1/messages"
FMT='  ttfb=%{time_starttransfer}s total=%{time_total}s\n'
curl -so /dev/null --http1.1 -w "$FMT" --proxy http://127.0.0.1:8888 --cacert "$CA" \
  "$URL" "$URL" "$URL" "$URL" "$URL" "$URL"
```

Expected : TTFB des requêtes 2..N **~20 ms** (vs ~38 ms avant le pool) — économie ≈ handshake upstream. Consigner les chiffres dans la description de PR (valeurs étiquetées « ce réseau »).

- [ ] **Step 3: Smoke fonctionnel** : `iris doctor` (proxy-ping 200) + un appel `claude` réel (substitution + streaming token-par-token toujours OK).

---

## Self-Review (effectué)

- **Spec coverage** : §5.1 pool → Tasks 1-4 ; §5.2 UpstreamClient → Task 6 ; §5.3 relais retirable + reusable → Task 5 ; §5.4 ProxyServer shutdown → Task 7 ; §6 data flow → Task 6 ; §7 staleness/framing/retry/idle/cap/shutdown → Tasks 1-7 ; §8 sécurité (clé=host) → factory fige le serverHostname (Task 6) ; §9 critères 1-3 → Tasks 8/9/10 (réutilisation, retry, framing) + suite complète (Task 10 step 3) + mesure (Task 11). Aucun gap.
- **Raffinement assumé vs spec** : §5.1 disait `acquire(host, port, sslContext)` ; le plan injecte une **factory** à la place (TLS/HTTP capturés par la closure) — découple le pool de TLS, conforme à l'esprit « injectables pour les tests » (§9). À refléter dans la spec si on veut l'alignement strict.
- **Placeholder scan** : aucun TBD/TODO ; tout le code des steps est concret.
- **Type consistency** : `StreamOutcome { statusCode, reusable }` (Task 5) cohérent avec les lectures `outcome.reusable`/`outcome.statusCode` (Task 6) ; `UpstreamConnectionPool.ConnectionFactory`, `acquire`, `release`, `shutdown` cohérents entre Tasks 1/4/6 ; `PoolingMockUpstream.acceptCount` cohérent Tasks 8/9/10.
- **Point de vigilance implémentation** : Task 7 dépend de la forme exacte de la méthode d'arrêt de `ProxyServer` (à localiser au step 1) ; Task 8 dépend du helper de démarrage du proxy de test (factoriser ou inliner depuis `ProxyEndToEndTests`).
