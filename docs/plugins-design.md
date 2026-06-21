# Design — Système de plugins IRIS

> Document de design (source de vérité pour le plan d'implémentation).
> Statut : **validé en brainstorm**, plan à dériver.
> Date : 2026-06-21. Branche : `feat/plugins`.
> S'intègrera à terme dans `SPECS.md` (section dédiée) une fois la v1 stabilisée.

---

## 1. Objectif & périmètre

Permettre à l'utilisateur de définir des **plugins** : du code tiers, activable/désactivable,
qui s'insère dans le pipeline de traitement du proxy pour **lire et modifier** les requêtes
sortantes (et, en phases ultérieures, les réponses entrantes), selon des **points de hook** et
des **conditions de déclenchement** déclarés.

Un plugin doit pouvoir couvrir, à terme, ces quatre familles d'usage :

1. **Transformation requête/réponse** — réécrire/injecter des headers, transformer ou rédiger un body.
2. **Politique de sécurité custom** — règles type exfil, allow/deny par route/host/code HTTP.
3. **Observabilité / sinks** — émettre vers fichier/SIEM/metrics, audit enrichi.
4. **Adaptateurs par fournisseur** — façonner requête/réponse par API (retry, rewrite, normalisation).

Contrainte produit posée par l'utilisateur : **le système le plus souple possible** (un plugin = du
vrai code, pas seulement de la config) avec un **surcoût d'interface minimal** (la latence d'un
plugin lourd est acceptée ; le framework lui-même ne doit pas plomber le chemin commun).

---

## 2. Décisions de design (verrouillées en brainstorm)

| # | Axe | Décision |
|---|-----|----------|
| D1 | Modèle d'exécution | **Hors-process sandboxé** : chaque plugin actif = sous-process séparé, chaud, parlant JSON-RPC 2.0 sur stdio. Langage libre. |
| D2 | Visibilité des secrets | **Jamais le secret réel.** Hooks requête **avant** substitution → le plugin ne voit que les placeholders `{{kc:NAME}}`. |
| D3 | Sandbox | **Deny-by-default + capabilities** déclarées au manifest, **approuvées à l'activation**, appliquées par un profil sandbox. |
| D4 | Provenance | **Install explicite + TOFU** (épinglage d'un hash de contenu, ré-approbation si l'exécutable change). Pas d'exigence Developer-ID. |
| D5 | Hook réponse | **Mode de livraison déclaré par hook** : `metadata` / `buffered` / `streaming`. `buffered` implémenté en premier. *(phase ultérieure)* |
| D6 | Config plugin | **Schema-driven** : le manifest déclare un JSON Schema, Iris rend un formulaire générique. *(phase ultérieure)* |
| D7 | IHM | Nouvelle section **« Plugins »** dans la fenêtre Réglages existante. |
| D8 | Plugin d'exemple | **Swift** (cohérent avec la stack ; le runtime reste polyglotte). |
| D9 | Ordre de chaîne | **Réordonnable dans l'UI** ; ordre persisté dans `config.json` (défaut = ordre d'install). |
| D10 | Périmètre v1 | Socle runtime + hook `onRequest` + CLI + UI liste + plugin d'exemple. |

---

## 3. Invariant de sécurité central

> **Le scan exfil + le scoping `allowed_hosts` + la substitution d'Iris s'exécutent toujours, sur la
> forme finale de la requête, après tous les plugins. Aucun plugin ne peut les désactiver, les
> contourner, ni voir un secret réel.**

Conséquences :

- Un plugin qui plante, timeout ou se comporte mal **ne peut jamais affaiblir** la sécurité d'Iris :
  au pire sa transformation est sautée, mais l'analyse de sécurité d'Iris tourne sur ce qui part
  réellement sur le réseau.
- Honore directement `CLAUDE.md §6.3` (scoping = invariance) et `§6.6` (pas de mode qui désactive le
  scoping).
- Le plugin ne reçoit jamais que des placeholders côté requête (`{{kc:NAME}}`), jamais la valeur
  résolue. La substitution a lieu **après** le passage plugin, hors de sa portée.

Le plugin reste néanmoins un **nouveau principal de confiance** : il voit les bodies/headers de
requête (prompts, données utilisateur) — d'où le sandbox deny-by-default (§6).

