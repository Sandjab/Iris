# Phase 8b — ACL Keychain : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lier les items Keychain écrits par `irisd` (valeurs de secrets + clé privée CA) à une ACL par binaire, de sorte que seul `irisd` signé y accède en silence et que tout autre process soit prompté/refusé (CLAUDE.md §6.2, SPECS §12.3).

**Architecture:** Un seul appel à l'API legacy `SecAccessCreate(description, nil, &access)` — `nil` ⇒ « ne faire confiance qu'au binaire appelant » — produit un `SecAccess` qu'on passe en `kSecAttrAccess` à `SecItemAdd`, en retirant `kSecAttrAccessible` (attributs mutuellement exclusifs : file-based vs data-protection keychain). La logique vit dans un nouvel enum-namespace `KeychainACL` (convention `CATrustStore` de 8a) ; les deux stores (`KeychainSecretStore`, `KeychainCAKeyStore`) l'appellent sur leur chemin de création. La vérification réelle est smoke-only (binaire signé + panneau de consentement) ; la CI ne couvre que les fonctions pures de descripteur.

**Tech Stack:** Swift 5.9+, Security.framework (`SecAccessCreate`, `SecItemAdd`), XCTest, SwiftPM. macOS 13+.

**Spec:** `docs/superpowers/specs/2026-06-03-phase-8b-keychain-acl-design.md`.

**Préliminaire :** sur la branche `feat/phase-8b-keychain-acl` (déjà créée ; le design doc y est committé). Aucune modif de `Package.swift` : SwiftPM compile récursivement `Sources/IrisKit/`, donc le nouveau sous-dossier `Keychain/` est pris automatiquement.

---

### Task 1 : Spike runtime (de-risking — GATE, manuel, jetable, non committé)

Valide les mécaniques d'API **avant** d'écrire le vrai code (leçon 8a : le runtime est l'oracle, pas l'hypothèse). Si ce spike échoue, **pivoter l'API** (`SecAccessCreateWithOwnerAndACL` + `SecACLCreateWithSimpleContents`, ou `SecKeychainItemSetAccess` post-insertion) avant de continuer.

**Files:**
- Create (jetable, hors repo) : `/tmp/iris-acl-spike/main.swift`

- [ ] **Step 1 : Écrire le programme de spike**

Écrire dans `/tmp/iris-acl-spike/main.swift` :

```swift
import Foundation
import Security

let service = "io.iris.spike"
let account = "probe"

// 1. Build a self-only access (nil trustedlist ⇒ only the calling binary).
var access: SecAccess?
let accStatus = SecAccessCreate("io.iris.spike.probe" as CFString, nil, &access)
guard accStatus == errSecSuccess, let access else {
    print("SecAccessCreate FAILED: \(accStatus)")
    exit(1)
}

// 2. Clean any prior probe item.
SecItemDelete([
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
] as CFDictionary)

// 3. Add WITH kSecAttrAccess and WITHOUT kSecAttrAccessible.
let addStatus = SecItemAdd([
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecValueData as String: Data("topsecret".utf8),
    kSecAttrAccess as String: access,
] as CFDictionary, nil)
print("SecItemAdd status: \(addStatus)  (0 = success)")

// 4. Read back from THIS (the adding) binary — must be silent (status 0, no panel).
var out: AnyObject?
let readStatus = SecItemCopyMatching([
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
] as CFDictionary, &out)
print("self read status: \(readStatus)  (0 = silent read OK)")
```

- [ ] **Step 2 : Compiler et exécuter**

```bash
mkdir -p /tmp/iris-acl-spike
# (écrire main.swift ci-dessus)
swiftc -framework Security /tmp/iris-acl-spike/main.swift -o /tmp/iris-acl-spike/spike
/tmp/iris-acl-spike/spike
```

Expected : `SecItemAdd status: 0  (0 = success)` puis `self read status: 0  (0 = silent read OK)`.
Si `SecItemAdd status` est `-50` (`errSecParam`), le combo `kSecAttrAccess` + absence de `kSecAttrAccessible` est rejeté ⇒ **pivot API requis**.

