# Phase 8a — Installation de la CA dans le trust store (domaine user)

> Design validé le 2026-06-03. Première moitié de la « Phase 8 » du phasage
> CLAUDE.md §12. La seconde moitié — ACL Keychain (`SecAccess` liant secrets +
> clé CA au binaire signé) — fait l'objet d'une phase **8b distincte** et n'est
> **pas** couverte ici.

## 1. Objectif

Ajouter `iris ca install` et `iris ca uninstall` qui ajoutent / retirent la CA
racine IRIS aux réglages de confiance de **l'utilisateur courant** (domaine
`.user`), sans étape manuelle dans Keychain Access. Après installation, les
outils de l'utilisateur qui consultent le vérificateur système (Safari, `gh`,
`curl` système via SecureTransport) font confiance aux certificats feuilles
forgés par le proxy MITM. `iris ca is-trusted` reflète déjà le résultat (il lit
le domaine `.user`).

## 2. Décisions de cadrage (verrouillées)

| Décision | Choix | Justification |
|----------|-------|---------------|
| Périmètre | **8a seul** (install trust store) | L'ACL Keychain (8b) a un profil de risque/testabilité radicalement différent (API legacy dépréciée, smoke-only). Découpe par phase démontrable (CLAUDE.md §8/§12). |
| Domaine de confiance | **`.user`** | Threat model mono-utilisateur. Le login keychain est honoré par Safari/`gh`/`curl`-système pour l'utilisateur courant. Pas de mot de passe admin (G7 no-friction). Cohérent avec `CATrustStore.isTrusted(.user)` déjà écrit. Dévie du libellé littéral de SPECS §11.3 (System.keychain), qui ciblait la couverture multi-users/démons root — hors scope. |
| Symétrie | **install + uninstall** | Rend le smoke répétable (install → vérifie → uninstall → recommence), prépare le futur bouton app « Remove CA » (6.3). |
| Mécanisme | **Shell-out vers `/usr/bin/security`** (révisé) | L'API native `SecTrustSettings*` (recommandée à l'origine) rend `errSecInternalComponent` (-2070) depuis le binaire CLI non Developer-ID-signé. Voir §3 pour le diagnostic runtime. |

## 3. Approche : shell-out vers `/usr/bin/security` (révisé après runtime)

### 3.1 Approche initiale (API native) — abandonnée

Le design retenait `SecTrustSettingsSetTrustSettings(cert, .user, nil)` : non
déprécié (macOS 10.0+), `nil` ⇒ « always trust this root », symétrique du
chemin de lecture `SecTrustSettingsCopyCertificates(.user)`, sans subprocess.

**Le smoke runtime (2026-06-03, macOS 26.4.1) a invalidé cette approche.**
L'appel rend systématiquement `errSecInternalComponent` (**-2070**), instantané,
sans présenter de panneau, **dans la session du poste comme en CI**. Diagnostic
(via systematic-debugging) :

- `.build/release/iris` est `adhoc, linker-signed` (`TeamIdentifier=not set`).
  L'API de trust settings refuse l'écriture depuis un binaire non
  Developer-ID-signé → `errSecInternalComponent`.
- L'outil **Apple-signé `/usr/bin/security add-trusted-cert`**, lui, persiste
  bien le trust setting `.user` (panneau d'auth + mot de passe login →
  `dump-trust-settings` montre `IRIS local CA` avec un tableau de trust settings
  vide = « always trust root »). MDM écarté (DEP/MDM No).
- C'est la **convention macOS** (mkcert, Keychain Access passent tous par
  l'outil `security`, jamais par l'API programmatique pour les tiers).

### 3.2 Approche retenue

`CATrustStore.install`/`uninstall` shell-out vers `/usr/bin/security` (process
Apple-signé, exécute l'opération sous sa propre identité ⇒ insensible à la
signature de notre binaire ; robuste au split dev `adhoc` / prod Developer-ID) :

- install : `security add-trusted-cert -r trustRoot -k <login.keychain-db> <pem>`.
  Les flags sont **load-bearing** : `-r trustRoot` marque le root de confiance ;
  `-k <login keychain>` est requis pour que le trust setting **persiste** (une
  invocation sans `-k` a été observée renvoyant succès mais sans écrire).
- uninstall : `security remove-trusted-cert <pem>`.

Le système présente lui-même le panneau d'auth (mot de passe login) ; l'appel
**bloque** et **exige une session GUI** (le subprocess `security` doit pouvoir
présenter l'UI dans la session de l'utilisateur). ⇒ l'install/uninstall réels
sont du **smoke manuel lancé par l'utilisateur**, pas du test CI. Pas d'escaping
shell : on passe un vecteur d'arguments à `Process`, pas une ligne de commande.

