# Phase 5 — CLI `iris` — Design

**Status** : approved, awaiting plan
**Source spec** : `SPECS.md` §4.3, §16, §16.1
**Memory anchor** : `project-iris-state.md`

---

## 1. Goal

Livrer la cible exécutable `iris` (binaire CLI macOS) en s'appuyant sur les RPCs daemon déjà disponibles depuis Phase 3 et le scoping/exfil de Phase 4. La cible :

- Pilote toutes les opérations utilisateur sur le daemon sans jamais exposer une valeur de secret.
- Expose un sous-ensemble cohérent de SPECS §4.3 (commandes faisables sans nouvelles RPCs daemon).
- Ajoute `iris mcp wrap` / `unwrap` minimal pour éliminer la friction de copier-coller des env vars proxy/CA dans les configs MCP.

## 2. Non-goals

- **Pas de mod daemon** au-delà de l'endpoint `/__iris_ping` réservé pour `iris doctor` (§5.2).
- `iris rule add/list/rm` et `iris config reload` (SIGHUP) **différés Phase 4.x** : les sous-commandes existent en stub `EX_USAGE` (64) avec message `"not implemented in Phase 5 (tracked in Phase 4.x)"`.
- `iris ca rotate` roadmap, hors Phase 5 (déjà déclaré roadmap dans SPECS §4.3).
- `iris mcp wrap` ne supporte ni `--watch` (FSEvents + debounce + hash exclusion) ni JSONC (comments, trailing commas) → différés **Phase 5.3.1**.

## 3. Découpe en sous-PRs

| PR | Branche | Contenu | Smoke |
|----|---------|---------|-------|
| 5.1 | `feat/phase-5.1-cli-core` | Wiring CLI sur RPCs existants : `secret.*`, `status`, `pause/resume`, `ca export/fingerprint/is-trusted`, `config get`, stubs `rule.*` + `config reload` | §5.1 |
| 5.2 | `feat/phase-5.2-logs-doctor` | `iris logs` (events.query + SSE follow), `iris doctor` (+ endpoint `/__iris_ping` ajouté côté daemon) | §5.2 |
| 5.3 | `feat/phase-5.3-mcp-wrap` | `iris mcp wrap` + `iris mcp unwrap` (JSON strict, pas JSONC, pas --watch), `OrderedJSONDocument`, `MCPPatcher` | §5.3 |

Chaque PR : branche dédiée, smoke checklist explicite, revue Gemini (workflow CLAUDE.md §8), squash-and-merge sur confirmation user.

## 4. Pattern commun

Hérité par toutes les sous-commandes.

### 4.1 Connexion daemon

`ConnectionOptions` (`@OptionGroup`) :
- `--socket-path` : défaut `~/Library/Application Support/iris/admin.sock` (tilde expansé via `NSString.expandingTildeInPath`, aligné sur `Config.default.broker.adminSocket`).
- `--config-path` : optionnel ; si fourni, lit le TOML et utilise sa valeur `broker.admin_socket`. Sinon défaut.

Helper `withAdminClient(_ body: (AdminClient) async throws -> Void) async throws` :
- Crée un `MultiThreadedEventLoopGroup(numberOfThreads: 1)`.
- Crée `AdminClient(socketPath:, group:)`.
- Exécute `body`, `defer` shutdown du group puis du client.
- Catch `AdminClientError.connectFailed` → exit code **2**, message stderr : `"irisd not running. Try: launchctl kickstart -k gui/$UID/io.iris.daemon"` (SPECS §16).

### 4.2 Exit codes

| Code | Sens |
|------|------|
| 0    | succès (y compris no-op idempotent) |
| 1    | erreur de logique métier (secret absent, JSON invalide, validation, doctor `fail`) |
| 2    | daemon unreachable |
| 3    | erreur I/O (backup, write atomique) |
| 64 (`EX_USAGE`) | sous-commande stubbée |

### 4.3 Sortie

