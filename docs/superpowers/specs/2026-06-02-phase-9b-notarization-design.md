# Phase 9b — Notarisation & stapling

> Soumettre le `build/Iris.pkg` signé (produit par la Phase 9a) au service de
> notarisation Apple, agrafer le ticket (`stapler`), et prouver que Gatekeeper
> l'accepte (`spctl --assess` → « accepted source=Notarized Developer ID »).
> Source SPECS : §18.1 (build pipeline, étapes `notarytool submit` / `stapler
> staple`). Objectif G6 (« single signed and **notarized** `.pkg` »).
> Pré-requis administratif : `docs/phase-9-notarization-prep.md` (11 cases cochées,
> profil keychain `iris-notary` valide, certs Developer ID en place).

## 1. Objectif et portée

La Phase 9a a livré un `.pkg` *notarization-ready* : signé Developer ID Installer,
l'app et `irisd` signés Developer ID Application sous **hardened runtime** avec
**timestamp**. La Phase 9b franchit la dernière étape de la chaîne de distribution :
faire valider ce pkg par Apple et y agrafer le ticket, de sorte qu'il s'installe
sans avertissement Gatekeeper sur une machine tierce.

**Dans le périmètre :**
- Enrichir `packaging/notarize.sh` (aujourd'hui un squelette) pour un flux robuste :
  soumission avec capture du *submission ID*, récupération **systématique** du log,
  gestion explicite d'un rejet, stapling, validation, `spctl`.
- **Exécution réelle** de la notarisation (`build-pkg.sh` → `notarize.sh`) pour
  produire un `.pkg` notarisé + stapled et capturer la preuve.

**Hors périmètre (frontières explicites) :**
- ❌ Entitlements / ACL Keychain → **Phase 8**. La notarisation valide la signature
  et le hardened runtime, **pas** les entitlements ; elle réussit sans fichier
  d'entitlements. L'accès Keychain de `irisd` sous hardened runtime relève de la
  Phase 8.
- ❌ Auto-start `SMAppService` → **Phase 7** (le plist est posé, pas enregistré).
- ❌ Onglet Settings / « Install CA » → **Phase 6.3**.
- ❌ Orchestrateur `release.sh` chaînant build + notarize → YAGNI (deux scripts
  séparés exécutés en séquence ; on l'ajoutera si un vrai pipeline de release le
  justifie).
- ❌ Install + lancement réels sur une **machine tierce vierge** → pas de 2ᵉ
  machine disponible. Limite honnête : la preuve réalisable est `spctl --assess`
  sur la machine de build *après* stapling (cf §5).

## 2. Décisions de design

### 2.1 — Deux scripts séparés, enrichir `notarize.sh` seul (approche A)

On conserve la frontière établie en 9a : `build-pkg.sh` produit le pkg signé
**hors-ligne** ; `notarize.sh` prend le relais pour la **soumission réseau**. Tout
le travail 9b est concentré dans `notarize.sh`.

Rejeté :
- **Fusionner la notarisation dans `build-pkg.sh`** : rend `build-pkg.sh`
  inutilisable hors-ligne, mélange deux responsabilités (assemblage/signature vs
  soumission Apple), casse la séparation 9a.
- **Orchestrateur `release.sh`** : ajoute un 3ᵉ script pour un gain mince tant qu'il
  n'y a pas de pipeline de release (YAGNI).

### 2.2 — Capture du submission ID via `plutil` natif (pas de `jq`)

`notarytool submit --wait --output-format json` émet un JSON contenant l'`id` et le
`status` final. On extrait ces champs avec `plutil` (présent sur tout macOS), **sans
ajouter `jq`** comme dépendance d'environnement. Cohérent avec CLAUDE.md (pas de
dépendance non justifiée) et avec un script qui doit tourner sur une machine de
build standard.

### 2.3 — Log récupéré systématiquement

`notarytool log <id>` est exécuté **dans tous les cas** (succès comme échec) et
sauvegardé dans `build/notarization-log.json`. Le doc de prep §6 le souligne : le
log peut contenir des *warnings* même quand le statut est `Accepted`. En cas de
rejet, ce log est la seule source de diagnostic.

