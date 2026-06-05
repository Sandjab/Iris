# Phase 4 — Scoping `allowed_hosts` et détection d'exfiltration

**Statut**: design validé, prêt pour planning d'implémentation
**Date**: 2026-05-25
**Branche cible**: `feat/phase-4-scoping-exfil`
**Couverture SPECS**: §8 (Allowed-hosts scoping), §9 (Exfiltration detection)

---

## 1. Objectif et scope

Passer la substitution de placeholders d'un mode naïf (substitution systématique dès que le secret existe) à un mode scopé (substitution conditionnée au host) avec détection active des tentatives d'exfiltration via cinq règles (R1–R5).

**Invariant central** : pour chaque hit `{{kc:NAME}}` détecté dans une requête vers `H`, la substitution n'a lieu que si `H ∈ secret(NAME).allowed_hosts` ET qu'aucune règle R1–R5 ne fire. Sinon, la requête est forwardée **inchangée** (placeholder littéral dans la payload) et un `Event(.exfilBlocked, alert: ...)` est émis. L'upstream rejette naturellement la requête malformée — c'est le backstop.

### Dans le scope

- Pipeline two-pass scan → evaluate → substitute conditionnelle.
- Règles R1 (host mismatch), R2 (non-canonical location), R3 (multiple distinct secrets), R4 (suspicious content type), R5 (volume anomaly).
- Application de `config.security.on_exfil_attempt` (`block_only`, `block_and_notify`, `block_notify_pause`) **côté daemon uniquement**.
- Compteur R5 in-memory (sliding window 60s, par nom de secret).
- Extension du protocole `SecretStore` avec `metadata(forName:)`.
- Tests unitaires sur scanner et evaluator, tests d'intégration sur le handler MITM.

### Hors scope (différés)

- RPC `rule.add/list/delete`, `config.reload`, `events.clear` — Phase 4.x dédiée.
- Notification macOS `UNUserNotificationCenter` — vit dans l'app menu-bar, Phase 6.
- Persistance SQLite des events — Phase 5/6 (besoin du store events).
- Notification UI sur `block_and_notify` — daemon headless, log warn seulement.
- Configurabilité des canonical headers et des fragments R4 — open question SPECS §21.4, roadmap.
- Wildcards host matching — SPECS §8.2, roadmap v1.1.
- Backpressure SSE réelle — différée Phase 3.x, low priority.

---

## 2. Data flow

```
                        ┌─────────────────────────────────┐
HTTPRequestHead+Body ─► │ 1. PlaceholderScanner.scan      │
                        │    (pure, no store)             │
                        │    → [PlaceholderHit{name,      │
                        │       location, snippet}]       │
                        └────────────┬────────────────────┘
                                     │
                        ┌────────────▼────────────────────┐
                        │ 2. ExfilRuleEngine.evaluate     │
                        │    (host, method, path,         │
                        │     content-type, hits)         │
                        │    → R1..R5 appliquées          │
                        │    → ExfilDecision              │
                        │      .allow(resolvable)         │
                        │      | .block(alert)            │
                        └────────────┬────────────────────┘
                                     │
                  ┌──────────────────┴──────────────────┐
                  │                                     │
       .allow(resolvable)                       .block(alert)
                  │                                     │
        ┌─────────▼─────────────────┐       ┌───────────▼──────────┐
        │ 3a. PlaceholderEngine.    │       │ 3b. Forward unchanged │
        │     substituteResolvable  │       │     (placeholder en   │
        │     → mutated request     │       │      payload)         │
        │ + recordSubstitution(...)│       │                       │
        └─────────┬─────────────────┘       └───────────┬──────────┘
                  │                                     │
        ┌─────────▼─────────┐               ┌───────────▼──────────┐
        │ Event(.substituted│               │ Event(.exfilBlocked, │
        │  | .noMatch)      │               │   alert: ...)        │
        │                   │               │ + apply policy:      │
        │                   │               │   .blockNotifyPause  │
        │                   │               │   → server.setPaused │
        └─────────┬─────────┘               └───────────┬──────────┘
                  │                                     │
                  └────────────┬────────────────────────┘
                               ▼
                        Forward to upstream
```