---

## 4. Pipeline & points de hook

### 4.1 Insertion dans le flux

```
CONNECT → TLS MITM → [requête déchiffrée, placeholders présents]
   │
   ├─(1) HookDispatcher.onRequest  ← plugins (chaîne ordonnée), placeholders only
   │         pass | modify(head,body) | block(reason) | respond(synthétique)
   │
   ├─(2) Scan exfil + scoping + substitution d'Iris   ← TOUJOURS, sur la sortie de (1)
   │
   └─(3) Forward upstream
              │
              ├─(4) [phase ultérieure] HookDispatcher.onResponse ← plugins
              └─(5) Relais vers le client (streaming préservé hors hook réponse)

(6) [phase ultérieure] HookDispatcher.onComplete ← observabilité, fire-and-forget
```

Point d'intégration code : **une seule insertion** dans `MITMHandler.processRequest`, tout au début
(après le check `bypass`, avant le strip `Accept-Encoding` et le scan existant). Le dispatcher peut
remplacer `head`/`body` ; le reste du pipeline est inchangé. Le chemin de réponse (streaming) **n'est
pas touché en v1**.

### 4.2 Hooks

| Hook | Phase | Visibilité | Retour | Notes |
|------|-------|-----------|--------|-------|
| `onRequest` | **v1** | head/uri/body **avec placeholders** | `pass` \| `modify` \| `block` \| `respond` | Avant scan/substitution. |
| `onResponse` | ultérieure | head/status/body upstream | `pass` \| `modify` | Mode `metadata`/`buffered`/`streaming` déclaré. |
| `onComplete` | ultérieure | métadonnées de la requête terminée | — (fire-and-forget) | Jamais bloquant, lecture seule. Pour les sinks. |

### 4.3 Conditions de déclenchement

Déclarées au manifest, évaluées **par Iris avant tout IPC** → une requête sans plugin applicable paie
**zéro coût** (pas de sérialisation, pas d'aller-retour). Champs :

- `hosts` — exact ou glob (réutilise la logique de matching de host existante, cf. `SPECS §8.2`).
- `methods` — liste de méthodes HTTP.
- `pathRegex` — regex sur le path (hors query).
- `contentType` — type de contenu de la requête.
- `status` — code(s) HTTP (hooks réponse seulement).
- `headerPresent` / `headerMatch` — présence/valeur d'un header.

### 4.4 Chaînage

Plusieurs plugins sur un même hook forment une **chaîne ordonnée** : chacun voit la sortie du
précédent ; puis Iris scanne/substitue le résultat final. Ordre **persisté** (index par plugin dans
`config.json`), **réordonnable dans l'UI** (D9), défaut = ordre d'install. Un `block`/`respond`
court-circuite la suite de la chaîne.

### 4.5 Échec d'un plugin

`onFailure` déclaré par hook :

- `skip` (**défaut** transformateurs) — on continue la chaîne sans ce plugin.
- `block` (**défaut** plugins de politique) — la requête est bloquée (traitée comme un refus).

Timeout par hook (`timeoutMs`), plafonné par Iris. Un plugin qui dépasse le timeout est traité selon
son `onFailure`.

---

## 5. Manifest (`plugin.json`)

Format **JSON** (cohérent avec le passage du repo de TOML à `config.json`).

```json
{
  "id": "org.example.header-tagger",
  "name": "Header Tagger",
  "version": "1.0.0",
  "description": "Ajoute un header de tag aux requêtes POST /v1/*.",
  "apiVersion": 1,
  "executable": "bin/header-tagger",
  "hooks": [
    {
      "event": "onRequest",
      "match": { "hosts": ["api.anthropic.com"], "methods": ["POST"], "pathRegex": "^/v1/" },
      "mutates": true,
      "onFailure": "skip",
      "timeoutMs": 200
    }
  ],
  "capabilities": {
    "network": [],
    "filesystem": ["scratch"]
  },
  "config": {
    "schema": {},
    "defaults": {}
  }
}
```

Notes :
- `executable` : chemin relatif au dossier du plugin. (Un futur champ `interpreter` pourra cibler un
  script ; v1 = exécutable direct.)
- `apiVersion` : version du contrat IPC ; Iris refuse une version non supportée.
- `capabilities.network` : liste de `host:port` autorisés en sortie. Vide = aucune sortie réseau.
- `capabilities.filesystem` : `scratch` = un dossier de travail dédié par plugin ; rien d'autre par défaut.

---

## 6. Sandbox & capabilities

Tout interdit par défaut. Le manifest **déclare** ses besoins (`network`, `filesystem`).
L'utilisateur **approuve** ces capabilities **à l'activation** ; le runtime applique un profil sandbox
au sous-process.

**⚠️ Risque technique à vérifier en planning (sosumi / doc Apple) — ne pas affirmer avant
vérification :**

- Mécanisme exact d'enforcement sur macOS 13+ : `sandbox-exec`/seatbelt (statut de dépréciation
  flou) **vs** App Sandbox pour un helper non-bundlé **vs** profil seatbelt généré. Décision
  d'implémentation à trancher après vérification doc.