- Texte humain par défaut (stdout). Tableaux alignés via formatter minimal maison.
- `--json` flag global : `JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys]`, snake_case explicite via `CodingKeys` (cohérent wire format Phase 3 — pas de stratégie magique, cf. décision mémoire Phase 3).
- Erreurs : stderr humain ; en mode `--json` un objet `{"error": {"code": N, "message": "..."}}` sur stderr puis exit code approprié.

### 4.4 Invariant sécurité

**Aucune valeur de secret n'est ni demandée, ni reçue, ni imprimée par le CLI au-delà du moment d'`add`/`rotate`.** Les RPCs `secret.list`/`secret.get` ne renvoient que name + allowed_hosts. Locké par test d'intégration : un dump complet de la sortie `iris secret list/show` (y compris en `--json`) ne contient jamais la valeur ajoutée.

Pour `add`/`rotate` :
- Lecture stdin via `FileHandle.standardInput.readToEnd()`, strip d'**un seul** `\n` final.
- Refus si valeur vide.
- `--value <v>` accepté pour scripting avec warning stderr `"warning: --value exposes the secret to shell history; prefer --value-from-stdin"` (SPECS §16).
- Si stdin est un TTY et qu'aucune valeur n'est fournie, prompt via `getpass(3)` (Darwin) avec confirmation. Sinon lecture stdin direct.

## 5. Sections par PR

### 5.1 PR `feat/phase-5.1-cli-core`

**Commandes** :

| Commande | RPC | Notes |
|----------|-----|-------|
| `iris secret add <name> [--allowed-hosts h,...] (--value-from-stdin\|--value v)` | `secret.add` | Voir §4.4 pour lecture valeur. |
| `iris secret list [--json]` | `secret.list` | Renvoie `[Secret]` (`name`, `allowed_hosts`, `created_at`, `last_used_at`, `usage_count`). Texte = `NAME  CREATED  LAST_USED  USES  HOSTS`. |
| `iris secret show <name> [--json]` | `secret.get` | Affiche name + allowed_hosts ; jamais la valeur. |
| `iris secret edit <name> --allowed-hosts h,...` | `secret.update` | Au moins un `--allowed-hosts` requis. |
| `iris secret rotate <name>` | `secret.rotate` | Prompt TTY ou stdin (cf. §4.4). |
| `iris secret rm <name> [--yes]` | `secret.delete` | Sans `--yes`, demande confirmation par retape du name. |
| `iris status [--json]` | `daemon.status` | `pid=… uptime=… version=… req=… sub=… exfil=… err=…`. |
| `iris pause` / `iris resume` | `daemon.pause/resume` | Imprime l'état retourné (`paused: true/false`). Idempotent. |
| `iris ca export [--path P] [--print]` | `ca.export_path` | Sans flag : imprime le path. `--path` copie. `--print` cat le PEM. |
| `iris ca fingerprint [--json]` | `ca.fingerprint` | Imprime `sha256: …`. |
| `iris ca is-trusted` | `ca.is_trusted` | Exit 0 si trusted, 1 sinon. |
| `iris config get [--json]` | `config.get` | TOML-ish pretty en texte ; JSON sinon. |
| `iris rule add/list/rm` | — | Stub `EX_USAGE` 64 + message. |
| `iris config reload` | — | Stub `EX_USAGE` 64 + message. |

**Fichiers ajoutés** :
- `Sources/iris/main.swift` (réduit à `IrisCLI.main()`).
- `Sources/iris/Commands/SecretCommands.swift`
- `Sources/iris/Commands/StatusCommand.swift`
- `Sources/iris/Commands/PauseResumeCommands.swift`
- `Sources/iris/Commands/CACommands.swift`
- `Sources/iris/Commands/ConfigCommands.swift`
- `Sources/iris/Commands/RuleCommands.swift` (stub)
- `Sources/iris/Commands/ReloadCommand.swift` (stub)
- `Sources/iris/Support/ConnectionOptions.swift`
- `Sources/iris/Support/Output.swift`
- `Sources/iris/Support/SecretInput.swift`

