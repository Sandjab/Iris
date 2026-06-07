# Design — Compléter l'installation (CLI `iris` + config terminal)

> Date : 2026-06-07
> Statut : design validé (brainstorming), à transformer en plan d'implémentation.
> Branche : `feat/install-completion`

## 1. Contexte et problème

La documentation utilisateur (`docs/user-guide.md §3/§4.1`) et les écrans de l'installeur
(`packaging/installer/resources/*/readme.html`, `conclusion.html`) **promettent une topologie
d'installation que l'implémentation ne réalise pas** :

| Élément | Doc/installeur promettent | Implémentation réelle |
|---|---|---|
| CLI `iris` | `/usr/local/bin/` | **nulle part** (jamais livré par le `.pkg`) |
| `irisd` | `/usr/local/libexec/` | embarqué dans `Iris.app/Contents/MacOS/` |
| LaunchAgent | `~/Library/LaunchAgents/` + `launchctl bootstrap` | plist **dans le bundle**, via **SMAppService** |
| Config terminal | « patch automatique de `~/.zshrc` » | **aucun code ne patche le shell** (manuel) |
| `Iris.app` | `/Applications/` | `/Applications/` ✅ |

Conséquences directes :
- `iris ca install` (suggéré par `conclusion.html`) ne peut pas marcher pour un utilisateur
  final : le binaire n'existe nulle part.
- Le trafic CLI n'est jamais intercepté tant que l'utilisateur n'a pas ajouté **à la main** les
  variables d'environnement — alors que l'installeur affirme que c'est automatique.

Cette incohérence bloque la conception d'une désinstallation propre (on ne peut pas nettoyer ce
qui n'a pas été posé de façon connue). **Décision produit prise** : aligner l'implémentation sur la
doc **là où c'est possible** (CLI + config terminal), et **corriger la doc** là où c'est
impossible (irisd / launchctl).

### Contrainte dure (non négociable)

La **Phase 7 (mergée, `e9eefaf`)** utilise **SMAppService**, qui **exige** que `irisd` et son
plist vivent **dans le bundle**. `CLAUDE.md §4` impose SMAppService et interdit `launchctl`/
`SMJobBless`. Aligner `irisd`/`launchctl` sur la doc reviendrait à **défaire la Phase 7** : c'est
**hors-scope**. Ces passages de la doc seront **corrigés**, pas implémentés.

## 2. Périmètre

Ce design couvre **uniquement** le « temps 1 » : compléter l'installation. La désinstallation
(bouton in-app + script de secours) fait l'objet d'un design séparé (« temps 2 »), qui consommera
les acquis d'ici (CLI survivant + bloc shell balisé retirable).

**Dans le scope :**
- A. Livrer réellement la commande `iris` dans `/usr/local/bin/`.
- B. Configurer le terminal automatiquement, **après consentement explicite**, de façon réversible.
- C. Corriger la doc et les écrans d'installeur sur les points faux.

**Hors-scope (YAGNI) :**
- Shells autres que `zsh` (bash/fish) — ajoutables plus tard si besoin.
- Déplacement de `irisd` hors du bundle / retour à `launchctl` (casserait la Phase 7).
- Toute la désinstallation (temps 2).

## 3. Décisions

1. **CLI = vraie copie** dans `/usr/local/bin/iris`, **pas un symlink** vers le bundle : la
   commande doit **survivre au drag-to-trash** de l'app (prérequis de la désinstallation de
   secours du temps 2).
2. **Livraison par un composant `.pkg` dédié** `io.iris.cli` (→ `/usr/local/bin/`), distinct du
   composant app. Évite un doublon du binaire dans le bundle, et enregistre un receipt
   `pkgutil` propre.
3. **Config terminal avec consentement** : au 1er lancement, l'app **montre** le bloc et **demande
   l'accord** avant d'écrire. Rien n'est modifié dans le dos de l'utilisateur (`Rule 1`, respect du
   fichier perso).
4. **Bloc balisé et idempotent** : les lignes sont encadrées par des marqueurs
   `# >>> iris >>>` … `# <<< iris <<<`. Réappliquer met à jour le bloc sans le dupliquer. La
   désinstallation (temps 2) retirera exactement ce bloc, sans toucher au reste du fichier.
