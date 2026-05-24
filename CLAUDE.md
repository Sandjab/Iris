# CLAUDE.md — Instructions pour l'agent d'implémentation

> Ce fichier guide Claude Code CLI pour implémenter le projet **IRIS**
> (Interception, Resolution, Injection, Substitution).
> Lis-le intégralement avant d'écrire la moindre ligne. Relis-le si tu te perds.

---

## 1. Contexte projet

**IRIS** est un broker de credentials local pour macOS. Il intercepte le trafic HTTPS sortant d'outils comme Claude Code CLI via un proxy MITM local, substitue à la volée des placeholders (`{{kc:NAME}}`) par les vraies valeurs tirées du trousseau système, et forwarde la requête. L'outil hôte (Claude Code) ne voit jamais les credentials réels.

**Stack imposée** :
- Langage : Swift 5.9+
- Plateforme : macOS 13 Ventura minimum
- Build : SwiftPM (`Package.swift` à la racine)
- Dépendances tierces autorisées : `swift-nio`, `swift-nio-ssl`, `swift-nio-http2`, `swift-argument-parser`, `swift-log`, `swift-toml` (ou équivalent). **Pas d'autres dépendances sans justification écrite dans le commit.**
- UI : SwiftUI + AppKit (NSStatusItem pour la menu bar)
- Distribution : `.pkg` signé + notarisé

**Trois cibles** :
1. `irisd` — daemon (LaunchAgent)
2. `iris` — CLI
3. `Iris.app` — menu bar app

**Module partagé** : `IrisKit` (modèles, config, client IPC, génération CA, accès Keychain).

---

## 2. Avant de coder

**Lis dans l'ordre** :
1. `SPECS.md` — spec technique complète, source de vérité
2. `README.md` — vue d'ensemble utilisateur, sert de check de cohérence

Si une décision n'est pas dans `SPECS.md` : **ne pas spéculer, demander**. Une décision implicite mal posée se propage et coûte cher à corriger.

---

## 3. Posture de travail

- Direct, sans préambule, sans flatterie, sans empathie performative. Baselinbe = Rigueur sans complaisance.
- Si tu doutes d'une API : **vérifie la doc (cf 4. Vérification s obligatoires) avant d'affirmer**. Jamais de spéculation sur les signatures, paramètres, ou comportements.
- Erreur dans une dépendance (traceback) → consulter la doc de la dépendance ET de la lib principale.

## 4. Vérifications obligatoires

**Accède à la doc Apple ou Swift dans l'odre suivant** : 
1. API/framework Apple → sosumi (search puis fetch)
2. Concept présenté en session WWDC → sosumi video transcript
3. Lib open-source Swift → context7
4. Sinon → WebFetch / WebSearch en dernier recours

**Avant d'utiliser une API** :
- Security.framework, SecKeychain, SecTrust : doc Apple via `sosumi:searchAppleDocumentation` ou `sosumi:fetchAppleDocumentation`.
- swift-nio, swift-nio-ssl : Context7 (`/apple/swift-nio`, `/apple/swift-nio-ssl`).
- `SMAppService` (registration LaunchAgent moderne) : doc Apple, **pas** `SMJobBless` ni les anciennes APIs.
- `URLProtocol` ou MITM HTTP/2 : Context7 + doc swift-nio-http2.

Si une API est dépréciée dans macOS 13+ : ne pas l'utiliser. Confirmer la version d'intro sur la doc.

---

## 5. Conventions code Swift

- Indentation 4 espaces.
- `swift-format` config par défaut, exécuté avant chaque commit (cible CI à prévoir).
- `// MARK:` pour structurer les fichiers > 200 lignes.
- Pas de force-unwrap (`!`) hors tests. Toujours `guard let` / `if let` / nil-coalescing.
- `Sendable` partout où c'est demandé par concurrency Swift 6 (le projet doit compiler `-strict-concurrency=complete`).
- Pas d'`@objc` sauf interop nécessaire (NSStatusItem, NSMenu).
- Logs via `swift-log` avec niveaux explicites. **Jamais de `print()` en code de production.**
- Erreurs : `enum` conformes à `Error` et `LocalizedError`, jamais `NSError` direct.

---

## 6. Sécurité — règles non-négociables

1. **Aucune valeur de secret ne doit transiter par les logs, l'UI, ou le stream SSE.** Toujours redacter avec le nom du secret. Ajouter un test unitaire qui vérifie qu'un dump d'event ne contient jamais la valeur brute.
2. **L'ACL Keychain doit cibler le binaire signé** (`SecAccessCreateWithOwnerAndACL` + identité signée). Ne jamais utiliser `kSecAttrAccessibleAlwaysThisDeviceOnly` sans ACL — c'est du "always allow" universel.
3. **Le scoping `secret → allowed_hosts` est une invariance** : aucune substitution ne doit avoir lieu sans match explicite. Si le code de substitution change, ajouter/modifier les tests de regression correspondants.
4. **Socket Unix** : permissions `0600`, owner = utilisateur courant. Vérification au démarrage du daemon, refus de bind sinon.
5. **CA root** : clé privée stockée en Keychain (jamais sur disque en clair). Certificat public peut être exporté en PEM pour `NODE_EXTRA_CA_CERTS`.
6. **Pas de mode debug qui désactive le scoping** ou écrit des secrets en clair. Si besoin de debugging : niveaux de log, mais redaction maintenue.

---

## 7. Tests

