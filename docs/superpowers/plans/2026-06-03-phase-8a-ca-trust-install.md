# Phase 8a — CA Trust Store Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **⚠️ Plan révisé après pivot d'implémentation (2026-06-03).** L'approche native `SecTrustSettings*` (Goal d'origine + blocs de code des Tasks 1-2 ci-dessous) a été **abandonnée en cours d'exécution** : elle rend `errSecInternalComponent` (-2070) depuis le binaire CLI non Developer-ID-signé. L'implémentation finale shell-out vers `/usr/bin/security add-trusted-cert` — cf. design §3 révisé et la source (`CATrustStore.addTrustedCertArguments`/`install(pemPath:)`). Les Tasks 1-2 sont conservées comme plan pré-pivot ; se référer au design et au code pour la version réelle.

**Goal:** Add `iris ca install` / `iris ca uninstall` that add/remove the IRIS root CA to/from the current user's trust settings (`.user` domain) by shelling out to `/usr/bin/security` (révisé ; l'API native `SecTrustSettings*` initialement prévue rend -2070 depuis un binaire adhoc).

**Architecture:** Extend the existing read-only `CATrustStore` enum with pure `addTrustedCertArguments`/`removeTrustedCertArguments` seams (CI-testable) plus two effectful `install(pemPath:)`/`uninstall(pemPath:)` calls that spawn `/usr/bin/security` (GUI-auth, smoke-only). Add two ArgumentParser subcommands that reuse the existing `ca.is_trusted` + `ca.export_path` RPCs — no protocol change. The daemon never installs; only the CLI (and later the app) triggers the GUI auth in the user session.

**Tech Stack:** Swift 5.9+, Foundation (`Process` → `/usr/bin/security add-trusted-cert`/`remove-trusted-cert`), Security.framework (`SecTrustSettingsCopyCertificates` pour le read path), swift-argument-parser, XCTest.

**Design ref:** `docs/superpowers/specs/2026-06-03-phase-8a-ca-trust-install-design.md` (§3 documente le pivot)

---

## Context the engineer needs

- `CATrustStore` is a stateless `enum` namespace at `Sources/IrisKit/CA/CATrustStore.swift`. It already has `static func isTrusted(fingerprintSHA256:) -> Bool` reading `SecTrustSettingsCopyCertificates(.user, ...)`. We add three static funcs here.
- `CAError` lives at `Sources/IrisKit/CA/CACertificate.swift:29` — an `enum: Error, LocalizedError, Equatable`. We add one case.
- `CAManager(keyStore: InMemoryCAKeyStore())` → `await ensureCA()` returns a `CACertificate` with `.pem: String` and `.derBytes: Data`. With default `Options` (no `publicCertPath`), it writes nothing to disk. This is the fixture for the CI test.
- `SecCertificateCopyData(cert) as Data` returns the cert's DER (already used at `CATrustStore.swift:30`).
- CLI subcommands live in `Sources/iris/Commands/CACommands.swift` nested in `struct CACommand`. Existing siblings: `Export`, `Fingerprint`, `IsTrusted`. Mirror their shape (`@OptionGroup var connection: ConnectionOptions`, `@Flag(--json)`, `withAdminClient { client in client.call(...) }`).
- Output helpers: `Output.ack(message:json:)` emits `{ok,message}` in `--json`, plain text otherwise. Exit codes: `IrisExitCode.ioError = 3` (`Sources/iris/Support/ConnectionOptions.swift`).
- **CI reality:** `install`/`uninstall` call `SecTrustSettingsSetTrustSettings(.user, ...)`, which per Apple docs presents a login-password auth panel and may block — it requires a GUI session. They are **not** unit-testable. The only CI-testable logic is `makeCertificate(fromPEM:)`. Everything else is covered by the manual smoke checklist (Task 4). This is by design; do not fake CI coverage of the install path (CLAUDE.md §6/§12, Rule 12).

---

## File Structure

- **Modify** `Sources/IrisKit/CA/CACertificate.swift` — add `CAError.trustSettingsFailed(OSStatus)` case + its `errorDescription`.
- **Modify** `Sources/IrisKit/CA/CATrustStore.swift` — add `makeCertificate(fromPEM:)`, `install(_:)`, `uninstall(_:)`.
- **Create** `Tests/IrisKitTests/CATrustStoreTests.swift` — CI tests for `makeCertificate`.
- **Modify** `Sources/iris/Commands/CACommands.swift` — add `Install` + `Uninstall` subcommands, register both.

---

## Task 1: Extend `CATrustStore` with cert loading + install/uninstall

**Files:**
- Modify: `Sources/IrisKit/CA/CACertificate.swift:29-54`
- Modify: `Sources/IrisKit/CA/CATrustStore.swift`
- Test: `Tests/IrisKitTests/CATrustStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/IrisKitTests/CATrustStoreTests.swift`:

```swift
import Foundation
import Security
import XCTest

@testable import IrisKit

final class CATrustStoreTests: XCTestCase {
    /// The SecCertificate we'd hand to the trust store must be byte-identical
    /// to the CA we generated — otherwise `install` would trust the wrong cert
    /// (or none), silently breaking MITM verification.
    func testMakeCertificateFromValidPEMRoundTripsDER() async throws {
        let manager = CAManager(keyStore: InMemoryCAKeyStore())
        let ca = try await manager.ensureCA()

        let cert = try CATrustStore.makeCertificate(fromPEM: ca.pem)

        let der = SecCertificateCopyData(cert) as Data
        XCTAssertEqual(der, ca.derBytes)
    }

    func testMakeCertificateFromGarbageThrows() {
        XCTAssertThrowsError(try CATrustStore.makeCertificate(fromPEM: "not a pem"))
    }

    func testMakeCertificateFromEmptyThrows() {
        XCTAssertThrowsError(try CATrustStore.makeCertificate(fromPEM: ""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CATrustStoreTests`
Expected: FAIL — compile error, `type 'CATrustStore' has no member 'makeCertificate'`.

- [ ] **Step 3: Add the `CAError` case**

In `Sources/IrisKit/CA/CACertificate.swift`, add the case after `case dataCorruption(String)` (line 35):

```swift
    case dataCorruption(String)
    case trustSettingsFailed(OSStatus)
```

And add to `errorDescription`'s switch, after the `.dataCorruption` case (line 50-51):

```swift
        case .dataCorruption(let reason):
            return "CA data corruption: \(reason)"
        case .trustSettingsFailed(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Trust settings error: \(message ?? "OSStatus \(status)")"
```

- [ ] **Step 4: Implement the three funcs in `CATrustStore`**

In `Sources/IrisKit/CA/CATrustStore.swift`, add `import SwiftASN1` to the imports (it currently imports `Crypto`, `Foundation`, `Security`), then add inside the `enum CATrustStore`, after `isTrusted(...)`:

```swift
    /// Parses a PEM-encoded certificate into a `SecCertificate`. Pure — no
    /// keychain or trust-store side effects, so it is the CI-testable seam of
    /// the install path. Throws `CAError.dataCorruption` on malformed input.
    public static func makeCertificate(fromPEM pem: String) throws -> SecCertificate {
        let der: Data
        do {
            der = try Data(PEMDocument(pemString: pem).derBytes)
        } catch {
            throw CAError.dataCorruption("invalid CA PEM: \(error)")
        }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CAError.dataCorruption("SecCertificateCreateWithData returned nil")
        }
        return cert
    }

    /// Adds `cert` to the current user's trust settings as an always-trusted
    /// root (`SecTrustSettingsSetTrustSettings(.user, nil)`; passing `nil`
    /// means "always trust this root regardless of use", valid for a
    /// self-signed root). The system presents a login-password auth panel and
    /// may block — GUI session required, so this is exercised by manual smoke,
    /// not CI.
    public static func install(_ cert: SecCertificate) throws {
        let status = SecTrustSettingsSetTrustSettings(cert, .user, nil)
        guard status == errSecSuccess else {
            throw CAError.trustSettingsFailed(status)
        }
    }

    /// Removes `cert`'s trust settings from the current user's domain
    /// (`SecTrustSettingsRemoveTrustSettings(.user)`). Same GUI-auth caveat as
    /// `install`.
    public static func uninstall(_ cert: SecCertificate) throws {
        let status = SecTrustSettingsRemoveTrustSettings(cert, .user)
        guard status == errSecSuccess else {
            throw CAError.trustSettingsFailed(status)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CATrustStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Verify the whole module still builds**

Run: `swift build`
Expected: build succeeds, 0 warnings (the install/uninstall funcs compile against Security.framework).

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/CA/CACertificate.swift Sources/IrisKit/CA/CATrustStore.swift Tests/IrisKitTests/CATrustStoreTests.swift
git commit -m "feat(phase-8a): CATrustStore install/uninstall via SecTrustSettings (.user)"
```

---

## Task 2: Add `iris ca install` / `iris ca uninstall` subcommands

**Files:**
- Modify: `Sources/iris/Commands/CACommands.swift:9` (register) and append two structs before the closing brace of `struct CACommand`.

No CI unit test: the command body calls the GUI-auth `CATrustStore.install`. Verification is `--help` wiring (no daemon, no GUI) + the Task 4 smoke checklist.

- [ ] **Step 1: Register the subcommands**

In `Sources/iris/Commands/CACommands.swift`, change line 9:

```swift
        subcommands: [Export.self, Fingerprint.self, IsTrusted.self]
```

to:

```swift
        subcommands: [Export.self, Fingerprint.self, IsTrusted.self, Install.self, Uninstall.self]
```

- [ ] **Step 2: Add the `Install` struct**

Inside `struct CACommand`, after the `IsTrusted` struct's closing brace (`CACommands.swift:91`) and before `CACommand`'s closing brace, add:

```swift
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install the IRIS CA into the current user's trust store."
        )

        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            // Idempotent: skip if already trusted, avoiding a needless auth prompt.
            let trusted = try await withAdminClient(connection) { client in
                try await client.call(.caIsTrusted, returning: CAIsTrustedResult.self)
            }
            if trusted.trusted {
                try Output.ack(message: "already trusted", json: json)
                return
            }

            let pathResult = try await withAdminClient(connection) { client in
                try await client.call(.caExportPath, returning: CAExportPathResult.self)
            }
            let pem: String
            do {
                pem = try String(contentsOfFile: pathResult.path, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data("read CA failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }
            do {
                let cert = try CATrustStore.makeCertificate(fromPEM: pem)
                try CATrustStore.install(cert)
            } catch {
                FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }
            try Output.ack(message: "CA installed in user trust store", json: json)
        }
    }
```

- [ ] **Step 3: Add the `Uninstall` struct**

Immediately after the `Install` struct:

```swift
    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Remove the IRIS CA from the current user's trust store."
        )

        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let trusted = try await withAdminClient(connection) { client in
                try await client.call(.caIsTrusted, returning: CAIsTrustedResult.self)
            }
            if !trusted.trusted {
                try Output.ack(message: "not installed", json: json)
                return
            }

            let pathResult = try await withAdminClient(connection) { client in
                try await client.call(.caExportPath, returning: CAExportPathResult.self)
            }
            let pem: String
            do {
                pem = try String(contentsOfFile: pathResult.path, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data("read CA failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }
            do {
                let cert = try CATrustStore.makeCertificate(fromPEM: pem)
                try CATrustStore.uninstall(cert)
            } catch {
                FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }
            try Output.ack(message: "CA removed from user trust store", json: json)
        }
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: build succeeds, 0 warnings.

- [ ] **Step 5: Verify ArgumentParser wiring without a daemon/GUI**

Run: `swift run iris ca --help`
Expected: the SUBCOMMANDS list includes `install` and `uninstall`.

Run: `swift run iris ca install --help`
Expected: usage printed with `--json` and the shared connection options; exit 0. (Help is handled before `run()`, so no daemon/GUI involved.)

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/Commands/CACommands.swift
git commit -m "feat(phase-8a): iris ca install/uninstall subcommands"
```

---

## Task 3: Full verification gate (build + test + format)

**Files:** none (verification only).

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: all tests pass (the existing suite + 3 new `CATrustStoreTests`). No skips.

- [ ] **Step 2: Release build (local warning oracle)**

Run: `swift build -c release`
Expected: succeeds, 0 warnings. (Per project memory, the local toolchain is the oracle for concurrency warnings.)

- [ ] **Step 3: Lint**

Run: `swift-format lint --recursive --strict Sources Tests`
Expected: no output (clean). If it reports diffs, run `swift-format format -i -r Sources Tests`, re-lint, and `git commit -m "style(phase-8a): swift-format"`.

- [ ] **Step 4: Confirm no RPC/protocol drift**

Run: `git diff --stat origin/main -- Sources/IrisKit/IPC`
Expected: empty — Phase 8a adds no admin methods or wire types (reuses `ca.is_trusted` + `ca.export_path`).

---

## Task 4: Manual smoke at the poste (PR checklist)

**Files:** none. These steps require a GUI session and produce the PR's smoke-testing checklist (CLAUDE.md §8 — without it the PR is not mergeable). Run with the daemon up (`launchctl kickstart -k gui/$UID/io.iris.daemon` or `.build/release/irisd --foreground` in another shell).

- [ ] `iris ca install` → login-password auth panel appears → prints `CA installed in user trust store`.
- [ ] `iris ca is-trusted` → prints `trusted`, exit 0.
- [ ] CA visible in Keychain Access (login keychain) marked "Always Trust".
- [ ] A request through the proxy to a MITM-whitelisted host no longer raises a cert error (e.g. `curl` via the proxy, or `claude` against an `api.anthropic.com` rule).
- [ ] Second `iris ca install` → prints `already trusted`, **no auth prompt** (idempotence).
- [ ] `iris ca uninstall` → prints `CA removed from user trust store`; `iris ca is-trusted` → `not trusted`, exit 1.

---

## Self-review notes

- **Spec coverage:** §3 native API → Task 1 `install`/`uninstall`. §4.1 `makeCertificate`/`install`/`uninstall` + `CAError.trustSettingsFailed` → Task 1. §4.2 + §5 CLI subcommands, idempotency, RPC reuse, exit codes → Task 2. §6 unit tests → Task 1 Step 1; smoke → Task 4. §7 non-goals respected (no ACL, no admin domain, no app button, no env-var handling; no RPC change verified in Task 3 Step 4).
- **No placeholders:** every code step shows complete code; commands have expected output.
- **Type consistency:** `makeCertificate(fromPEM:)`, `install(_:)`, `uninstall(_:)`, `CAError.trustSettingsFailed(OSStatus)`, `CAIsTrustedResult`, `CAExportPathResult`, `IrisExitCode.ioError`, `Output.ack` used consistently across tasks and match the existing source read during planning.
