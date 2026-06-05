# Exfil — substitution headers-only — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un secret n'est jamais substitué dans un body de requête ; la substitution est réservée aux headers d'auth canoniques, et les noms inconnus n'arment plus aucune règle d'exfil.

**Architecture:** Deux familles de changements dans `ExfilRuleEngine.evaluate` : (1) R2 rend `.body` toujours non-canonique (un secret connu en body → block + forward littéral + alerte) ; (2) R3 et R4 ne comptent que les `knownHits` (les inconnus deviennent inertes). Conséquence : R4 est subsumée par R2 (conservée, défense en profondeur). Le scan du body reste actif (détection préservée).

**Tech Stack:** Swift 5.9+, SwiftPM, XCTest, swift-format. Aucune nouvelle dépendance.

---

## Contexte & invariants

- Spec : `docs/superpowers/specs/2026-06-05-exfil-header-only-substitution-design.md`.
- L'instrumentation diagnostic (`Exfil hit inventory`, commit `15ed55c`) est déjà sur la branche `feat/exfil-r3-diag-logs`. Ce plan empile dessus.
- Ordre d'évaluation des règles : R1 > R2 > R3 > R4 > R5, première qui fire l'emporte. Important : une fois `.body` non-canonique, **R2 préempte R4** sur tout hit body connu.
- `.block` ne droppe pas : la requête est forwardée avec le placeholder littéral + `Event(.exfilBlocked)`. Sémantique inchangée.
- CLAUDE.md §6.1 : aucune valeur de secret en log/test dump. Les tests existants `RedactionTests`/`ExfilDiagnosticLogTests` le couvrent.

## File structure

- Modify: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift` — R2 helper, R3 bloc, R4 appel.
- Modify: `Tests/IrisKitTests/ExfilRuleEngineTests.swift` — inversions body + R3 known-only.
- Modify: `Tests/IrisKitTests/ExfilDiagnosticLogTests.swift` — sanity-check `.block`→`.allow`.
- Modify: `SPECS.md` — G2, R2, R3, R4.
- Modify: `docs/superpowers/specs/2026-05-25-phase-4-scoping-exfil-design.md` — §7.1.

Aucun test d'intégration impacté (placeholders y sont tous dans des headers ; vérifié).

---

## Task 1 : R2 — `.body` toujours non-canonique (ferme l'exfil body)

**Files:**
- Modify: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`
- Test: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`

- [ ] **Step 1 : Mettre à jour/écrire les tests body (doivent échouer).**

Dans `Tests/IrisKitTests/ExfilRuleEngineTests.swift`, **remplacer** `testR2BodyOnPOSTAllowed` par :

```swift
    func testR2BodyOnPOSTBlocks() async throws {
        // Headers-only : un secret connu n'importe où dans un body est un signal
        // d'exfil (forwardé littéral + alerte), jamais substitué.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx(method: "POST"))
        guard case .block(let alert, _) = decision else {
            return XCTFail("known secret in POST body must block (body non-canonical)")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }
```

**Remplacer** `testR4JSONAPIPathAllowed` par (ferme le gap A2-json PAT→comment) :

```swift
    func testKnownSecretInJSONBodyBlocks() async throws {
        // A2 : un secret connu dans un body JSON vers son propre host autorisé
        // (ex. un PAT faufilé dans un commentaire GitHub) était silencieusement
        // substitué. R2 (body non-canonique) le bloque désormais.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.anthropic.com",
                method: "POST",
                path: "/v1/messages",
                contentType: "application/json"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("known secret in JSON body must block")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }
```

**Remplacer** `testR4NoContentTypeDoesNotFire` par :

```swift
    func testKnownSecretInBodyNoContentTypeBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(host: "api.github.com", method: "POST", path: "/issues", contentType: nil)
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("known secret in body must block regardless of content-type")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }
```

Dans les quatre tests `testR4TextPlainToIssuesPathBlocks`, `testR4FormUrlencodedToCommentsBlocks`, `testR4MultipartToBlobBlocks`, `testR4ContentTypeWithCharsetParameter` : **changer** chaque ligne `XCTAssertEqual(alert.rule, .suspiciousContentType)` en `XCTAssertEqual(alert.rule, .nonCanonicalLocation)` (R2 préempte R4 sur le hit body connu). Laisser le reste (dont `XCTAssertEqual(alert.detectedAt, .body)` qui reste vrai).

- [ ] **Step 2 : Lancer → échec attendu.**

Run: `swift test --filter ExfilRuleEngineTests 2>&1 | tail -20`
Expected: FAIL — `testR2BodyOnPOSTBlocks`/`testKnownSecretInJSONBodyBlocks`/etc. échouent (l'engine actuel renvoie `.allow` ou `.suspiciousContentType`).

- [ ] **Step 3 : Implémenter R2 `.body` non-canonique.**

Dans `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`, **remplacer** la fonction `isNonCanonicalLocation` par (retirer le paramètre `method`, devenu inutile) :

```swift
    private static func isNonCanonicalLocation(hit: PlaceholderHit) -> Bool {
        switch hit.location {
        case .header(let name):
            return !canonicalAuthHeaders.contains(name)
        case .urlPath, .queryString, .body:
            // Substitution réservée aux headers d'auth canoniques : query, path
            // et body sont tous non-canoniques. Un secret connu qui y apparaît
            // est un signal d'exfil (bloqué, forwardé littéral, alerté).
            return true
        }
    }
