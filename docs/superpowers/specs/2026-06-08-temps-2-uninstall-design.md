# TEMPS 2 — Désinstallation propre d'IRIS

> Spec de conception. Source de vérité pour le plan d'implémentation.
> Date : 2026-06-08. Branche : `feat/temps-2-uninstall`.
> Fait suite au TEMPS 1 (« compléter l'installation », PR #48 `a8163e5`).
> Réf. SPECS §17.3 / §18.3 (Uninstall), §10 (jamais de suppression silencieuse), §6 (sécurité).

---

## 1. Contexte & objectif

Le smoke du TEMPS 1 a prouvé que désinstaller IRIS à la main est **hostile** : le daemon `irisd`,
lancé depuis le bundle par launchd (SMAppService, Phase 7), **verrouille le bundle** → le
drag-to-trash est inopérant tant qu'on n'a pas fait `launchctl bootout` en ligne de commande ;
et sur macOS 26, Launchpad/App Library ne jette pas les apps tierces. Inacceptable pour le grand
public. La désinstallation propre est donc **in-scope avant la 1ʳᵉ release `1.0.0`**.

**Objectif** : fournir deux chemins de désinstallation complémentaires qui retirent toutes les
traces d'une installation propre, sans jamais supprimer les secrets de l'utilisateur sans son
consentement explicite (§10).

## 2. Non-objectifs (scope)

- **Pas de self-delete du bundle par l'app.** Conformément à SPECS §18.3 #5, on ouvre le Finder ;
  l'utilisateur jette l'app (ou le script le fait avec son mot de passe).
- **Pas de nettoyage des résidus de dev** (anciens bundle ids, CA régénérées multiples au-delà du
  trust store, DerivedData, containers d'anciens sandbox). Cela reste le rôle de
  `packaging/dev-uninstall.sh` (DEV ONLY, non distribué).
- **Pas de rotation/réparation de CA.** On retire, on ne régénère pas.
- **Pas de télémétrie ni de « phone-home »** à la désinstallation (§10 « Ce qu'il ne faut PAS faire »).

## 3. Architecture — deux chemins complémentaires

### Chemin nominal — bouton « Quit & Uninstall » (app)
L'app fait tout ce qui **ne nécessite pas de mot de passe admin** (ou seulement le panneau natif
macOS pour le trust store), puis ouvre le Finder et oriente vers le script pour le reste.

### Chemin de secours — script `uninstall.sh`
Couvre le **paquet protégé** (éléments possédés par `root`, exigeant `sudo`) **et** le cas
« app déjà jetée à la corbeille » (plus de bouton à cliquer). Déposé dans App Support (survit au
drag-to-trash) et versionné dans `packaging/scripts/`.

**Principe directeur** : le **daemon** est le seul à pouvoir toucher au Keychain sans déclencher de
prompts (ACL 8b : items liés au binaire `irisd` signé) ; l'**app** touche à ce qui vit dans le home
et au trust store (prompt admin natif) ; le **script** touche au paquet `root` (`sudo`) et finit le
ménage des fichiers. Le daemon ne touche **aucun fichier** : un seul responsable des fichiers
(le script), ce qui évite que le daemon efface le script de secours sous ses propres pieds.

## 4. Inventaire — qui retire quoi

| Cible | Identifiant | Qui | Comment |
|---|---|---|---|
| Secrets Keychain | service `io.iris.secret`, account = nom | **daemon** (RPC) | opt-in ; ACL 8b → 0 prompt tant qu'`irisd` vit |
| Clé privée CA | service `io.iris.ca`, account `privatekey` | **daemon** (RPC) | ACL 8b → 0 prompt |
| Cert CA (trust store) | CN `IRIS local CA` | **app** + **script** | `CATrustInstalling.uninstall` (1 prompt admin) / `security delete-certificate -Z` (sans panneau) |
| Bloc `~/.zshrc` | balises `# >>> iris >>>` … `# <<< iris <<<` | **app** + **script** | `ShellConfiguring.uninstall` / `sed` |
| Auto-start | SMAppService daemon + app login-item | **app** | `AutoStartControlling.unregister` ×2 |
| Configs MCP wrappées | `.iris.bak` listés dans le registre | **app** + **script** | `MCPPatcher.unwrap` / `cp`+`rm` en bash |
| CLI | `/usr/local/bin/iris` (root:wheel) | **script** | `sudo rm` |
| Bundle | `/Applications/Iris.app` (root:wheel) | **script** + Finder | `sudo rm` ou corbeille |
| Receipts | `io.iris.app`, `io.iris.cli` | **script** | `sudo pkgutil --forget` |
| App Support | `~/Library/Application Support/iris/` | **script** | `rm -rf` en dernier (self-suppression) |

## 5. Composant A — RPC daemon `admin.uninstall`

**`Sources/IrisKit/IPC/AdminProtocol.swift`**
- Nouveau case : `case adminUninstall = "admin.uninstall"`.
- Requête : `struct AdminUninstallRequest { let deleteSecrets: Bool }`
  (`CodingKeys`: `deleteSecrets = "delete_secrets"`).
- Réponse **value-free** : `struct AdminUninstallResult { let caKeyDeleted: Bool; let secretsDeleted: Int }`
  (`CodingKeys`: `ca_key_deleted`, `secrets_deleted`).

**`Sources/.../AdminDispatcher.swift`** (handler) :
1. Supprime la clé privée CA via le `SecretStore` injecté (service `io.iris.ca`, account `privatekey`).
   Absente → `caKeyDeleted = false`, pas d'erreur (idempotent).
2. Si `deleteSecrets` : `secretStore.list()` puis `delete` pour chaque secret. `secretsDeleted` = nombre
   effectivement supprimé. Si `false` : ne touche à aucun secret, `secretsDeleted = 0`.
3. Idempotent : un appel répété sur un trousseau déjà nettoyé renvoie `caKeyDeleted = false`, `secretsDeleted = 0`.
4. **Ne touche à aucun fichier** (ni `ca.pem`, ni `events.db`, ni `config.json`).
5. N'arrête pas le daemon : c'est `unregister()` côté app (étape suivante) qui le fait via launchd.

**Sécurité (§6)** : aucune valeur de secret n'apparaît dans la réponse ni les logs ; seuls des
comptes. Test de non-fuite obligatoire (dump de la réponse → aucune valeur).

## 6. Composant B — Orchestration du bouton (app)

**`IrisApp/IrisApp/SettingsTab.swift`** : bouton « Quit & Uninstall » (section dédiée de l'onglet
Settings). Affiche un dialog de confirmation :
- Texte : « Ceci va arrêter irisd, retirer le démarrage automatique, le certificat CA et la
  configuration du terminal. »
- **Checkbox « Supprimer aussi mes secrets du trousseau »**, décochée par défaut (§10).

**`Sources/IrisAppCore/AppModel.swift`** : méthode `uninstall(deleteSecrets:) async` qui orchestre,
via les seams existants, dans cet **ordre strict** :

1. **RPC `admin.uninstall(deleteSecrets:)`** (via `AdminClient`) — daemon vivant, ACL active → Keychain
   nettoyé sans prompt. **Cette étape vient en premier, toujours** : la faire après `unregister()`
   tuerait le daemon avant qu'il puisse nettoyer le Keychain sans prompts.
2. `CATrustInstalling.uninstall(pemPath:)` — retire le cert (1 prompt admin natif).
3. **MCP unwrap** — lit le registre (Composant C), restaure chaque entrée via `MCPPatcher.unwrap` ;
   skip + agrège les entrées périmées.
4. `ShellConfiguring.uninstall()` — retire le bloc `~/.zshrc`.
5. **`AutoStartControlling.unregister(.daemon)` puis `.unregister(.app)`** — arrête launchd +
   login-item, libère le verrou du bundle.
6. **Alerte finale bloquante** : récapitule ce qui a été fait, **liste ce qui a échoué** (le cas
   échéant), et indique ce qui reste (CLI + app exigent le mot de passe). Bouton **« Révéler
   uninstall.sh dans le Finder »** → `open -R "~/Library/Application Support/iris/uninstall.sh"`
   (à défaut, `open /Applications`). Puis quitte l'app (`NSApp.terminate`).

**Robustesse (Rule 12)** : chaque étape 1→5 est encapsulée pour qu'un échec (ex. prompt cert annulé,
daemon injoignable) n'interrompe pas les suivantes ; les erreurs sont **agrégées** et affichées à
l'étape 6. L'ordre RPC-avant-unregister est non négociable.

## 7. Composant C — Registre des wraps MCP

**Problème** : `iris mcp wrap <chemin>` patche un fichier arbitraire et pose un `.iris.bak` à côté ;
`iris mcp unwrap <chemin>` restaure depuis ce backup. Il n'existe **aucune liste** des fichiers
wrappés → la désinstallation ne sait pas où chercher. On introduit un registre.

**`Sources/IrisKit/MCPConfig/WrappedPathsRegistry.swift`** (nouveau) :
- Manifeste : `~/Library/Application Support/iris/wrapped-paths.json` — tableau JSON de chemins
  **absolus** (tilde-expandus), dédupliqué.
- API : `add(_ path: String)`, `remove(_ path: String)`, `list() -> [String]`. Création paresseuse du
  fichier ; absence = liste vide. Écriture atomique (`replaceItemAt`/move, cohérent `ConfigStore`).

**`Sources/IrisKit/MCPConfig/MCPPatcher.swift`** : extraire la logique d'« unwrap » aujourd'hui logée
dans `MCPCommands.Unwrap.run` vers une fonction réutilisable
`public static func unwrap(path: String) throws` (restaure le fichier depuis `<path>.iris.bak`,
supprime le `.bak`). La commande CLI `Unwrap` l'appelle ensuite (refactor chirurgical, comportement
inchangé côté CLI). L'app réutilise la même fonction.