### 2.4 — Échec loud sur rejet, jamais de staple d'un pkg rejeté

Si le statut final ≠ `Accepted`, le script affiche le log et sort en `exit ≠ 0`
**avant** toute tentative de stapling. Agrafer un ticket sur un pkg rejeté est
impossible de toute façon ; l'objectif est de **ne pas masquer l'échec** (CLAUDE.md
§12, « fail loud »).

## 3. Architecture

### 3.1 Fichiers créés / modifiés

**Modifiés :**

| Fichier | Changement |
|---|---|
| `packaging/notarize.sh` | Passe du squelette au flux robuste complet (cf §3.2). |

**Invariants :**
1. **Zéro `.swift`, zéro `.pbxproj`** touché → le gate CI `xcodebuild` macos-15
   n'est pas affecté ; `swift build` / `swift test` / `swift-format` sont sans objet
   (comme en 9a). Le seul fichier modifié est un script bash.
2. `build/` est **gitignoré** → le `.pkg` notarisé, `notarization-submit.json` et
   `notarization-log.json` **ne sont pas commités**. La preuve d'exécution vit dans
   la description de PR (sorties collées + checklist smoke).

### 3.2 Flux de `notarize.sh` enrichi

```
0. PRÉCONDITIONS (fail-fast)
   • PKG (build/Iris.pkg par défaut, ou $1) existe, sinon exit ≠ 0
   • PROFILE = ${IRIS_NOTARY_PROFILE:-iris-notary}  (défaut déjà en place depuis #35)

1. SOUMISSION (bloquante, réseau)
   xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait \
     --output-format json  > build/notarization-submit.json

2. EXTRACTION id + status   (plutil natif, pas de jq)
   id     = plutil -extract id     raw build/notarization-submit.json
   status = plutil -extract status raw build/notarization-submit.json

3. LOG (TOUJOURS — succès comme échec)
   xcrun notarytool log "$id" --keychain-profile "$PROFILE" \
     build/notarization-log.json

4. GARDE-FOU
   si status ≠ "Accepted" :
     cat build/notarization-log.json   (diagnostic)
     exit ≠ 0                          (PAS de staple)

5. STAPLE
   xcrun stapler staple "$PKG"

6. VALIDATE
   xcrun stapler validate "$PKG"       → "The validate action worked!"

7. VÉRIF GATEKEEPER
   spctl --assess --type install -vv "$PKG"
     → attendu : "accepted source=Notarized Developer ID"
```

Subtilités load-bearing :
- **`--wait`** bloque jusqu'au verdict Apple (typiquement quelques minutes) ; sans
  lui, `submit` rend la main immédiatement et l'`id` ne reflète pas un statut final.
- **3 avant 4** : on récupère le log *avant* de décider de l'échec, pour qu'un rejet
  produise toujours un diagnostic exploitable.
- **`--type install`** (et non `--type execute`) : on évalue un **installeur** `.pkg`.

## 4. Edge cases et error handling

- **`set -euo pipefail`** (déjà présent) ; chaque commande `xcrun`/`spctl` vérifiée.
- **Rejet Apple (`Invalid`)** : log récupéré, affiché, `exit ≠ 0` (§2.4). Le débogage
  d'un rejet (corriger le binaire, re-signer, re-soumettre) est un sous-flux normal,
  pas une branche à coder a priori.
- **Réseau requis** : `submit` et le serveur d'horodatage Apple exigent une
  connexion. Offline → échec explicite, jamais de fallback silencieux.
- **Idempotence** : re-run sûr. Apple accepte une re-soumission du même pkg ;
  `stapler staple` est ré-applicable (remplace le ticket).
- **Sécurité (CLAUDE.md §6.1)** : aucune valeur sensible dans les sorties. Le log
  `notarytool` ne contient ni credentials ni secrets applicatifs ; le script ne
  dumpe ni le profil keychain, ni le `.p8`, ni le Team ID.