- [ ] **Step 3 : Prouver qu'un binaire tiers est prompté/refusé**

```bash
security find-generic-password -s io.iris.spike -a probe -w
```

Expected : macOS affiche un **panneau de consentement** (« security veut utiliser une clé… »), car `/usr/bin/security` est un binaire **différent** du spike. C'est la preuve que l'accès silencieux est réservé au binaire ayant créé l'item. (Annuler le panneau est OK.)

- [ ] **Step 4 : Nettoyer**

```bash
security delete-generic-password -s io.iris.spike -a probe 2>/dev/null
rm -rf /tmp/iris-acl-spike
```

> **Décision de gate :** Steps 2 & 3 verts ⇒ le recipe `SecAccessCreate(_, nil, _)` + `kSecAttrAccess` (sans `kSecAttrAccessible`) est validé ⇒ continuer. Sinon, mettre à jour le design §5/§7.1 avec le recipe alternatif retenu, puis adapter Task 2.

---

### Task 2 : `KeychainACL` — descripteurs purs + construction d'ACL effectful

**Files:**
- Create: `Sources/IrisKit/Keychain/KeychainACL.swift`
- Test: `Tests/IrisKitTests/KeychainACLTests.swift`

- [ ] **Step 1 : Écrire les tests qui échouent**

Créer `Tests/IrisKitTests/KeychainACLTests.swift` :

```swift
import XCTest

@testable import IrisKit

final class KeychainACLTests: XCTestCase {
    // Le descripteur est le nom de l'item affiché dans le panneau de consentement
    // macOS quand un process non-irisd tente de lire l'item, et il calque le
    // nommage service/account du Keychain. On le verrouille pour qu'un refactor ne
    // change pas silencieusement ce que voit l'utilisateur ni le contrat de nommage.
    func testSecretAccessDescription() {
        XCTAssertEqual(
            KeychainACL.accessDescription(forSecret: "anthropic_api_key"),
            "io.iris.secret.anthropic_api_key"
        )
    }

    func testCAPrivateKeyDescription() {
        XCTAssertEqual(KeychainACL.caPrivateKeyDescription(), "io.iris.ca.privatekey")
    }

    func testACLErrorHasNonEmptyDescription() {
        let error = KeychainACLError.creationFailed(errSecParam)
        XCTAssertFalse((error.errorDescription ?? "").isEmpty)
    }
}
```

- [ ] **Step 2 : Lancer les tests, vérifier l'échec**

```bash
swift test --filter KeychainACLTests
```

Expected : échec de compilation — `cannot find 'KeychainACL' in scope` / `cannot find 'KeychainACLError' in scope`.

- [ ] **Step 3 : Écrire l'implémentation minimale**

Créer `Sources/IrisKit/Keychain/KeychainACL.swift` :

```swift
import Foundation
import Security

/// Builds the per-binary Keychain ACL that grants silent read access ONLY to the
/// signed `irisd` binary and prompts/denies every other process (CLAUDE.md §6.2,
/// SPECS §12.3). Design: `docs/superpowers/specs/2026-06-03-phase-8b-keychain-acl-design.md`.
public enum KeychainACL {
    /// Item name shown in the system consent dialog when a non-trusted process
    /// tries to read the secret. Mirrors the Keychain service/account naming.
    public static func accessDescription(forSecret name: String) -> String {
        "io.iris.secret.\(name)"
    }

    /// Item name shown in the consent dialog for the CA private key.
    public static func caPrivateKeyDescription() -> String {
        "io.iris.ca.privatekey"
    }

    /// Builds a `SecAccess` whose restricted operations (decrypt/read) are silent
    /// ONLY for the calling binary (`irisd`) and prompt every other process.
    /// Passing `nil` as the trusted list means "trust only the calling app"
    /// (Apple docs, `SecAccessCreate`). The security property is structural —
    /// carried by the `nil`, not by a policy table.
    ///
    /// Uses the deprecated `SecAccessCreate` (SecKeychain family): the modern
    /// data-protection keychain has no per-binary ACL primitive. This is a
    /// deliberate, documented exception to CLAUDE.md §5 (design 8b §3). The lone
    /// deprecation warning is localized here and non-fatal (CI has no
    /// warnings-as-errors). Smoke-only: relies on the calling binary being
    /// Developer-ID signed for a stable identity.
    public static func selfOnlyAccess(description: String) throws -> SecAccess {
        var access: SecAccess?
        let status = SecAccessCreate(description as CFString, nil, &access)
        guard status == errSecSuccess, let access else {
            throw KeychainACLError.creationFailed(status)
        }
        return access
    }
}

/// Failure building a Keychain `SecAccess`. Propagated through the stores'
/// existing `throws` (`add` / `storeKey`).
public enum KeychainACLError: Error, LocalizedError, Equatable {
    case creationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain ACL creation failed: \(message ?? "OSStatus \(status)")"
        }
    }
}
```

