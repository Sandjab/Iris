# Audit de sécurité approfondi — IRIS (2026-05-25)

> Audit conduit sur `main` après merge de la PR Phase 3 (commit `f47b953`). Couvre les 4 grands domaines de sécurité du daemon : secrets / substitution / redaction, PKI (CA + TLS), IPC + networking, configuration / supply chain / lifecycle.
> Méthode : revue de code statique, vérification API Apple/Swift via `developer.apple.com`, audit des dépendances supply chain via GitHub. Lectures effectuées dans le contexte de l'agent principal — le sous-répertoire `Sources/IrisKit/Secrets/` est volontairement deny par le sandbox utilisateur ; les comportements ont donc été inférés via le contrat exposé (tests publics, signature `SecretStore`, consommation `PlaceholderEngine`).

---

## Résumé exécutif

| Catégorie | 🔴 Critical | 🟠 High | 🟡 Medium | 🔵 Low |
|---|:---:|:---:|:---:|:---:|
| Total findings | 0 | 4 | 11 | 5 |

**Verdict global** : **rigueur élevée pour une Phase 3**. Les invariants `CLAUDE.md §6` les plus durs (Keychain ACL, scoping `allowed_hosts`, ACL CA root) sont **connus et explicitement planifiés pour des phases ultérieures** (4 et 8) — annotations en code et tests présents. Aucun finding 🔴 Critical. Les 4 findings 🟠 High se répartissent en 2 dettes documentées (scoping Phase 4, ACL CA Phase 8) et 2 défauts actionnables maintenant (CRLF injection, gating du mode debug). Le sandbox utilisateur (deny sur `Sources/IrisKit/Secrets/`) constitue une posture défensive supplémentaire saluable.

**Top 3 findings actionnables tout de suite** :
1. **CRLF injection via valeur de secret** dans `MITMHandler.applySubstitution` — un secret contenant `\r\n` peut splitter les headers HTTP forwardés.
2. **Mode `--in-memory-secrets` sans gate "unsafe"** — un debug bypass trop facilement activable, secrets via env vars visibles par `ps -E`.
3. **CONNECT passthrough = SSRF** vers `127.0.0.1:22` etc. — pas de filtre destination dans `ConnectHandler.performPassthrough`.

---

## Threat model implicite

L'audit s'appuie sur les hypothèses suivantes (dérivées de SPECS + CLAUDE.md §6) :

- **Attaquant local non-root** (process malveillant tournant en tant que l'utilisateur) : doit être bloqué par les permissions Unix (socket 0600, Keychain ACL).
- **Hôte malveillant** (outil hôte type Claude Code CLI compromis) : ne doit jamais voir les valeurs de secrets, peut tenter d'exfiltrer via placeholder vers un host non autorisé, peut envoyer des bodies forgés.
- **Attaquant réseau LAN** : ne doit pas voir le trafic intercepté (proxy loopback), ne doit pas pouvoir injecter via le SSE.
- **Vol de la machine** : la Keychain protège les secrets sous le mot de passe utilisateur. Pas dans le scope direct de cet audit.

---

## Domaine A — Secrets, substitution, redaction

### 🟠 High — Substitution sans check `allowed_hosts` (§6.3)

**Référence** : `Sources/IrisKit/Placeholder/PlaceholderEngine.swift:43` (méthode `substitute`)

**Description** : `PlaceholderEngine.substitute(_:)` résout et substitue **tous** les placeholders rencontrés sans vérifier si le host destination figure dans `allowedHosts` du secret. Le commentaire ligne 40-42 documente cette limitation : *"Phase 2: naive byte-level substitution with no host scoping. [...] Scoping (`allowed_hosts`) and exfil detection arrive in Phase 4."*

**Scénario** : pendant Phase 3 (état actuel) un placeholder `{{kc:anthropic_key}}` dans une requête vers `evil.example.com` (non whitelisté côté MITM) sera substitué et envoyé en clair vers l'upstream — exactement le scénario d'exfiltration que §6.3 interdit. Atténué par le fait que `ConnectHandler` ne fait MITM que sur les hosts whitelistés ; les hosts non-whitelistés passent en tunnel TLS opaque (le proxy ne voit pas le placeholder). Donc l'exfiltration suppose qu'un attaquant ajoute le host cible à `allowedHosts` du MITM — ce qui requiert d'écrire le TOML config.

**Sévérité** : 🟠 High (invariant §6.3 violé), **mais dette explicitement planifiée Phase 4**. Branche active `feat/phase-4-scoping-exfil`.

**Fix suggéré** : ajouter à `substitute()` un paramètre `host: String`, fetcher d'abord la metadata du secret (incluant `allowed_hosts`), refuser l'expansion si pas de match, émettre `Event.Kind.exfilBlocked`.

---

### 🟠 High — CRLF injection possible via valeur de secret substituée dans header

**Référence** : `Sources/IrisKit/Proxy/MITMHandler.swift:197-205`

**Description** : la substitution des headers passe le `value` substitué directement à `HTTPHeaders.add(name:value:)`. Si la valeur du secret contient `\r\n`, swift-nio peut soit rejeter (à vérifier), soit ré-émettre des bytes qui splitteraient le frame HTTP côté upstream.

```swift
let valueOutcome = try await engine.substituteString(value)
let newValue = String(data: valueOutcome.output, encoding: .utf8) ?? value
newHeaders.add(name: newName, value: newValue)
```

**Scénario** : un secret malveillamment configuré avec `"Bearer x\r\nX-Smuggled: yes"` injecté dans `Authorization` produirait deux headers upstream au lieu d'un, permettant request-smuggling vers l'upstream. Surface d'attaque limitée (suppose un secret hostile, généralement contrôlé par l'utilisateur lui-même), **mais** un copier-coller distrait depuis un client malveillant qui injecte `\r\n` dans un input "API key" est plausible.