- Confirmation que le daemon (hardened runtime, notarisé) peut **spawn** un exécutable séparé sans
  entitlement particulier (a priori oui : c'est du `posix_spawn`, pas du `dlopen` — donc **aucun**
  besoin de `com.apple.security.cs.disable-library-validation`, la notarisation n'est pas affaiblie).
  À confirmer.

Point d'appui : comme on ne charge **aucun** code dans le binaire signé, on évite par construction le
conflit Library Validation qui aurait condamné un modèle in-process.

---

## 7. Provenance, installation, état

### 7.1 Emplacement

Dossier **par-utilisateur** : `~/Library/Application Support/Iris/Plugins/<id>/`
(jamais dans le bundle d'app, scellé par la signature). Le daemon (LaunchAgent, tourne en
utilisateur) le lit.

### 7.2 Install (explicite + TOFU)

`iris plugin install <path>` (ou bouton `+` UI) :

1. Valide le manifest (schéma, `apiVersion`, champs requis).
2. Affiche les **capabilities déclarées** pour **approbation** utilisateur.
3. Copie le dossier dans le répertoire par-user.
4. **Épingle un hash de contenu** (TOFU). Si l'exécutable change ultérieurement →
   **ré-approbation requise** (état `needsReapproval`, plugin suspendu).

Pas d'exigence Developer-ID (on peut lancer son propre script/binaire Swift). Le sandbox applique les
capabilities quoi qu'il arrive.

### 7.3 État persisté

Dans `config.json` via `ConfigStore`, nouvelle section `plugins`. Par plugin :
`enabled`, `approvedCapabilities`, `pinnedHash`, `order` (index de chaîne), `configValues`
(**non-secrètes**).

> **Hors-scope v1** : valeur **secrète** de config plugin. On ne met jamais un secret dans
> `config.json`. Un plugin qui doit s'authentifier auprès d'un service tiers sera traité dans une
> phase ultérieure (sans jamais exposer un secret Iris au plugin).

---

## 8. Protocole IPC (JSON-RPC 2.0 sur stdio)

Daemon = client, plugin = serveur. Cadrage des messages : à trancher en planning
(newline-delimited JSON **ou** framing `Content-Length`). Cycle :

- **`initialize`** (daemon → plugin) au démarrage : `apiVersion`, `configValues`, capabilities
  accordées. Réponse : capacités confirmées par le plugin.
- **`onRequest`** (daemon → plugin) par requête matchée :
  ```json
  { "method": "POST", "uri": "/v1/messages",
    "headers": [["x-api-key", "{{kc:anthropic_api_key}}"], ["content-type", "application/json"]],
    "host": "api.anthropic.com",
    "body": { "encoding": "utf8", "data": "..." } }
  ```
  Réponse :
  ```json
  { "action": "modify", "head": { "headers": [...], "uri": "..." },
    "body": { "encoding": "utf8", "data": "..." } }
  ```
  `action` ∈ `pass` | `modify` | `block` (avec `reason`) | `respond` (réponse synthétique : status,
  headers, body).
- **`shutdown`** (daemon → plugin) à la désactivation : arrêt gracieux puis kill si dépassement.

Le processus reste **chaud** entre les requêtes (pas de spawn par requête). Crash → restart avec
backoff ; après N échecs → auto-désactivation + alerte via le canal `SystemAlert` existant.

---

## 9. Modèle de données & intégration code

### 9.1 Nouveau module `Sources/IrisKit/Plugins/`

| Type | Rôle |
|------|------|
| `PluginManifest` | Décodage + validation du `plugin.json`. |
| `PluginRegistry` | Découverte des plugins installés, état, persistance via `ConfigStore`. |
| `PluginProcess` / `PluginHost` | Lifecycle du sous-process + transport IPC. |
| `PluginSandbox` | Génération/application du profil sandbox depuis les capabilities. |
| `HookDispatcher` | Gating (conditions), construction de la chaîne, dispatch, application des retours. |
| `PluginRPC` | Types du protocole (requêtes/réponses JSON-RPC). |

Injection dans `ProxyServer` comme `exfilRuleEngine` / `placeholderEngine` (mêmes conventions).

### 9.2 Modèles & canaux existants touchés

- Nouveau modèle `Plugin` + enum `PluginState` (`disabled`, `active`, `failed`, `needsReapproval`).
- Méthodes admin socket (`SPECS §13`) : `plugin.list`, `plugin.install`, `plugin.info`,
  `plugin.enable`, `plugin.disable`, `plugin.remove`, `plugin.reorder`.
- `Event` : champ `pluginId` + (kind ou sous-type) pour tracer l'activité plugin (invoqué, modifié,
  bloqué, erreur). **Toujours value-free** : id + action, **jamais** de payload. La redaction
  (`CLAUDE.md §6.1`) est maintenue.