- [ ] **Step 4 : Lancer les tests, vérifier le succès**

```bash
swift test --filter KeychainACLTests
```

Expected : 3 tests PASS. (Le build peut afficher **un** warning de dépréciation sur `SecAccessCreate` dans `KeychainACL.swift` — attendu et non-fatal.)

- [ ] **Step 5 : Formater et committer**

```bash
swift-format format --in-place --recursive Sources/IrisKit/Keychain Tests/IrisKitTests/KeychainACLTests.swift
swift-format lint --strict Sources/IrisKit/Keychain/KeychainACL.swift Tests/IrisKitTests/KeychainACLTests.swift
git add Sources/IrisKit/Keychain/KeychainACL.swift Tests/IrisKitTests/KeychainACLTests.swift
git commit -m "feat(phase-8b): KeychainACL — SecAccess silencieux pour le binaire appelant"
```

---

### Task 3 : Câbler l'ACL dans `KeychainSecretStore.add`

Pas de test CI nouveau (l'item réel exige le Keychain + binaire signé) : la garantie est `swift build` OK, `swift test` toujours vert (les tests utilisent `InMemorySecretStore`, inchangé) et le smoke (Task 5). On retire `kSecAttrAccessible` (exclusif de `kSecAttrAccess`).

**Files:**
- Modify: `Sources/IrisKit/SecretStore/KeychainSecretStore.swift:4-11` (commentaire d'en-tête) et `:35-46` (corps de `add`)

- [ ] **Step 1 : Mettre à jour le commentaire d'en-tête du fichier**

Remplacer le bloc de doc (lignes 4-11, qui dit « Phase 1 uses … without per-application ACL … scheduled for Phase 8 ») par :

```swift
/// Keychain-backed `SecretStore`. Items are stored as `kSecClassGenericPassword`
/// with `service = io.iris.secret` and `account = <name>`, value = secret bytes,
/// generic attribute = JSON-encoded metadata (allowed_hosts, timestamps, usage).
///
/// Phase 8b: each item is added with a per-binary `SecAccess` (`KeychainACL`)
/// granting silent read access only to the signed `irisd` binary, so other
/// processes are prompted/denied (CLAUDE.md §6.2). `kSecAttrAccess` (file-based
/// keychain) replaces `kSecAttrAccessible` — the two attributes are mutually
/// exclusive.
```

- [ ] **Step 2 : Construire l'ACL et l'appliquer dans `add`**

Dans `add(_:named:allowedHosts:createdAt:)`, après `let metadataBlob = try encode(metadata)`, insérer la construction de l'ACL, puis remplacer le dict `attributes` (retirer la ligne `kSecAttrAccessible`, ajouter `kSecAttrAccess`). Le bloc devient :

```swift
        let metadataBlob = try encode(metadata)
        let access = try KeychainACL.selfOnlyAccess(
            description: KeychainACL.accessDescription(forSecret: name)
        )

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecAttrGeneric as String: metadataBlob,
            kSecValueData as String: value,
            kSecAttrAccess as String: access,
        ]
```

- [ ] **Step 3 : Build + tests complets**

```bash
swift build
swift test
```

Expected : build OK (1 warning de dépréciation attendu, localisé à `KeychainACL.swift`) ; tous les tests PASS (404+ inchangés ; les tests SecretStore utilisent l'in-memory).

- [ ] **Step 4 : Formater et committer**

```bash
swift-format format --in-place --recursive Sources/IrisKit/SecretStore
swift-format lint --strict Sources/IrisKit/SecretStore/KeychainSecretStore.swift
git add Sources/IrisKit/SecretStore/KeychainSecretStore.swift
git commit -m "feat(phase-8b): ACL irisd-seul sur les secrets (kSecAttrAccess, retire kSecAttrAccessible)"
```

---

### Task 4 : Câbler l'ACL dans `KeychainCAKeyStore.storeKey`

Même schéma, scope clé CA (descripteur `io.iris.ca.privatekey`), uniquement sur le chemin de **création** (`SecItemAdd`) ; le `SecItemUpdate` de rotation reste inchangé (préserve l'ACL).

**Files:**
- Modify: `Sources/IrisKit/CA/KeychainCAKeyStore.swift:5-10` (commentaire) et `:68-78` (bloc `addAttrs` + `SecItemAdd`)

- [ ] **Step 1 : Mettre à jour le commentaire d'en-tête du fichier**

Remplacer le bloc de doc (lignes 5-10, « Phase 1 uses generic-password storage without ACL — Phase 8 migrates to kSecClassKey … ») par :

```swift
/// Persists the CA private key in the Keychain as a `kSecClassGenericPassword`
/// containing the raw 32-byte P256 private key representation.
///
/// Phase 8b: the create path attaches a per-binary `SecAccess` (`KeychainACL`)
/// granting silent access only to the signed `irisd` binary (CLAUDE.md §6.2).
/// `kSecAttrAccess` replaces `kSecAttrAccessible` (mutually exclusive). NOTE: the
/// key is still loaded as raw bytes to sign leaf certs — SPECS §11.2 ("never
/// exported to memory", i.e. a non-extractable `SecKey`) is a separate hardening
/// card, out of scope for 8b.
```

- [ ] **Step 2 : Construire l'ACL et l'appliquer sur le chemin de création**

Dans `storeKey(_:)`, juste avant le bloc `let addAttrs` (le chemin atteint après le `break` du `SecItemUpdate` not-found), construire l'ACL et remplacer le dict (retirer `kSecAttrAccessible`, ajouter `kSecAttrAccess`) :

```swift
        let access = try KeychainACL.selfOnlyAccess(description: KeychainACL.caPrivateKeyDescription())
        let addAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccess as String: access,
        ]
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CAError.keychainStatus(addStatus)
        }
```

- [ ] **Step 3 : Build + tests complets**

```bash
swift build
swift test
```

Expected : build OK (même warning de dépréciation attendu) ; tous les tests PASS (les tests CA utilisent `InMemoryCAKeyStore`, inchangé).

- [ ] **Step 4 : Formater et committer**

```bash
swift-format format --in-place --recursive Sources/IrisKit/CA
swift-format lint --strict Sources/IrisKit/CA/KeychainCAKeyStore.swift
git add Sources/IrisKit/CA/KeychainCAKeyStore.swift
git commit -m "feat(phase-8b): ACL irisd-seul sur la clé privée CA (chemin de création)"
```

---

### Task 5 : Vérification finale + PR

**Files:** aucun (CI parity + PR).

- [ ] **Step 1 : Reproduire la CI localement**

```bash
swift-format lint --strict --recursive Sources Tests Package.swift IrisApp
swift build
swift test
```

Expected : lint clean ; build OK (1 warning de dépréciation `SecAccessCreate` attendu, non-fatal — pas de `-warnings-as-errors` en CI) ; tous les tests PASS.

- [ ] **Step 2 : Pousser la branche**

```bash
git push -u origin feat/phase-8b-keychain-acl
```

- [ ] **Step 3 : Ouvrir la PR avec la checklist de smoke**

```bash
gh pr create --title "feat(phase-8b): ACL Keychain — SecAccess lié au binaire signé" --body "$(cat <<'EOF'
## Phase 8b — ACL Keychain

ACL par binaire (`SecAccess`, `nil`-trustedlist ⇒ binaire appelant seul) sur les valeurs de secrets et la clé privée CA. Élimine l'« always allow » universel (CLAUDE.md §6.2, SPECS §12.3). Exception assumée et documentée à CLAUDE.md §5 (API legacy `SecAccessCreate`, seule à exprimer l'ACL par binaire). Design : `docs/superpowers/specs/2026-06-03-phase-8b-keychain-acl-design.md`.

### Smoke testing (poste — binaire Developer-ID signé du bundle 9a)
- [ ] `iris secret add <name> --host <h>` via le daemon **signé** → pas de boucle de prompts ; Keychain Access montre l'item avec accès limité à `irisd`.
- [ ] **Assertion sécurité clé** : `security find-generic-password -s io.iris.secret -a <name> -w` (process tiers) → **panneau de consentement / refus** (prouve que non-`irisd` n'a pas l'accès silencieux).
- [ ] Substitution proxy réelle : `irisd` lit le secret **sans prompt** pendant une requête `{{kc:<name>}}`.
- [ ] Clé CA : `irisd` forge un leaf cert **sans prompt** ; lecture tierce de `io.iris.ca / privatekey` → panneau / refus.
- [ ] `iris secret rotate` / mise à jour des `allowed_hosts` → l'ACL **persiste** (toujours pas de prompt pour `irisd`).
- [ ] `swift build` + `swift test` + `swift-format lint --strict` verts ; xcode-build gate vert.

### Hors-scope
- SPECS §11.2 (clé CA non-extractable / `SecKey` / Secure Enclave) → carte de hardening séparée.
- Migration des items pré-8b → aucune (recréation manuelle).
EOF
)"
```

- [ ] **Step 4 : Attendre et traiter la revue Gemini** (CLAUDE.md §8 : polling 1 min, arrêt à 10 min de silence, plafond 30 min). Pour chaque commentaire : appliquer+commit+répondre, ou refuser factuellement.

- [ ] **Step 5 : Merge sur confirmation explicite de l'utilisateur** (CLAUDE.md §8 : `gh pr merge --squash`, jamais automatique ; tous les items de smoke cochés + Gemini traité + CI verte).

---

## Self-Review (rempli par l'auteur du plan)

**Couverture spec :** §1 invariant → Tasks 3+4. §2 décisions verrouillées → Tasks 2-4 (irisd-seul = `nil`-trustedlist ; login keychain = inchangé ; pas de migration = aucune tâche, documenté). §3 exception §5 → commentaire `KeychainACL.swift` + corps PR. §4.1 `KeychainACL` → Task 2. §4.2/§4.3 stores → Tasks 3/4. §4.4 `KeychainACLError` → Task 2. §5 recipe `SecAccessCreate(_, nil, _)` → Tasks 1-2. §6 concurrence (construit+consommé in-actor) → respecté (l'ACL est une variable locale de `add`/`storeKey`). §7.1 spike → Task 1. §7.2 unit → Task 2 (Step 1). §7.3 smoke → Task 5 (checklist PR).

**Placeholders :** aucun `<name>`/`<h>` non-littéral hors des templates de commande/PR (intentionnels). Tout le code des steps est complet.

**Cohérence des types :** `KeychainACL.accessDescription(forSecret:)`, `KeychainACL.caPrivateKeyDescription()`, `KeychainACL.selfOnlyAccess(description:)`, `KeychainACLError.creationFailed(OSStatus)` — mêmes signatures en Tasks 2, 3, 4. `kSecAttrAccess`/`kSecAttrAccessible` traités identiquement dans les deux stores.