**Branchements** :
- `iris mcp wrap` : après un patch réussi, `WrappedPathsRegistry.add(chemin absolu)`. En mode
  `--watch`, on n'ajoute qu'une fois (dédup).
- `iris mcp unwrap` : après restauration réussie, `WrappedPathsRegistry.remove(chemin)`.

**Staleness** : à la désinstallation, une entrée dont le fichier ou le `.iris.bak` a disparu est
**skippée et signalée** (jamais une erreur fatale).

## 8. Composant D — Script `uninstall.sh`

Source versionnée : **`packaging/scripts/uninstall.sh`** (dans le dossier embarqué par
`pkgbuild --scripts`, cf §9). Dérivé épuré de `packaging/dev-uninstall.sh`, restreint à une install
propre. Chaque section affiche d'abord ce qu'elle va faire, puis demande confirmation.

Sections (ordre) :
1. **Arrêter le daemon** — `launchctl bootout gui/$UID/io.iris.daemon` (sinon bundle verrouillé).
2. **Bundle** — `sudo rm -rf /Applications/Iris.app` (root:wheel) + rappel « ou via la corbeille ».
3. **CLI** — `sudo rm -f /usr/local/bin/iris`.
4. **Receipts** — `sudo pkgutil --forget io.iris.app` et `io.iris.cli`.
5. **Cert(s) CA** — boucle `security delete-certificate -Z <SHA-1>` sur tous les `IRIS local CA`
   (sans panneau ; purge aussi le trust setting).