---

## 3. Composants

### 3.1 `PlaceholderScanner` (nouveau, statique pur)

Fichier : `Sources/IrisKit/Placeholder/PlaceholderScanner.swift`.

```swift
public struct PlaceholderHit: Sendable, Hashable {
    public enum Location: Sendable, Hashable {
        case header(name: String)   // name lowercased
        case urlPath
        case queryString
        case body
    }
    public let name: String          // secret name without {{kc:}}
    public let location: Location
    public let snippet: String       // pre-substitution context, max 256 chars
}

public enum PlaceholderScanner {
    public static func scan(
        headers: [(name: String, value: String)],
        uri: String,
        body: Data?
    ) -> [PlaceholderHit]

    public static func scanString(_ text: String, location: PlaceholderHit.Location) -> [PlaceholderHit]
}
```

- Aucun accès `SecretStore`. Aucune dépendance actor. Pur, synchrone, testable trivialement.
- Le scan splitte l'URI sur le premier `?` pour distinguer `.urlPath` et `.queryString`.
- Le `snippet` capture ~80 caractères de contexte autour du hit, troncature avec `…`. Caractères non-imprimables remplacés par `?`. Par construction (pré-substitution), le snippet ne peut pas contenir de valeur de secret.
- Le scan body skip si non-UTF-8 (consistant avec SPECS §7.4).

### 3.2 `ExfilRuleEngine` (nouveau, actor)

Fichier : `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`.

```swift
public enum ExfilDecision: Sendable {
    case allow(resolvable: [PlaceholderHit])     // hits OK to substitute
    case block(alert: Alert, allHits: [PlaceholderHit])
}

public struct RequestContext: Sendable {
    public let host: String           // lowercased, no port
    public let method: String         // "GET", "POST", ...
    public let path: String           // URI minus query string
    public let contentType: String?   // lowercased, prefix before ";"
}

public actor ExfilRuleEngine {
    private let secretStore: any SecretStore
    private let maxSubstitutionsPerMinute: Int
    private var volumeCounters: [String: SlidingMinuteCounter]

    private static let canonicalAuthHeaders: Set<String> = [
        "authorization", "x-api-key", "api-key", "x-auth-token"
    ]
    private static let suspiciousPathFragments: [String] = [
        "/comments", "/issues", "/notes", "/messages", "/blob"
    ]
    private static let suspiciousContentTypes: Set<String> = [
        "text/plain", "application/x-www-form-urlencoded", "multipart/form-data"
    ]

    public init(secretStore: any SecretStore, maxSubstitutionsPerMinute: Int)

    public func evaluate(hits: [PlaceholderHit], context: RequestContext) async throws -> ExfilDecision

    public func recordSubstitution(secretNames: [String])
}

private struct SlidingMinuteCounter: Sendable {
    private var timestamps: [Date] = []
    mutating func recordAndCount(now: Date) -> Int  // prune > 60s, append, return count
    mutating func currentCount(now: Date) -> Int    // prune > 60s, return count
}
```

- Sliding window R5 : Array de `Date`, prune à chaque accès. Borne supérieure de taille = `maxSubstitutionsPerMinute` (60 par défaut). O(60) en pire cas.
- `recordSubstitution` est appelé **uniquement** après une substitution réussie (côté MITMHandler). Une décision `.block` n'incrémente pas le compteur.
- `evaluate` lit les metadata via `secretStore.metadata(forName:)` (pas `value(forName:)`) — pas de prompt Keychain.

### 3.3 Modifications à `PlaceholderEngine`

Fichier : `Sources/IrisKit/Placeholder/PlaceholderEngine.swift` (modification).