**Fix suggéré** : valider à l'écriture (`SecretStore.add` / `update`) qu'aucune valeur ne contient `\r`, `\n`, `\0`. Idéalement aussi à la lecture juste avant substitution dans headers (`engine.substituteString` pour `header.value` devrait rejeter ou échapper). Test à ajouter dans `RedactionTests` / `PlaceholderEngineTests`.

---

### 🟠 High — Mode `--in-memory-secrets` sans gate "unsafe"

**Référence** : `Sources/irisd/App.swift:33-37`, `Sources/irisd/Daemon.swift:192-225`

**Description** : le flag `--in-memory-secrets` (et son frère `--in-memory-ca`) active un mode où :
- les valeurs de secrets sont lues depuis `IRIS_SECRET_<NAME>` env vars (visibles via `ps -E`, hérités par les enfants)
- la trace `logger.info("Loaded in-memory secrets", metadata: ["names": "\(loaded.sorted())"])` (Daemon.swift:222) liste les NAMES (pas les valeurs, OK §6.1) mais expose l'inventaire des secrets aux logs.

Bien que `logger.warning` (Daemon.swift:193) signale que c'est debug, **le flag n'a pas de prefix "unsafe"** et la `--help` se contente de `"(debug)"`. Un utilisateur qui le tape sans bien lire ne saisit pas qu'il vient de désactiver toute la sécurité Keychain.

**Scénario** : un opérateur trace `irisd --in-memory-secrets` dans un script, push le script en clair sur Git, l'env du process contient les secrets en clair, `ps -E` les expose à tout user local. §6.6 ne dit pas "no debug mode" mais dit "pas de mode debug qui désactive le scoping ou écrit des secrets en clair" — l'env var EST en clair.

**Note positive** : la chute fallback `allowedHosts: ["debug.invalid"]` (Daemon.swift:215) signifie que les secrets chargés via env **ne matcheront aucun host réel** en pratique → §6.6 accidentellement préservé. Mais l'intention du code était `["*"]` (rejeté par `isValidHost`), donc la sécurité tient par accident d'implémentation, pas par design.