- **Unit tests** : `XCTest` ou `swift-testing` (préférer ce dernier si macOS 14+ accepté en CI). Couvrir :
  - Parser de config TOML
  - Regex substitution
  - Logique de scoping `allowed_hosts`
  - Détection des règles `exfil_blocked` (1 à 5 dans SPECS)
  - Redaction logs/events
- **Integration tests** : spawner un `irisd` éphémère, lui envoyer du trafic via `URLSession` configuré avec proxy, vérifier substitution et passage upstream (utiliser un mock HTTP server local).
- **Pas de tests qui requièrent un vrai trousseau** : abstraire l'accès Keychain derrière un protocole (`SecretStore`) avec un mock en mémoire.

---

## 8. Workflow git & PR

### Branche & commits

- **Une phase = une branche dédiée.** Nommage : `feat/phase-<N>-<slug>` (ex. `feat/phase-3-ipc`). Hors phasage : `feat/<slug>`, `fix/<slug>`, `chore/<slug>`, `docs/<slug>`.
- **Pas de push direct sur `main`.** Toute modification passe par une PR.
- Commits conventional : `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`.
- Un commit = un changement cohérent. Pas de méga-commits "wip".

### PR

- En fin de développement d'une feature ou d'une phase, créer une PR depuis la branche dédiée vers `main`.
- **La description de la PR doit contenir une checklist de smoke testing explicite** (cases `- [ ]`) couvrant les critères de réussite de la phase. Sans cette checklist, la PR n'est pas mergeable.
- Pré-requis avant ouverture : `swift build` et `swift test` passent localement.

### Revue Gemini Code Assist

- Toute PR est revue automatiquement par **Gemini Code Assist** (GitHub App). Après ouverture, Claude attend les commentaires de revue pendant **10 minutes maximum** (polling via `gh pr view --comments` ou `gh api repos/:owner/:repo/pulls/:n/comments`).
- Pour chaque commentaire de Gemini, Claude doit faire **un et un seul** des deux choix :
  - **Appliquer le fix**, commit sur la branche de PR, puis répondre au commentaire en référençant le commit.
  - **Refuser** avec une justification **factuelle** (citation de doc, spec, test, comportement observable). Jamais de "je pense que" ou pushback vague.
- Au-delà de 10 min sans nouveau commentaire : considérer la revue terminée.

### Merge

- Conditions cumulatives avant merge :
  1. Tous les commentaires Gemini sont soit appliqués, soit refusés factuellement.
  2. Tous les tests passent (`swift build` + `swift test`).
  3. Tous les items de la checklist de smoke testing sont cochés.
- **Confirmation explicite de l'utilisateur requise avant `gh pr merge`.** Jamais de merge automatique.
- Stratégie : **squash and merge** (`gh pr merge --squash`). Un commit propre par PR sur `main`.

---

## 9. Build & run

```bash
# Build daemon + CLI
swift build -c release

# Run daemon localement (foreground, pour debug)
.build/release/irisd --foreground

# Run tests
swift test

# Build app (Xcode requis pour la cible app)
xcodebuild -scheme IrisApp -configuration Release build

# Package final (script séparé)
./packaging/build-pkg.sh
```

---

## 10. Ce qu'il ne faut PAS faire

- **Pas de réécriture d'Apple SDKs**. Si tu trouves une lib tierce pour parser TLS quand `swift-nio-ssl` peut le faire, c'est non.
- **Pas de blocking I/O** dans le proxy. Tout doit être async (Swift Concurrency ou NIO `EventLoop`).
- **Pas de `Thread.sleep`** comme moyen de synchronisation.
- **Pas de stockage de l'état du daemon sur disque non chiffré.** SQLite local pour les events est OK (pas de secrets dedans, seulement noms et métadonnées).
- **Pas de désinstallation silencieuse** qui supprime les items Keychain de l'utilisateur. Toujours demander confirmation explicite.
- **Pas de télémétrie, pas de phone-home.** Le daemon ne contacte que les hosts définis dans la whitelist MITM, point final.

---

## 11. Questions à poser plutôt que de deviner

Si l'un des points suivants n'est pas tranché dans `SPECS.md`, **demander avant d'implémenter** :

- Comportement exact sur HTTP/2 (downgrade h1.1 ou support h2 natif côté proxy)
- Format précis du fichier d'events SQLite (schéma)
- Comportement si la CA expire (durée de validité par défaut)
- Si la rotation de la CA est in-scope MVP ou roadmap
- UI exacte du sheet "Add secret" dans l'app (champs, validation)

---

## 12. Phasage suggéré (à confirmer)

1. **Phase 0** — Setup repo, `Package.swift`, CI minimale (`swift build` + `swift test`)
2. **Phase 1** — `IrisKit` : modèles, config TOML, accès Keychain abstrait, génération CA
3. **Phase 2** — `irisd` : proxy MITM monothread, 1 host whitelisté, substitution naïve, pas d'IPC
4. **Phase 3** — IPC : Unix socket JSON-RPC, SSE events
5. **Phase 4** — Scoping `allowed_hosts` + règles d'exfiltration
6. **Phase 5** — CLI `iris` (including `mcp wrap`)
7. **Phase 6** — Menu bar app (lecture seule d'abord, puis CRUD)
8. **Phase 7** — LaunchAgent + `SMAppService` integration
9. **Phase 8** — Installation CA dans trust store, ACL Keychain
10. **Phase 9** — `.pkg` + codesign + notarize
11. **Phase 10** — Hardening (tests d'intégration, fuzzing du parser de placeholder)

Chaque phase doit être démontrable (build, run, test) avant de passer à la suivante.
