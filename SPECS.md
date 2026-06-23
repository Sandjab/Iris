# SPECS.md — Technical specification for IRIS

**Acronym**: Interception, Resolution, Injection, Substitution
**Tagline**: Secrets Are Safe

**Version**: 0.1.0-draft
**Target platform**: macOS 13 (Ventura) and later
**Status**: design complete, ready for implementation

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [Threat model](#2-threat-model)
3. [System overview](#3-system-overview)
4. [Components](#4-components)
5. [Data model](#5-data-model)
6. [Configuration format](#6-configuration-format)
7. [Placeholder syntax and substitution](#7-placeholder-syntax-and-substitution)
8. [Allowed-hosts scoping](#8-allowed-hosts-scoping)
9. [Exfiltration detection](#9-exfiltration-detection)
10. [Request flow](#10-request-flow)
11. [TLS MITM implementation](#11-tls-mitm-implementation)
12. [Keychain integration](#12-keychain-integration)
13. [IPC: admin Unix socket](#13-ipc-admin-unix-socket)
14. [IPC: events SSE stream](#14-ipc-events-sse-stream)
15. [Menu bar app](#15-menu-bar-app)
16. [CLI](#16-cli)
17. [LaunchAgent and SMAppService](#17-launchagent-and-smappservice)
18. [Installation and distribution](#18-installation-and-distribution)
19. [Logging and event storage](#19-logging-and-event-storage)
20. [Project layout](#20-project-layout)
21. [Open questions](#21-open-questions)
22. [Annex A — Edge cases and gotchas](#annex-a--edge-cases-and-gotchas)

---

## 1. Goals and non-goals

### Goals

- **G1.** Run an HTTPS forward proxy on `127.0.0.1` that performs MITM on a whitelist of upstream hosts.
- **G2.** Substitute placeholders `{{kc:NAME}}` found in **canonical auth headers** with values fetched from the macOS Keychain. Placeholders of known secrets found in query strings, URL paths, or request bodies are treated as exfiltration signals: the request is forwarded with the placeholder literal (never substituted) and an alert is emitted.
- **G3.** Enforce per-secret destination scoping: `{{kc:NAME}}` is only resolved when the request goes to a host in `secret.allowed_hosts`.
- **G4.** Detect and log exfiltration attempts (placeholder appearing where it shouldn't); surface them as alerts in the menu bar app.
- **G5.** Manage secrets, MITM rules, and configuration from a menu bar app and a CLI.
- **G6.** Install via a single signed and notarized `.pkg`. Run as a LaunchAgent. No manual `launchctl` for the user.
- **G7.** Be invisible in normal operation. No prompts after initial install. No notifications unless alerts fire.
- **G8.** Scope interception to shell-launched processes only. IRIS is activated by exporting `HTTPS_PROXY` and `NODE_EXTRA_CA_CERTS` in the user's shell profile. GUI apps (Safari, Slack, Mail, etc.) launched from Finder/Dock/Spotlight do NOT inherit this env and are not intercepted. This is intentional: the target use case is agentic CLI tooling, where the host set is narrow and predictable.

### Non-goals

- Multi-user, team, or organization features.
- Network-wide deployment.
- Egress filtering or DLP beyond placeholder scoping.
- Replacing existing secrets managers (1Password, vault, etc.). The Keychain is the store; this is a substitution layer.

---

## 2. Threat model

### Assumptions

- The user's macOS account is not compromised at the OS level.
- The signed `irisd` binary is not compromised (codesign + notarization verify integrity at launch).
- The user trusts the upstream APIs they whitelist (Anthropic, GitHub, etc.).

### In-scope adversaries

- **A1.** A prompt-injected AI agent running locally that tries to read its own environment, dump it to a file, and POST it to an attacker-controlled URL.
- **A2.** A prompt-injected agent that tries to substitute a placeholder into a request body destined for an unauthorized host (e.g., dumping the Anthropic key to `api.github.com` as part of an issue body).
- **A3.** A malicious MCP server invoked by the agent that tries to read the agent's environment via stdio inheritance.
- **A4.** A malicious local process (non-root, non-`irisd`) trying to read the broker's CA private key or substituted secrets in transit.

### Out-of-scope adversaries

- Local root/admin access. If the attacker has root, they own the machine.
- Kernel exploits, Mach injection, SIP bypass.
- Network adversaries on the local network (the broker only listens on `127.0.0.1`).
- The agent calling a non-whitelisted host directly with credentials — but since the agent never has the real credentials, this is moot for whitelisted secrets.
- A same-user process that drives the legitimate `iris` CLI (or the admin socket) to **re-scope** a secret (`iris secret edit`) or add a MITM host (`iris rule add`). The admin socket is `0600`/owner-only (I5), but any same-uid process can run the signed CLI exactly as the user can — authenticating the socket peer's code signature would not change this, since the CLI is freely invokable. This mirrors the `ssh-agent`/`gpg-agent` posture and **user decision #4**. IRIS's guarantee is over secret *values* (I1/I2), not over a same-uid actor's ability to change which hosts a secret is scoped to. See [§13.3](#133-auth).

### Key invariants

- **I1.** The plaintext value of any secret is never written to disk except inside the Keychain.
- **I2.** The plaintext value of any secret is never written to logs, events, the SSE stream, or the UI.
- **I3.** A placeholder is only resolved if the destination host matches the secret's `allowed_hosts` list.
- **I4.** The CA private key is accessible only to the signed `irisd` binary (Keychain ACL).
- **I5.** The admin Unix socket has mode `0600` and is owned by the current user.

### Accepted residuals (audit 2026-06)

These are known, deliberately-accepted limitations; each is documented at its point of relevance.

- **CA without `NameConstraints`** — a stolen CA private key could mint leaf certs for any host, not only whitelisted ones. Constraining the CA to a name set is incompatible with dynamic `rule add` (it would either break interception of newly-added hosts or force a trust-store re-prompt on every host change). The CA key itself is protected by I4, and industry MITM tools (mitmproxy, Charles) omit the constraint for the same reason. See [§11.1](#111-ca-generation).
- **CA key adoption before first boot** — a same-uid process that pre-positions a CA private key (and a matching `ca.pem`) before the daemon's first launch could have its key adopted as the root. The write path is hardened (the daemon stores the key with `SecItemAdd` and fails on a duplicate; it never overwrites or adopts via update), but full closure is structurally impossible to distinguish from a legitimate prior install without a hardware root of trust — it requires a non-extractable / Secure-Enclave key (deferred, see [§11.1](#111-ca-generation)). Preconditions are strong (code execution before first boot + the user installing the resulting trust anchor).
- **Events SSE stream is unauthenticated** — the loopback SSE endpoint (§14) exposes request metadata (hostnames, paths, secret *names*, exfil alerts — never values, I2 holds) to any local process. On a single-user machine this is equivalent to same-uid access; the residual is cross-user metadata exposure on shared machines. See [§14.1](#141-endpoint).
- **Unbounded request-body buffering** — a same-uid client can grow the in-memory request-body buffer before the size cap is applied. This is a local same-uid availability concern only (no privilege boundary is crossed; such a process can already exhaust its own memory). Bounding it safely requires streaming pass-through rather than buffering (deferred). See [§7.2](#72-scan-scope).

---

## 3. System overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         User session                            │
│                                                                 │
│  ┌─────────────────┐         ┌──────────────────────────────┐   │
│  │  Agent / tool   │ HTTPS   │  irisd                 │   │
│  │  (Claude Code,  ├────────►│  ┌─────────────────────────┐ │   │
│  │   curl, gh,     │ via     │  │ MITM proxy :8888        │ │   │
│  │   MCP servers)  │ proxy   │  │  - whitelist check      │ │   │
│  │                 │         │  │  - TLS terminate (CA)   │ │   │
│  │  ENV:           │         │  │  - scan + substitute    │ │   │
│  │  HTTPS_PROXY    │         │  │  - emit events          │ │   │
│  │  NODE_EXTRA_CA  │         │  │  - forward TLS          │ │   │
│  │  *_API_KEY=     │         │  └─────────────────────────┘ │   │
│  │   "{{kc:...}}"  │         │  ┌─────────────────────────┐ │   │
│  └─────────────────┘         │  │ Events SSE :8899        │ │   │
│                              │  └─────────────────────────┘ │   │
│  ┌─────────────────┐         │  ┌─────────────────────────┐ │   │
│  │ Iris.app  │◄────────┤  │ Admin RPC (unix sock)   │ │   │
│  │ (menu bar)      │  IPC    │  └─────────────────────────┘ │   │
│  └─────────────────┘         └──────────────────────────────┘   │
│                                       │                         │
│  ┌─────────────────┐                  │                         │
│  │ iris CLI  │──────────────────┘                         │
│  └─────────────────┘  IPC                                       │
└─────────────────────────────────────────┬───────────────────────┘
                                          │
                                          ▼
                              ┌─────────────────────────┐
                              │  macOS System Keychain  │
                              │  - CA private key       │
                              │  - secret values        │
                              │  - secret attributes    │
                              │    (allowed_hosts JSON) │
                              └─────────────────────────┘
                                          │
                                          ▼
                              ┌─────────────────────────┐
                              │  Upstream APIs (TLS)    │
                              │  api.anthropic.com      │
                              │  api.github.com         │
                              │  ...                    │
                              └─────────────────────────┘
```

---

## 4. Components

### 4.1 `irisd` (daemon)

Long-running process launched by LaunchAgent. Single instance per user session.

**Responsibilities:**

- Bind the proxy listener on `config.broker.listen`.
- Bind the events SSE endpoint on `config.broker.events_listen`.
- Bind the admin Unix socket on `config.broker.admin_socket`.
- Load config from `config.json` at startup (seed defaults if absent); reload on SIGHUP.
- Maintain in-memory map of `Secret` (by name) with `allowed_hosts` and Keychain reference.
- Maintain LRU cache of resolved secret values (TTL: 5 min, max 32 entries).
- Maintain an in-memory ring buffer of last 10 000 events; persist to SQLite for durable history.
- Emit events to all connected SSE subscribers.

**Process model:** single process, async I/O via Swift Concurrency on top of `swift-nio`. One `EventLoopGroup` shared across listeners.

### 4.2 `IrisKit` (library)

SwiftPM library, linked by `irisd`, `iris`, and `IrisApp`. Pure Swift, no UI.

**Contents:**

- `Config` + `ConfigStore` — JSON config: seed, validate, atomic 0600 write, timestamped backups
- `Secret`, `MITMRule`, `Event`, `Alert` — data models (Codable, Sendable)
- `SecretStore` protocol + `KeychainSecretStore` (production) + `InMemorySecretStore` (tests)
- `CAManager` — generate, store, export, install CA
- `AdminClient` — Unix socket JSON-RPC client (used by app and CLI)
- `EventsClient` — SSE consumer (used by app)
- `PlaceholderEngine` — scan + substitute logic, exfiltration heuristics

### 4.3 `iris` (CLI)

Built with `swift-argument-parser`. Connects to the daemon's admin Unix socket. Subcommands:

```
iris secret add <name> [--allowed-hosts h1,h2] [--value-from-stdin | --value <v>]
iris secret list
iris secret show <name>          # name + allowed_hosts only, never value
iris secret edit <name> [--allowed-hosts h1,h2]
iris secret rotate <name>        # prompts for new value
iris secret rm <name>

iris rule add <host>
iris rule list
iris rule rm <host>

iris status                      # daemon up/down, uptime, stats
iris logs [--follow] [--filter ...]
iris config reload               # SIGHUP
iris pause / iris resume

iris ca export [--path PATH]     # PEM of public CA cert
iris ca install                  # add to System trust store (prompts admin)
iris ca rotate                   # roadmap, not MVP

iris doctor                      # health check: daemon, trust store, ACL, ports

iris mcp wrap <path> [--watch] [--dry-run]   # patch .mcp.json / claude.json
iris mcp unwrap <path>                       # revert from .bak
```

### 4.4 `Iris.app` (menu bar app)

`NSStatusItem` with SwiftUI popover. Source of truth for state = daemon. App is a thin client.

See [§15](#15-menu-bar-app) for details.

---

## 5. Data model

### 5.1 `Secret`

```swift
public struct Secret: Codable, Sendable, Hashable {
    public let name: String                  // e.g. "anthropic_api_key"
    public let allowedHosts: [String]        // e.g. ["api.anthropic.com"]
    public let createdAt: Date
    public let lastUsedAt: Date?
    public let usageCount: UInt64
    // Value is NEVER part of this struct. Fetch separately via SecretStore.
}
```

The value is fetched lazily via `SecretStore.value(for: name)` and never stored on the model.

### 5.2 `MITMRule`

```swift
public struct MITMRule: Codable, Sendable, Hashable {
    public let host: String                  // exact match, no wildcards in MVP
    public let createdAt: Date
}
```

Wildcards (`*.anthropic.com`) are in scope for v1.1, not MVP.

### 5.3 `Event`

```swift
public struct Event: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let host: String
    public let method: String                // GET / POST / ...
    public let path: String
    public let statusCode: Int?              // nil if not yet completed
    public let durationMs: UInt32?
    public let substitutedSecrets: [String]  // names only, never values
    public let alert: Alert?                 // present if kind == .exfilBlocked

    public enum Kind: String, Codable, Sendable {
        case substituted        // normal substitution, request forwarded
        case passThrough        // CONNECT-only, no MITM, no scan
        case noMatch            // MITM'd, scanned, no placeholder found
        case exfilBlocked       // placeholder found but scoping rejected
        case error              // upstream error, TLS error, etc.
    }
}
```

### 5.4 `Alert`

```swift
public struct Alert: Codable, Sendable, Hashable {
    public let severity: Severity            // .low, .medium, .high
    public let rule: ExfilRule               // which detection rule fired
    public let secretName: String
    public let detectedAt: Location          // .header, .queryString, .urlPath, .body
    public let snippet: String               // redacted, max 256 chars

    public enum ExfilRule: String, Codable, Sendable {
        case hostMismatch         // R1: secret not authorized for this host
        case nonCanonicalLocation // R2: placeholder in non-auth-header location
        case multipleSecrets      // R3: multiple secrets in one request
        case suspiciousContentType// R4: placeholder in text/plain or form to non-API
        case volumeAnomaly        // R5: rate exceeds threshold
    }

    public enum Severity: String, Codable, Sendable {
        case low, medium, high
    }

    public enum Location: String, Codable, Sendable {
        case header, queryString, urlPath, body
    }
}
```

---

## 6. Configuration format

Path: `~/Library/Application Support/iris/config.json`

The configuration is a **single JSON file owned by the daemon** (app-first model, Phase 6.3a). It is **seeded** from built-in defaults on first run if absent, and mutated via the CLI/app over RPC (`config.set`, `rule.add`/`rule.delete`) — the daemon is the only writer. Before every write it backs up the current file under `backups/config-<timestamp>.json` (rotated to `backups.max_count`). `TOMLKit` and the old `runtime-rules.json` are gone.

```json
{
  "version": 1,
  "broker": {
    "listen": "127.0.0.1:8888",
    "events_listen": "127.0.0.1:8899",
    "admin_socket": "~/Library/Application Support/iris/admin.sock",
    "log_level": "info",
    "event_retention_days": 7,
    "event_ring_size": 10000
  },
  "security": {
    "on_exfil_attempt": "block_and_notify",
    "max_substitutions_per_minute": 60
  },
  "backups": { "max_count": 10 },
  "hosts": [
    { "host": "api.anthropic.com", "origin": "default", "created_at": "2026-06-05T12:00:00Z" }
  ]
}
```

- `on_exfil_attempt`: `block_only` (block + log, no notification) | `block_and_notify` (+ macOS notification) | `block_notify_pause` (+ pause daemon until resumed).
- `max_substitutions_per_minute`: volume anomaly threshold (rule R5).
- `hosts[].origin`: `default` (seeded, **protected** — not removable via RPC, prevents accidentally breaking `claude`) | `user` (added via `rule.add`).
- **Hot-editable** at runtime (no restart): `security.*`, `backups.max_count`, and `hosts` (via `rule.*`). **Structural** fields (`broker.*`) persist but require a restart; `config.set` returns them under `requires_restart`. `broker.log_level` is restart-required (backend wiring is a separate TODO).

**Note:** secrets are NOT stored in this file. They live in Keychain, plus their `allowed_hosts` array which is also stored in Keychain attributes (see [§12](#12-keychain-integration)). Rationale: a stolen `config.json` should reveal nothing useful.

**Corruption at boot → degraded boot (not refusal):** if `config.json` is unparseable at startup, the daemon backs it up (`backups/config-corrupted-<timestamp>.json`), re-seeds defaults, stays up (substitution active with safe defaults), and emits a high-severity system alert (visible in the Security tab / `iris logs`). Only an unrepairable I/O error (unreadable dir, full disk) aborts boot.

---

## 7. Placeholder syntax and substitution

### 7.1 Syntax

```
{{kc:<NAME>}}
```

Where `<NAME>` matches the regex `[a-zA-Z0-9_-]{1,64}`.

Full match regex (Swift `NSRegularExpression`):
```
\{\{kc:([a-zA-Z0-9_-]{1,64})\}\}
```

### 7.2 Scan scope

For each intercepted HTTPS request that targets a MITM-whitelisted host, the broker scans:

1. **All request headers**, both name and value. (Substitution in header names is allowed but extremely rare in practice.)
2. **URL path and query string.**
3. **Request body**, only if the **received body** is ≤ 4 MiB (configurable). The decision is made on the bytes actually buffered, **not** on the client-declared `Content-Length` header (a lie would otherwise skip the scan, audit L-1). Bodies larger than the threshold: pass through unchanged, emit a `noMatch` event with a `bodyTooLarge` flag.

> **Deferred (audit L-1):** the body is buffered entirely before the cap is checked, so a same-uid client can grow the in-memory buffer. This is a local same-uid availability concern only; bounding it safely requires streaming pass-through (see [§2 Accepted residuals](#accepted-residuals-audit-2026-06)).

Response bodies are **never** scanned or modified.

Plugins may, via the `onResponse` hook (metadata mode), observe the response status
line and **overlay response headers** before relay. Response **bodies** remain never
scanned, modified, or buffered (the relay forwards body parts part-by-part, §7.3).

### 7.3 Streaming

For Server-Sent Events and chunked responses going upstream→client, the broker forwards bytes without buffering or modification.

For chunked request bodies client→upstream: buffer up to the size limit, scan, substitute, re-emit. If the body exceeds the limit, pass through unchanged with a warning event.

### 7.4 Encoding

Substitution is byte-level on UTF-8 encoded content. Non-UTF-8 bodies (e.g., binary uploads) are not scanned — emit `noMatch` with `nonUtf8` flag.

### 7.5 Content-Encoding

If the request body is `gzip` or `br` compressed:

- **MVP**: strip `Accept-Encoding` from client→upstream requests to avoid having to decompress responses (which we don't scan anyway). For request bodies, refuse to substitute if compressed; emit a warning.
- **v1.1**: decompress, substitute, recompress.

### 7.6 HTTP/2

Anthropic and GitHub both accept HTTP/1.1. The proxy negotiates HTTP/1.1 with both client and upstream by advertising only `http/1.1` in ALPN. This sidesteps the complexity of an HTTP/2 MITM in MVP. (See Annex A.)

---

## 8. Allowed-hosts scoping

### 8.1 Rule

For each placeholder match `{{kc:NAME}}` in an intercepted request to host `H`:

```
if NAME not in known secrets:
    → leave placeholder unchanged, emit warning event
if H not in secret(NAME).allowed_hosts:
    → DO NOT substitute. Emit Event(kind: .exfilBlocked, alert: hostMismatch).
    → Forward the request as-is (placeholder still in payload).
       The upstream will reject it as malformed auth, which is the desired outcome.
else:
    → Fetch real value from Keychain (cached).
    → Substitute.
    → Emit Event(kind: .substituted, substitutedSecrets: [NAME]).
```

### 8.2 Host matching

Exact string match, case-insensitive, no port. The `Host` header is normalized before comparison.

Wildcards are not supported in MVP. If needed in v1.1, format: `*.example.com` matches `foo.example.com` but not `example.com` or `a.b.example.com` (single level).

### 8.3 Edge case: request targets a non-MITM-whitelisted host

The broker CONNECT-tunnels (no decryption). Placeholders, if any, are sent encrypted to upstream as-is. There is no way for the agent to leak a real secret because there is no substitution. Emit `Event(kind: .passThrough)`.

---

## 9. Exfiltration detection

Five rules. Each fires an `Event(kind: .exfilBlocked, alert: Alert(rule: ...))`. All firing rules contribute to a single alert per event; severity = max of fired rules.

### R1 — Host mismatch (high)

Placeholder for secret `NAME` appears in a request to host `H`, and `H ∉ secret(NAME).allowed_hosts`.

This is the central rule. See [§8](#8-allowed-hosts-scoping).

### R2 — Non-canonical location (high)

Placeholder appears in:
- The URL path or query string of a request to a host other than the one expecting the secret in that location (rare; most APIs use a header).
- The body of a request (any method) — secrets are substituted only in canonical auth headers.
- A `User-Agent`, `Referer`, or non-auth-related header.

Whitelisted "canonical" locations per host can be configured (e.g., `api.anthropic.com` expects secrets in header `x-api-key`). MVP default: any of `Authorization`, `x-api-key`, `api-key`, `x-auth-token` is canonical; everything else fires R2.

### R3 — Multiple distinct secrets in one request (medium)

≥ 2 distinct **known** secret names in a single request. Smells like an `env` dump. Unknown placeholder names are not counted: they never resolve (cannot leak), and the `{{kc:…}}` grammar appears in ordinary text — including IRIS's own documentation — so counting them produced structural false positives.

### R4 — Suspicious content type (medium)

Placeholder found in body where `Content-Type` is `text/plain`, `application/x-www-form-urlencoded`, or `multipart/form-data` AND target path is not a known API endpoint pattern (heuristic: contains `/comments`, `/issues`, `/notes`, `/messages`, `/blob`, or matches user-configured patterns).

Keys off known secrets only. On the current path, R2 (body non-canonical) preempts R4 for any known body secret, so R4 no longer fires in practice; it is retained for defense-in-depth and for a future body-credential allowlist.

### R5 — Volume anomaly (low)

For a given secret, more than `config.security.max_substitutions_per_minute` substitutions in a rolling minute window.

### Behavior on detection

Driven by `config.security.on_exfil_attempt`:

- `block_only`: log event, no notification, daemon continues.
- `block_and_notify` (default): + send `UNUserNotificationCenter` notification, set red badge on menu bar icon.
- `block_notify_pause`: + pause daemon (refuse all new substitutions until user clicks "Resume" in app).

In all cases, the offending request itself is **forwarded unchanged** (placeholder still present in payload) — the upstream rejection is the natural backstop.

---

## 10. Request flow

End-to-end trace of a successful substituted request.

```
1.  Agent constructs:
        POST https://api.anthropic.com/v1/messages
        x-api-key: {{kc:anthropic_api_key}}
        Content-Type: application/json
        {"model":"claude-...","messages":[...]}

2.  Agent's HTTP client honors HTTPS_PROXY=http://127.0.0.1:8888.
    It opens TCP to 127.0.0.1:8888 and sends:
        CONNECT api.anthropic.com:443 HTTP/1.1
        Host: api.anthropic.com:443

3.  Daemon receives CONNECT. Checks api.anthropic.com against MITM whitelist.
    Match found.
    Responds: HTTP/1.1 200 Connection Established

4.  Daemon initiates TLS handshake AS THE SERVER toward the agent,
    presenting a cert for "api.anthropic.com" signed by the local CA.
    ALPN advertises only "http/1.1".
    Agent accepts (because NODE_EXTRA_CA_CERTS / system trust store).

5.  In parallel, daemon initiates TLS handshake AS THE CLIENT toward
    api.anthropic.com:443, verifying the real cert chain via the system
    trust store. ALPN advertises only "http/1.1".

6.  Agent sends the (now decrypted from daemon's POV) HTTPS request:
        POST /v1/messages HTTP/1.1
        Host: api.anthropic.com
        x-api-key: {{kc:anthropic_api_key}}
        ...

7.  Daemon's PlaceholderEngine scans:
        - Headers: hit on "x-api-key" → {{kc:anthropic_api_key}}
        - Path/query: no hit
        - Body: no hit (Content-Type application/json, < 4 MiB)
    Single distinct secret: anthropic_api_key.

8.  Scoping check:
        secret("anthropic_api_key").allowed_hosts = ["api.anthropic.com"]
        request host = "api.anthropic.com"
        → match. Resolve via SecretStore (Keychain hit, cached).

9.  R2 check:
        "x-api-key" is in canonical-locations set → OK.
    R3 check:
        1 secret → OK.
    R4 check:
        Content-Type application/json + /v1/messages → OK.
    R5 check:
        Substitution count this minute = 12 < 60 → OK.

10. Substitute placeholder with real value.

11. Forward modified request to upstream over the established TLS.

12. Upstream responds (potentially streaming, SSE). Daemon proxies bytes
    verbatim back to the agent over the agent-facing TLS, no buffering.

13. On request completion, emit:
        Event(kind: .substituted,
              host: "api.anthropic.com",
              method: "POST",
              path: "/v1/messages",
              statusCode: 200,
              durationMs: 8421,
              substitutedSecrets: ["anthropic_api_key"],
              alert: nil)

    Event lands in ring buffer + SQLite + SSE stream.
```

For an **exfiltration attempt** (e.g., agent POSTs the env to `api.github.com/repos/foo/bar/issues`):

```
7.  Scan: body contains "ANTHROPIC_API_KEY={{kc:anthropic_api_key}}"
9.  R1 fires: secret allowed_hosts = ["api.anthropic.com"], host = "api.github.com" → mismatch (HIGH)
    R2 also fires: location = body, but content type is JSON + path matches /issues → R4 fires too (MEDIUM)
    R3 may fire if multiple secrets.
11. DO NOT substitute. Forward request as-is.
12. Upstream (GitHub) accepts the issue body containing the LITERAL string "{{kc:anthropic_api_key}}".
    No secret leaked. The literal placeholder is harmless.
13. Emit Event(kind: .exfilBlocked, alert: Alert(severity: .high, rule: .hostMismatch, ...)).
    Send macOS notification per config.
```

---

## 11. TLS MITM implementation

### 11.1 CA generation

On first daemon startup:

1. Check Keychain for a private key labeled `io.iris.ca.privatekey`.
2. If absent:
    - Generate an ECDSA P-256 key pair via `Security.framework` (`SecKeyCreateRandomKey`).
    - Store the private key in the System Keychain with attributes:
        - `kSecAttrLabel`: `io.iris.ca.privatekey`
        - `kSecAttrApplicationTag`: `"io.iris.ca".data(using: .utf8)`
        - ACL: access granted only to the signed `irisd` binary (see [§12.3](#123-acl-strategy)).
    - Build a self-signed root certificate:
        - CN: `IRIS local CA`
        - O: `iris`
        - Validity: 10 years from creation
        - Extensions: `basicConstraints=CA:TRUE`, `keyUsage=keyCertSign,cRLSign`. **No `NameConstraints`** — see [§2 Accepted residuals](#accepted-residuals-audit-2026-06) for the rationale (incompatible with dynamic `rule add`).
    - Export the public cert as PEM to `~/Library/Application Support/iris/ca.pem` (mode 0644 — public material, fine on disk).
3. If present: load and verify it parses correctly. If not, refuse to start and emit a critical log.

### 11.2 Per-host leaf certificates

For each MITM-whitelisted host, the daemon mints a leaf certificate on first use and caches it in memory (no disk persistence; cheap to regenerate).

- CN matches the SNI / `Host`.
- SAN includes the host.
- Validity: 90 days.
- Signed by the CA via `SecKeyCreateSignature` (with the CA private key still in Keychain, accessed via `SecKeyCreateSignature` — never extracted).

**Crucial:** the CA private key is **never exported to memory** outside what the Keychain API hands us during signing operations. Use the keychain item reference, not raw key material.

### 11.3 Trust store installation

The CA public cert (`ca.pem`) must be trusted by:

1. The macOS System trust store (covers `gh`, Safari, many CLI tools).
2. Node.js (via `NODE_EXTRA_CA_CERTS` exported in the shell).
3. Python / curl (via `SSL_CERT_FILE` / `CURL_CA_BUNDLE`).

Installation paths:

- **System trust store**: `iris ca install` runs:
  ```
  /usr/bin/security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain \
      ~/Library/Application\ Support/iris/ca.pem
  ```
  This prompts the user for admin credentials **once**. The CLI calls this via `AuthorizationExecuteWithPrivileges` (deprecated but still functional in 13.x; alternative: `NSWorkspace.shared.openApplication` for a privileged helper. **MVP: shell out to `security` with an explicit `osascript`-driven `do shell script with administrator privileges`** — simplest path).

- **Per-tool env vars**: documented in `README.md`. The user adds them to their shell profile. `iris doctor` checks they're set.

### 11.4 TLS library

Use `swift-nio-ssl` for both server-facing and client-facing TLS. Rationale:

- Apple's `Network.framework` does not expose enough control over cert chain and ALPN for MITM.
- `swift-nio-ssl` exposes `NIOSSLContext`, `NIOSSLServerHandler`, `NIOSSLClientHandler`, dynamic cert callbacks, ALPN.

For the agent-facing side, set up `NIOSSLContext` with a `sniHostnameCallback` that, given the SNI, returns a dynamically generated leaf cert chain.

For the upstream-facing side, standard client TLS verifying against system trust store via `NIOSSLContext.defaultTrustRoots = .default`.

### 11.5 HTTP/2

ALPN advertises only `http/1.1` on both sides. Upstream accepts (Anthropic, GitHub, OpenAI all support h1.1). Agent's HTTP client downgrades transparently.

If a future upstream forces h2-only: dedicated card on the roadmap. `swift-nio-http2` exists; the MITM mechanics are the same but the stream multiplexing adds complexity.

---

## 12. Keychain integration

### 12.1 Where things live

| Item                       | Keychain          | Item class                  | Label                                  |
|----------------------------|-------------------|-----------------------------|----------------------------------------|
| CA private key             | System Keychain   | `kSecClassKey`              | `io.iris.ca.privatekey`          |
| CA public cert             | (also on disk)    | `kSecClassCertificate`      | `io.iris.ca.cert`                |
| Secret values              | login Keychain    | `kSecClassGenericPassword`  | `io.iris.secret.<name>`          |

`kSecAttrService`: `io.iris.secret`
`kSecAttrAccount`: `<secret_name>`
`kSecAttrGeneric`: JSON-encoded `{"allowed_hosts": ["api.example.com"], "created_at": "..."}` — used to keep secret metadata co-located with the value, so a Keychain backup/export preserves it.

### 12.2 Why login Keychain for secrets

Secrets are per-user. Login Keychain unlocks on user login, which matches the LaunchAgent lifecycle. Putting them in System Keychain would require admin to modify, which contradicts G7 (no friction).

The CA private key is in System Keychain because it's signed-binary-scoped, not user-scoped; storing it in login Keychain risks losing it on user re-creation.

### 12.3 ACL strategy

For the CA private key: the goal is **silent access for `irisd`, denied for everything else**.

- Build an `SecAccess` with a single ACL entry granting `kSecACLAuthorizationDecrypt` and `kSecACLAuthorizationSign` to the signed `irisd` binary (referenced by its `SecTrustedApplicationRef`).
- Use `SecKeychainItemSetAccess` to apply the ACL after insertion.
- Result: any other process accessing the key gets a "Keychain wants to allow" prompt; `irisd` does not.

For secret values: same pattern. The signed `irisd` and `iris` CLI binaries are both in the ACL.

The menu bar app does **not** need direct Keychain access for secret values. It manipulates them through the daemon's admin RPC. The app does need read access to *metadata* (names, allowed_hosts), but those come from the daemon too. Net: only `irisd` (and optionally the CLI) holds the ACL grants.

### 12.4 Adding a secret (`iris secret add`)

1. CLI sends `secret.add(name, allowed_hosts, value)` RPC to the daemon.
2. Daemon:
    - Validates name (regex `^[a-zA-Z0-9_-]{1,64}$`).
    - Validates allowed_hosts (each: valid DNS name, non-empty).
    - Inserts a `kSecClassGenericPassword` item:
        - service = `io.iris.secret`
        - account = `name`
        - generic = JSON metadata
        - value = the secret bytes
        - access = `SecAccess` with ACL granting `irisd` + `iris` CLI silent access
    - **First-time only**: macOS may prompt the user "irisd is trying to access the login keychain — Allow / Always Allow / Deny". The ACL we set is "always allow" for the specified apps, so this prompt is the user confirming the ACL. Acceptable friction (one prompt per secret added).
3. Daemon emits an admin event so the menu bar app refreshes its Secrets tab.

### 12.5 Rotating a secret

Same as `add` but `SecItemUpdate` instead of `SecItemAdd`. Preserves the existing ACL.

### 12.6 Deleting a secret

`SecItemDelete`. The daemon also evicts the LRU cache entry for that name.

---

## 13. IPC: admin Unix socket

### 13.1 Transport

Unix domain socket at `config.broker.admin_socket` (default `~/Library/Application Support/iris/admin.sock`). Mode `0600`, owner = current user.

Length-prefixed JSON-RPC 2.0 frames:

```
<4-byte big-endian uint32: payload length><JSON payload>
```

### 13.2 Methods

```
secret.add(name, allowed_hosts, value)        → { name, allowed_hosts, created_at }
secret.list()                                 → [Secret]            (no values)
secret.get(name)                              → Secret              (no value)
secret.update(name, allowed_hosts)            → Secret
secret.rotate(name, value)                    → Secret
secret.delete(name)                           → { deleted: true }

rule.add(host)                                → MITMRule
rule.list()                                   → [MITMRule]
rule.delete(host)                             → { deleted: true }

config.reload()                               → { reloaded: true, ignored: [...] }
config.get()                                  → Config              (sanitized)
config.set(updates: [{key, value}])           → { applied: [...], requires_restart: [...] }

daemon.status()                               → { pid, uptime_s, version, stats, paused }
daemon.pause()                                → { paused: true }
daemon.resume()                               → { paused: false }
daemon.stats()                                → { req_total, sub_total, exfil_blocked_total, ... }

events.query(since?, until?, limit?, kind?)   → [Event]             (from SQLite)
events.clear()                                → { deleted_count: N }

ca.export_path()                              → { path: "..." }
ca.fingerprint()                              → { sha256: "..." }
ca.is_trusted()                               → { trusted: bool }
```

Errors: standard JSON-RPC 2.0 error object. Custom codes in the `-32000..-32099` range:

```
-32001  unknownSecret
-32002  invalidName
-32003  invalidAllowedHosts
-32004  duplicate
-32005  daemonPaused
-32006  notFound
```

### 13.3 Auth

The socket is `0600` + owner-uid (invariant I5), so only the current user's processes can connect. This matches **user decision #4** in design.

**Threat-model boundary (explicit).** IRIS does **not** defend against a malicious process running as the **same user** that can execute arbitrary code — including invoking the signed `iris` CLI. Such a process can re-scope a secret (`iris secret edit`, which only takes a name + allowed-hosts, never the value) or add a MITM host (`iris rule add`) exactly as the user could. This is the same posture as `ssh-agent` / `gpg-agent` (any same-uid process can drive the agent). Authenticating the connecting peer's code signature would **not** change this boundary, because the legitimate CLI is freely invokable by any same-uid process; it would only stop a process speaking the socket protocol directly, which is not the relevant capability.

**What IRIS does guarantee:** secret *values* never leave the daemon — not via this IPC channel (`secret.get`/`secret.list` return metadata only), nor logs, events, or the host tool's view of upstream traffic (I1/I2).

**Possible future hardening (out of scope):** out-of-band user confirmation (e.g. a GUI prompt / Touch ID) for sensitive mutations such as re-scoping a secret or adding a host. This is the only mechanism that would meaningfully raise the bar, at a real cost in friction.

---

## 14. IPC: events SSE stream

### 14.1 Endpoint

`http://127.0.0.1:<events_listen>/events`

The stream is **loopback-only and unauthenticated**: it carries request metadata (hostnames, paths, secret *names*, exfil alerts) but never secret values (I2). Any local process can subscribe. See [§2 Accepted residuals](#accepted-residuals-audit-2026-06) for the cross-user-exposure boundary on shared machines.

### 14.2 Protocol

Standard SSE. Each event:

```
event: <Event.Kind>
id: <uuid>
data: <JSON-encoded Event>

```

Keep-alive comment lines every 15 s: `: ping\n\n`.

### 14.3 Filtering

Query parameters:

- `since=<ISO8601>` — backlog from a timestamp
- `kind=substituted,exfilBlocked` — filter by kind
- `host=api.github.com` — filter by host

The menu bar app uses `since=` on reconnect to backfill.

### 14.4 Backpressure

If a subscriber falls behind by > 1000 events, the daemon drops them and sends a final `event: dropped` with a count, then closes. The app reconnects with a new `since=`.

---

## 15. Menu bar app

`NSStatusItem` with template icon (a small key / shield). Click opens a `NSPopover` with SwiftUI content. Always running (auto-start via `SMAppService.mainApp.register()`).

### 15.1 Status icon states

- **Idle (default)**: gray key icon.
- **Active (substituted in last 5 s)**: same icon with subtle animation.
- **Paused**: outlined icon.
- **Unread alert(s)**: red badge with count.
- **Daemon down**: red strikethrough.

### 15.2 Popover layout

Header (40 px tall):
- Daemon status (green dot / red dot)
- Uptime
- Buttons: Pause / Resume, Open full window
- Settings gear

Tabs (segmented control, persisted in `UserDefaults`):

1. **Overview**
    - 24h counters: requests, substitutions, blocked, errors
    - Sparkline of substitutions/hour
    - Last 5 events (read-only list)

2. **Logs**
    - Live stream from SSE
    - Columns: time, host, method+path, status, secrets, duration
    - Filters: kind multi-select, host text-field, time range
    - Search box (matches across host, path, secret name)
    - "Pause stream" toggle
    - Export CSV / JSON
    - Row click → detail sheet (full event)

3. **Security**
    - List of `exfilBlocked` events (highest severity at top)
    - Each entry: timestamp, secret name, attempted host, rule(s) fired, snippet
    - Mark as read / acknowledge all
    - "Quarantine secret" action: temporarily disables substitution for that secret until manually re-enabled

4. **Secrets**
    - Table: name, allowed_hosts (comma list), created, last_used, usage_count
    - Buttons: Add, Edit (allowed_hosts only), Rotate (prompts for new value via NSPanel), Delete
    - Sheet for Add: name field (validates regex live), value field (`SecureField`), hosts (token field with autocompletion from MITM whitelist + free text)

5. **Rules** (MITM hosts)
    - Table: host, added
    - Add: text field with validation (DNS-like)
    - Delete with confirmation
    - Inline warning: "Adding a host means traffic to it can have placeholders substituted into it. Make sure no secret allows hosts you don't trust."

6. **Settings**
    - Listen ports (read-only display; structural — restart required)
    - Log level dropdown
    - Event retention days
    - `on_exfil_attempt` dropdown (hot-editable via `config.set`)
    - Max substitutions/minute (hot-editable via `config.set`)
    - "Open config.json"
    - "Reload config" button
    - "Trust store status" indicator + "Install CA" button if not trusted
    - "Quit & Uninstall" (confirmation, removes LaunchAgent, asks about Keychain items)

### 15.3 Notifications

`UNUserNotificationCenter`. On first install, the app requests notification permission. On `exfilBlocked` event with severity ≥ medium AND `on_exfil_attempt ≥ block_and_notify`:

```
Title:    Exfiltration attempt blocked
Subtitle: anthropic_api_key → api.github.com
Body:     Rule: host mismatch. Click to inspect.
```

Click opens the app's Security tab focused on that event.

### 15.4 State management

App holds an `@MainActor`-isolated `AppModel: ObservableObject`. Source of state:

- Initial snapshot via admin RPC `daemon.status()`, `secret.list()`, `rule.list()`, recent `events.query()`.
- Live updates via SSE stream.
- Periodic `daemon.status()` poll (~5 s) refreshes stats and **pause state**, so a pause/resume triggered out-of-band (CLI or another client) propagates to the UI — icon and status indicator — even while the SSE stream stays connected.
- Mutations always go through admin RPC; UI updates after RPC ack to ensure consistency.

---

## 16. CLI

Built with `swift-argument-parser`. Subcommands listed in [§4.3](#43-iris-cli). Key behaviors:

- All commands talk to the daemon. If the daemon is not running, exit code 2 with message "irisd not running. Try: launchctl kickstart -k gui/$UID/io.iris.daemon".
- `secret add` reads value from stdin if `--value-from-stdin`. Never echoes. Never accepts via command-line `--value=...` in interactive mode (would leak to shell history) — but allows it with explicit `--value` flag for scripting (with a warning printed to stderr).
- `--json` flag on all read commands emits JSON.
- `iris doctor` runs:
    1. Daemon reachable on Unix socket
    2. Daemon stats consistent (PID alive)
    3. CA cert present at expected path
    4. CA cert trusted by system (`security verify-cert`)
    5. Env vars present in current shell (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `HTTPS_PROXY`)
    6. Test connectivity: an internal endpoint that the daemon serves only at boot — `127.0.0.1:8888/__iris_ping` returns `200 ok`. (Bypasses MITM logic; reserved path.)
    7. **`apiKeyHelper` not set** in `~/.claude/settings.json` (incompatible with IRIS — see Annex A.11).

### 16.1 `iris mcp wrap` — automatic MCP config patching

**Purpose**: eliminate the friction of manually duplicating proxy/CA env vars into every MCP server's `env` block.

**Usage**:

```
iris mcp wrap <path>          # patch in place
iris mcp wrap <path> --watch  # patch then watch via FSEvents, re-patch on changes
iris mcp wrap <path> --dry-run # show diff, don't write
iris mcp unwrap <path>        # revert from <path>.bak
```

**Accepted file formats**: any JSON file with an `mcpServers` key at the root or nested one level deep. Covers:

- `~/.claude.json` (user-level Claude Code config)
- `<project>/.mcp.json` (project-level MCP config)
- `~/Library/Application Support/Claude/claude_desktop_config.json` (Claude Desktop — bonus)

**Patching rules** for each entry in `mcpServers`:

1. If `env` block exists, ensure these keys are present (do not overwrite existing values):
    ```
    HTTPS_PROXY         = config.broker.listen as http URL
    HTTP_PROXY          = same
    NODE_EXTRA_CA_CERTS = absolute path to ca.pem
    SSL_CERT_FILE       = same
    CURL_CA_BUNDLE      = same
    REQUESTS_CA_BUNDLE  = same
    ```

2. If `env` block is absent, create it with the 6 vars above.

3. **Never** modify entries where `type` is `http` or `sse` and no `env` block existed (HTTP MCP transports inherit the parent's env naturally and have no `env` block by design).

4. Existing user values for these 6 keys are preserved verbatim — `wrap` never overwrites.

5. Placeholder values (any key whose value matches `^\{\{kc:[a-zA-Z0-9_-]{1,64}\}\}$`) are left untouched.

**Backup**: before any write, copy `<path>` to `<path>.iris.bak` (overwriting any previous backup). `unwrap` restores from this backup.

**Idempotency**: running `wrap` twice in a row produces no diff on the second run.

**`--watch` mode**: uses FSEvents on the file's parent directory, debounce 500 ms. On change to `<path>` (excluding writes from `wrap` itself, detected via a content hash held in memory), re-runs the patch. Useful when Claude Code rewrites the file as part of its UI flow (e.g., installing a new MCP via the CLI).

**Output**: human-readable diff on stdout. `--json` for machine-readable summary with counts (`patched`, `already_compliant`, `skipped`, `errors`).

**Exit codes**:
- `0` — success, possibly no-op
- `1` — file not found or unparseable
- `2` — daemon unreachable (needed to know listen port and CA path)
- `3` — backup write failed

**Implementation notes**:
- Parse and re-emit JSON with stable key ordering, 2-space indent, trailing newline. (Use `JSONEncoder.OutputFormatting.sortedKeys` is wrong if the user's file has a specific order — actually, preserve key order via a custom `OrderedJSONDocument` type. Important: many `mcpServers` configs are hand-edited; clobbering key order is hostile.)
- The patcher must be tolerant of comments (`// ...`) and trailing commas if the file is JSONC. Detect by extension and by content. Use a JSONC-aware parser (`json5` or a minimal hand-rolled scanner).
- Validate the result parses as valid JSON before overwriting.

---

## 17. LaunchAgent and SMAppService

### 17.1 Registration

The app registers the daemon via `SMAppService.daemon(plistName: "io.iris.daemon.plist").register()` on first launch.

**Wait**: `SMAppService.daemon` registers a `LaunchDaemon` (root-owned). We want a `LaunchAgent` (user-owned, per-session). Use `SMAppService.agent(plistName: "io.iris.daemon.plist").register()`. The plist must live in the app bundle at `Contents/Library/LaunchAgents/`.

### 17.2 Plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.iris.daemon</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/irisd</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/irisd.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/irisd.err.log</string>
</dict>
</plist>
```

Note: `BundleProgram` is relative to the registering app bundle. The `irisd` binary lives inside `Iris.app/Contents/MacOS/`.

### 17.3 Lifecycle

- App registers on first launch → `launchd` starts the daemon.
- App quit does **not** stop the daemon (it's a separate service).
- "Quit & Uninstall" in the app calls `SMAppService.agent(...).unregister()` and waits for confirmation.

---

## 18. Installation and distribution

### 18.1 Build pipeline

```
xcodebuild archive
  → archive .xcarchive
  → export-archive to .app
  → codesign --force --deep --sign "Developer ID Application: ..." Iris.app
  → productbuild --component Iris.app /Applications \
                 --sign "Developer ID Installer: ..." \
                 --scripts ./packaging/scripts \
                 Iris.pkg
  → xcrun notarytool submit Iris.pkg --apple-id ... --wait
  → xcrun stapler staple Iris.pkg
```

### 18.2 Postinstall script

`packaging/scripts/postinstall`:

```bash
#!/bin/bash
set -e

# Run as the installing user, not root.
USER_HOME="$(eval echo ~$USER)"
mkdir -p "$USER_HOME/Library/Application Support/iris"

# Register the agent. The app will do this on first launch as well,
# but we do it here so the daemon is up immediately.
sudo -u "$USER" /usr/bin/open -a "/Applications/Iris.app" --args --first-launch

exit 0
```

The `--first-launch` flag triggers the app to:

1. Generate CA if absent.
2. Register the LaunchAgent.
3. Show a welcome window prompting: "Install CA in trust store?" → `security add-trusted-cert` (prompts admin once).
4. Show a section explaining the shell setup with copy-paste commands.

### 18.3 Uninstall

Menu bar app → Settings → Quit & Uninstall:

1. Confirm dialog ("This will stop irisd, remove the LaunchAgent, and optionally remove your Keychain items.")
2. `SMAppService.agent(...).unregister()`
3. `security delete-certificate -c "IRIS local CA"` (prompts admin)
4. Checkbox in dialog: "Also delete my secrets from Keychain". If checked, delete each `io.iris.secret.*` item.
5. Open Finder at `/Applications` so the user can drag the app to Trash.

---

## 19. Logging and event storage

### 19.1 Application logs

`swift-log` with `os.log` backend. Subsystem `io.iris.daemon`, categories: `proxy`, `keychain`, `ipc`, `events`, `config`, `ca`.

Levels controlled by `config.broker.log_level`.

**Mandatory redaction**: any log statement that references a secret value or a substituted token must pass through `redact(_:)` which returns `"[REDACTED:<sha256-first-8-hex>]"`. Unit-test this with an assertion that no log line contains values configured during the test.

### 19.2 Event store

SQLite at `~/Library/Application Support/iris/events.db`. Schema:

```sql
CREATE TABLE events (
    id TEXT PRIMARY KEY,                    -- UUID
    ts INTEGER NOT NULL,                    -- epoch ms
    kind TEXT NOT NULL,                     -- Event.Kind raw value
    host TEXT NOT NULL,
    method TEXT NOT NULL,
    path TEXT NOT NULL,
    status_code INTEGER,
    duration_ms INTEGER,
    substituted_secrets TEXT NOT NULL,      -- JSON array of names
    alert TEXT                              -- JSON-encoded Alert, nullable
);

CREATE INDEX idx_events_ts ON events(ts);
CREATE INDEX idx_events_kind ON events(kind);
CREATE INDEX idx_events_host ON events(host);
```

Retention enforced by a daily compaction task: delete rows where `ts < now - retention_days`.

The DB file is `mode 0600`. Contains no secret values — only metadata. Still kept private as it reveals usage patterns.

### 19.3 In-memory ring buffer

Size `config.broker.event_ring_size` (default 10 000). Backs the SSE stream's "live" view without a DB round-trip.

---

## 20. Project layout

```
iris/
├── CLAUDE.md
├── README.md
├── SPECS.md
├── LICENSE
├── Package.swift
├── Sources/
│   ├── IrisKit/
│   │   ├── Config/
│   │   │   ├── Config.swift
│   │   │   └── ConfigStore.swift
│   │   ├── Models/
│   │   │   ├── Secret.swift
│   │   │   ├── MITMRule.swift
│   │   │   ├── Event.swift
│   │   │   └── Alert.swift
│   │   ├── Secrets/
│   │   │   ├── SecretStore.swift           // protocol
│   │   │   ├── KeychainSecretStore.swift
│   │   │   └── InMemorySecretStore.swift
│   │   ├── CA/
│   │   │   ├── CAManager.swift
│   │   │   └── LeafCertCache.swift
│   │   ├── IPC/
│   │   │   ├── AdminClient.swift
│   │   │   ├── AdminProtocol.swift
│   │   │   └── EventsClient.swift
│   │   ├── Placeholder/
│   │   │   ├── PlaceholderEngine.swift
│   │   │   └── ExfilRules.swift
│   │   └── Util/
│   │       ├── Redaction.swift
│   │       └── Logging.swift
│   ├── irisd/
│   │   ├── main.swift
│   │   ├── Daemon.swift
│   │   ├── Proxy/
│   │   │   ├── ProxyServer.swift
│   │   │   ├── ConnectHandler.swift
│   │   │   ├── MITMHandler.swift
│   │   │   └── UpstreamClient.swift
│   │   ├── IPC/
│   │   │   ├── AdminServer.swift
│   │   │   └── EventsServer.swift
│   │   └── Storage/
│   │       └── EventDB.swift
│   ├── iris/                         // CLI
│   │   ├── main.swift
│   │   ├── Commands/
│   │   │   ├── Secret.swift
│   │   │   ├── Rule.swift
│   │   │   ├── Status.swift
│   │   │   ├── Logs.swift
│   │   │   ├── Config.swift
│   │   │   ├── CA.swift
│   │   │   └── Doctor.swift
│   └── IrisApp/                      // not in SwiftPM, Xcode project
│       ├── IrisApp.swift             // @main App
│       ├── MenuBar/
│       │   ├── StatusItemController.swift
│       │   └── PopoverViewController.swift
│       ├── Views/
│       │   ├── OverviewView.swift
│       │   ├── LogsView.swift
│       │   ├── SecurityView.swift
│       │   ├── SecretsView.swift
│       │   ├── RulesView.swift
│       │   └── SettingsView.swift
│       ├── Model/
│       │   └── AppModel.swift
│       └── Resources/
│           ├── Assets.xcassets
│           └── Library/LaunchAgents/io.iris.daemon.plist
├── Tests/
│   ├── IrisKitTests/
│   │   ├── PlaceholderEngineTests.swift
│   │   ├── ExfilRulesTests.swift
│   │   ├── ConfigTests.swift
│   │   ├── RedactionTests.swift
│   │   └── AdminProtocolTests.swift
│   └── IntegrationTests/
│       └── ProxyEndToEndTests.swift
└── packaging/
    ├── build-pkg.sh
    ├── scripts/
    │   ├── postinstall
    │   └── preinstall
    └── notarize.sh
```

Note: `IrisApp` is an Xcode project (cannot use SwiftPM for menu bar apps with `SMAppService` plist embedding). It links `IrisKit` as a SwiftPM dependency.

---

## 21. Open questions

To be answered before final implementation:

1. **CA validity period**: 10 years default seems excessive. Should it be configurable? 2 years with auto-rotation in v1.1?
2. **HTTP/2 support timeline**: MVP downgrades to h1.1. If a target API forces h2 (gRPC over h2 in particular), what's the priority?
3. **Wildcard host matching**: needed in MVP for things like `*.s3.amazonaws.com`?
4. **Per-host canonical-location config**: should `api.anthropic.com` → `x-api-key` be configurable per host, or fixed?
5. **Sandbox profile**: should `irisd` adopt a `sandbox-exec` profile to limit what it can do if compromised? (e.g., no filesystem outside `~/Library/Application Support/iris/`, no network outside the listed MITM hosts on egress)
6. **App Store distribution**: out of scope (the CA install requires admin and can't run in App Store sandbox). Direct download + notarized `.pkg` only.

---

## Annex A — Edge cases and gotchas

### A.1 Claude Code's `settings.json` env block does not work for `NODE_EXTRA_CA_CERTS`

Confirmed bug in Claude Code: env vars set in `~/.claude/settings.json` are not respected for TLS. The user must export them in their shell profile.

**Action**: `README.md` instructs shell-profile setup. `iris doctor` checks.

### A.2 Node's `fetch()` and HTTPS_PROXY

Node 20+ native `fetch()` does NOT honor `HTTPS_PROXY` by default. Claude Code uses an HTTP client (`undici` with explicit proxy agent) that does. If a future version of Claude Code switches to native `fetch()` without a proxy agent, this design breaks.

**Mitigation**: monitor Claude Code releases. Doctor command can probe by attempting a request to a known endpoint and checking if it lands on the proxy.

### A.3 MCP server child processes and env inheritance

Claude Code's MCP stdio servers inherit the full parent env. The placeholder + proxy chain works for them too. Validated against Claude Code v2.1+.

If a future version restricts env inheritance: the daemon could expose a list of "ENV vars to inject" via the wrapper, but that complicates the threat model — out of scope for MVP.

### A.4 Bun-based "Cowork" / Claude Desktop

Native Bun builds don't load macOS system certs in some configurations. `NODE_EXTRA_CA_CERTS` alone may not be sufficient. The scope of this project is Claude **Code** CLI; desktop apps are out of scope.

### A.5 The agent putting a placeholder in `User-Agent`

Rule R2 fires (medium severity), substitution does not happen, request goes out with literal placeholder in UA. Upstream typically logs UA but the literal string `{{kc:...}}` is harmless. No leak. Event surfaced as exfil attempt.

### A.6 Multipart bodies with embedded files

If a placeholder appears inside a multipart part (e.g., the agent uploads a file containing the env): the body is scanned per the byte-level rule. Substitution attempts trigger R4 (suspicious content type) if Content-Type is `multipart/form-data`. R1 fires unless the destination host is authorized.

For very large multipart bodies (> 4 MiB): pass through unchanged, log warning.

### A.7 WebSockets

If a whitelisted host upgrades to WebSocket, the broker forwards the upgrade and from that point on does not scan frames. Out of scope for substitution; the WS handshake itself can have placeholders in headers (substituted normally).

### A.8 TCP keepalive and long-lived connections

Anthropic's streaming responses can take 30+ seconds. Both client-facing and upstream-facing channels must have generous idle timeouts (≥ 5 min). Configurable.

### A.9 What if Claude Code is updated to use HTTPS pinning?

Game over for substitution — the agent would reject the broker's leaf cert. Currently not the case; Anthropic doesn't pin in the CLI.

**Mitigation**: monitor. If pinning lands, users can opt-out of MITM for `api.anthropic.com` and instead pre-inject the resolved secret via a wrapper at process launch. But then the agent's process holds the secret — back to square one. There is no clean answer if upstream pins.

### A.10 Two `irisd` instances trying to bind the same port

Second instance fails to bind, exits 1, `launchd` re-launches it in a loop, log spam. The LaunchAgent uses `ThrottleInterval` (default 10 s) to limit. The plist should explicitly set `ThrottleInterval=30`.

### A.11 Incompatibility with Claude Code's `apiKeyHelper`

IRIS is **incompatible** with the `apiKeyHelper` setting in `~/.claude/settings.json`. This is by design.

**Why**: confirmed bug anthropics/claude-code#2646 — when `apiKeyHelper` is configured, Claude Code does not respect `HTTPS_PROXY` for inference requests, meaning IRIS's MITM proxy is bypassed for the Anthropic API call. The two mechanisms cannot coexist safely.

**Design choice**: rather than implementing a dual-endpoint architecture (MITM proxy + reverse-proxy at `/anthropic` served via `ANTHROPIC_BASE_URL` + a trivial `iris-keyhelper` returning a literal token), IRIS uses one unified mechanism. Simpler surface, single mental model, single diagnostic path.

**Enforcement**:
- At daemon startup, `irisd` reads `~/.claude/settings.json` (and any project-level `.claude/settings.local.json` in `pwd` at launch, best-effort). If `apiKeyHelper` is set, emit a `WARN` log and a startup alert event surfaced as a banner in the menu bar app.
- `iris doctor` flags this as an error.
- Documentation in `README.md` instructs users to remove the setting.

**Migration path** from `apiKeyHelper`-based setups (including `op run`-wrapped, Docker sandbox plugin, Cordon):
1. `iris secret add anthropic_api_key --allowed-hosts api.anthropic.com --value-from-stdin`
2. Remove `apiKeyHelper` line from all `settings.json` files.
3. Set `ANTHROPIC_API_KEY='{{kc:anthropic_api_key}}'` in shell profile.
4. Restart shell, launch `claude`.

**Trade-off accepted**: if Anthropic ever ships cert pinning on `api.anthropic.com`, IRIS breaks for that host with no clean recourse short of implementing the dual-endpoint design. Probability assessed as low (would break all corporate TLS-inspection proxies in the same move).

---

**End of SPECS.md.**