### 9.3 Insertion `MITMHandler`

Appel `HookDispatcher.onRequest(...)` au début de `processRequest` (après `bypass`, avant scan). Le
résultat (`head`/`body` éventuellement remplacés, ou un court-circuit `block`/`respond`) alimente le
pipeline existant **inchangé**.

---

## 10. IHM & CLI

### 10.1 CLI `iris plugin`

```
iris plugin list                  # plugins installés + état
iris plugin install <path>        # valide, affiche capabilities, installe, épingle le hash
iris plugin info <id>             # manifest, capabilities, hash, état
iris plugin enable <id>           # approuve capabilities + active (spawn)
iris plugin disable <id>          # désactive (shutdown)
iris plugin remove <id>           # supprime du dossier par-user
iris plugin reorder <id> <index>  # position dans la chaîne
```

### 10.2 Section UI « Plugins »

Nouvelle entrée dans la sidebar de la fenêtre Réglages (à côté de General/Certificate/Integration/
Advanced). Contenu v1 :

- Liste des plugins + **état** (actif / désactivé / échec / ré-approbation requise).
- **Activer / désactiver / supprimer**.
- Affichage **capabilities** déclarées + statut de **provenance/hash** (TOFU).
- **Réordonnancement** de la chaîne (drag, ou monter/descendre).

Formulaire de config schema-driven = **phase ultérieure** (D6).

---

## 11. Plugin d'exemple (v1)

**Swift** (D8), exécutable SwiftPM. Démontre un `onRequest` mutateur minimal et sûr : ajoute un header
de tag (`X-Iris-Plugin: header-tagger`) aux requêtes matchées. Sert de **documentation vivante** et de
support aux **tests d'intégration**. `capabilities` vides (aucune sortie réseau/FS).

---

## 12. Tests (cf. `CLAUDE.md §7`)

- **Unit** : décodage/validation manifest ; gating des conditions de déclenchement (match/no-match) ;
  construction & ordre de la chaîne ; application des retours (`pass`/`modify`/`block`/`respond`) ;
  TOFU (hash pin + détection de changement) ; redaction des events plugin (aucun payload).
- **Intégration** : daemon éphémère + plugin d'exemple ; prouver qu'un `onRequest` modifie bien la
  requête forwardée ; prouver que **la substitution d'Iris s'applique après** le plugin ; prouver
  qu'un plugin en échec (`skip`) ne casse pas la requête et **ne bypasse pas** le scan exfil.