- **Team ID** : nécessaire uniquement à `build-pkg.sh` (`IRIS_TEAM_ID`).
  `notarize.sh` n'a besoin que du profil keychain (`iris-notary`). Le Team ID est
  passé en variable d'environnement au moment de l'exécution — **jamais commité**.

## 5. Testing strategy (démonstration)

9b est de l'infra de distribution : **aucune logique Swift nouvelle → pas de tests
unitaires** (Rule 9). La preuve passe par l'exécution réelle, qui alimente la
checklist smoke de la PR.

### 5.1 Séquence d'exécution réelle

1. `export IRIS_TEAM_ID=…` (Team ID Apple, non tracé dans l'historique partagé)
2. `./packaging/build-pkg.sh` → `build/Iris.pkg` signé
3. `./packaging/notarize.sh` → soumission (`--wait`) → staple → `spctl`
4. capture des sorties pour la PR

### 5.2 Portée honnête (Rule 4)

`spctl --assess` est exécuté sur la **machine de build**. Le delta démontrable vs 9a
est net : 9a rendait `rejected (the code is not signed / Unnotarized Developer ID)`,
9b doit rendre `accepted source=Notarized Developer ID`. L'installation et le
lancement sur une **machine tierce vierge** ne sont pas testés (pas de 2ᵉ machine) ;
le ticket agrafé est précisément ce qui permettra cette install sans réseau, mais sa
vérification cross-machine reste hors preuve.

### 5.3 Smoke checklist PR (cases à cocher avant merge)

- [ ] `bash -n packaging/notarize.sh` passe sans erreur.
- [ ] `build-pkg.sh` produit `build/Iris.pkg` signé Developer ID Installer.
- [ ] `notarytool submit --wait` → statut **`Accepted`**.
- [ ] `notarization-log.json` sans `issues` bloquantes (warnings tolérés et
      documentés).
- [ ] `stapler validate build/Iris.pkg` → valide.
- [ ] `spctl --assess --type install -vv build/Iris.pkg` →
      **`accepted source=Notarized Developer ID`** (le delta clé vs 9a).

## 6. Quality gates

- Gate CI `xcodebuild` macos-15 inchangé (aucun fichier de l'app touché — script
  bash uniquement).
- `swift build` / `swift test` / `swift-format` sans objet (zéro Swift modifié).
- Checklist §5.3 entièrement cochée.

## 7. Points à vérifier au plan (sosumi / doc Apple)

- **Quoi stapler** : le `.pkg` seul (hypothèse retenue : suffisant pour une
  distribution `.pkg`) vs aussi l'`.app` interne. Si la doc impose de stapler
  l'`.app` avant `productbuild`, cela **déborde sur `build-pkg.sh`** (re-build du pkg
  après staple) → revenir vers l'utilisateur avant d'élargir le scope (Rule 3).
  Sources : TN3147, « Customizing the notarization workflow ».
- **Flags exacts** `notarytool submit` / `log` ; clé d'extraction `plutil` de l'`id`
  et du `status` dans la sortie `--output-format json`.
- **Exit code** de `submit --wait` sur statut `Invalid` : déterminer si l'étape 4
  (garde-fou explicite) est redondante avec un exit ≠ 0 natif, ou nécessaire.

## 8. Limitations connues / différé explicite

- Pas d'entitlements / ACL Keychain → **Phase 8** (la notarisation 9b n'en a pas
  besoin ; le fonctionnement de `irisd` sur machine vierge sous hardened runtime en
  dépendra).
- Pas d'auto-start `SMAppService` → **Phase 7**.
- Pas d'onglet Settings / « Install CA » → **Phase 6.3**.
- Install + lancement sur machine tierce non testés (pas de 2ᵉ machine) — cf §5.2.
- ⚠️ **Gemini Code Assist (consumer) en fin de vie** (arrêt des reviews le
  17 juillet 2026, annoncé dans la review de la PR #35) : la procédure de polling
  Gemini de CLAUDE.md §8 deviendra caduque. Sans impact direct sur 9b, mais à garder
  en tête pour les PR de cette phase et des suivantes.
