# Design — Plugins : hook `onComplete`

> Document de design (source de vérité pour le plan d'implémentation).
> Statut : **validé en brainstorm** (2026-06-22), plan à dériver.
> Date : 2026-06-22. Branche : `feat/plugins-oncomplete`.
> Étend le système de plugins v1 (`docs/plugins-design.md`, P1→P5 mergées).
> Première des deux PR de l'extension « hooks réponse/complétion » (`onResponse`
> suit en PR séparée, avec sa propre décision SPECS §7.2).

---

## 1. Objectif & périmètre

Ajouter le hook **`onComplete`** au système de plugins : un point d'observabilité
**fire-and-forget, lecture seule**, déclenché à la **fin** d'une requête, qui livre au
plugin les **métadonnées HTTP-level** de la requête terminée. C'est le « tier
observabilité / sinks » de `plugins-design.md §1` (famille d'usage #3) et `§13` (phases
ultérieures).

Cas d'usage cible : audit enrichi, émission vers fichier/SIEM/metrics, comptage par
host/route/statut. Le plugin **n'altère rien** : il observe et émet ailleurs.

### Décision de séquençage (brainstorm 2026-06-22)

L'extension `onResponse`/`onComplete` est scindée en **deux PR** :

- **PR 1 (ce design)** — `onComplete` seul. Petit, sans conflit d'invariant, pose le
  champ `status` de `HookMatch` que `onResponse` réutilisera.