5. **Variables exportées** — exactement **deux**, valeurs tirées des défauts de config
   (`Config.swift:38`) :
   ```bash
   # >>> iris >>>
   export HTTPS_PROXY=http://127.0.0.1:8888
   export NODE_EXTRA_CA_CERTS="$HOME/Library/Application Support/iris/ca.pem"
   # <<< iris <<<
   ```
   **⚠️ Correction post-revue (ne PAS ré-ajouter `SSL_CERT_FILE` ni `HTTP_PROXY`).** Une version
   antérieure de ce spec listait les 4 variables que `iris doctor` vérifiait (`DoctorCommand.swift:109`).
   C'était une **erreur** : IRIS fait un MITM **sélectif** (SPECS §8.3 ; `ConnectHandler`/`GlueHandler`
   tunnellisent sans déchiffrer les hosts non whitelistés, qui gardent leur **vrai** certificat).
   `SSL_CERT_FILE` **remplace** tout le bundle CA d'OpenSSL (Python/curl/Ruby) par la seule CA d'IRIS
   → casserait la validation TLS de tout host tunnelé. `NODE_EXTRA_CA_CERTS` ne fait qu'**ajouter**,
   donc reste sûr. `HTTP_PROXY` est omis (design HTTPS-only, conforme à la doc d'origine §4.2).
   `DoctorCommand.swift:109` a été corrigé pour ne vérifier que ces 2 variables.
6. **Cible shell** : `zsh` → `~/.zshrc` (défaut macOS). Autres shells hors-scope MVP.
7. **Double surface, sans popup automatique** : le consentement passe par (a) la commande
   `iris shell install` **interactive** (affiche le bloc, demande O/N avant d'écrire ; `--yes`
   pour sauter) et (b) un bouton « Configurer le terminal » dans l'onglet Settings (montre le bloc
   puis applique sur clic). **Pas** de fenêtre modale déclenchée au 1er lancement : l'app est
   lancée en arrière-plan par l'installeur, un modal y serait fragile. La même logique sera
   réutilisée par la désinstallation.

## 4. Architecture et composants

### 4.1 `ShellProfileConfigurator` (IrisKit) — cœur testable

Module sans dépendance UI, scindé en **logique pure** + **couche I/O** :

- **Logique pure (fonctions sur `String`)** :
  - `renderBlock() -> String` : construit le bloc balisé à partir des constantes (port, chemins).
  - `applyBlock(to content: String) -> String` : insère le bloc s'il est absent, le **remplace**
    entre marqueurs s'il est présent (idempotent).
  - `removeBlock(from content: String) -> String` : retire exactement le bloc entre marqueurs,
    laisse le reste intact ; no-op si absent.
  - `containsBlock(_ content: String) -> Bool`.
- **Couche I/O** : `install()` / `uninstall()` lisent `~/.zshrc` (créent si absent), appliquent la
  fonction pure, écrivent de façon atomique. Le chemin du fichier est **injectable** (test).

Bénéfice : toute la logique délicate (insertion/remplacement/retrait) est testée sans toucher au
vrai `~/.zshrc`.

### 4.2 Commande CLI `iris shell`

Nouvelle commande (cf. `Sources/iris/Commands/`), symétrique de `iris ca install/uninstall` :
- `iris shell install` : applique le bloc (affiche le diff, écrit).
- `iris shell uninstall` : retire le bloc.
- `iris shell status` : indique si le bloc est présent (utile pour `iris doctor` et la
  désinstallation).

S'appuie sur `ShellProfileConfigurator`. Pur (pas d'accès Keychain).

### 4.3 Bouton « Configurer le terminal » (IrisApp Settings)

Ajout dans l'onglet Settings (`SettingsTab.swift`), à côté de CA Install/Uninstall, suivant le même
pattern testable : un seam `ShellConfiguring` (réplique de `CATrustInstalling`) injecté, une action
sur `AppModel` (`Task.detached` hors main actor). Le bouton affiche le bloc à ajouter, puis applique
sur confirmation, et un libellé reflète l'état (présent/absent) via `ShellProfileConfigurator`.
**Pas** de popup au 1er lancement (cf. décision 7).

### 4.4 Packaging (`packaging/build-pkg.sh` + `Distribution.xml`)