## 4. Composants

### 4.1 `Sources/IrisKit/CA/CATrustStore.swift` (étendu)

On étend l'enum-namespace existant (cohésion : toute la logique trust-domain en
un seul fichier). Séparation pure / effectful pour la testabilité :

- `static func addTrustedCertArguments(pemPath:loginKeychainPath:) -> [String]`
  et `static func removeTrustedCertArguments(pemPath:) -> [String]` — **purs**,
  CI-testables. Construisent le vecteur d'arguments `/usr/bin/security` (flags
  load-bearing verrouillés par test).
- `static func install(pemPath: String) throws` / `uninstall(pemPath: String) throws`
  — **effectful** : `runSecurity(...)` spawn `/usr/bin/security` via `Process`
  (vecteur d'args, pas de shell). Smoke manuel.
- `private static func runSecurity(_:)` — spawn + `waitUntilExit` + mapping de
  l'échec.

Mapping d'erreur : nouveau cas `CAError.trustCommandFailed(status: Int32, message: String)`
(exit code ≠ 0 de `security` + stderr).

### 4.2 `Sources/iris/Commands/CACommands.swift` (étendu)

Deux sous-commandes calquées sur `Export` / `IsTrusted` existantes, ajoutées à
`subcommands:` de `CACommand` :

- `Install` (`commandName: "install"`)
- `Uninstall` (`commandName: "uninstall"`)

Chacune avec `@OptionGroup var connection: ConnectionOptions` et
`@Flag(--json)`.

## 5. Surface CLI & comportement

### `iris ca install [--json]`

1. Appel RPC `ca.is_trusted`. Si `trusted == true` ⇒ affiche
   `already trusted`, exit `0`, **aucun prompt** (idempotent ; évite une
   authentification inutile).
2. Sinon : RPC `ca.export_path` → `CATrustStore.install(pemPath:)` (passe le
   chemin du PEM à `security add-trusted-cert`). Le système prompte (mot de
   passe login). Succès ⇒ `CA installed in user trust store`.

### `iris ca uninstall [--json]`

Symétrique : si `ca.is_trusted == false` ⇒ `not installed`, exit `0`. Sinon
RPC `ca.export_path` → `CATrustStore.uninstall(pemPath:)` ⇒
`CA removed from user trust store`.

### Invariants transverses

- **Aucun changement de protocole RPC.** Réutilise `ca.export_path` +
  `ca.is_trusted` (déjà exposés). Le daemon **n'installe jamais** : pas d'auth
  GUI depuis un LaunchAgent en arrière-plan. C'est le process CLI (et plus tard
  l'app 6.3, en appelant directement `CATrustStore.install`) qui déclenche
  l'installation dans la session GUI de l'utilisateur.
- Sortie `--json` via `Output.ack` (ack `{ok, message}`) pour les succès/no-op,
  cohérent avec les autres sous-commandes `ca`.
- Exit codes : `success` 0 ; échec/annulation de l'auth (`security` exit ≠ 0) →
  message stderr explicite + `ioError` (3).

## 6. Tests & vérification

### Unit (CI, headless)

- `addTrustedCertArguments(pemPath:loginKeychainPath:)` ⇒ vecteur exact
  `["add-trusted-cert", "-r", "trustRoot", "-k", <login>, <pem>]` (verrouille les
  flags load-bearing).
- `removeTrustedCertArguments(pemPath:)` ⇒ `["remove-trusted-cert", <pem>]`.

> Les appels `install`/`uninstall` réels (qui spawn `security`) ne sont **pas**
> testés en CI : ils exigent une session GUI et un panneau d'authentification
> (cf §3). C'est assumé et documenté ; couvert par le smoke manuel.

### Smoke manuel (poste — checklist PR)

- [ ] `iris ca install` → panneau d'auth login → succès.
- [ ] `iris ca is-trusted` bascule `trusted`.
- [ ] CA visible dans Keychain Access (login) marquée « always trust ».
- [ ] `curl https://<host-mitm>` via le proxy ne signale plus d'erreur de cert.
- [ ] 2ᵉ `iris ca install` ⇒ `already trusted`, **aucun prompt** (idempotence).
- [ ] `iris ca uninstall` → `iris ca is-trusted` repasse `not trusted`.

## 7. Hors-scope (non-goals)

- ACL Keychain `SecAccess` (secrets + clé CA) → **Phase 8b**.
- Domaine admin/système → tranché : `.user` uniquement.
- Bouton « Install CA » dans l'app menu-bar → **Phase 6.3** (réutilisera
  `CATrustStore.install`).
- Gestion des variables d'env `NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE` /
  `CURL_CA_BUNDLE` → déjà documentée dans le README ; `claude`/node passe par
  l'env-var, pas par le trust store.