**Tests** :
- `Tests/IrisKitTests/IrisCLI/OutputTests.swift` (formatter unit).
- `Tests/IrisKitTests/IrisCLI/SecretInputTests.swift` (parser stdin/TTY mock).
- `Tests/IntegrationTests/CLISecretFlowTests.swift` (spawn `irisd` + driver `iris`, round-trip add/list/show/rotate/rm, invariant aucune valeur leakée).
- `Tests/IntegrationTests/CLIExitCodesTests.swift` (exit 2 si socket absent, 1 si secret absent).

**Smoke checklist** :
- [ ] `iris secret add foo --allowed-hosts api.x.com --value-from-stdin <<<"sk-xxx"` → ok
- [ ] `iris secret list` → table imprime `foo`
- [ ] `iris secret list --json` → JSON valide, pas de valeur secret
- [ ] `iris secret show foo` / `--json` → name + hosts, jamais valeur
- [ ] `iris secret rotate foo` via stdin → ok
- [ ] `iris secret rm foo` sans `--yes` puis confirmation → ok
- [ ] `iris status` / `--json` → champs cohérents
- [ ] `iris pause` puis `iris resume` (2x chacun) → idempotent
- [ ] `iris ca export --print` → PEM imprimé
- [ ] `iris ca fingerprint` → sha256 16 caractères × 8
- [ ] `iris config get` → TOML lisible
- [ ] `iris rule add foo` → exit 64, message Phase 4.x
- [ ] `iris status` avec daemon arrêté → exit 2, message launchctl

---

### 5.2 PR `feat/phase-5.2-logs-doctor`

**Commandes** :

- `iris logs [--since X] [--until Y] [--limit N] [--kind k1,k2] [--host H] [--json]` → `events.query`. Relatif accepté : `5m`, `1h`, `24h`, `7d`.
- `iris logs --follow [--kind …] [--host …] [--json]` → `EventsClient` SSE. Loop jusqu'à SIGINT. `--json` = ndjson (un objet event par ligne).
- `iris logs --follow` incompatible avec `--since/--until/--limit` (ArgumentParser validation).
- `iris doctor` : checks séquentiels imprimant `[ok|warn|fail] <name> — <détail>`. Exit 0 si aucun fail ; 1 sinon.

**Checks `doctor`** (SPECS §16) :