Nouvelle méthode principale :

```swift
public struct ResolvedRequestPayload: Sendable {
    public let headers: [(name: String, value: String)]
    public let uri: String
    public let body: Data?
    public let substituted: [String]      // distinct names actually replaced
    public let unresolved: [String]       // names that failed lookup mid-substitution
}

public func substituteResolvable(
    headers: [(name: String, value: String)],
    uri: String,
    body: Data?,
    resolvableHits: [PlaceholderHit]
) async throws -> ResolvedRequestPayload
```

- Court-circuit si `resolvableHits.isEmpty` → retourne verbatim.
- Fetch values via le cache LRU existant (TTL 5 min, 32 entrées, conservé).
- Applique `replaceAll` ciblé : seul un placeholder dont `(name, location)` apparaît dans `resolvableHits` est substitué.
- Conserve `substitute(_ data: Data)` actuel pour compat tests (à supprimer en cleanup post-Phase 4 une fois le call site MITMHandler migré).

### 3.4 Extension `SecretStore`

Fichier : `Sources/IrisKit/Secrets/SecretStore.swift` (modification).

```swift
public protocol SecretStore: Sendable {
    func value(forName name: String) async throws -> Data
    func metadata(forName name: String) async throws -> Secret    // NEW
    func list() async throws -> [Secret]
}
```

- `KeychainSecretStore.metadata(forName:)` : `SecItemCopyMatching` avec `kSecReturnAttributes = true` (sans `kSecReturnData`). Parse `kSecAttrGeneric` JSON → `Secret`. Pas de prompt Keychain.
- `InMemorySecretStore.metadata(forName:)` : lookup dans la map en mémoire, throw `SecretStoreError.unknownSecret` si absent.

### 3.5 Modifications à `MITMHandler`

Fichier : `Sources/IrisKit/Proxy/MITMHandler.swift` (refactor de `applySubstitution`).

```swift
private struct ProcessedRequest {
    let head: HTTPRequestHead
    let body: ByteBuffer?
    let outcome: Outcome
    enum Outcome {
        case bypassed                                          // daemon paused
        case substituted(names: [String])
        case noMatch(unresolved: [String], nonUtf8: Bool, bodyTooLarge: Bool)
        case blocked(alert: Alert)
    }
}

private static func processRequest(
    head: HTTPRequestHead,
    body: ByteBuffer?,
    evaluator: ExfilRuleEngine,
    engine: PlaceholderEngine,
    logger: Logger,
    host: String,
    bypass: Bool
) async throws -> ProcessedRequest
```

Étapes internes :

1. Si `bypass == true` : strip `Accept-Encoding`, force `http/1.1`, retourne `.bypassed`.
2. Strip `Accept-Encoding` + force HTTP/1.1 (comportement existant Phase 2).
3. Si `Content-Length > 4 MiB` : skip scan, retourne `.noMatch(bodyTooLarge: true)`.
4. Décode body en `Data`. Si non-UTF-8 : retourne `.noMatch(nonUtf8: true)`.
5. `PlaceholderScanner.scan(headers, uri, body)` → `[Hit]`. Si vide : retourne `.noMatch(unresolved: [])`.
6. Build `RequestContext(host: host.lowercased(), method, path = uri sans query, contentType)`.
7. `evaluator.evaluate(hits, context)`.
8. Si `.block(alert)` → retourne `.blocked(alert)` avec head/body originaux (juste `Accept-Encoding` strippé). Aucune substitution.
9. Si `.allow(resolvable)`:
   - `engine.substituteResolvable(headers, uri, body, resolvableHits: resolvable)`.
   - Si `payload.substituted.isEmpty` → `.noMatch(unresolved: payload.unresolved)`.
   - Sinon : recalcule `Content-Length` si body modifié, `evaluator.recordSubstitution(secretNames: payload.substituted)`, retourne `.substituted(names: payload.substituted)`.