- Builder `iris` : `swift build -c release --product iris`.
- **Signer** `iris` Developer ID Application (hardened runtime, `-i io.iris.cli`) — requis pour la
  notarisation ; **pas** d'entitlements, **pas** d'ACL Keychain (le CLI est pur RPC).
- `pkgbuild --root <staging>/usr/local/bin --install-location /usr/local/bin --identifier
  io.iris.cli …` → composant CLI.
- `Distribution.xml` : ajouter le `pkg-ref`/`choice` `io.iris.cli` au flux (invisible, installé par
  défaut comme le composant app).

### 4.5 Documentation corrigée

- `docs/user-guide.md §3` : `irisd` est dans le bundle (pas `/usr/local/libexec/`) ; démarrage via
  SMAppService (pas `launchctl bootstrap`) ; LaunchAgent dans le bundle. `iris` est bien dans
  `/usr/local/bin/`.
- `docs/user-guide.md §4.1` : la config terminal se fait **avec consentement** au 1er lancement
  (montrée puis appliquée), pas « patch automatique » silencieux.
- `packaging/installer/resources/*/conclusion.html` & `readme.html` : aligner sur le comportement
  réel (consentement ; mention `iris` valide).

## 5. Flux

**Installation (.pkg)** : l'installeur pose `Iris.app` dans `/Applications` **et** `iris` dans
`/usr/local/bin`. Aucun shell modifié à ce stade. L'écran de conclusion invite à lancer
`iris shell install`.

**Config terminal (au choix de l'utilisateur)** : soit `iris shell install` depuis le terminal
(affiche le bloc, demande O/N, écrit si accepté), soit le bouton « Configurer le terminal » dans
l'onglet Settings de l'app. Aucune écriture sans accord explicite. Message « ouvre une nouvelle
fenêtre de terminal » ensuite.

**Réparation / retrait** : `iris shell status` / `iris shell uninstall` depuis le terminal.

## 6. Gestion d'erreur

- `ShellProfileConfigurator` : écriture atomique (fichier temporaire + remplacement) ; si
  `~/.zshrc` absent, le créer ; jamais d'écriture partielle. Erreurs remontées (pas de silence,
  `CLAUDE.md` Rule 12).
- App : refus de l'utilisateur = état valide (pas d'erreur). Échec d'écriture = message clair +
  rappel de la commande CLI manuelle.
- Packaging : `build-pkg.sh` reste fail-fast (préconditions de signature déjà en place).

## 7. Tests

- **Logique de bloc (pure, exhaustif)** : fichier vide → bloc ajouté ; fichier avec contenu → bloc
  ajouté en fin sans abîmer l'existant ; **idempotence** (réappliquer ne duplique pas) ; **mise à
  jour** (valeurs changées → bloc remplacé) ; **retrait** (enlève exactement le bloc, garde le
  reste) ; retrait quand absent → no-op ; contenu autour des marqueurs préservé.
- **CLI `iris shell`** : install/uninstall/status sur un fichier temporaire injecté.
- **Intent (Rule 9)** : un test asserte que le bloc rendu contient les 2 variables canoniques
  (`HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`) avec le port/chemin attendus, **et** des assertions
  négatives (`SSL_CERT_FILE`/`HTTP_PROXY` absents) → casse si une constante diverge ou si une
  variable dangereuse est ré-ajoutée.
- **Packaging** : non testable en unit → **smoke manuel au poste** : `.pkg` installe `iris` dans
  `/usr/local/bin` ; `iris` fonctionne ; `iris` **survit** au drag-to-trash de l'app.

## 8. Critères de réussite (smoke)

- [ ] Après install `.pkg`, `which iris` → `/usr/local/bin/iris` et `iris status` répond.
- [ ] `iris shell install` affiche le bloc et demande O/N ; réponse « non » → `~/.zshrc` intact.
- [ ] Accord (ou bouton Settings) → bloc présent dans `~/.zshrc` ; nouvelle fenêtre terminal → `iris doctor` voit les
      variables ; trafic `claude` intercepté.
- [ ] `iris shell install` deux fois de suite → pas de doublon.
- [ ] `iris shell uninstall` → bloc retiré, reste du `~/.zshrc` intact.
- [ ] Après drag-to-trash de l'app, `iris` répond encore (binaire indépendant).
- [ ] Doc et écrans installeur ne mentionnent plus `/usr/local/libexec` ni `launchctl bootstrap`.