1. Socket reachable (`connect()` direct).
2. Daemon alive (`daemon.status` + `kill(pid, 0)` non-throwing).
3. CA cert présent (`ca.export_path` + `FileManager.fileExists`).
4. CA trusté system (`ca.is_trusted`).
5. Env vars shell courant (`HTTPS_PROXY`, `HTTP_PROXY`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`) → **warn** si absent (pas fail).
6. Ping endpoint `127.0.0.1:<broker.listen.port>/__iris_ping` → `200 ok`.
7. `~/.claude/settings.json` absence de `apiKeyHelper` (SPECS Annex A.11) → fail si présent.

**Endpoint `/__iris_ping`** :
- Ajouté dans `MITMHandler` (early-return avant scan/substitute/exfil-eval).
- Répond `HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok\n`.
- N'émet **aucun** `Event` (test d'invariance).
- Path réservé documenté comme tel ; n'apparaît jamais dans `events.query`.

**Fichiers ajoutés** :
- `Sources/iris/Commands/LogsCommand.swift`
- `Sources/iris/Commands/DoctorCommand.swift`
- `Sources/iris/Support/SignalHandling.swift` (SIGINT pour `--follow`)
- `Sources/iris/Support/RelativeTime.swift` (parser `Nm|Nh|Nd`)

**Fichiers modifiés** :
- `Sources/IrisKit/Proxy/MITMHandler.swift` — early-return `/__iris_ping`.

**Tests** :
- Unit `RelativeTimeTests` (parser).
- Unit `LogsOutputTests` (formatter table + ndjson).
- Unit `DoctorAggregationTests` (ok+warn+fail composition → exit code attendu).
- Integration `CLILogsFollowTests` : spawn daemon, `iris logs --follow` lu via pipe, déclencher 1 requête proxy substituée, vérifier SSE arrive ≤ 2s.
- Integration `CLIDoctorTests` : run avec daemon vivant + `apiKeyHelper` injecté dans fichier temp `HOME`.
- Integration `PingEndpointTests` : curl direct sur `/__iris_ping`, vérifier réponse + absence event dans `events.query`.

**Smoke checklist** :
- [ ] `iris logs` (vide) → ok
- [ ] Après trafic, `iris logs` → events listés
- [ ] `iris logs --since 5m --limit 3 --kind substituted` → filtré
- [ ] `iris logs --host api.x.com` → filtré
- [ ] `iris logs --follow` → events live, Ctrl-C clean
- [ ] `iris logs --follow --json` → ndjson
- [ ] `iris logs --follow --since 5m` → erreur de validation
- [ ] `iris doctor` daemon up → tous ok
- [ ] `iris doctor` daemon down → exit 1
- [ ] `iris doctor` avec `apiKeyHelper` injecté → fail check 7
- [ ] `curl http://127.0.0.1:<port>/__iris_ping` → `200 ok`, pas d'event

---

### 5.3 PR `feat/phase-5.3-mcp-wrap`

**Commandes** :
- `iris mcp wrap <path> [--dry-run] [--json]`
- `iris mcp unwrap <path>`

**Algorithme `wrap`** :

1. Call `config.get` + `ca.export_path` ; exit 2 si daemon down.
2. `Data(contentsOf:)` puis `OrderedJSONDocument.parse(_:)`. Si parse fail → exit 1 message `"<path>: not valid JSON (JSONC not supported in Phase 5)"`. Validate racine = object.
3. Refuser si `<path>` se termine par `.iris.bak` (anti-pied-de-biche).
4. Localiser `mcpServers` : racine ou un niveau de nesting (premier match).
5. Pour chaque entry :
   - Skip si `type` ∈ {`"http"`, `"sse"`} et `env` absent (SPECS §16.1.3).
   - Construire env attendu (6 vars) :
     - `HTTPS_PROXY` / `HTTP_PROXY` = `http://<broker.listen>` (host:port).
     - `NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE` / `CURL_CA_BUNDLE` / `REQUESTS_CA_BUNDLE` = chemin absolu vers `ca.pem`.
   - Si `env` absent → créer avec 6 vars (clés triées alpha).
   - Si `env` présent → ajouter chaque var manquante uniquement. Jamais d'overwrite. Valeurs matchant `^\{\{kc:[a-zA-Z0-9_-]{1,64}\}\}$` laissées intactes.
6. Diff via `OrderedJSONDocument.diff(original, patched)`.
7. `--dry-run` → print diff, exit 0.
8. Si patched == original → print `"already compliant: <path>"`, exit 0.
9. Sinon :
   - `cp` atomique vers `<path>.iris.bak` (write+rename via `Data.write(.atomic)`). Échec → exit 3.
   - `OrderedJSONDocument.serialize(patched)` (2-space, trailing `\n`, key order préservé).
   - Re-parse de validation via `JSONSerialization` avant write. Échec → exit 1.
   - Write atomique sur `<path>`.
10. Output texte = diff humain ou message d'état ; `--json` = `{"patched": N, "already_compliant": M, "skipped_http_sse": K, "errors": 0}`.

**Algorithme `unwrap`** :

- `<path>.iris.bak` doit exister → sinon exit 1.
- Validate `.bak` parse JSON (sanity).
- Move atomique `bak → path` ; `.bak` est consommé.

**`OrderedJSONDocument`** (`Sources/IrisKit/MCPConfig/OrderedJSONDocument.swift`) :

```swift
indirect enum OrderedJSONValue: Sendable, Equatable {
    case object([(String, OrderedJSONValue)])
    case array([OrderedJSONValue])
    case string(String)
    case number(Double)
    case integer(Int64)
    case bool(Bool)
    case null
}
```

- Parser hand-rolled, RFC 8259 strict. Pas de comments, pas de trailing commas.
- Serializer : 2-space indent, `\n` final, key order préservé, escapes RFC, numbers via round-trip check pour préserver `Int64` vs `Double` d'origine.
- API mutation : helpers ciblés sur les chemins MCP (`/mcpServers/<name>/env/<KEY>`) ; pas de subscript générique pour limiter la surface.

**`MCPPatcher`** (`Sources/IrisKit/MCPConfig/MCPPatcher.swift`) :

- Fonction pure `patch(document:brokerListen:caPemPath:) -> (OrderedJSONDocument, PatchSummary)`.
- Testable sans I/O ni daemon (input = doc + 2 strings).

**Fichiers ajoutés** :
- `Sources/iris/Commands/MCPCommands.swift`
- `Sources/IrisKit/MCPConfig/OrderedJSONDocument.swift`
- `Sources/IrisKit/MCPConfig/MCPPatcher.swift`

**Tests** :
- Unit `OrderedJSONDocumentTests` : ≥20 fixtures round-trip (ordered keys, nested, escapes, unicode, numbers, edge cases).
- Unit `MCPPatcherTests` :
  - entry sans env → 6 vars ajoutées
  - entry avec env partiel → seules vars manquantes ajoutées
  - `type: http` / `type: sse` sans env → skip
  - placeholder `{{kc:NAME}}` → préservé
  - valeur user existante → préservée verbatim
  - idempotence : 2 passes consécutives = pas de diff
  - nesting `mcpServers` un niveau profond
- Integration `MCPWrapFlowTests` : daemon spawné, fichier `.mcp.json` réaliste, wrap puis unwrap → identique byte-pour-byte.
- Test refus `.iris.bak` en input.

**Smoke checklist** :
- [ ] `iris mcp wrap <fichier minimal>` → patch + bak
- [ ] `iris mcp wrap <même fichier>` 2e passe → `already compliant`
- [ ] `iris mcp wrap --dry-run` → diff sans écriture
- [ ] `iris mcp wrap` skip entry `"type": "http"` sans env
- [ ] `iris mcp wrap` préserve `{{kc:foo}}`
- [ ] `iris mcp wrap` préserve l'ordre des clés (hand-edit comparison)
- [ ] `iris mcp unwrap <fichier>` → restauré exact
- [ ] `iris mcp unwrap` sans `.bak` → exit 1
- [ ] `iris mcp wrap` daemon down → exit 2
- [ ] `iris mcp wrap` sur JSON invalide → exit 1
- [ ] `iris mcp wrap <fichier.iris.bak>` → refus

## 6. Risques identifiés

| Risque | Mitigation |
|--------|-----------|
| `getpass(3)` ne fonctionne pas si stdin redirigé | Détection TTY via `isatty(0)` ; fallback stdin direct. |
| SSE `--follow` pipe broken si `iris` redirigé vers tail | SIGPIPE → exit 0 propre (cf. SignalHandling). |
| `OrderedJSONDocument` parser : edge cases unicode | ≥20 fixtures dont surrogates UTF-16 ; corpus pris de RFC 8259 examples. |
| `/__iris_ping` accidentellement loggé via traffic | Test d'invariance verrouille. |
| Concurrence : 2 `iris mcp wrap` en parallèle sur même path | Hors scope MVP, documenté. |

## 7. Différé hors Phase 5

- **Phase 5.3.1** : `iris mcp wrap --watch` (FSEvents + debounce 500ms + content-hash exclusion) ; JSONC support (comments, trailing commas).
- **Phase 4.x** : `rule.*` RPC daemon + `iris rule *` CLI, `config.reload` SIGHUP + `iris config reload`, `events.clear` (besoin SQLite store).
- **Phase 8** : `iris ca rotate` (roadmap, voir SPECS §4.3).

## 8. Critères de complétion Phase 5

- [ ] 3 PRs mergées sur main avec smoke checklists toutes cochées.
- [ ] `swift build -c release` clean, 0 warnings.
- [ ] `swift-format lint --strict --recursive` clean.
- [ ] `swift test` 100% verts (cibles `IrisKitTests` + `IntegrationTests`).
- [ ] Mémoire `project-iris-state.md` mise à jour avec décisions Phase 5.
- [ ] `docs/user-guide.md` placeholders screenshots `iris secret`, `iris doctor`, `iris mcp wrap` à filler quand visuels disponibles (suite cohérente avec PR #9).