Émission d'event dans le callback NIO (déjà sur `flatMap`) :

```swift
let event: Event
switch processed.outcome {
case .bypassed:        event = Event(kind: .passThrough, ...)
case .substituted(let names):
    event = Event(kind: .substituted, ..., substitutedSecrets: names)
case .noMatch:         event = Event(kind: .noMatch, ...)
case .blocked(let alert):
    event = Event(kind: .exfilBlocked, ..., substitutedSecrets: [], alert: alert)
}
```

Application de la politique `on_exfil_attempt` (uniquement sur `.blocked`) :

```swift
case .blockOnly:
    break  // event already in ring + SSE
case .blockAndNotify:
    server.logger.warning("exfil blocked, notify intent", metadata: ...)
    // UI notification deferred to Phase 6 (menu-bar app, UNUserNotificationCenter)
case .blockNotifyPause:
    server.logger.warning("exfil blocked, auto-pausing daemon", metadata: ...)
    server.setPaused(true)
```

### 3.6 Wiring `ProxyServer` / `Daemon`

`ProxyServer.Configuration` :

```swift
public struct Configuration: Sendable {
    // existant...
    public let exfilRuleEngine: ExfilRuleEngine
    public let onExfilAttempt: ExfilAttemptPolicy
}
```

`Daemon.start(...)` instancie un `ExfilRuleEngine` unique, partagé entre toutes les connexions MITM. `maxSubstitutionsPerMinute` lu de `config.security`. Pas de mutation au runtime en Phase 4 (pas de `config.reload`).

---

## 4. Règles R1–R5

### Sévérité, ordre, composition

- Severity finale d'un event = max des sévérités des règles ayant fire.
- `Alert.rule` = première règle dans l'ordre R1 > R2 > R3 > R4 > R5 parmi celles qui ont fire (tiebreak déterministe).
- Le modèle `Alert` actuel ne porte qu'**une** règle. Les autres règles fired sont loggées en metadata mais pas exposées dans l'event. Limite acceptée Phase 4 (pas de modification du modèle).

### R1 — Host mismatch (high)

```
fire si: hit.name est connu (secretStore) ET context.host ∉ secret(hit.name).allowedHosts
```

- Comparaison `context.host` vs `allowedHosts[i]` : lowercased, sans port.
- Si `hit.name` est inconnu : ne fire pas R1, mais le hit est exclu de `resolvable`.
- Une seule occurrence suffit pour bloquer toute la requête.

### R2 — Non-canonical location (high)

```
fire si: hit.location est l'une de :
  - .header(name) avec name ∉ canonicalAuthHeaders
  - .urlPath
  - .queryString
  - .body si context.method == "GET"
```

- `canonicalAuthHeaders` = `{authorization, x-api-key, api-key, x-auth-token}` (lowercase).
- `.body` sur POST/PUT/PATCH ne fire pas R2 — R4 couvre le cas suspect.

### R3 — Multiple distinct secrets (medium)

```
fire si: |{ hit.name | hit ∈ hits }| ≥ 2
```

- 2+ noms distincts dans la requête, indépendamment de leur connaissance dans le store.
- Un même nom multipliquement présent ne déclenche pas R3.
- `Alert.secretName` = nom alphabétiquement premier (déterministe).

### R4 — Suspicious content type (medium)

```
fire si: ∃ hit avec hit.location == .body
         ET context.contentType ∈ {text/plain, application/x-www-form-urlencoded, multipart/form-data}
         ET context.path contient l'un de : /comments, /issues, /notes, /messages, /blob
```

- `contentType` lowercased, prefix avant `;` (ignorer `; charset=utf-8`).
- MVP : fragments hard-codés. Configurabilité = roadmap.

### R5 — Volume anomaly (low)

```
fire si: ∃ hit dont counter(hit.name) sur les 60 dernières secondes ≥ maxSubstitutionsPerMinute
```