- **PR 2 (design séparé, ultérieur)** — `onResponse` (lire/**modifier** la réponse).
  Demande une décision explicite de relâchement de **SPECS §7.2** (« *Response bodies are
  never scanned or modified* ») **et** la réintroduction d'un collecteur de réponse
  bufferisé gaté sur le match (régression assumée du streaming Phase 2.x pour les
  requêtes matchées). Hors scope ici.

### Dans le périmètre (PR 1)

- `HookEvent.onComplete` + condition de gating `status` sur `HookMatch`.
- Type IPC `OnCompleteParams` + méthode `on_complete` en **notification** NDJSON.
- `PluginHost.onComplete` (fire-and-forget) + ajout au protocole `PluginInvoking`.
- Chaîne `onComplete` séparée dans `HookDispatcher` + publication par `PluginHostManager`.
- Insertion unique dans `MITMHandler.forwardRequest` (`.whenComplete`), en `Task` détaché.
- Extension du plugin d'exemple `header-tagger` (doc vivante + véhicule de test).
- Tests unitaires (mock) + intégration (plugin réel) + sécurité (value-free).

### Hors périmètre (justifié)

- **`onResponse`** (lire/modifier la réponse) → PR 2.
- **Config schema-driven** (D6) — phase séparée ; `onComplete` est déclaré au manifest,
  aucun formulaire requis.
- **Nouveau CLI / nouvelle UI** — le hook est déclaré dans `plugin.json` ; `iris plugin
  list/info` et la section Réglages « Plugins » existantes le couvrent sans changement.
- **`.pkg` Phase 9** embarquant/signant `iris-sandbox-exec` — maintenance distincte
  (suivi P2b), orthogonale à `onComplete`.

---

## 2. Décisions tranchées (brainstorm)

| # | Axe | Décision |
|---|-----|----------|
| C1 | Transport | **Notification NDJSON** `on_complete` (pas d'`id`, pas de réponse attendue), comme `shutdown` (§8). Le daemon écrit une ligne et n'attend rien. Écartée : request/response (suivi d'in-flight pour un résultat jeté — aucune valeur). |
| C2 | Bloquant | **Jamais.** Dispatché depuis un `Task` **détaché** dans `.whenComplete`, après le relais de la réponse et l'engagement du `channel.close`. |
| C3 | Visibilité | **HTTP-level minimal** : `method`, `uri` (originale → placeholder-form), `host`, `status`, `durationMs`. **Pas de headers, pas de body.** L'outcome interne d'Iris (substituted/blocked/…) et les noms de secrets **ne sont pas** exposés en v1 (extensible plus tard). |
| C4 | Déclenchement | **Exactement quand Iris enregistre l'`Event` de complétion** — les 2 branches de `.whenComplete`. Couvre tous les dénouements terminaux + l'échec upstream. |
| C5 | Échec upstream | `onComplete` se déclenche aussi sur la branche échec, avec **`status = 0`** (sentinelle « erreur avant/pendant la réponse »). |
| C6 | Gating | `HookMatch` gagne `status: [Int]?` ; le matching `onComplete` réutilise `hosts`/`methods`/`pathRegex`/`contentType` (request content-type) **+** `status`. Évalué **avant** tout IPC → zéro coût si aucun hook applicable. |
| C7 | `onFailure` / `timeoutMs` | **Sans objet** pour `onComplete` (on n'attend pas de réponse). Documentés comme ignorés. |
| C8 | Chaîne | Chaîne `onComplete` **séparée et homogène** (parité avec la chaîne `onRequest`), même tri par `order`. Dispatch **fire-and-forget par plugin**, indépendant (pas de chaînage de sortie : lecture seule). |

---

## 3. Invariants conservés / non-impactés

- **SPECS §7.2** (réponse jamais scannée ni modifiée) — **intact** : `onComplete` ne reçoit
  ni le body ni les headers de réponse, ne bufferise rien, ne modifie rien. Le chemin de
  réponse streaming Phase 2.x est **inchangé**.
- **CLAUDE.md §6.1 / plugins-design §9.2** (value-free) — l'`uri` transmise est l'**URI
  originale**, capturée **avant** substitution (`MITMHandler.swift:119`), donc en
  placeholder-form (`{{kc:NAME}}`), **jamais** la valeur résolue. Comme `onRequest`, le
  plugin ne voit aucun secret. Aucun body/header → aucune fuite par ce canal.
- **plugins-design §3** (invariant central) — `onComplete` est lecture seule **après** le
  pipeline complet ; il ne peut rien désactiver ni contourner.
- **Robustesse process** — un plugin `onComplete` mort/lent ne peut ni retarder ni casser
  la réponse client : dispatch détaché (C2) + `F_SETNOSIGPIPE` déjà posé
  (`PluginHost.swift:111`) → une écriture vers un plugin mort échoue en `EPIPE` (catché),
  jamais en SIGPIPE qui tuerait `irisd`.

---

## 4. Déclenchement (quand `onComplete` se déclenche)

Règle unique : **`onComplete` se déclenche exactement quand Iris enregistre l'`Event` de
complétion** — c.-à-d. dans le bloc `.whenComplete` de `forwardRequest`
(`MITMHandler.swift:178`), pour **chaque** requête, dans **les deux** branches :

| Branche | Cas couverts | `status` transmis |
|---|---|---|
| `.success` | `substituted`, `passThrough`, `noMatch`, `exfilBlocked`, `pluginBlocked`, `pluginResponded` | `outcome.statusCode` réel |
| `.failure` | upstream injoignable (502) ou stream tronqué mid-réponse | **`0`** (sentinelle, C5) |

Le ping diagnostic `/__iris_ping` (`MITMHandler.swift:101`) retourne **avant** ce chemin →
pas de `onComplete` (cohérent : ce n'est pas une requête proxifiée).

---

## 5. Gating (`HookMatch.status`)

`HookMatch` gagne :

```swift
public let status: [Int]?   // response status codes; nil/empty = wildcard. onComplete/onResponse only.
```

Sémantique : si `status` est non-vide, le hook ne matche que si le `status` de complétion
∈ `status`. Exemple « réagir aux erreurs serveur » : `"status": [500, 502, 503]` (et `0`
pour capter aussi l'échec upstream, C5).

`HookMatch.matches(...)` gagne un paramètre `status: Int?` ; il est **ignoré** quand le
hook est un `onRequest` (pas de statut à ce stade) et **évalué** pour `onComplete`. Les
autres conditions (`hosts`/`methods`/`pathRegex`/`contentType`) sont réutilisées telles
quelles. Le **request** content-type est capturé à l'entrée de `forwardRequest`
(`originalContentType`, comme `originalURI`) pour rester disponible à la complétion.

Gating évalué **dans le dispatcher, avant tout IPC** : une requête sans hook `onComplete`
applicable ne déclenche aucune sérialisation ni écriture (parité §4.3 `onRequest`).

---

## 6. Protocole IPC

Méthode **`on_complete`** (notification, daemon → plugin) :

```json
{ "jsonrpc": "2.0", "method": "on_complete",
  "params": { "method": "POST", "uri": "/v1/messages",
              "host": "api.anthropic.com", "status": 200, "duration_ms": 1342 } }
```

- **Notification** : aucun `id`, **aucune réponse attendue** (C1). Le plugin traite à son
  rythme.
- `PluginRPC.encodeNotification` est étendu pour porter un `params` encodable (il ne porte
  aujourd'hui que `method`, pour `shutdown`).
- `OnCompleteParams` : `method: String`, `uri: String`, `host: String`, `status: Int`,
  `durationMs: Int` (clé wire `duration_ms`, snake_case comme le reste du protocole).
- `PluginRPC.Method.onComplete = "on_complete"`.

---

## 7. Architecture & pièces touchées

Toutes des **extensions** de patterns déjà posés par `onRequest` (P1→P3).

| Fichier | Changement |
|---|---|
| `Sources/IrisKit/Plugins/PluginManifest.swift` | `HookEvent.onComplete = "on_complete"` ; `HookMatch.status: [Int]?` (+ `init`/decode tolérant) ; `matches(..., status:)` status-aware. |
| `Sources/IrisKit/Plugins/PluginRPC.swift` | `OnCompleteParams` ; `Method.onComplete` ; `encodeNotification(method:params:)`. |
| `Sources/IrisKit/Plugins/PluginHost.swift` | `func onComplete(_ params:) async` — encode la notification + write (fire-and-forget, **pas** de `pending`) ; conformance `PluginInvoking`. |
| `Sources/IrisKit/Plugins/HookDispatcher.swift` | `completeChainBox` + `updateCompleteChain(_:)` ; `func onComplete(host:method:path:contentType:status:durationMs:)` — gate + dispatch fire-and-forget par plugin applicable. Ajout `onComplete` à `PluginInvoking`. |
| `Sources/IrisKit/Plugins/PluginHostManager.swift` | `republishChain` publie **aussi** la chaîne `onComplete` (filtre `event == .onComplete`, même tri `order`). |
| `Sources/IrisKit/Proxy/MITMHandler.swift` | capture `originalContentType` ; dispatch `onComplete` dans les 2 branches de `.whenComplete`, en `Task` détaché (après `channel.close`). |

### 7.1 `PluginInvoking` & chaîne

`PluginInvoking` gagne `func onComplete(_ params: PluginRPC.OnCompleteParams) async throws`.
Le `PluginHost` l'implémente en écrivant la notification ; les erreurs (EPIPE, process
mort) sont **log-and-ignore** côté dispatcher (rien à bloquer).

La chaîne `onComplete` est séparée de la chaîne `onRequest` : `republishChain` construit les
**deux** listes homogènes (filtrées par `event`) et les pousse atomiquement. Forme exacte du
câblage (second callback vs. struct unifiée `{request, complete}`) tranchée au plan — la
contrainte de design est : **mise à jour atomique des deux chaînes** (pas de fenêtre où
l'une est neuve et l'autre périmée). Un même plugin déclarant `onRequest` **et**
`onComplete` produit une entrée dans chaque chaîne.

### 7.2 Insertion `MITMHandler`

Dans `.whenComplete`, après l'émission de l'`Event` existante et l'engagement du
`channel.close(promise: nil)` :

```text
Task { await server.hookDispatcher.onComplete(
    host: host, method: originalMethod, path: <path de originalURI>,
    contentType: originalContentType, status: <statusCode | 0>, durationMs: duration) }
```

Détaché → ne touche jamais le chemin critique. Le dispatcher gate (filtre les plugins
applicables) puis fire-and-forget chaque invocation.

---

## 8. Plugin d'exemple (`header-tagger`)

`header-tagger` (actuellement `onRequest` seul) gagne **aussi** un hook `onComplete` :
à chaque complétion matchée, il append une ligne (`method status uri`) dans un fichier de
son `scratch` (lui octroyant `capabilities.filesystem: ["scratch"]`). Double bénéfice :

- **Doc vivante** des deux hooks dans un seul exemple cohérent.
- **Véhicule de test d'intégration** : le test lit le fichier scratch pour prouver la
  livraison de `on_complete` (le plugin n'a aucune sortie réseau).

La cible source partagée (`Package.swift` principal + package exemple) suit le montage P5
déjà en place.

---

## 9. Tests & critères de succès (cf. `CLAUDE.md §7`, plugins-design §12)

| Niveau | Ce qui est prouvé |
|---|---|
| **Unit (mock `PluginInvoking`)** | Gating `status`/`host`/`method`/`path`/`contentType` (match & no-match) ; `onComplete` déclenché pour chaque type d'outcome (incl. `pluginBlocked`/`pluginResponded`) ; `status=0` sur la branche échec (C5) ; dispatch fire-and-forget **non bloquant** (le retour de `forwardRequest`/close ne dépend pas de la complétion du plugin). |
| **Intégration (daemon éphémère + `header-tagger`)** | Après une vraie requête proxifiée, le plugin a reçu `on_complete` (marqueur scratch) avec le bon `status` ; un plugin `onComplete` **lent/mort ne casse pas** la réponse (mutation-vérifié : rouge si le dispatch était synchrone — Rule 9). |
| **Sécurité** | Un dump de `OnCompleteParams` ne contient **jamais** de valeur de secret (`uri` = placeholder-form) ni de body/header de réponse. |
| **Régression** | Suites plugins (P1→P5) + proxy (`ProxyEndToEndTests`, streaming) restent vertes ; le chemin de réponse streaming est byte-for-byte inchangé quand aucun hook `onComplete` n'applique. |

**Definition of done :**
1. `swift build -c release` **0 warning** ; `swift test` vert ; `swift-format lint --strict`
   clean.
2. Test de non-blocage **vert et rouge sur un dispatch synchrone** (mutation-vérifié).
3. CI macos-15 verte (juge final).
4. Checklist de smoke testing de la PR cochée (daemon éphémère isolé : `on_complete` livré
   avec le bon statut, réponse intacte).

---

## 10. Risques & suivis

- **Backpressure notification** : le dispatch `onComplete` est **concurrent** entre plugins
  (`withTaskGroup`) — un plugin lisant lentement son stdin (pipe ~64 KiB plein → écriture
  bloquée) **ne retarde donc pas** la livraison aux **autres** plugins. **Jamais l'EL du
  proxy** non plus (qui ne fait que `Task { … }`). Résidu : pour un plugin déclarant **les
  deux** hooks, une écriture `on_complete` bloquée tient l'executor de **son propre** `actor`
  `PluginHost` et sérialiserait devant **son prochain `onRequest`** — lequel, lui, est sur le
  chemin critique (le proxy `await`-e `onRequest`). En pratique auto-limité (un tel plugin
  dépasserait déjà son `timeoutMs` sur `onRequest`), borné à ce plugin, hors EL. Raffinement
  (write non bloquant pour `on_complete`) différé si jamais observé.
- **PR 2 `onResponse`** : design séparé ; décision SPECS §7.2 + collecteur bufferisé gaté.
- **`status=0`** : sentinelle d'échec — documenter dans le manifest d'exemple et la doc
  plugin (manuel ch. 23) lors d'un passage doc ultérieur.

---

## 11. Références

- `docs/plugins-design.md` (§1, §3, §4.2-4.3, §8, §9.2, §13) — design v1.
- `docs/superpowers/specs/2026-06-02-response-streaming-design.md` — chemin réponse Phase 2.x
  (motivation du non-conflit §7.2 et de l'isolement de `onResponse` en PR 2).
- Code : `Sources/IrisKit/Plugins/{PluginManifest,PluginRPC,PluginHost,HookDispatcher,PluginHostManager}.swift`,
  `Sources/IrisKit/Proxy/MITMHandler.swift`, `Sources/IrisKit/Models/Event.swift`.
- SPECS : §7.2 (réponse jamais modifiée), §8.2 (host matching), §13 (admin socket).
