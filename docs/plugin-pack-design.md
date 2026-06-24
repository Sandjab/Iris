# Design — `iris plugin pack` (issue #89)

> Statut : design validé, prêt pour plan d'implémentation.
> Périmètre : résoudre #89 (le flux d'install du README échoue sur le daemon de prod).

## 1. Problème

Découvert pendant le smoke de #88. Le flux documenté dans
`examples/plugins/header-tagger/README.md` ne marche qu'avec un daemon éphémère
dont le CWD est le repo ; il échoue en distribution réelle. **Aucun impact
sécurité** — le validateur fait son travail. C'est de l'ergonomie + doc.

Deux causes distinctes :

1. **Path relatif résolu contre le CWD du daemon.**
   `iris plugin install examples/plugins/header-tagger` transmet le path brut par
   RPC. Le daemon (`AdminDispatcher.swift:273`, LaunchAgent, CWD = `/`) le résout
   en `/examples/...` → `No such file or directory`.

2. **Le dossier source contient des symlinks `.build/`.**
   Le `plugin.json` pointe `executable: ".build/release/header-tagger"`. SwiftPM
   crée `.build/release` comme symlink, et `PluginSourceValidator` refuse tout
   symlink (design §14 #8, légitime — un symlink est non-pinnable par le hash
   TOFU). `.build/` dépasse aussi les limites taille/count. Le dossier source tel
   quel est donc **ininstallable**, même avec un path absolu. Il faut un bundle
   propre `{ plugin.json, <binaire> }`.

## 2. Décisions de design

| Décision | Choix | Raison |
|----------|-------|--------|
| `pack` build-t-il ? | **Non, assemble seulement.** | Le contrat plugin (exécutable parlant NDJSON sur stdio, §8) est agnostique au langage. `swift build` puis `pack` garde `pack` simple et utilisable pour un plugin Python/Go/Rust. |
| Contenu du bundle | **`plugin.json` (executable réécrit en basename) + le binaire, à plat. Rien d'autre.** | Le contrat actuel : seul `executable` référence un fichier. Pas de `.build/`, pas de sources. YAGNI : pas de support de ressources additionnelles tant qu'un champ manifest ne les déclare pas. |
| Emplacement de sortie par défaut | **`<source-dir>/dist`** (override via `--output`). | Le bundle est un artefact dérivé de la source → vit à côté d'elle (comme `.build/` de SwiftPM). Indépendant du CWD (ne rejoue pas le piège du problème 1). Un seul `.gitignore dist/` suffit, pas de collision multi-plugins. |
| Où vit la logique | **`PluginPacker` dans `IrisKit/Plugins/`**, pas dans la commande CLI. | Testable unitairement, réutilisable. Cohérent avec `PluginSourceValidator` (déjà dans IrisKit). |
| Le daemon est-il impliqué ? | **Non.** | `pack` est de la manipulation de fichiers locaux côté client. Pas de RPC, contrairement à `install`. |

## 3. Architecture

Trois changements indépendants, une seule PR.

### 3.1 `PluginPacker` (cœur réutilisable — `Sources/IrisKit/Plugins/PluginPacker.swift`)

Contrat :

```swift
public enum PluginPacker {
    /// Assemble un bundle installable à partir d'un dossier source contenant
    /// plugin.json. Renvoie l'URL du dossier bundle produit.
    public static func pack(source: URL, output: URL, force: Bool) throws -> URL
}
```

Étapes (toutes fail-closed) :

1. Lire `source/plugin.json`, le décoder en `PluginManifest` et appeler
   `manifest.validate()`. Fournit l'`executable` d'origine et garantit un
   manifest sain en entrée.
2. Résoudre `executable` relativement à `source`, puis **realpath**
   (`URL.resolvingSymlinksInPath` / `realpath`) pour atteindre le **fichier
   binaire réel** derrière `.build/release/...`. Vérifier que c'est un fichier
   régulier.
3. Préparer `output` : refuser d'écraser un dossier non-vide sauf `force == true`,
   sinon créer le dossier.