- Sliding window in-memory dans l'actor `ExfilRuleEngine`.
- **Incrémenté uniquement après substitution réussie** (`recordSubstitution`).
- Lors de l'evaluate : on regarde `count(name) + 1 > max` (cette substitution franchirait le seuil).

---

## 5. Modèles et redaction

### 5.1 `Event` et `Alert`

Aucune modification des types existants. `Event.alert: Alert?` est nullable, peuplé uniquement quand `kind == .exfilBlocked`.

Pour `.exfilBlocked` :
- `substitutedSecrets = []`
- `alert.severity` = max des règles fired
- `alert.rule` = première règle fired dans l'ordre R1 > R2 > R3 > R4 > R5
- `alert.secretName` = nom du hit déclencheur
- `alert.detectedAt` = location du hit déclencheur (mappée vers `Alert.Location`)
- `alert.snippet` = snippet redacté ≤ 256 chars

### 5.2 Redaction du snippet

Par construction, le snippet est extrait **avant** substitution et contient au plus le placeholder littéral `{{kc:name}}` + contexte. Il ne peut pas contenir de valeur de secret. Test d'invariance dans `RedactionTests` :

```swift
// Setup: secret value = "sk-supersecret", placeholder = "{{kc:foo}}"
// Run scan + evaluate → Alert
XCTAssertFalse(alert.snippet.contains("sk-supersecret"))
XCTAssertTrue(alert.snippet.contains("{{kc:foo}}"))
```

### 5.3 Logging

`swift-log` subsystem `proxy`, niveau :
- `info` pour `.substituted`, `.noMatch`.
- `warn` pour `.exfilBlocked` (avec `rule`, `secretName`, `host` en metadata).
- `error` pour erreurs upstream (existant).

