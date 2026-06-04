# Phase 8b — ACL Keychain (`SecAccess` liant les items au binaire signé)

> Design validé le 2026-06-03. Seconde moitié de la « Phase 8 » du phasage
> CLAUDE.md §12 (la première, 8a, a installé la CA dans le trust store user —
> cf `2026-06-03-phase-8a-ca-trust-install-design.md`). Aucune dépendance entre
> les deux moitiés au-delà du partage du fichier `CA/`.

## 1. Objectif & invariant

Attacher une **ACL par binaire** aux items Keychain écrits par `irisd`, de sorte
que **`irisd` signé y accède en silence** et que **tout autre process du même
utilisateur soit prompté ou refusé**. Cela élimine l'« always allow » universel
actuel — aujourd'hui les deux stores écrivent en
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` **sans aucune ACL**
(`KeychainSecretStore.swift:43`, `KeychainCAKeyStore.swift:73`), ce qui rend les
items lisibles par n'importe quel process de l'utilisateur dès le trousseau
déverrouillé.

Couvre les deux actifs : **valeurs de secrets** (login keychain,
`kSecClassGenericPassword`, `service = io.iris.secret`) et **clé privée CA**
(login keychain, `kSecClassGenericPassword`, `service = io.iris.ca`,
`account = privatekey`).

Satisfait l'invariant non-négociable CLAUDE.md §6.2 et la prescription SPECS §12.3.

## 2. Décisions de cadrage (verrouillées)

| Décision | Choix | Justification |
|----------|-------|---------------|
| API | **Legacy `SecAccess`** (`SecTrustedApplicationCreateFromPath` + `SecAccessCreate` + `kSecAttrAccess`) | Seule famille d'API produisant le comportement « silencieux pour le binaire désigné / prompt pour les autres » (modèle historique mkcert/Chrome). **Exception assumée à CLAUDE.md §5** — voir §3. |
| Binaires trustés | **`irisd` seul**, pour les deux items | Le daemon est le **seul** acteur Keychain : vérifié — seul `Daemon.swift:63,71` instancie `KeychainSecretStore`/`KeychainCAKeyStore`, et `Sources/iris/` n'a ni `import Security`, ni `SecItem*`, ni instanciation de store. Tranche l'incohérence interne de SPECS §12.3 (« irisd **et** iris CLI » vs « only irisd (and optionally the CLI) ») au profit de la source vivante (Rule 8). |
| Clé CA | **ACL chirurgicale** sur l'item raw-P256 existant | On attache un `SecAccess` à l'item `kSecClassGenericPassword` actuel. La portée « clé jamais extraite en mémoire » (SPECS §11.2, aujourd'hui violée par `key.rawRepresentation`) est **hors-scope** → carte de hardening séparée. L'ACL `irisd`-seul satisfait pleinement l'invariant 8b indépendamment de §11.2. |
| Emplacement | **login keychain** (existant) | System Keychain (SPECS §12.1) exige l'admin pour modifier → contredit G7 (no-friction) et la décision `.user` de 8a. Déviation SPECS §12.1 documentée, cohérente avec 8a. |
| Migration | **Aucune** | Pas d'utilisateurs réels (pré-1.0). Les items créés avant 8b conservent leur absence d'ACL jusqu'à recréation ; le smoke part d'un trousseau propre. Limitation documentée, pas de re-scellement automatique au démarrage (éviterait le scope + le risque runtime). |

## 3. Approche : `SecAccess` legacy — exception documentée à CLAUDE.md §5

### 3.1 Le conflit

SPECS §12.3 prescrit `SecAccessCreateWithOwnerAndACL` +
`SecTrustedApplicationCreateFromPath` + `SecKeychainItemSetAccess`. La doc Apple
(vérifiée le 2026-06-03 via sosumi) marque **ces trois symboles
`deprecated: true`**, motif « SecKeychain is deprecated ». CLAUDE.md §5 dit :
« API dépréciée macOS 13+ : ne pas l'utiliser ».

### 3.2 Pourquoi l'exception est justifiée

L'API **moderne** ne sait pas exprimer une ACL par binaire :

- `SecAccessControlCreateWithFlags` / `kSecAttrAccessControl` ne couvre que des
  contraintes de présence/biométrie/passcode/usage-de-clé — **pas** une liste
  d'applications autorisées.
- Le pendant moderne du scoping par app est `kSecAttrAccessGroup` (access
  groups), qui exige des **entitlements `keychain-access-groups` + une signature
  Developer ID de la même équipe** sur `irisd` (et tout autre accédant), **casse
  la boucle de dev** (binaires adhoc `.build/release` non éligibles), impose une
  migration des items, et reste un primitive de *partage* inter-app — pas le
  modèle « consent prompt » demandé.

Les API legacy restent **fonctionnelles** (non retirées) sur macOS 13–26. Le
choix est donc : implémenter la prescription SPECS littérale avec une exception
§5 **assumée et documentée ici**, plutôt que de basculer vers une refonte
d'architecture (access groups) qui dévie de SPECS, dégrade la sécurité voulue
(deny silencieux ≠ consent prompt) et casse le dev. Décision tranchée par
l'utilisateur le 2026-06-03.

### 3.3 Sensibilité à la signature (leçon 8a — load-bearing)

8a a établi que les opérations Security.framework se comportent **différemment
selon la signature du binaire** : `SecTrustSettingsSetTrustSettings` rendait
`errSecInternalComponent` (-2070) depuis un binaire adhoc, mais l'outil
Apple-signé persistait correctement. Corollaire pour 8b :

- L'ACL ne se lie de façon stable qu'à un binaire **Developer-ID signé** (le
  bundle 9a). `SecAccessCreate(_, nil, _)` capture l'identité (signature de code)
  du **binaire appelant** ; en dev (`.build/release/irisd` adhoc) cette identité
  change à chaque rebuild ⇒ re-prompt systématique. Le smoke réel se fait donc sur
  le **binaire signé**, pas sur le binaire de dev.
- **Le runtime est l'oracle, pas l'hypothèse.** D'où le spike runtime en
  première étape d'implémentation (§6).

## 4. Composants

### 4.1 `Sources/IrisKit/Keychain/KeychainACL.swift` (nouveau)

Enum-namespace (convention `CATrustStore` de 8a), séparation pure / effectful
pour la testabilité :

- `static func accessDescription(service: String, account: String) -> String` →
  `"<service>.<account>"` — **pure, CI-testable**. Ce descripteur est le texte
  affiché dans le panneau de consentement système quand un process **non** trusté
  tente de lire l'item ; il prend le `service`/`account` **réels** du store (et
  non des constantes codées en dur) pour rester correct même avec une config
  non-défaut. On verrouille la chaîne par test (analogue au verrou du vecteur
  d'args de 8a).
- `static func selfOnlyAccess(description: String) throws -> SecAccess` —
  **effectful**, smoke-only. **Un seul** appel déprécié :
  `SecAccessCreate(description as CFString, nil, &access)`. Le `trustedlist == nil`
  signifie, d'après la doc Apple, « ne faire confiance qu'au binaire **appelant** »
  (= `irisd`) pour les opérations restreintes (decrypt/lecture). Aucun
  `SecTrustedApplicationCreateFromPath`, aucune résolution de chemin, aucun
  subprocess. La propriété de sécurité (« seul `irisd` lit en silence ») est
  **structurelle** — portée par le `nil`, pas par une table de politique.

Mapping d'erreur : `KeychainACLError` (voir §4.4).

### 4.2 `Sources/IrisKit/SecretStore/KeychainSecretStore.swift` (modifié)

- `add(_:named:allowedHosts:createdAt:)` — construit
  `let access = try KeychainACL.selfOnlyAccess(description: KeychainACL.accessDescription(service: service, account: name))`
  puis met `kSecAttrAccess: access` dans le dict d'attributs du `SecItemAdd`. **Et
  retire `kSecAttrAccessible`** : `kSecAttrAccess` (file-based keychain) et
  `kSecAttrAccessible` (data-protection keychain) sont **mutuellement exclusifs** ;
  l'item bascule dans le login keychain fichier, dont l'accessibilité par défaut
  est « trousseau déverrouillé » (suffisant — le login keychain ne synchronise pas
  iCloud de toute façon).
- `update` / `rotate` — **inchangés** : ils ne touchent que `kSecAttrGeneric` /
  `kSecValueData` via `SecItemUpdate`, qui **préserve** l'ACL existante (conforme
  SPECS §12.5 « Preserves the existing ACL »).

### 4.3 `Sources/IrisKit/CA/KeychainCAKeyStore.swift` (modifié)

- `storeKey(_:)` — sur le chemin de **création** (`SecItemAdd`), construit
  `try KeychainACL.selfOnlyAccess(description: KeychainACL.accessDescription(service: service, account: account))`,
  met `kSecAttrAccess: access` et **retire `kSecAttrAccessible`** (même exclusivité
  qu'en §4.2). Le chemin `SecItemUpdate` (rotation de valeur) reste inchangé
  (préserve l'ACL).

### 4.4 Erreurs

`selfOnlyAccess` étant partagé par les deux stores, il lève son **propre** type —
nouvel `enum KeychainACLError: Error, LocalizedError { case creationFailed(OSStatus) }`
dans `KeychainACL.swift` (message non vide). Il **se propage** par le `throws`
déjà présent sur `add` / `storeKey` ; pas de cas dupliqué dans `SecretStoreError`
ni `CAError`.

## 5. Pattern API (validé par le spike §7.1)

```swift
var access: SecAccess?
let status = SecAccessCreate(description as CFString, nil, &access)  // nil ⇒ seul le binaire appelant (irisd)
guard status == errSecSuccess, let access else { throw KeychainACLError.creationFailed(status) }
// access → kSecAttrAccess sur SecItemAdd ; kSecAttrAccessible RETIRÉ (exclusivité, §4.2)
```

`SecAccessCreate(_:_:_:)` (signature confirmée doc Apple 2026-06-03 :
`(CFString, CFArray?, UnsafeMutablePointer<SecAccess?>) -> OSStatus`) crée un
access par défaut à trois entrées ; l'entrée **restreinte** (decrypt/lecture)
n'accorde l'accès silencieux qu'aux apps de `trustedlist`, et `nil` ⇒ « seul le
binaire appelant ». SPECS nommait `SecAccessCreateWithOwnerAndACL` ; le recipe
`nil`-trustedlist est strictement plus simple et donne la même garantie. **Une
seule API dépréciée** (`SecAccessCreate`, famille SecKeychain). Le spike (§7.1)
confirme que l'ACL **persiste** réellement depuis le binaire signé ; sinon,
pivot vers `SecAccessCreateWithOwnerAndACL` + `SecACLCreateWithSimpleContents`.

> **Warning de dépréciation** : l'appel `SecAccessCreate` émet **un** warning de
> dépréciation, localisé à `KeychainACL.swift`. Package.swift n'active pas
> `-warnings-as-errors` (seulement `StrictConcurrency`) → le build **ne casse
> pas**. Coût assumé et documenté de l'exception §5 ; un shim C (`#pragma clang
> diagnostic ignored`) serait sur-dimensionné pour un unique site d'appel
> (Rule 2/3).

## 6. Concurrence

`SecAccessRef` est un type CoreFoundation non-`Sendable`. Il est **construit et
consommé à l'intérieur de la même méthode actor-isolée** du store (`add` /
`storeKey`) — aucun franchissement de frontière d'acteur, aucune capture dans une
closure échappante. Compatible `-strict-concurrency=complete`.

## 7. Vérification

### 7.1 Spike runtime (étape 1 d'implémentation — de-risking)

Avant tout build-out, sur le binaire **Developer-ID signé** (bundle 9a), prouver
au runtime :

1. `SecItemAdd` avec `kSecAttrAccess` **et sans** `kSecAttrAccessible` **réussit**
   et l'ACL **persiste** (relecture des attributs / inspection Keychain Access).
   (Valide aussi l'exclusivité des deux attributs.)
2. Un process tiers (`security find-generic-password …`) est **prompté ou
   refusé**.
3. `irisd` relit l'item **en silence** (pas de panneau).

Si le recipe échoue (à l'image de trust-settings en 8a), **pivoter l'API avant
d'écrire le reste** (`SecAccessCreateWithOwnerAndACL` + `SecACLCreateWithSimpleContents`,
voire `SecKeychainItemSetAccess` post-insertion).

### 7.2 Unit (CI, headless)

- `KeychainACL.accessDescription(service:account:)` →
  `(io.iris.secret, anthropic_api_key) → "io.iris.secret.anthropic_api_key"` et
  `(io.iris.ca, privatekey) → "io.iris.ca.privatekey"` (verrouille les
  descripteurs du panneau de consentement et le calque sur le nommage réel).
- `KeychainACLError.creationFailed` est `LocalizedError` (message non vide).

> Les appels `SecAccess`/`SecItemAdd` réels **ne sont pas** testés en CI : ils
> exigent un binaire signé (et éventuellement un panneau d'authentification). Cf
> §3.3 — assumé et documenté, comme le smoke-only de 8a.

### 7.3 Smoke manuel (poste — checklist PR)

- [ ] `iris secret add <name> --host <h>` via le daemon **signé** → pas de boucle
      de prompts ; Keychain Access montre l'item avec accès limité à `irisd`.
- [ ] **Assertion sécurité clé (§6.2)** : `security find-generic-password -s io.iris.secret -a <name> -w`
      (process tiers) → **panneau de consentement / refus** (prouve que
      non-`irisd` n'a pas l'accès silencieux).
- [ ] Substitution proxy réelle : `irisd` lit le secret **sans prompt** pendant
      une requête `{{kc:<name>}}`.
- [ ] Clé CA : `irisd` forge un leaf cert **sans prompt** ; lecture tierce de
      `io.iris.ca / privatekey` → panneau / refus.
- [ ] `iris secret rotate` / mise à jour des `allowed_hosts` → l'ACL **persiste**
      (toujours pas de prompt pour `irisd`, toujours prompt pour les tiers).

## 8. Hors-scope (non-goals)

- **SPECS §11.2** « clé CA jamais extraite en mémoire » (migration `SecKey`
  non-extractable / Secure Enclave + signature in-place) → **carte de hardening
  séparée**. 8b ne change pas le chemin de signature des leaf certs (swift-crypto
  P256 reste).
- **Migration des items pré-8b** → aucune (recréation manuelle ; smoke part d'un
  trousseau propre).
- **Bascule data-protection keychain / access groups / entitlements** → rejetée
  (§3.2).
- **Grant du CLI `iris` dans l'ACL** → écarté (le CLI n'accède pas au Keychain).
- **System Keychain pour la clé CA** (SPECS §12.1 littéral) → écarté au profit du
  login keychain (§2).