```

Au site d'appel R2, **remplacer** `if Self.isNonCanonicalLocation(hit: hit, method: context.method) {` par `if Self.isNonCanonicalLocation(hit: hit) {`.

- [ ] **Step 4 : Lancer → succès.**

Run: `swift test --filter ExfilRuleEngineTests 2>&1 | tail -10`
Expected: PASS (tous les tests de la suite).

- [ ] **Step 5 : Commit.**

```bash
git add Sources/IrisKit/Placeholder/ExfilRuleEngine.swift Tests/IrisKitTests/ExfilRuleEngineTests.swift
git commit -m "fix(exfil): .body toujours non-canonique — secret connu en body bloqué

R2 traitait le body POST comme canonique (substitution autorisée), laissant
ouvert l'exfil d'un secret connu vers son propre host (PAT faufile dans un
commentaire JSON). .body devient non-canonique pour tout method, comme query
et path le sont deja. Ferme A2 par construction (fail-closed). R4 (body) est
des lors preemptee par R2."
```

---

## Task 2 : R3 — ne compter que les noms connus (tue le FP de la doc)

**Files:**
- Modify: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`
- Test: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`, `Tests/IrisKitTests/ExfilDiagnosticLogTests.swift`

- [ ] **Step 1 : Mettre à jour les tests R3 (doivent échouer).**

Dans `ExfilRuleEngineTests.swift`, **remplacer** `testR3CountsUnknownNames` par :

```swift
    func testR3IgnoresUnknownNames() async throws {
        // R3 ne compte que les secrets CONNUS (un env-dump de vrais credentials).
        // Un nom inconnu ne résout jamais → ne peut fuiter → ne doit pas bloquer.
        // C'est le fix du faux positif de la doc `{{kc:NAME}}`.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}"),
            PlaceholderHit(name: "ghost", location: .header(name: "x-api-key"), snippet: "{{kc:ghost}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow(let resolvable) = decision else {
            return XCTFail("1 known + 1 unknown → R3 must not fire (known-only)")
        }
        XCTAssertEqual(resolvable.map(\.name), ["foo"])
    }
```

**Supprimer** entièrement `testR3TiebreakWinnerCanBeUnknownName` (sa prémisse — un inconnu peut gagner le tiebreak R3 — disparaît ; le tiebreak entre noms connus reste couvert par `testR3MultipleDistinctSecretsBlocks`).

Dans `ExfilDiagnosticLogTests.swift`, dans `testHitInventoryLogsNamesAndLocationsButNeverValue`, **remplacer** le bloc :

```swift
        // Sanity: this is indeed the R3 multipleSecrets block we want to diagnose.
        guard case .block(let alert, _) = decision, alert.rule == .multipleSecrets else {
            return XCTFail("expected R3 multipleSecrets block for two distinct names")
        }
```

par :

```swift
        // Post-fix (R3 known-only) : un secret connu en header + un placeholder
        // inconnu en body ne bloque plus. L'inventaire est logué avant les règles,
        // donc capturé quelle que soit la décision.
        guard case .allow = decision else {
            return XCTFail("known header secret + unknown body name should allow (R3 known-only)")
        }
```

- [ ] **Step 2 : Lancer → échec attendu.**

Run: `swift test --filter "ExfilRuleEngineTests|ExfilDiagnosticLogTests" 2>&1 | tail -20`
Expected: FAIL — `testR3IgnoresUnknownNames` (l'engine bloque encore) et le diag test (attend `.block`).

- [ ] **Step 3 : Implémenter R3 known-only.**

Dans `ExfilRuleEngine.swift`, **remplacer** le bloc R3 par :

```swift
        // R3 — multiple distinct KNOWN secrets (medium). Les noms inconnus ne
        // résolvent jamais (ne fuient pas) et la grammaire `{{kc:…}}` apparaît
        // dans du texte ordinaire (la doc d'IRIS elle-même) → on ne les compte
        // pas. Aligné sur R1/R2/R5 qui clés déjà sur knownHits.
        let distinctNames = Set(knownHits.map(\.name))
        if distinctNames.count >= 2 {
            guard let triggeringName = distinctNames.sorted().first else {
                return .allow(resolvable: knownHits)
            }
            let triggeringHit = knownHits.first { $0.name == triggeringName } ?? knownHits[0]
            let alert = Alert(
                severity: .medium,
                rule: .multipleSecrets,
                secretName: triggeringName,
                detectedAt: alertLocation(from: triggeringHit.location),
                snippet: triggeringHit.snippet
            )
            return .block(alert: alert, allHits: effectiveHits)
        }
```

- [ ] **Step 4 : Lancer → succès.**

Run: `swift test --filter "ExfilRuleEngineTests|ExfilDiagnosticLogTests" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5 : Commit.**

```bash
git add Sources/IrisKit/Placeholder/ExfilRuleEngine.swift Tests/IrisKitTests/ExfilRuleEngineTests.swift Tests/IrisKitTests/ExfilDiagnosticLogTests.swift
git commit -m "fix(exfil): R3 ne compte que les secrets connus — tue le FP de la doc

Compter les noms inconnus (design §7.1) faisait sur-bloquer tout corps
contenant la grammaire {{kc:...}} (la doc d'IRIS auto-injectee par claude).
Un inconnu ne resout jamais → 0 leak → ne doit pas bloquer. Aligne R3 sur
R1/R2/R5 (knownHits)."
```

---

## Task 3 : R4 — ne considérer que les hits connus

**Files:**
- Modify: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`
- Test: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`

- [ ] **Step 1 : Écrire le test (doit échouer).**

Dans `ExfilRuleEngineTests.swift`, **ajouter** dans la section `// MARK: R4` :

```swift
    func testR4IgnoresUnknownBodyName() async throws {
        // R4 clé sur les secrets connus uniquement. Un placeholder inconnu dans
        // un body suspect ne doit pas bloquer (il ne résout jamais). R2 ne le
        // bloque pas non plus (R2 clé sur les connus) → requête autorisée.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "ghost", location: .body, snippet: "{{kc:ghost}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(host: "api.github.com", method: "POST", path: "/issues", contentType: "text/plain")
        )
        guard case .allow = decision else {
            return XCTFail("unknown body name must not fire R4 (known-only)")
        }
    }
```

- [ ] **Step 2 : Lancer → échec attendu.**

Run: `swift test --filter ExfilRuleEngineTests/testR4IgnoresUnknownBodyName 2>&1 | tail -10`
Expected: FAIL — R4 sur `effectiveHits` voit `ghost` et bloque (`.suspiciousContentType`).

- [ ] **Step 3 : Implémenter R4 known-only.**

Dans `ExfilRuleEngine.swift`, **remplacer** la ligne d'appel R4 `if let triggeringHit = Self.suspiciousContentTypeFires(hits: effectiveHits, context: context) {` par :

```swift
        // R4 — suspicious content type (medium). Hits connus uniquement : un nom
        // inconnu ne résout jamais. NOTE : sur le chemin courant R2 (body
        // non-canonique) préempte R4 pour tout hit body connu — R4 ne fire donc
        // plus ; conservée pour la défense en profondeur et un futur allowlist
        // body-credential.
        if let triggeringHit = Self.suspiciousContentTypeFires(hits: knownHits, context: context) {
```

- [ ] **Step 4 : Lancer → succès.**

Run: `swift test --filter ExfilRuleEngineTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5 : Commit.**

```bash
git add Sources/IrisKit/Placeholder/ExfilRuleEngine.swift Tests/IrisKitTests/ExfilRuleEngineTests.swift
git commit -m "fix(exfil): R4 ne considere que les hits connus

Coherence avec R3 et le principe known-only : un nom inconnu en body ne doit
pas armer R4. R4 reste subsumee par R2 sur le chemin courant ; conservee pour
defense en profondeur."
```

---

## Task 4 : Documentation (SPECS + design Phase 4)

**Files:**
- Modify: `SPECS.md`
- Modify: `docs/superpowers/specs/2026-05-25-phase-4-scoping-exfil-design.md`

- [ ] **Step 1 : SPECS G2.**

Dans `SPECS.md`, **remplacer** la ligne G2 :

```
- **G2.** Substitute placeholders `{{kc:NAME}}` found in HTTP headers, query strings, and request bodies with values fetched from the macOS Keychain.
```

par :

```
- **G2.** Substitute placeholders `{{kc:NAME}}` found in **canonical auth headers** with values fetched from the macOS Keychain. Placeholders of known secrets found in query strings, URL paths, or request bodies are treated as exfiltration signals: the request is forwarded with the placeholder literal (never substituted) and an alert is emitted.
```

- [ ] **Step 2 : SPECS R2.**

Dans `SPECS.md`, sous `### R2 — Non-canonical location (high)`, **remplacer** la puce :

```
- The body of a `GET` request.
```

par :

```
- The body of a request (any method) — secrets are substituted only in canonical auth headers.
```

- [ ] **Step 3 : SPECS R3.**

Dans `SPECS.md`, **remplacer** le corps de `### R3 — Multiple distinct secrets in one request (medium)` :

```
≥ 2 distinct placeholder names in a single request. Smells like an `env` dump.
```

par :

```
≥ 2 distinct **known** secret names in a single request. Smells like an `env` dump. Unknown placeholder names are not counted: they never resolve (cannot leak), and the `{{kc:…}}` grammar appears in ordinary text — including IRIS's own documentation — so counting them produced structural false positives.
```

- [ ] **Step 4 : SPECS R4.**

Dans `SPECS.md`, à la fin du paragraphe `### R4 — Suspicious content type (medium)` (après `... or matches user-configured patterns).`), **ajouter** :

```
Keys off known secrets only. On the current path, R2 (body non-canonical) preempts R4 for any known body secret, so R4 no longer fires in practice; it is retained for defense-in-depth and for a future body-credential allowlist.
```

- [ ] **Step 5 : Design Phase 4 §7.1.**

Dans `docs/superpowers/specs/2026-05-25-phase-4-scoping-exfil-design.md`, **remplacer** le paragraphe §7.1 :

```
R3 compte les noms distincts trouvés **indépendamment** de leur connaissance dans le store. 2 noms (1 connu, 1 inconnu) → R3 fire (medium) → bloque tout. Choix justifié par l'invariant "0 leak" : un agent qui mélange un placeholder valide et des typos bizarres est exactement le pattern à flagger.
```

par :

```
**Révisé (2026-06-05).** R3 ne compte que les noms **connus**. Un nom inconnu ne résout jamais (0 leak) et la grammaire `{{kc:…}}` apparaît dans du texte ordinaire — la doc d'IRIS auto-injectée par claude_code en est l'exemple : compter les inconnus produisait un faux positif structurel sans gain de sécurité. Voir `docs/superpowers/specs/2026-06-05-exfil-header-only-substitution-design.md`.
```

- [ ] **Step 6 : Commit.**

```bash
git add SPECS.md docs/superpowers/specs/2026-05-25-phase-4-scoping-exfil-design.md
git commit -m "docs(exfil): SPECS G2/R2/R3/R4 + design §7.1 — substitution headers-only"
```

---

## Task 5 : Vérification complète + préparation smoke

**Files:** aucun (vérification).

- [ ] **Step 1 : Suite complète.**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests, with .* failures" | tail -3`
Expected: 0 failures.

- [ ] **Step 2 : Lint.**

Run: `swift-format lint --recursive Sources Tests 2>&1 | head` puis (si besoin) `swift-format format -i` sur les fichiers touchés et re-lint.
Expected: aucune sortie (clean).

- [ ] **Step 3 : Build release (oracle warnings local).**

Run: `swift build -c release 2>&1 | grep -E "warning:|error:|Build complete"`
Expected: `Build complete`, et aucun warning nouveau (seul `SecAccessCreate` déprécié préexistant 8b est toléré).

- [ ] **Step 4 : Smoke (USER au Terminal — lancements daemon refusés côté agent).**

Re-jouer le smoke `claude` depuis le repo `iris` avec `--log-level debug` (cf handoff). Critères :
- `grep "Exfil hit inventory" /tmp/iris-r3.log` sur `/v1/messages` montre `distinctNames=1` côté connus → **plus** de block R3.
- `claude -p "dis bonjour"` ne renvoie **plus** « invalid api key » ; la substitution header opère, `{{kc:NAME}}` reste littéral dans le corps.
- (Optionnel) preuve A2 : `curl` avec un secret connu **dans le body** vers son host autorisé → log `Exfiltration attempt blocked rule=nonCanonicalLocation`, valeur absente upstream.

---

## Self-review

**Spec coverage :** R2 body non-canonique (Task 1) ✓ ; R3 known-only (Task 2) ✓ ; R4 known-only + subsomption (Task 3) ✓ ; SPECS/design (Task 4) ✓ ; smoke/diag (Task 5) ✓. Hors scope respecté (pas d'allowlist OAuth, pas de suppression du code substitution body de `PlaceholderEngine`).

**Placeholders :** aucun TBD/TODO ; chaque step de code montre le code exact.

**Type consistency :** `isNonCanonicalLocation(hit:)` (signature changée, site d'appel mis à jour) ; `suspiciousContentTypeFires(hits:context:)` inchangée, juste l'argument `effectiveHits→knownHits` ; `knownHits`/`effectiveHits`/`distinctNames` cohérents avec l'engine existant ; `Alert(rule: .nonCanonicalLocation | .multipleSecrets | .suspiciousContentType)` — cases existantes.