Aucun secret value ne traverse jamais le logger — garanti par construction (la value n'est lue qu'au moment de la substitution dans `substituteResolvable`, et n'est pas exposée en dehors du buffer modifié).

---

## 6. Politique `on_exfil_attempt`

Trois modes, déjà parsés depuis `config.toml` (`SecurityConfig.onExfilAttempt`) :

| Mode                   | Comportement Phase 4 (daemon)                                                       |
|------------------------|-------------------------------------------------------------------------------------|
| `block_only`           | Event émis dans ring + SSE. Aucun side-effect supplémentaire.                       |
| `block_and_notify`     | Idem + log `warn` "notify intent". Notification UI déférée à Phase 6.               |
| `block_notify_pause`   | Idem + appel `server.setPaused(true)`. Le daemon refuse toute substitution jusqu'à `daemon.resume()` RPC. |

`block_and_notify` ne déclenche pas de notification macOS en Phase 4 : le daemon est headless. L'app menu-bar (Phase 6) consommera l'event via SSE et déclenchera `UNUserNotificationCenter`. À documenter explicitement pour ne pas créer d'attente fausse.

---

## 7. Edge cases

### 7.1 Hits mixtes : connus + inconnus dans la même requête

**Révisé (2026-06-05).** R3 ne compte que les noms **connus**. Un nom inconnu ne résout jamais (0 leak) et la grammaire `{{kc:…}}` apparaît dans du texte ordinaire — la doc d'IRIS auto-injectée par claude_code en est l'exemple : compter les inconnus produisait un faux positif structurel sans gain de sécurité. Voir `docs/superpowers/specs/2026-06-05-exfil-header-only-substitution-design.md`.

### 7.2 Hits mixtes R1 : un autorisé, un mismatch

R1 fire sur le mismatch. La requête est bloquée entièrement. Aucun secret n'est substitué. SPECS §10 (trace exfiltration) confirme cette sémantique.

### 7.3 `allowed_hosts = []`

R1 fire systématiquement (aucun host ne match). Validation côté RPC `secret.add/update` doit rejeter ce cas — sinon le filet R1 protège le runtime.

### 7.4 R5 pendant `bypass`

`bypass == true` court-circuite avant scan. Counter R5 non incrémenté. `daemon.resume()` reprend depuis le dernier état. Sliding window 60s nettoiera de toute façon.

### 7.5 Concurrence R5

L'actor `ExfilRuleEngine` sérialise `evaluate` + `recordSubstitution`. Deux requêtes concurrentes ne peuvent pas franchir le seuil de plus de 1 chacune.

### 7.6 Reload de config

Hors scope. `maxSubstitutionsPerMinute` fixé au démarrage. `config.reload` Phase 4.x.

### 7.7 Path traversal encodé (`%7B%7Bkc%3A...%7D%7D`)

Le scan regex sur bytes UTF-8 littéraux ne voit pas le placeholder encodé. L'upstream URL-décode et reçoit `{{kc:...}}` littéral. Pas de leak ; l'upstream rejette ou ignore. Limitation MVP acceptée.

### 7.8 Header avec valeurs multiples

`HTTPHeaders` NIO permet plusieurs valeurs même nom. Le scan itère par entrée, chaque (name, value) traité indépendamment.

### 7.9 Compteur R5 et redémarrage daemon

Counters in-memory uniquement. Redémarrage = reset. Acceptable (window 60s, persistance sans intérêt).

---

## 8. Tests

### 8.1 `PlaceholderScannerTests` (nouveau)

- Hit unique dans header value canonique (`Authorization`).
- Hit dans header name (rare mais valide selon SPECS §7.2).
- Hit dans path (`/foo/{{kc:x}}/bar`) → `.urlPath`.
- Hit dans query string (`?key={{kc:x}}`) → `.queryString`.
- Hit dans body JSON.
- Multiple hits du même secret (1 nom distinct, plusieurs locations).
- Multiple hits de secrets distincts (R3 setup).
- Body non-UTF-8 → 0 hit, sans crash.
- URI sans `?` → location `.urlPath` uniquement, jamais `.queryString`.
- Pattern régex limites : `{{kc:}}` invalide, nom > 64 chars invalide.

### 8.2 `ExfilRuleEngineTests` (nouveau)

- **R1 mismatch** : `allowed_hosts = ["api.anthropic.com"]`, host `api.github.com` → `.block(hostMismatch, high)`.
- **R1 unknown name** : nom inconnu → ne fire pas R1, exclu de `resolvable`.
- **R1 case-insensitive** : `API.Anthropic.com` match `api.anthropic.com`.
- **R2 header non-canonique** : placeholder dans `X-Custom-Header` → R2.
- **R2 canonical** : dans `Authorization` → ne fire pas.
- **R2 GET avec body** : method GET + hit body → R2.
- **R2 path/query** : hit dans path ou query → R2.
- **R3** : 2 noms distincts → R3 (medium).
- **R3 same name multiple hits** : 1 nom, 3 occurrences → ne fire pas R3.
- **R4** : body POST `Content-Type: text/plain` vers `/issues/123` → R4.
- **R4 JSON API** : `application/json` vers `/v1/messages` → ne fire pas R4.
- **R5** : `max = 3`, `recordSubstitution(["x"]) × 3`, evaluate du 4e → R5.
- **R5 sliding window** : 3 substitutions à t=0, mock time +61s, evaluate → ne fire pas R5.
- **Severity composition** : R1+R3 fired simultanés → `Alert.rule = .hostMismatch`, severity = high.
- **R5 invariant** : evaluate `.block` → `recordSubstitution` non appelé → counter plat.

### 8.3 Tests d'intégration (étendre `ProxyEndToEndTests`)

- **Exfil host mismatch end-to-end** : secret avec `allowed_hosts = ["api.anthropic.com"]`, requête vers `api.github.com` avec `Authorization: {{kc:foo}}`. Vérifier :
  - Mock upstream reçoit `Authorization: {{kc:foo}}` (littéral).
  - Ring buffer contient `Event(kind: .exfilBlocked, alert.rule == .hostMismatch, alert.severity == .high)`.
- **Substitution scopée OK** : `allowed_hosts = ["api.github.com"]` → mock upstream reçoit la vraie valeur, event `.substituted`.
- **`block_notify_pause` auto-pause** : config + requête exfil → `server.isPaused == true` après le forward, prochaine requête → `.passThrough`.
- **R5 volume** : `max = 2`, 3 requêtes autorisées d'affilée vers le bon host → 3e émet `.exfilBlocked(.volumeAnomaly)`, upstream reçoit le placeholder littéral.

### 8.4 Redaction (étendre `RedactionTests`)

- Asserter `alert.snippet` ne contient jamais la valeur du secret.

### 8.5 Pas testé en Phase 4

- `UNUserNotificationCenter` (Phase 6).
- Persistance SQLite des events (Phase 5/6).
- Fuzz sur compteur R5.

---

## 9. Budget de performance

Two-pass scan/evaluate/substitute ≈ équivalent au single-pass actuel sur le coût CPU :

| Étape                | Aujourd'hui                                  | Phase 4                                              |
|----------------------|----------------------------------------------|------------------------------------------------------|
| Regex scan           | N actor hops (1 par champ)                   | 1 pass global statique                               |
| Evaluate règles      | aucun                                        | 1 actor hop, lookups O(1), 5 prédicats               |
| Substitution         | N passes (1 par champ)                       | Seulement sur champs ayant un hit autorisé           |
| Actor hops totaux    | ~N                                           | ~2–3                                                  |

Coût dominant reste réseau (handshake TLS + roundtrip upstream). Scan/evaluate en µs, invisible. Cache valeurs Keychain inchangé.

R5 sliding window : array borné par `maxSubstitutionsPerMinute` (60), prune O(60). Trivial.

Pas d'attente de mesure formelle Phase 4. Si une régression apparaît au smoke, on instrumente `os_signpost`.

---

## 10. Plan de livraison (esquisse, à raffiner par writing-plans)

1. Étendre `SecretStore` protocol + impls (`metadata(forName:)`).
2. Implémenter `PlaceholderScanner` + tests unitaires.
3. Implémenter `ExfilRuleEngine` + tests unitaires (R1–R5 isolés et composés).
4. Implémenter `PlaceholderEngine.substituteResolvable` + tests.
5. Refactorer `MITMHandler.applySubstitution` → `processRequest`.
6. Wiring `ProxyServer.Configuration` + `Daemon.start`.
7. Tests d'intégration `ProxyEndToEndTests` (exfil, scopé, auto-pause, R5).
8. Smoke test E2E (proxy réel + agent simulé).
9. `swift-format lint --strict`, `swift build`, `swift test` clean.
10. PR avec smoke checklist Phase 4.

Critères d'acceptation Phase 4 :

- [ ] Substitution n'a lieu que si `host ∈ secret.allowed_hosts`.
- [ ] R1 host mismatch détecté, event `.exfilBlocked` émis, requête forwardée inchangée.
- [ ] R2/R3/R4/R5 chacun déclenchable par un test unitaire dédié et un scénario d'intégration.
- [ ] `block_notify_pause` met le daemon en pause après une exfil détectée.
- [ ] Aucun secret value n'apparaît dans `Alert.snippet`, dans les logs, ni dans le ring buffer.
- [ ] 0 régression sur les 121 tests Phase 0–3.
- [ ] `swift-format lint --strict` clean.

---

## 11. Références

- SPECS §8 — Allowed-hosts scoping
- SPECS §9 — Exfiltration detection (R1–R5, `on_exfil_attempt`)
- SPECS §10 — Request flow (trace nominale + trace exfiltration)
- SPECS §19.1 — Mandatory redaction
- État projet : Phases 0–3 ✅, this design = Phase 4 entry point.