4. Copier le binaire réel dans `output/<basename>` (basename de l'executable
   d'origine, ex. `header-tagger`). `copyItem` sur le **realpath** copie le
   fichier, pas le symlink.
5. Écrire `output/plugin.json` = le manifest source avec **uniquement**
   `executable` réécrit en basename. Manipuler le JSON de manière générique
   (préserver d'éventuels champs non modélisés du manifest tiers) plutôt que de
   réencoder `PluginManifest` — à trancher en plan, mais le principe est : ne
   muter que la clé `executable`.
6. Faire passer `output` par **`PluginSourceValidator.validate(directory:)`**.
   Échoue tôt si le bundle n'est pas installable → garantit l'invariant « ce que
   `pack` produit, `install` l'accepte ».

Justification runtime : à l'install puis au lancement, le daemon résout
l'executable en `pluginsDirectory/<id>/<executable>` (`PluginHostManager.swift:153-156`).
Avec un bundle `{ plugin.json (executable: "header-tagger"), header-tagger }`, la
résolution donne `pluginsDirectory/<id>/header-tagger` → correct. `validate()`
accepte le basename (`PluginManifest.swift:74-80`, chaque composant de path doit
être un composant sûr).

### 3.2 Commande CLI `iris plugin pack`

```
iris plugin pack <source-dir> [--output <dir>] [--force] [--json]
```

- `<source-dir>` : dossier contenant `plugin.json`. `pack` étant purement local,
  `URL(fileURLWithPath:)` résout naturellement le path relatif contre le CWD du
  client — pas besoin de l'absolutiser pour un RPC (contrairement à `install`).
- `--output` : défaut `<source-dir>/dist`.
- `--force` : autorise l'écrasement d'un dossier de sortie non-vide.
- Appelle `PluginPacker.pack(...)`, affiche le chemin du bundle et le hint
  `iris plugin install <bundle>`.

Purement client — pas de connexion au daemon.

### 3.3 Fix problème 1 — `iris plugin install` absolutise le path

Dans `PluginCommands.Install.run()`, transformer `path` en absolu avant l'envoi
RPC, via le pattern déjà utilisé dans la CLI (`MCPCommands.swift:40-41`) :

```swift
let expanded = (path as NSString).expandingTildeInPath
let absolute = URL(fileURLWithPath: expanded).path   // résolu contre le CWD du client iris
```

Le daemon refait `expandingTildeInPath` + `URL(fileURLWithPath:)` (no-op sur un
absolu). Bénéficie aussi à l'argument `<source-dir>` de `pack`.

## 4. Exemple + README (`examples/plugins/header-tagger/`)

- Le `plugin.json` source garde `executable: ".build/release/header-tagger"`
  (manifest « de dev » : où le binaire se trouve après `swift build`).
- Ajouter un `.gitignore` à l'exemple : `dist/`.
- Corriger le README avec le flux réel :

  ```bash
  swift build -c release
  iris plugin pack examples/plugins/header-tagger
  iris plugin install "$(pwd)/examples/plugins/header-tagger/dist"
  iris plugin enable org.iris.example.header-tagger
  ```

  Le bloc « remove then reinstall » est mis à jour de la même façon (re-pack avant
  re-install).

## 5. Tests

- **Unit `PluginPacker`** : monter un dossier source avec un `executable` derrière
  un symlink (reproduit `.build/release/...`). Vérifier que le bundle produit
  contient `{ plugin.json (executable basename), <binaire réel> }`, ne contient
  **aucun** symlink, et **passe `PluginSourceValidator`**. Couvrir aussi : refus
  d'écraser sans `--force`, erreur si `executable` introuvable.
- **Unit fix install** : la transformation path relatif → absolu (tilde + CWD).
- **Doc** : mettre à jour `docs/plugins-design.md` si un paragraphe « commandes »
  l'exige (à vérifier en plan).

## 6. Hors-scope (YAGNI)

- `pack` ne lance pas de build (l'utilisateur build avec son outil natif).
- Pas de support de ressources additionnelles dans le bundle (le manifest ne les
  déclare pas aujourd'hui).
- Pas de signature/notarisation du binaire de plugin (le modèle de confiance est
  TOFU au moment de l'install, design §14).
