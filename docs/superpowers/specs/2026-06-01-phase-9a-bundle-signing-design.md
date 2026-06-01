# Phase 9a — Assemblage bundle & signature Developer ID

> Produire un `Iris.app` signé Developer ID + hardened runtime, avec `irisd`
> embarqué et le plist LaunchAgent en place, plus la structure de packaging
> (`build-pkg.sh` jusqu'à un `.pkg` signé, `notarize.sh` en squelette).
> Aucune notarisation réelle, aucun auto-start.
> Source SPECS : §18 (build pipeline + postinstall), §17 (LaunchAgent/plist),
> §20 (arborescence projet). Objectif G6 (« single signed and notarized `.pkg` »).

## 1. Objectif et portée

La Phase 9a établit le **pivot de distribution** dont toutes les phases restantes
dépendent : une identité de signature stable et un bundle correctement structuré.
Elle transforme l'app « harnais de dev » en un `Iris.app` signé, embarquant le
daemon, et fournit l'ossature de packaging — sans encore notariser ni démarrer
automatiquement quoi que ce soit.

**Dans le périmètre :**
- `Iris.app` complet : `Contents/MacOS/Iris` (app) + `Contents/MacOS/irisd` (daemon)
  + `Contents/Library/LaunchAgents/io.iris.daemon.plist`.
- Chaîne de signature **inner-first** (irisd puis bundle), Developer ID Application
  + hardened runtime, vérifiable localement.
- `packaging/build-pkg.sh` exécutable jusqu'à `Iris.pkg` signé (Developer ID Installer).
- `packaging/notarize.sh` + `packaging/scripts/{preinstall,postinstall}` créés.

**Hors périmètre (frontières explicites) :**
- ❌ `SMAppService.*.register()` → **Phase 7**. En 9a on ne fait que *déposer le
  fichier plist* dans le bundle ; on ne l'enregistre pas. Le daemon ne démarre
  pas automatiquement.
- ❌ Notarisation réelle (`notarytool submit`) + stapling → **Phase 9b**.
- ❌ ACL Keychain → **Phase 8** (mais 9a fournit l'identité signée stable dont
  l'ACL aura besoin — cf SPECS §12.3).
- ❌ Onglet Settings / bouton « Install CA » → Phase 6.3.

**Conséquence à acter :** le `.pkg` de 9a installe l'app dans `/Applications` mais
**ne démarre rien automatiquement**. Le `postinstall` de la spec (§18.2) appelle
`open -a Iris.app --args --first-launch`, or la gestion de `--first-launch`
(génération CA, registration, prompt CA) n'existe pas encore (Phase 6.3/7). En 9a,
`postinstall` est donc un **squelette inerte** (création du dossier
`Application Support` seulement).

## 2. Décisions de design

### 2.1 — Route de build : `xcodebuild archive` + orchestration par script (approche ①)

La spec §18.1 prescrit `xcodebuild archive → export → codesign → productbuild →
notarytool`. On retient l'**orchestration par script** : `xcodebuild` produit le
`.app`, puis `packaging/build-pkg.sh` build `irisd` via SwiftPM, l'embarque, signe
inner-first, et produit le `.pkg`.

Rejeté :
- **Phase « Run Script » Xcode** (build de `irisd` imbriqué dans la cible app) :
  fragile (working-dir, config, builds incrémentaux), et **impacterait le gate CI
  macos-15** qui buildrait alors `irisd` dans l'app.
- **`irisd` en cible Xcode native** : duplique la définition de la cible et de ses
  dépendances (SwiftPM **et** Xcode), viole la source unique, risque de dérive.

`irisd` reste donc buildé par SwiftPM (source unique, comme le CI) et **n'est pas
référencé** dans le `.pbxproj`.

### 2.2 — Signature inner-first (déviation assumée de `--deep`)

La spec §18.1 écrit `codesign --force --deep`. La doc Apple **« Creating
distribution-signed code for macOS »** a une section explicite *« Avoid deep code
signing »* : `--deep` applique les mêmes options à tous les items (or app et `irisd`
peuvent différer) et ne signe pas le code dans les emplacements non-standard. On
signe donc explicitement, **de l'intérieur vers l'extérieur** : **`irisd` d'abord**
(`-o runtime`, et `-i io.iris.daemon` car c'est du code non-bundle), **puis le
bundle** (re-scelle CodeResources, qui couvre `irisd` signé + le plist).

`--deep` reste utilisé pour la **vérification** (`codesign --verify --deep
--strict`), usage légitime.

> Les flags `codesign` exacts et le contenu des entitlements seront **vérifiés
> contre la doc Apple via sosumi au moment du plan d'implémentation** — ce design
> fige la *séquence*, pas le détail de chaque option (cf §7).

### 2.3 — Distribution `.pkg`, pas `.dmg`

SPECS (source de vérité) et README disent `.pkg` ; seul `docs/design-assets.md`
mentionne `.dmg` (et se contredit : « *si* distribution `.dmg` »). Le choix est
**architectural** : un `.pkg` exécute les scripts `preinstall`/`postinstall` dont
la spec §18.2 dépend (`open -a Iris.app --args --first-launch`) ; un `.dmg` ne peut
rien exécuter (drag-and-drop pur). On reste donc sur `.pkg`.

> Nettoyage doc à faire **séparément** (hors 9a, Rule 3) : corriger la mention
> `.dmg` de `docs/design-assets.md`.

### 2.4 — `.pbxproj` CI-safe : Developer ID appliqué par le script

Le CI macos-15 (seul juge des changements IrisApp) fait un `xcodebuild` **sans
certs Developer ID**. On **ne fige donc PAS d'identité Developer ID dans la config
Release partagée** du `.pbxproj`, sous peine de casser le build CI (identité
introuvable).

**Principe :** le `.pbxproj` reste CI-safe (au minimum la phase Copy Files du
plist). La signature Developer ID + hardened runtime + entitlements sont appliqués
par `build-pkg.sh` (via `exportOptions.plist` méthode `developer-id` et les
`codesign --options runtime --entitlements` explicites). Le détail (style de
signature, ce qui va dans le projet vs le script) est tranché au plan **et validé
sur le CI, pas en local** (toolchain locale ≠ oracle du gate).

### 2.5 — `postinstall` inerte

Pas de câblage `--first-launch` tant que l'app ne gère pas ce flag (YAGNI : ne pas
brancher un trigger ignoré). `postinstall` se limite à créer
`~/Library/Application Support/iris`. `preinstall` = `exit 0`.

## 3. Architecture

### 3.1 Fichiers créés / modifiés

**Créés :**

| Fichier | Rôle |
|---|---|
| `IrisApp/IrisApp/io.iris.daemon.plist` | Plist LaunchAgent (contenu = §17.2). Embarqué via phase **Copy Files** Xcode (destination *Wrapper*, sous-chemin `Library/LaunchAgents/`). Fichier seulement, pas d'enregistrement. |
| _(pas de fichier entitlements en 9a)_ | **Vérifié contre Apple** (« Creating distribution-signed code for macOS ») : app **non sandboxée**, aucun entitlement restreint (`keychain-access-groups` = Phase 8), réseau autorisé par défaut sous HR. Le hardened runtime vient de `-o runtime` à la signature, **pas** d'un fichier. On n'en crée donc aucun (YAGNI) ; si le smoke runtime révèle un blocage, on ajoutera. |
| `packaging/build-pkg.sh` | Orchestration ① (cf §3.2). |
| `packaging/notarize.sh` | **Squelette** : `notarytool submit --wait` + `stapler staple` + `spctl --assess`. Non exécuté en 9a. |
| `packaging/scripts/postinstall` | **Squelette inerte** : crée `~/Library/Application Support/iris`. |
| `packaging/scripts/preinstall` | **Squelette minimal** : `exit 0`. |
| `packaging/exportOptions.plist` | Requis par `xcodebuild -exportArchive` (méthode `developer-id`, équipe, identité). |

**Modifiés :**

| Fichier | Changement |
|---|---|
| `IrisApp/IrisApp.xcodeproj/project.pbxproj` | **Uniquement** la phase **Copy Files** du plist (CI-safe : aucun cert requis pour un simple build). Aucune identité Developer ID ni hardened runtime figés dans la config partagée — la signature + `-o runtime` sont appliqués par `build-pkg.sh` (overrides `xcodebuild` + `codesign` manuel, §2.4). |

Deux invariants :
1. `irisd` n'est **pas** une cible Xcode (§2.1) → absent du `.pbxproj`.
2. Layout réel suivi (projet plat `IrisApp/IrisApp/…`), pas l'arbre idéalisé de
   SPECS §20 (Rule 11).

### 3.2 Flux build & signature (`build-pkg.sh`, inner-first)

```
0. PRÉCONDITIONS (fail-fast)
   • security find-identity -v -p codesigning → présence des 2 identités
     "Developer ID Application" + "Developer ID Installer", sinon exit ≠ 0 + message
   • Team ID défini, dossier build/ propre

1. BUILD irisd (SwiftPM)
   swift build -c release --product irisd            → .build/release/irisd

2. ARCHIVE app (Xcode)
   xcodebuild archive -project IrisApp/IrisApp.xcodeproj -scheme IrisApp \
     -configuration Release -archivePath build/Iris.xcarchive
   → app archivée contient DÉJÀ le plist (Copy Files), PAS encore irisd

3. EXPORT
   xcodebuild -exportArchive -archivePath build/Iris.xcarchive \
     -exportOptionsPlist packaging/exportOptions.plist -exportPath build/export
   → build/export/Iris.app (signée par l'export, SANS irisd)

4. EMBED (ditto, pas cp — préserve la structure de code, recommandé Apple)
   ditto .build/release/irisd build/export/Iris.app/Contents/MacOS/irisd

5. SIGNATURE INNER-FIRST (pas de --deep ; jamais sous sudo)
   a. irisd D'ABORD (code non-bundle → -i obligatoire ; aucun entitlements) :
      codesign -s "Developer ID Application" -f --timestamp -o runtime \
        -i io.iris.daemon \
        build/export/Iris.app/Contents/MacOS/irisd
   b. le BUNDLE ENSUITE (re-scelle CodeResources → couvre irisd + plist) :
      codesign -s "Developer ID Application" -f --timestamp -o runtime \
        build/export/Iris.app

6. VÉRIF signature (--deep légitime ici = vérification)
   codesign --verify --deep --strict --verbose=2 build/export/Iris.app

7. PKG signé
   productbuild --component build/export/Iris.app /Applications \
     --scripts packaging/scripts \
     --sign "Developer ID Installer: … (TEAM)" --timestamp \
     build/Iris.pkg

8. VÉRIF pkg
   pkgutil --check-signature build/Iris.pkg
   → build/Iris.pkg (signé, NON notarisé → notarize.sh prend le relais en 9b)
```

Subtilités load-bearing :
- **5a avant 5b** : le sceau du bundle référence la signature de `irisd` ; il faut
  que `irisd` soit déjà signé.
- **`--force` sur le bundle (5b)** re-signe le binaire principal + re-scelle les
  ressources, mais ne descend pas dans les helpers → d'où la signature séparée de
  `irisd` en 5a (et non `--deep`). La signature posée à l'export est supersédée.
- **`--options runtime` + `--timestamp` dès maintenant** → le `.pkg` 9a est
  *notarization-ready*, la Phase 9b n'aura qu'à soumettre.

### 3.3 Structure du bundle cible

```
Iris.app/
└── Contents/
    ├── MacOS/
    │   ├── Iris            (app, signée Developer ID)
    │   └── irisd           (daemon SwiftPM embarqué, signé inner-first)
    ├── Library/
    │   └── LaunchAgents/
    │       └── io.iris.daemon.plist   (BundleProgram = Contents/MacOS/irisd)
    ├── Resources/
    └── Info.plist          (LSUIElement = true, héritage Phase 6.1 — à confirmer)
```

## 4. Edge cases et error handling

- **Fail-fast** : `set -euo pipefail` ; chaque `xcodebuild`/`codesign`/`productbuild`
  vérifié, exit ≠ 0 propagé avec contexte. **Aucun fallback ad-hoc silencieux** si
  les identités Developer ID manquent (signer ad-hoc produirait un artefact
  inutilisable en simulant un succès — interdit).
- **`build/` nettoyé au démarrage** : évite qu'un vieux `irisd` ou une archive
  périmée contamine le bundle.
- **Embed→re-sign load-bearing** : oublier 5b après 4 → sceau CodeResources
  incomplet → `codesign --verify` échoue (« sealed resource missing/invalid »).
- **`--timestamp` exige le réseau** (serveur d'horodatage Apple) ; offline → échec.
  Pas un fallback : requis pour la notarisation 9b.
- **`exportOptions.plist` méthode = `developer-id`** (ni `app-store` ni
  `mac-application`).
- **Scripts exécutables** : `chmod +x packaging/scripts/{preinstall,postinstall}`
  sinon `productbuild` ne les exécute pas.
- **Désambiguïsation d'identité** : `codesign --sign` matche par sous-chaîne ;
  utiliser la chaîne complète ou le hash SHA-1 si plusieurs identités matchent.
- **DerivedData périmé** : `xcodebuild clean` ou `-derivedDataPath` dédié avant
  l'archive.
- **`irisd` statiquement lié** (produits SwiftPM) → pas besoin de
  `disable-library-validation`. Confirmer l'absence de `dlopen` runtime.

## 5. Testing strategy

9a est de l'infra build/signature : **aucune logique Swift métier nouvelle → pas de
tests unitaires** (Rule 9). La preuve passe par des vérifications reproductibles,
qui alimentent la checklist smoke-test de la PR (CLAUDE.md §8).

### 5.1 Vérifications

**Structurelle** (après `build-pkg.sh`) :
- `irisd` présent dans `Iris.app/Contents/MacOS/irisd`.
- Plist dans `Contents/Library/LaunchAgents/io.iris.daemon.plist` ; `plutil -lint`
  OK ; contenu == §17.2.

**Signature :**
- `codesign --verify --deep --strict --verbose=2 Iris.app` → valide, `irisd`
  reconnu comme code imbriqué signé.
- `codesign -dvvv Contents/MacOS/irisd` et `… Iris.app` → identité Developer ID
  Application, flag **runtime**, **timestamp** présent.
- `pkgutil --check-signature Iris.pkg` → Developer ID Installer, signé.
- ⚠️ **Non-pass attendu** : `spctl --assess --type execute Iris.app` → **rejeté**
  (« notarization required »). Correct en 9a ; passera après 9b. `codesign --verify`
  valide la *signature*, pas la politique Gatekeeper.

**Smoke runtime** (preuve « démontrable » CLAUDE.md §12) :
- Lancer le `irisd` embarqué : `Iris.app/Contents/MacOS/irisd --foreground`.
- Confirmer : démarre (n'est pas tué par le hardened runtime → signature +
  entitlements cohérents), bind sa socket Unix `0600`, log son démarrage.
- Connecter le `iris` CLI → un RPC basique (status/overview) round-trip.
- **Portée honnête (Rule 4)** : validé **sur la machine de build** (qui fait
  confiance à sa propre signature Developer ID). Ne prouve pas le lancement sur une
  machine tierce/propre — ça, c'est la notarisation (9b).

### 5.2 CI

Le gate `xcodebuild` macos-15 reste **inchangé** (build non-signé). Les changements
`.pbxproj` (§2.4) doivent **ne pas casser** ce gate (pas de Developer ID dans la
config partagée). **Validation sur le CI obligatoire** — la toolchain locale n'est
pas l'oracle du gate. `build-pkg.sh` tourne en local uniquement (certs Developer ID).

### 5.3 Smoke checklist PR (cases à cocher avant merge)

- [ ] `build-pkg.sh` s'exécute jusqu'au bout et produit `build/Iris.pkg`.
- [ ] `irisd` présent dans `Contents/MacOS/` ; plist présent + `plutil -lint` OK.
- [ ] `codesign --verify --deep --strict Iris.app` → valide.
- [ ] `codesign -dvvv` sur app **et** irisd → Developer ID + runtime + timestamp.
- [ ] `pkgutil --check-signature Iris.pkg` → signé Developer ID Installer.
- [ ] `spctl --assess` → rejeté (attendu, non notarisé) — documenté comme normal.
- [ ] `irisd` embarqué lancé en `--foreground` : démarre, bind socket `0600`, le
      CLI s'y connecte (RPC round-trip).
- [ ] Gate CI `xcodebuild` macos-15 toujours vert (validé sur le CI).

## 6. Quality gates

- `swift build` + `swift test` verts (inchangés — pas de code Swift nouveau).
- `swift-format` propre.
- Gate CI `xcodebuild` macos-15 vert (le juge des changements IrisApp).
- Checklist §5.3 entièrement cochée.

## 7. Points à vérifier au plan (sosumi / doc Apple)

- Flags `codesign` exacts (inner-first, `--options runtime`, `--timestamp`).
- Contenu précis des entitlements `IrisApp.entitlements` et `irisd.entitlements`
  sous hardened runtime (probablement minimal).
- Forme exacte de `exportOptions.plist` (méthode `developer-id`, signingStyle).
- Répartition signature projet vs script (§2.4) — à confirmer **sur le CI**.

## 8. Limitations connues / différé explicite

- Pas de notarisation, pas de stapling → **Phase 9b**.
- Pas d'auto-start `SMAppService` → **Phase 7** (le plist est posé, pas enregistré).
- Pas d'ACL Keychain → **Phase 8** (9a fournit l'identité signée stable requise).
- Pas d'onglet Settings / « Install CA » → **Phase 6.3**.
- Le `.pkg` 9a n'est pas installable sans avertissement Gatekeeper sur une machine
  tierce (notarisation requise) ni testé en install réelle hors machine de build.
- Nettoyage doc séparé : mention `.dmg` de `docs/design-assets.md` à corriger
  (hors 9a).