- **Sécurité** : un plugin ne reçoit **jamais** de valeur de secret résolue (placeholders only) ;
  un dump d'event plugin ne contient jamais de payload brut.

---

## 13. Phasage

Toute la vision est spécifiée ici ; **v1** = ce qui est construit/mergé en premier.

### v1 (périmètre retenu — D10)

- **P1** — Manifest + `PluginRegistry` + modèle `Plugin`/`PluginState` + section `plugins` du config + CLI `list/install/info/enable/disable/remove/reorder` (découverte + état, sans runtime).
- **P2** — `PluginProcess` lifecycle + IPC (`initialize`/`shutdown`) + `PluginSandbox` + enforcement capabilities (process chaud, sans dispatch de hook).
- **P3** — `HookDispatcher.onRequest` : gating + chaîne + intégration `MITMHandler` + `onFailure` + events plugin. (Invariant §3.)
- **P4** — Section UI « Plugins » (liste/activer/désactiver/supprimer/réordonner/capabilities).
- **P5** — Plugin d'exemple Swift + tests d'intégration.

### Phases ultérieures (designs/PR séparés)

- Hooks `onResponse` : `buffered` d'abord (buffering sous cap, streaming préservé hors hook), puis
  `streaming`/`metadata`.
- Config schema-driven (formulaires génériques depuis le JSON Schema du manifest).
- Tier observabilité `onComplete` / sinks externes.

---

## 14. Risques & questions ouvertes (à trancher en planning, après vérification doc)

1. **Enforcement sandbox macOS 13+** (§6) — mécanisme exact, à vérifier via sosumi avant de coder.
2. **Spawn sous hardened runtime** (§6) — confirmer qu'aucun entitlement n'est requis.
3. **Cadrage IPC** (§8) — newline-delimited vs `Content-Length`.
4. **Cap de buffering** réponse (phase ultérieure) — réutiliser les 4 MiB requête ou un cap distinct.
5. **Politique de restart/backoff** et seuil d'auto-désactivation après crashes répétés.

### Découvertes durant l'implémentation P1 (à durcir en P2)

> P1 (socle de gestion) est livré et mergé-candidat ; ces points sont sortis de la revue
> holistique et sont **différés à P2** par conception (aucun n'est un bloqueur P1, l'impact étant
> borné par le socket admin `0600` owner-only et l'absence d'exécution de plugin en P1).

6. **Install non transactionnel FS↔config sous concurrence.** `PluginRegistry.install` copie le
   dossier **avant** le commit atomique de l'état ; deux `install` concurrents du **même id** peuvent
   laisser une entrée d'état committée pointant vers un dossier supprimé par le rollback de l'autre.
   L'invariant du tableau de config reste intact ; c'est la cohérence FS↔config qui manque. Fix P2 :
   copier vers un chemin de staging puis `rename`-into-place **après** le commit (le rollback ne
   touche alors jamais un dossier committé), ou sérialiser l'install par un verrou par-id.
7. **Validation d'id centralisée.** P1 garde `enable` contre un id path-unsafe (le seul qui dérivait
   un chemin FS avant le check d'appartenance). En P2/P3, dès que le runtime dérive des dossiers de
   process/travail depuis l'id, **centraliser** la validation `isSafePathComponent` dans
   `directory(for:)` plutôt que par-méthode.
8. **Copie verbatim d'un arbre fourni par le client.** `install` recopie le dossier source tel quel :
   (a) les **symlinks** sont copiés et `PluginHasher` ignore les non-réguliers → un symlink est
   non-épinglé (sa cible peut changer après install sans changer le hash) ; (b) **aucun cap** de
   taille / nombre de fichiers. À durcir avant que P2 n'exécute quoi que ce soit depuis ce dossier.
9. **Coût du re-hash sur `list`/`info`.** `view(for:)` re-hash tout le dossier du plugin à chaque
   appel. Acceptable à l'échelle P1 ; ajouter un cache invalidé par mtime si le nombre/la taille des
   plugins croît.
10. **Validation des `capabilities`.** Les chaînes `network` (`host:port`) / `filesystem` sont
    stockées mais non validées en P1 (l'enforcement est P2/sandbox) — valider leur forme au moment
    où le sandbox les consomme.
