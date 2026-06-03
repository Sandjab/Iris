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
| Mécanisme | **API native `SecTrustSettings*`** | Voir §3. Non déprécié ; symétrique du chemin de lecture ; pas de subprocess ni d'escaping. |

## 3. Approche : `SecTrustSettings*` natif

`SecTrustSettingsSetTrustSettings(_:_:_:)` (doc Apple, vérifiée 2026-06-03) :
- Signature : `(SecCertificate, SecTrustSettingsDomain, CFTypeRef?) -> OSStatus`.
- **Non déprécié**, disponible macOS 10.0+.
- Passer `NULL` pour `trustSettingsDictOrArray` ⇒ « always trust this root
  certificate regardless of use » — exactement le cas d'une CA self-signed
  racine, en un seul appel.
- Pour le domaine `.user`, le système présente lui-même un panneau
  d'authentification (mot de passe login) ; l'appel **peut bloquer** en attente
  de saisie et **exige une session GUI** (impossible en headless). ⇒ l'appel
  réel est du **smoke manuel**, pas du test CI.

Uninstall : `SecTrustSettingsRemoveTrustSettings(_ cert:_ domain:)` (domaine
`.user`) — supprime le réglage de confiance (le cert n'apparaît plus dans
`SecTrustSettingsCopyCertificates(.user)`).

### Pourquoi pas le shell-out à `/usr/bin/security`

SPECS §11.3 proposait `security add-trusted-cert` comme « simplest path », mais
**sous l'hypothèse domaine admin + élévation `osascript`** (`do shell script
with administrator privileges`). En domaine `.user`, l'API native est plus
simple (zéro subprocess, zéro escaping de chemin, zéro surface d'injection
shell), non dépréciée, et réutilise le même framework que la lecture. Le
shell-out reste un repli possible si l'on veut coller au mécanisme littéral de
la spec, mais il n'apporte rien ici.

## 4. Composants

### 4.1 `Sources/IrisKit/CA/CATrustStore.swift` (étendu)

On étend l'enum-namespace existant (cohésion : toute la logique trust-domain en
un seul fichier). Séparation pure / effectful pour la testabilité :

- `static func makeCertificate(fromPEM pem: String) throws -> SecCertificate`
  — **pur**, testable. Parse le PEM → DER → `SecCertificateCreateWithData`.
  Throw si PEM invalide / vide / non-certificat.
- `static func install(_ cert: SecCertificate) throws`
  — **effectful** (`SecTrustSettingsSetTrustSettings(cert, .user, nil)`). Smoke.
- `static func uninstall(_ cert: SecCertificate) throws`
  — **effectful** (`SecTrustSettingsRemoveTrustSettings(cert, .user)`). Smoke.

Mapping d'erreur : nouveau cas `CAError.trustSettingsFailed(OSStatus)` (inclut
l'annulation utilisateur `errSecUserCanceled` et autres OSStatus ≠
`errSecSuccess`).

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
2. Sinon : RPC `ca.export_path` → lit le PEM du chemin retourné →
   `CATrustStore.makeCertificate(fromPEM:)` → `CATrustStore.install(_:)`. Le
   système prompte (mot de passe login). Succès ⇒
   `CA installed in user trust store`.

### `iris ca uninstall [--json]`

Symétrique : si `ca.is_trusted == false` ⇒ `not installed`, exit `0`. Sinon
charge le cert et `CATrustStore.uninstall(_:)` ⇒ `CA removed from user trust store`.

### Invariants transverses

- **Aucun changement de protocole RPC.** Réutilise `ca.export_path` +
  `ca.is_trusted` (déjà exposés). Le daemon **n'installe jamais** : pas d'auth
  GUI depuis un LaunchAgent en arrière-plan. C'est le process CLI (et plus tard
  l'app 6.3, en appelant directement `CATrustStore.install`) qui déclenche
  l'installation dans la session GUI de l'utilisateur.
- Sortie `--json` via `Output.ack` (ack `{ok, message}`) pour les succès/no-op,
  cohérent avec les autres sous-commandes `ca`.
- Exit codes : `success` 0 ; échec/annulation de l'auth (OSStatus ≠ 0) →
  message stderr explicite + `ioError` (3).

## 6. Tests & vérification

### Unit (CI, headless)

- `makeCertificate(fromPEM:)` :
  - PEM CA valide (généré via `CAManager` + `InMemoryCAKeyStore`) ⇒ cert non-nil
    dont la `SecCertificateCopyData` correspond au DER attendu.
  - PEM vide / tronqué / non-certificat ⇒ throw `CAError`.
- Mapping `CAError.trustSettingsFailed` (OSStatus ≠ success → erreur typée).

> Les appels `install`/`uninstall` réels ne sont **pas** testés en CI : ils
> exigent une session GUI et un panneau d'authentification (cf §3). C'est
> assumé et documenté ; couvert par le smoke manuel.

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