6. **Clé CA + secrets** — `security delete-generic-password` (`io.iris.ca`/`privatekey`, puis
   `io.iris.secret` en boucle). **Prompts trousseau attendus** : le daemon n'est plus là pour
   fournir l'ACL — c'est l'effet voulu. Secrets supprimés **uniquement** sur `--delete-secrets` ou
   confirmation interactive explicite.
7. **MCP unwrap** — lit `wrapped-paths.json` en itérant l'index avec `plutil`
   (`plutil -extract "$i" raw -o - "$manifest"` pour `i = 0, 1, …` jusqu'à échec — natif, pas de
   dépendance `jq`/`python`), restaure chaque `.iris.bak` en bash pur (`cp` puis `rm`, sans dépendre
   du CLI qui vient peut-être d'être retiré). Entrée périmée → skip + message.
8. **Bloc `~/.zshrc`** — retrait du bloc balisé + backup horodaté (`~/.zshrc.iris-bak.<epoch>`).
9. **App Support** — `rm -rf "~/Library/Application Support/iris"` **en dernier** (self-suppression,
   après lecture du registre à l'étape 7).
10. **SMAppService** — message manuel : « retirez Iris dans Réglages Système → Général → Ouverture
    au démarrage » (`unregister()` est impossible sans le bundle).

**Drapeaux** : interactif par défaut (confirmation par section) ; `--yes` (non-interactif, **sauf**
les secrets) ; `--delete-secrets` (requis pour supprimer les secrets, même avec `--yes`). Idempotent
(relançable jusqu'à « tout propre »).

## 9. Composant E — Packaging (dépôt du script)

- La source `packaging/scripts/uninstall.sh` est automatiquement embarquée dans les scripts du
  composant app (`build-pkg.sh` ligne 100 : `pkgbuild … --scripts packaging/scripts`).
- **`packaging/scripts/postinstall`** : après création du dossier de support, **copie le script
  depuis son répertoire d'exécution vers App Support** sous l'identité de l'utilisateur réel :
  `sudo -u "$INSTALL_USER" cp "$(dirname "$0")/uninstall.sh" "$USER_HOME/Library/Application Support/iris/uninstall.sh"`
  puis `chmod +x`. Best-effort (un échec de copie ne fait pas échouer l'install ; cohérent avec le
  reste du postinstall).

## 10. Invariants & ordre

- **I1 — RPC daemon avant `unregister()`** : le nettoyage Keychain sans prompt n'est possible que
  pendant qu'`irisd` vit. Vérifié par test d'orchestration (ordre des appels sur seams mockés).
- **I2 — Secrets opt-in partout** (§10) : ni le RPC, ni l'app, ni le script ne suppriment un secret
  sans consentement explicite (checkbox décochée / `--delete-secrets`).
- **I3 — Aucune fuite de valeur** (§6) : réponse RPC et logs value-free ; test de non-fuite.
- **I4 — Idempotence** : RPC et script relançables sans erreur sur un état déjà nettoyé.
- **I5 — Le daemon ne touche aucun fichier** : un seul responsable des fichiers (le script).

## 11. Tests

- **RPC `admin.uninstall`** (`InMemorySecretStore`) : clé CA supprimée ; secrets supprimés ssi
  `deleteSecrets` ; `secretsDeleted` exact ; idempotence ; **réponse value-free** (dump → aucune
  valeur configurée présente).
- **Registre des wraps** : `add` dédupliqué ; `remove` ; `list` ; absence de fichier = liste vide ;
  écriture atomique.
- **`MCPPatcher.unwrap`** : restaure depuis `.iris.bak`, supprime le backup ; backup absent → erreur
  propre ; comportement CLI inchangé après refactor (les tests existants de `mcp unwrap` passent).
- **Orchestration app** (seams mockés) : **ordre I1** ; poursuite sur échec partiel ; agrégation des
  erreurs ; checkbox secrets propagée au RPC.
- **Script** : `bash -n packaging/scripts/uninstall.sh` (syntaxe) en CI ; le reste couvert par le
  **smoke au poste** (checklist PR).
- Aucun test ne touche un vrai trousseau (§7).

## 12. Documentation

- **`docs/user-guide.md`** : nouvelle section « Désinstaller » (chemin nominal via le bouton +
  chemin de secours via le script ; mention du consentement secrets et du retrait manuel
  SMAppService).
- Vérifier les écrans installeur (`packaging/installer/resources/*/conclusion.html`) : s'ils
  évoquent la désinstallation, les aligner ; sinon, ne pas toucher (Rule 3).

## 13. Risques & points de vigilance (issus du smoke TEMPS 1)

- **macOS 26 / Launchpad** : on ne peut pas drag-to-trash une app tierce depuis Launchpad → le
  script et l'alerte finale dirigent vers **Finder + ⌘⌫ + mot de passe admin** (`open -R`).
- **`rm -rf` refusé à l'agent** (deny rule Claude Code) : sans impact sur le livrable (le script
  s'exécute chez l'utilisateur) ; impacte seulement le smoke par l'agent → passer par `mv` si besoin.
- **Containers TCC** : hors-scope (résidu dev) ; non traités par `uninstall.sh`.
- **`security delete-generic-password` sans daemon** : déclenche des prompts trousseau — **attendu**
  et documenté dans le script.

## 14. Critères de réussite (smoke, à reporter dans la checklist PR)

1. Bouton « Quit & Uninstall » (secrets décochés) : clé CA supprimée sans prompt, cert retiré (1
   prompt), bloc zshrc retiré, MCP unwrap effectué, auto-start désenregistré, Finder ouvert sur le
   script, app quittée. Les **secrets restent** dans le trousseau.
2. Même chose, **secrets cochés** : les secrets sont supprimés (compte attendu).
3. `uninstall.sh` lancé ensuite (ou seul, app jetée) : bundle + CLI + receipts retirés (sudo), App
   Support supprimé, `which iris` → absent, `ls /Applications/Iris.app` → absent.
4. Re-lancer `uninstall.sh` → tout en « rien à faire » (idempotent).
5. `mcp wrap` d'un `~/.claude.json` puis désinstallation → fichier restauré, `.iris.bak` retiré,
   entrée du registre disparue.
6. Aucune valeur de secret n'apparaît dans les logs `irisd` pendant la désinstallation.
7. `swift build` + `swift test` + `swift-format` verts ; CI verte (build-test + xcode-build macOS-15).