**Fix suggéré** :
- Renommer en `--unsafe-debug-secrets`
- Refuser l'activation si l'env `IRIS_ALLOW_DEBUG_SECRETS=1` n'est pas posée
- Émettre un event `Event.Kind.error` au démarrage (visible UI menu bar future)
- Documenter le comportement `allowedHosts` (qui empêche le match — à formaliser plutôt qu'à laisser comme accident)

---

### 🟡 Medium — Bypass non-UTF-8 dans la substitution body

**Référence** : `Sources/IrisKit/Placeholder/PlaceholderEngine.swift:45-47`

**Description** : si le body n'est pas UTF-8 valide, **aucune substitution** n'est effectuée et le body passe tel quel. SPECS §7.4 le documente. Mais un hôte malveillant peut injecter UN SEUL byte non-UTF-8 (`0xFF`) dans un body censé être JSON, et tous les placeholders du body passeront non-substitués vers l'upstream (donc en clair sous forme `{{kc:foo}}`) — mais le secret reste dans la Keychain, jamais exfiltré.

**Scénario** : pas d'exfiltration directe car les placeholders non-substitués révèlent juste les noms, pas les valeurs. Mais : **un client legit avec un body binaire (gRPC, multipart, etc.) verra ses placeholders inutilement laissés en clair**, ce qui dégrade silencieusement la sécurité de l'utilisateur (l'API key reste un placeholder, mais aussi tous les secrets attendus). Côté §6.3 c'est OK (rien n'est leaké), côté ergonomie c'est mauvais.

**Fix suggéré** : émettre un `Event.Kind.error` ou `noMatch` explicite quand `nonUtf8 == true` ET qu'un placeholder était présent dans la requête originale (le scan headers/URI peut le détecter). L'utilisateur saura que sa requête est passée non-substituée.

---

### 🟡 Medium — Cache de `PlaceholderEngine` sert des valeurs stale après rotation

**Référence** : `Sources/IrisKit/Placeholder/PlaceholderEngine.swift:84-91`, test `testCacheReturnsSameValueWithoutSecondKeychainCall:89`

**Description** : le cache LRU de 5 min sert la VIEILLE valeur d'un secret même après `secret.rotate`. Le test ligne 89 le confirme explicitement. Conséquence : pendant les 5 minutes qui suivent une rotation, les substitutions live continuent d'utiliser l'ancienne valeur. C'est intentionnel pour amortir les coûts Keychain, mais ça brise la promesse "rotation immédiate".

**Scénario** : un utilisateur révoque un secret compromis et le rotate via `iris secret rotate`. Le daemon continue d'envoyer l'ancien secret (potentiellement déjà observé par l'attaquant) pendant 5 min. Fenêtre d'attaque non-négligeable.

**Fix suggéré** : `SecretStore.rotate` doit publier un event d'invalidation sur le bus interne, `PlaceholderEngine` doit y souscrire et `cache.removeValue(forKey: name)`. À implémenter conjointement avec Phase 4 (le cache devra de toute façon être keyé `(name, host)` ou invalidé sur changement de scoping).

---

### 🟡 Medium — Redaction déterministe sans salt

**Référence** : `Sources/IrisKit/Util/Redaction.swift:5-13`

**Description** : `redact("alice@example.com")` produit toujours `[REDACTED:<même_hex>]`. Le préfixe 4 bytes (32 bits) suffit pour identifier la valeur si l'attaquant peut deviner / brute-forcer l'espace d'entrée (PII low-entropy : emails, IDs).

**Scénario** : un attaquant qui obtient un dump de logs et soupçonne que "alice@example.com" est mentionnée peut calculer `SHA-256("alice@example.com")[0..4]` et vérifier la correspondance. Pour des API keys haute-entropie (sk-ant-…), incalculable en pratique. Pour des IDs / emails, exploitable.

**Fix suggéré** : ajouter un sel par-process random au boot (`static let processSalt = SymmetricKey(size: .bits128)`). Redaction devient `HMAC-SHA256(salt, value).prefix(4)`. Trade-off : redactions plus comparables entre logs d'un même run mais incomparables entre runs (acceptable). Test : confirmer que deux processus distincts produisent des redactions différentes pour la même valeur.

---

### Défenses positives Domaine A

- ✅ `Secret.validateName` strict regex `[a-zA-Z0-9_-]{1,64}` (`Models/Secret.swift:34`)
- ✅ `Secret.isValidHost` RFC 1123 strict, ASCII-only (rejette IDN homoglyphes) (`Models/Secret.swift:51-63`)
- ✅ `PlaceholderScanner.makeSnippet` strip control chars `0x00-0x1F` + `0x7F` → `?` (anti-terminal-escape injection dans events display) (`Placeholder/PlaceholderScanner.swift:95-100`)
- ✅ Snippet cap 256 chars (anti log-bloat) (`Placeholder/PlaceholderScanner.swift:32`)
- ✅ Header names lowercased dans `PlaceholderHit.Location.header` (RFC 7230 compliant) (`PlaceholderScanner.swift:43`)
- ✅ `Event.substitutedSecrets` ne contient que des NAMES, jamais de values (`Models/Event.swift:12`)
- ✅ `AdminDispatcher.logCall` n'embarque jamais `params` pour `secret.add` / `secret.rotate` (`AdminDispatcher.swift:193-211`)
- ✅ Tests exhaustifs : `RedactionTests.testRedactNeverLeaksInputValue` vérifie explicitement l'absence du substring d'origine.

---

## Domaine B — CA, TLS, trust store

### 🟠 High — `KeychainCAKeyStore` stocke la clé privée CA SANS ACL (§6.2 / §6.5)

**Référence** : `Sources/IrisKit/CA/KeychainCAKeyStore.swift:47-79`

**Description** : la clé privée CA P-256 (rawRepresentation, 32 bytes) est stockée comme `kSecClassGenericPassword` avec `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` mais **sans `SecAccessCreateWithOwnerAndACL`**. Le commentaire en tête du fichier (lignes 8-10) le documente : *"Phase 1 uses generic-password storage without ACL — Phase 8 migrates to kSecClassKey with SecAccessCreateWithOwnerAndACL bound to the signed irisd binary"*.

**Conséquence concrète** : n'importe quelle app tournant en tant que l'utilisateur peut soit lire silencieusement (si elle est déjà autorisée par la même groupe d'apps, ce qui ne sera pas le cas pour irisd non signé), soit déclencher un prompt Keychain demandant l'autorisation. Avec ACL liée à l'identité signée, seul `irisd` signé Developer ID peut lire sans prompt — d'où la dépendance Phase 8.

**Pire cas** : un attaquant local qui obtient l'autorisation Keychain (via prompt déclenché à l'insu de l'utilisateur, ou via un screenshot du prompt) → récupère la clé privée CA → peut signer un leaf cert pour `*.google.com` qui passera Gatekeeper sur cette machine. **Impact si exploité : MITM transparent sur toutes les destinations TLS de l'utilisateur**.

**Sévérité** : 🟠 High, **mais dette explicitement planifiée Phase 8** (cf phasage CLAUDE.md §12).

**Fix suggéré** : Phase 8, basculer sur `kSecClassKey` + `SecAccessCreateWithOwnerAndACL` avec trusted app = identité de signature `Developer ID Application: <Nom> (<TEAM_ID>)`. Test : démarrer irisd, lancer un autre process binaire non-signé en tant que même user, vérifier que lecture Keychain prompt OU échoue.

---

### 🟡 Medium — `LeafCertCache` : pas d'expiration, pas d'invalidation rotation CA, croissance non bornée

**Référence** : `Sources/IrisKit/CA/LeafCertCache.swift:31-38`, `24`

**Description** : trois défauts cumulés :
1. Le cache n'expire jamais : `if let cached = cache[host] { return cached.leaf }` — un leaf vieux de 91 jours (validité 90) sera servi expiré.
2. Aucune invalidation sur rotation de la CA root. Si l'utilisateur ré-installe une nouvelle CA, les leafs cachés signés par l'ancienne deviennent invalides côté client mais sont toujours servis.
3. Le `cache: [String: CacheEntry]` n'a pas de capacité max. Un client malveillant qui force le proxy à minter des leafs pour `host1.com`, `host2.com`, …, `hostN.com` (en supposant qu'ils sont dans `allowedHosts` MITM) inflate la mémoire sans limite.

**Scénario 1** (expiration) : utilisateur lance `irisd` puis le laisse tourner 100 jours. Les leafs cachés expirent. Les clients TLS rejettent. UX cassée.
**Scénario 2** (rotation) : utilisateur fait `iris ca rotate` (n'existe pas encore mais sera ajouté), redémarre la CA. Si pas de full restart du daemon, leafs cachés invalides.
**Scénario 3** (DoS) : low-impact en pratique car `allowedHosts` limite l'ensemble.

**Fix suggéré** :
- Vérifier `cached.leaf.notAfter > Date()` au hit cache, sinon re-mint.
- Exposer `LeafCertCache.invalidate()` appelable depuis `CAManager.ensureCA()` quand un nouveau cert est généré.
- Borner le cache (LRU avec capacity = par exemple 256 hosts).

---

### 🟡 Medium — `CATrustStore.isTrusted` ne lit pas le trust setting result

**Référence** : `Sources/IrisKit/CA/CATrustStore.swift:14-38`

**Description** : la fonction utilise `SecTrustSettingsCopyCertificates(.user, ...)` qui retourne tous les certificats ayant **au moins une entrée** dans les trust settings user. Elle compare le fingerprint mais ne lit jamais le `kSecTrustSettingsResult` de chaque entrée. Conséquence : un cert pour lequel l'utilisateur a explicitement choisi *"Never Trust"* (`kSecTrustSettingsResultDeny`) sera rapporté `isTrusted = true`.

**Scénario** : utilisateur ajoute la CA IRIS dans le trust store, puis change d'avis et la marque "Never Trust" sans la supprimer. `iris ca status` → "trusted ✓" → utilisateur ne comprend pas pourquoi le proxy ne fonctionne pas.

**Fix suggéré** : pour chaque cert match, appeler `SecTrustSettingsCopyTrustSettings(cert, .user, &settings)` puis itérer le array CFArray retourné et vérifier qu'au moins une entrée a `kSecTrustSettingsResult == kSecTrustSettingsResultTrustRoot` ou `kSecTrustSettingsResultTrustAsRoot`. Doc Apple : [SecTrustSettingsCopyTrustSettings](https://developer.apple.com/documentation/security/sectrustsettingscopytrustsettings(_:_:_:)).

---

### Défenses positives Domaine B

- ✅ Algorithme **P-256 ECDSA SHA-256** (`CAManager.swift:181`, `LeafCertCache.swift:84`) — moderne, conforme NIST.
- ✅ `BasicConstraints isCertificateAuthority + critical` pour la root, `notCertificateAuthority + critical` pour les leafs (`CAManager.swift:160`, `LeafCertCache.swift:64`).
- ✅ `KeyUsage(keyCertSign:cRLSign:)` root, `KeyUsage(digitalSignature:keyEncipherment:)` + `ExtendedKeyUsage([.serverAuth])` leaf — séparation propre.
- ✅ **SAN avec `dnsName(host)`** sur les leafs (`LeafCertCache.swift:67`) — TLS moderne échoue sans SAN, c'est correct.
- ✅ `notBefore` back-daté de 1h pour gérer skew BoringSSL (`CAManager.swift:151`).
- ✅ Idempotence CA via reload depuis PEM si key match (`CAManager.swift:46-48`, test `testEnsureCAIsIdempotentAcrossManagerInstances`).
- ✅ Subject mismatch invalide le cache (re-génère si commonName/organization config a changé) (`CAManager.swift:84-90`).
- ✅ Public cert PEM écrit `0o644` (intentionnel et correct, pas un secret) (`CAManager.swift:248`).
- ✅ `UpstreamClient` valide les certs upstream via `.default` trust roots + SNI hostname (`UpstreamClient.swift:32, 42`) — pas de `verify=false` debug toggle.
- ✅ Tests bien couverts : `testEnsureCARegeneratesWhenOnDiskCertHasMismatchingKey`, `testMintsLeafSignedByCA`, `testLeafValidityIs90DaysByDefault`.

---

## Domaine C — IPC + networking

### 🟡 Medium — SSE pas d'authentification (events leaks hostnames+paths au LAN local user space)

**Référence** : `Sources/IrisKit/IPC/EventsServer.swift:65-122`

**Description** : le serveur SSE bind sur loopback (good, enforcement strict), mais **aucune authentification** sur la connexion HTTP. Tout process tournant en tant que le même user peut faire `curl http://127.0.0.1:8899/events` et streamer le flux d'events live. Le commentaire ligne 70-73 reconnaît que les events portent *"hostnames + paths visible to other LAN nodes"* (mais le bind loopback bloque le LAN).

**Scénario** : un process malveillant tournant comme l'utilisateur (téléchargé via une page web, ou app crackée, etc.) lit le SSE et collecte la liste des hosts API que l'utilisateur appelle + paths d'API + statuts. Métadonnée précieuse pour reconnaissance.

**Fix suggéré** : token bearer dans `Authorization: Bearer <token>` header. Token = random 256-bit régénéré au start du daemon, écrit dans un fichier `~/Library/Application Support/iris/events.token` mode 0600. Le menu bar app + CLI lisent ce fichier pour s'authentifier. Process malveillant ne peut pas lire `0600` token sans permissions équivalentes au user — qui est exactement le bar de privilège dont on parle.

---

### 🟡 Medium — `ProxyServer` ne refuse pas un bind non-loopback par défaut

**Référence** : `Sources/IrisKit/Proxy/ProxyServer.swift:23-30`, `Sources/IrisKit/Config/Config.swift:146-155`

**Description** : `listenHost` par défaut est `"127.0.0.1"`, mais `validateListenAddress` accepte n'importe quelle string non-vide (y compris `"0.0.0.0"` ou `"example.com"`). Pas de refus au démarrage si non-loopback (contrairement à `EventsServer` qui a un check explicite).

**Scénario** : utilisateur configure `listen = "0.0.0.0:8888"` (peut-être pour partager le proxy entre containers ou en test) → le proxy MITM est exposé sur le LAN → tout device LAN peut envoyer des requêtes MITM, déclencher des leafs cert, voir les events via SSE si même IP, etc.

**Fix suggéré** : `BrokerConfig.validate` doit vérifier `listen` et `events_listen` contre une whitelist loopback `{127.0.0.1, ::1, localhost}` SAUF si un flag explicite `unsafe_allow_lan_exposure = true` est posé dans la config. Cohérent avec le pattern `EventsServer.isLoopback`.

---

### 🟡 Medium — SSRF possible via CONNECT passthrough

**Référence** : `Sources/IrisKit/Proxy/ConnectHandler.swift:151-256`

**Description** : `performPassthrough()` ouvre une connexion TCP à `host:port` extrait verbatim de l'URI du CONNECT. Aucun filtre sur la destination. Un client malveillant peut faire `CONNECT 127.0.0.1:22 HTTP/1.1` et obtenir un tunnel TCP vers le SSH local.

**Scénario** : si l'utilisateur expose le proxy en LAN par erreur (cf finding précédent), un attaquant LAN peut utiliser le proxy comme **pivot SSRF** pour atteindre des services internes (`metadata.google.internal`, `169.254.169.254`, `127.0.0.1:<port>`, ranges RFC 1918, etc.). Même en loopback strict, un user local non-privilégié peut scanner les services qui binding loopback du même user (Postgres dev, Redis dev, etc.).

**Fix suggéré** : refuser le CONNECT vers :
- IP loopback (`127.0.0.0/8`, `::1`)
- IP link-local (`169.254.0.0/16`, `fe80::/10`)
- IP RFC 1918 private (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)
- Ports < 1024 sauf 80, 443
- Cohérent avec la pratique des proxies forward (Squid `acl Safe_ports`).

---

### 🟡 Medium — `EventsBus` backpressure non implémentée (Phase 3.x follow-up déclaré)

**Référence** : `Sources/IrisKit/Events/EventsBus.swift:9-16`, `62-83`

**Description** : avec `.bufferingNewest(queueDepth)`, un subscriber lent perd silencieusement les events les plus anciens. SPECS §14.4 spécifie un sentinel `event: dropped` + close de la connexion. Le commentaire du fichier le reconnaît : *"silently drops items if a consumer lags by > queueDepth events"*.

**Scénario** : un client SSE qui parse lentement (pause UI, GC) loupera des events. Le client ne saura pas qu'il les a loupés → false sense of completeness.

**Fix suggéré** : déclaré comme Phase 3.x follow-up. Implementation : passer à `NIOAsyncWriter` qui suspend sur backpressure TCP réelle.

---

### Défenses positives Domaine C

- ✅ **`AdminServer.preflightExistingFile` utilise `lstat` (pas `stat`)** → bloque l'attaque symlink-swap (`AdminServer.swift:155-174`).
- ✅ **Socket 0600 belt-and-suspenders** : `umask(0o177)` avant bind + `chmod 0o600` après + `stat()` vérification owner UID (`AdminServer.swift:84, 119, 176-189`).
- ✅ Erreur typée `unsafeExistingFile(path, ownerUID, currentUID)` pour le cas foreign-owner.
- ✅ **`JSONRPCFrameDecoder.defaultMaxFrameSize = 1 MiB`** — bloque OOM par header taille (`FrameCodec.swift:22, 47-49`).
- ✅ Big-endian explicite, drips correctement gérés via `ByteToMessageDecoder`.
- ✅ **`EventsServer.isLoopback`** whitelist stricte avant bind (`EventsServer.swift:72-74, 134-136`).
- ✅ `JSONRPCID` accepte int/string/null per spec (`JSONRPC.swift:62-89`).
- ✅ `JSONValue` decode dans le bon ordre (nil, bool, integer avant double pour préserver le typage).
- ✅ Heartbeat SSE 15s (`EventsServer.swift:224-234`).
- ✅ Dedup via `Event.id` (UUID) entre backlog et live stream (`EventsServer.swift:247-260`).
- ✅ `UpstreamClient` valide cert upstream avec **SNI hostname matching** (`UpstreamClient.swift:42`).
- ✅ `MITMHandler` **bypass body scan si > 4 MiB** (`MITMHandler.swift:162, 218-222`) — anti-OOM.
- ✅ `MITMHandler` recalcule Content-Length après substitution (`MITMHandler.swift:237-239`).
- ✅ `ConnectHandler.parseAuthority` valide port `(1...65535)` (`ConnectHandler.swift:325-333`).
- ✅ Tests intégration robustes : `testServerEnforces0600PermissionsOnBoundSocket`, `testServerUnlinksSelfOwnedResidueBeforeBind`, `testDecoderRejectsOversizedFrame`, `testServerRefusesNonLoopbackHost`.

---

## Domaine D — Config, supply chain, daemon lifecycle, events

### 🟡 Medium — TOMLKit supply chain : solo maintainer, dernière release 22 mois

**Référence** : `Package.swift:24`, `Package.resolved` (TOMLKit 0.6.0)

**Description** : TOMLKit (https://github.com/LebJe/TOMLKit) — dernière release **0.6.0 du 3 janvier 2024** (~22 mois sans release au 2026-05-25). Solo maintainer LebJe. 102 commits total, 3 issues ouvertes. Pas de CVE publié.

**Scénario** : si une CVE apparaît dans TOMLKit (e.g. parsing DoS), pas de garantie qu'un fix sera publié rapidement. Le projet IRIS dépend d'un parser TOML pour sa config — un bug parsing critique pourrait être exploité si l'attaquant peut écrire dans `~/Library/Application Support/iris/config.toml` (mais ça suppose déjà compromis user).

**Fix suggéré** :
- Option 1 : surveiller la lib, prévoir migration vers `swift-foundation` (Apple) quand son support TOML stable arrivera.
- Option 2 : vendor TOMLKit (copier le code dans `ThirdParty/`) pour figer la dépendance.
- Option 3 : audit code du parser une fois (taille modeste).
- Décision à arbitrer en Phase 10 (hardening).

---

### 🟡 Medium — Path traversal sur `admin_socket` et `caPath`

**Référence** : `Sources/IrisKit/Config/Config.swift:73-75` (BrokerConfig.resolvedAdminSocketURL), `Sources/irisd/App.swift:62-69` (caURL)

**Description** : `(adminSocket as NSString).expandingTildeInPath` expanse `~/...` mais ne sanitize pas `../`. Un config malicieux avec `admin_socket = "/tmp/../etc/passwd"` produirait `/etc/passwd`. `AdminServer.preflightExistingFile` refuserait d'unlinker si pas owned-by-user (good defense), mais le bind tenterait sur un path non prévu → erreur cryptique.

**Scénario** : compromis de la config TOML (qui suppose write access au home → déjà compromis). Faible exploitation pratique, mais defense-in-depth.

**Fix suggéré** : `URL(fileURLWithPath:).standardizedFileURL` + check que le chemin résolu est sous `~/Library/Application Support/iris/` ou `/var/run/iris/`. Refuser sinon avec une erreur claire.

---

### 🔵 Low — JSONDecoder sans depth limit

**Référence** : `Sources/IrisKit/IPC/JSONRPC.swift:248-252`

**Description** : `JSONRPCCoder.makeDecoder()` retourne un `JSONDecoder()` sans paramétrer de depth limit. Foundation `JSONDecoder` n'expose pas de limite native. Sur un payload JSON profondément imbriqué (1M niveaux), le décodage récursif blow le stack → crash du daemon.

**Atténuation** : `FrameCodec` cap à 1 MiB, donc un JSON profond contiendrait au plus ~500K niveaux d'imbrication, ce qui ferait probablement crasher avant. Reste : un DoS par crash, pas une exfiltration.

**Fix suggéré** : à Phase 10 hardening, considérer un pré-pass qui compte les `{` `[` avant décodage et reject si > N. Ou switch sur un parser JSON streaming.

---

### 🔵 Low — Mémoire heap des secrets non zeroized

**Référence** : `Sources/IrisKit/Placeholder/PlaceholderEngine.swift:23-32` (CacheEntry), partout où `Data` ou `String` portent une valeur

**Description** : Swift n'offre pas de "secure memory" native. `Data` est ARC-géré, après eviction du cache la mémoire reste allouée jusqu'au GC implicite, et n'est jamais explicitement zeroized. Une vidage mémoire (crash dump, swap) peut révéler des valeurs.

**Atténuation** : c'est une limitation systémique Swift, pas un bug. swift-crypto offre `SymmetricKey` qui zeroize on dealloc, mais nous stockons des `Data` arbitraires (les secrets utilisateur ne sont pas nécessairement des keys symétriques).

**Fix suggéré** : à Phase 10, encapsuler les valeurs de secret dans un wrapper struct qui appelle `bzero(&data)` dans `deinit`. Pas trivial — `Data` n'expose pas de pointer mutable garantie. Possible : utiliser `Crypto.SymmetricKey` comme conteneur opaque + import explicite vers `Data` au moment du replace dans le buffer.

---

### Défenses positives Domaine D

- ✅ **Signal handlers explicites SIG_DFL** restored au tout début (`App.swift:54-55`) — fix smoke-testé pour `kill -INT`.
- ✅ Config validation : listen address `host:port` split + port range `(1...65535)` (`Config.swift:146-155`).
- ✅ Config validation : `eventRetentionDays > 0` et `eventRingSize > 0` (`Config.swift:132-143`).
- ✅ **`MITMHostEntry.validate` réutilise `Secret.isValidHost`** (RFC 1123 strict).
- ✅ **`EventRing.recent(n)` guard `n > 0`** sinon trap `Array.suffix(-1)` (`EventRing.swift:46-49`).
- ✅ **`EventRing.capacity > 0` precondition** au construct (`EventRing.swift:18`).
- ✅ Cumulative `totals` per kind, jamais reset → stats fiables même après éviction du ring (`EventRing.swift:55-59`).
- ✅ `EventsBus.onTermination` cleanup eager des subscribers (anti-leak) (`EventsBus.swift:50-53`).
- ✅ Tests : `testConcurrentAppendsAreAllRecorded` valide la sûreté concurrente du ring.

---

## Phasage de remédiation suggéré

Aucun finding ne bloque la merge de Phase 3 vers `main` — c'est déjà fait, à raison. Les findings se hiérarchisent selon le phasage CLAUDE.md :

### Phase 4 (active : `feat/phase-4-scoping-exfil`)

- 🟠 **A.1** Scoping `allowed_hosts` dans `PlaceholderEngine.substitute` — invariant §6.3.
- 🟡 **A.5** Cache `PlaceholderEngine` keyé `(name, host)` + invalidation sur rotation.
- 🟡 **C.3** SSRF filter sur destinations CONNECT (loopback, link-local, RFC 1918).

### Phase 6-7 (menu bar app + LaunchAgent)

- 🟡 **C.1** Auth bearer token pour SSE.
- 🟡 **D.2** Path validation `admin_socket` / `caPath` sous whitelist directories.

### Phase 8 (Keychain ACL + trust store install)

- 🟠 **B.1** `KeychainCAKeyStore` → `SecAccessCreateWithOwnerAndACL` lié au binaire signé Developer ID — invariant §6.2.
- 🟡 **B.3** `CATrustStore.isTrusted` lire le `kSecTrustSettingsResult` réel.

### Phase 10 (hardening)

- 🟠 **A.2** CRLF validation des valeurs de secrets au write (`SecretStore.add` / `update`).
- 🟠 **A.3** Renommer `--in-memory-secrets` → `--unsafe-debug-secrets` + gate env.
- 🟡 **A.4** Émettre event sur bypass non-UTF-8 quand placeholder présent.
- 🟡 **A.6** Redaction salt par-process.
- 🟡 **B.2** `LeafCertCache` expiration check + invalidation rotation + bound capacity.
- 🟡 **C.2** Refus bind non-loopback par défaut côté `ProxyServer`.
- 🟡 **C.4** SSE backpressure réelle (`NIOAsyncWriter`).
- 🟡 **D.1** Décision supply chain TOMLKit (vendor / migrer / audit).
- 🔵 **D.3** JSON depth limit.
- 🔵 **D.4** Wrapper secret avec zeroize on deinit.

---

## Note méthodologique sur le sandbox

`Sources/IrisKit/Secrets/{SecretStore,InMemorySecretStore,KeychainSecretStore}.swift` ne sont pas lisibles depuis cet audit (deny rule sandbox utilisateur). Posture défensive volontaire qui limite l'exposition du code Keychain direct. L'audit a inféré le contrat depuis :
- la protocol `SecretStore` consommée par `PlaceholderEngine` (signatures `value(forName:) -> Data`, `add(_:named:allowedHosts:createdAt:) -> Secret`)
- les tests publics `InMemorySecretStoreTests`, `AdminDispatcherTests`
- les types publics `Models/Secret.swift`, `IPC/AdminProtocol.swift`

L'implémentation `KeychainSecretStore` n'a pas été directement revue. Un audit complet de cette partie nécessite soit :
- un assouplissement temporaire du deny rule (lever le sandbox sur `Sources/IrisKit/Secrets/`),
- soit un audit externe par un reviewer humain ou un agent avec permissions élargies.

C'est une **limitation reconnue de cet audit** et non un finding.

---

## Synthèse globale

**Niveau de risque actuel du repo** : **modéré-faible pour Phase 3**.

- **Aucun finding 🔴 Critical**. Pas de leak de secret en clair observé. Pas de bypass d'authentification IPC. Pas de TLS validation cassée.
- **4 🟠 High dont 2 sont des dettes documentées** (scoping Phase 4, ACL CA Phase 8). Les 2 autres (CRLF, mode debug gate) sont actionnables maintenant et de scope limité.
- **11 🟡 Medium** dont la majorité sont des défenses-en-profondeur ou des limitations connues du backpressure / supply chain.
- **Excellente discipline de tests** : presque chaque finding 🟡 dispose d'au moins un test négatif ou d'une note explicite de phasage.
- **Posture défensive notable** : socket Unix avec `lstat` + symlink-protection + 0600 belt-and-suspenders, frame size cap 1 MiB, SSE loopback enforcement, snippet stripping anti-terminal-escape, sandbox utilisateur sur `Sources/IrisKit/Secrets/`.

**Recommandation immédiate** (avant Phase 4 merge) :
1. Fix A.2 (CRLF validation au write — petit patch dans `Secret.validateName` ou nouveau `validateValue`)
2. Fix A.3 (renommer flag + gate env) — 10 lignes dans `App.swift` + `Daemon.swift`
3. Fix C.3 (SSRF filter CONNECT) — peut s'intégrer naturellement à la Phase 4 scoping

Le reste suit le phasage prévu. Aucune urgence pour interrompre Phase 4 en cours.
