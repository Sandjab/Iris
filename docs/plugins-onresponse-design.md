# Design — Plugins : hook `onResponse` (mode `metadata`)

> Document de design (source de vérité pour le plan d'implémentation).
> Statut : **implémenté** (2026-06-22) — voir `docs/plugins-onresponse-plan.md` (plan exécuté).
> Date : 2026-06-22. Branche : `feat/plugins-onresponse-metadata`.
> Étend le système de plugins v1 (`docs/plugins-design.md`, P1→P5 mergées) et la PR
> `onComplete` (`docs/plugins-oncomplete-design.md`, mergée #86).
> C'est la « PR 2 » forward-référencée par le design `onComplete` — mais **délibérément
> réduite au mode `metadata`** : status + headers de réponse seulement, jamais le body.

---

## 1. Objectif & périmètre

Ajouter le hook **`onResponse`** au système de plugins, dans son **mode `metadata`**
uniquement : un point **synchrone, sur le chemin critique de la réponse**, déclenché au
**response head** (status + headers reçus d'upstream, avant relais au client), qui livre au
plugin les **métadonnées de réponse** (status + headers) et lui permet de **modifier les
headers** avant relais. C'est le premier des trois modes de livraison de la décision
`plugins-design.md D5` (`metadata` / `buffered` / `streaming`).

Cas d'usage cible : réécriture/injection de headers de réponse, action conditionnée au
status (dans le chemin critique, là où `onComplete` n'agit qu'après coup), normalisation de
headers par fournisseur. Le plugin **ne touche jamais le body**.

### Décision de séquençage (brainstorm 2026-06-22)

`onResponse` est lui-même scindé par **mode de livraison** (D5), pour ne payer aucun coût
spéculatif (`CLAUDE.md §2`, YAGNI) :

- **Ce PR — `metadata`** : status + headers, modify **headers-only**. **Ne touche pas au
  body** → §7.2 (« *Response **bodies** are never scanned or modified* ») **intact** ;
  **aucune** régression streaming (le body continue de couler part-par-part). Pose toute la
  plomberie réutilisable (`HookEvent.onResponse`, méthode RPC `on_response`, chaîne réponse
  du dispatcher, gating `status` au response head, point d'interception dans le relais).
- **PR ultérieure — `buffered`-modify de body** : le plugin lit/réécrit le **body** de
  réponse sous cap. **Là** seulement intervient le relâchement explicite de §7.2 (body) + le
  collecteur de réponse bufferisé gaté (régression streaming assumée du Phase 2.x pour les
  requêtes matchées). **Gaté sur un plugin concret** — hors scope ici.
- **PR ultérieure — `streaming`-modify** : transform chunk-par-chunk préservant le
  streaming. Réassemblage de frames SSE + plugin à état. Plus tardif encore.

### Dans le périmètre (ce PR)

- `HookEvent.onResponse` (réutilise `HookMatch.status` posé par `onComplete`).
- Type IPC `OnResponseParams` + résultat `OnResponseResult` (`pass | modify(headers)`),
  méthode `on_response` en **request/response** NDJSON (bloquant, comme `on_request`).
- `PluginHost.onResponse` + ajout au protocole `PluginInvoking`.
- Chaîne `onResponse` séparée dans `HookDispatcher` + publication par `PluginHostManager`.
- Point d'interception unique : `UpstreamResponseRelay` (`case .head`), via une closure
  optionnelle passée par `MITMHandler`/`UpstreamClient.stream`.
- Extension du plugin d'exemple `header-tagger` (doc vivante + véhicule de test).
- Tests unitaires (mock) + intégration (plugin réel) + sécurité (value-free) + régression
  streaming (chemin NIO pur byte-for-byte inchangé quand aucun hook n'applique).

### Hors périmètre (justifié)

- **`onResponse` body** (`buffered` / `streaming`) → PR ultérieures (voir §1 séquençage).
- **Modification du status code** → headers-only ce PR (R3).
- **Config schema-driven** (D6) — phase séparée ; `onResponse` est déclaré au manifest.
- **Nouveau CLI / nouvelle UI** — déclaré dans `plugin.json` ; `iris plugin list/info` et la
  section Réglages « Plugins » existantes le couvrent sans changement.
- **`.pkg` Phase 9** embarquant/signant `iris-sandbox-exec` — maintenance distincte,
  orthogonale à `onResponse`.

---

## 2. Décisions tranchées (brainstorm)

| # | Axe | Décision |
|---|-----|----------|
| R1 | Mode de livraison | **`metadata` seul** ce PR (status + headers). `buffered`/`streaming` de body différés, gatés sur un plugin concret (D5, §1). |
| R2 | Transport | **Request/response NDJSON** `on_response` (avec `id`, réponse attendue), comme `on_request`. Le hook est **sur le chemin critique** : le relais retient le head jusqu'à la réponse du plugin (ou timeout). |
| R3 | Surface de modification | **Headers-only.** Le status code est **lecture seule** ce PR — le modifier casse la gestion d'erreur côté outil hôte, rarement utile. Le **body n'est jamais** transmis ni modifiable. |
| R4 | Échec / timeout | **`onFailure: skip` seul.** Une réponse upstream **existe déjà** quand le hook tourne → `block` n'a aucun sens ; il est **rejeté à la validation du manifest** pour les hooks réponse. Timeout/crash/erreur → on relaie le head **original** (jamais d'altération). `timeoutMs` par hook, plafonné par Iris (parité `onRequest`). |
| R5 | Capability | **Aucune nouvelle capability sandbox.** Les capabilities = portée sandbox (réseau/fs). Voir/modifier les headers de réponse = donnée livrée par IPC, gatée par la déclaration du hook au manifest + approbation à l'enable (D3/D4). |
| R6 | Gating | **Deux temps.** (a) *Pré-gate à l'émission de la requête* : `hosts`/`methods`/`pathRegex`/`contentType` (request) connus → si aucun hook `onResponse` ne pré-matche, la closure passée au relais est `nil` → chemin de réponse **strictement identique à v1, zéro coût**. (b) *Gate au response head* : pour les plugins pré-qualifiés, `HookMatch.status` est évalué contre le **vrai** status ; seuls les matchants reçoivent l'IPC. |
| R7 | Chaîne | Chaîne `onResponse` **séparée et homogène** (parité `onRequest`/`onComplete`), même tri par `order`. **Fold ordonné** : chaque plugin voit les headers du précédent ; pas de `block`/`respond` (R3/R4) → pas de court-circuit, la chaîne se déroule entière. |
| R8 | SPECS | **Clarification, pas relâchement.** §7.2/§7.3 explicitent : les plugins peuvent **observer/modifier la ligne de statut et les headers** de réponse ; les **bodies** restent jamais scannés/modifiés/bufferisés. |

---

## 3. Invariants conservés / clarification SPECS

- **SPECS §7.2** (« Response **bodies** are never scanned or modified ») — **intact**.
  `onResponse` mode `metadata` ne reçoit **pas** le body, ne le bufferise pas, ne le modifie
  pas. La clarification R8 précise que *headers/status* sont, eux, observables/modifiables —
  ce que le texte littéral de §7.2 (« bodies ») n'interdit pas.
- **SPECS §7.3** (streaming SSE/chunked « forwarded without buffering or modification ») —
  **intact pour le body**. `UpstreamResponseRelay` continue de relayer chaque `.body`/`.end`
  **part-par-part, non bufferisé, flush immédiat** (`UpstreamResponseRelay.swift:22-23,73-84`).
  Le mode `metadata` n'insère qu'une **pause au head** (avant le premier body part), jamais
  dans le flux du body. Quand aucun hook n'applique (R6.a), le chemin est **byte-for-byte
  celui de v1**.
- **CLAUDE.md §6.1 / plugins-design §9.2** (value-free) — l'`uri` transmise est l'**URI
  originale**, capturée **avant** substitution (`MITMHandler.swift:119`, en placeholder-form
  `{{kc:NAME}}`). Les **headers de réponse** proviennent d'upstream (Anthropic/GitHub) et
  **n'échoient jamais** les secrets d'Iris (substitués côté requête, jamais renvoyés). Dans
  les events/logs d'Iris : on enregistre les **noms** de headers touchés, **jamais** les
  valeurs (R8/§6.1).
- **plugins-design §3** (invariant central) — `onResponse` agit **après** le pipeline requête
  complet (scan/scoping/substitution déjà appliqués sur l'egress) ; il ne peut rien
  désactiver ni contourner côté requête. Côté réponse, il est borné à **headers-only** (R3).
- **Robustesse process** — un plugin `onResponse` mort/lent ne **casse jamais** la réponse :
  timeout par hook (R4) → relai du head **original** ; `F_SETNOSIGPIPE`
  (`PluginHost.swift:111`) → écriture vers un plugin mort en `EPIPE` (catché), jamais SIGPIPE.

> **Nouveau principal de confiance, côté réponse.** Contrairement à `onComplete` (lecture
> seule, après coup), `onResponse` est **sur le chemin critique** et **modifie** ce que reçoit
> l'outil hôte (headers). Un plugin mal écrit peut altérer des headers (ex. `content-type`,
> `cache-control`) que Claude Code interprète. Garde-fous : headers-only (pas de corruption
> du body / des blocs `tool_use` qui vivent dans le body) ; `skip` sur échec ; chaîne sans
> court-circuit ; gating strict ; approbation à l'enable.

---

## 4. Déclenchement (quand `onResponse` se déclenche)

Règle unique : **au response head**, dans `UpstreamResponseRelay.channelRead`, branche
`case .head` (`UpstreamResponseRelay.swift:59`), **avant** l'écriture du head au client
(`clientChannel.write(...head...)`, ligne 72).

```
upstream .head ──▶ pré-gate (R6.a) ? ──non──▶ write head  (NIO pur, identique à v1)
                          │ oui
                          ▼
                  onResponse chain (IPC, timeout)   ◀── status-gate par plugin (R6.b)
                          │  pass / modify(headers) / skip(timeout|fail)
                          ▼
                  write head (modifié|original) ──▶ body parts INCHANGÉS ──▶ end
```

- Le `/__iris_ping` diagnostic (`MITMHandler.swift:101`) retourne avant ce chemin → pas de
  `onResponse` (cohérent : pas une requête proxifiée).
- Échec upstream **avant** le head (502, `MITMHandler.swift:234` `!headWritten`) → aucun head
  upstream → `onResponse` **ne se déclenche pas** (rien à observer). Cohérent avec R3
  (headers-only d'une réponse réelle). `onComplete` reste, lui, le canal du `status=0`.

---

## 5. Gating à deux temps (R6)

**(a) Pré-gate — à l'émission de la requête** (`MITMHandler.forwardRequest`, là où `onRequest`
et le câblage `stream(...)` vivent déjà). Iris évalue les conditions **connues à ce stade**
(`hosts`/`methods`/`pathRegex`/`contentType` request) sur la chaîne `onResponse`. Si **aucun**
plugin ne pré-matche → la closure `responseHeadHook` passée à `UpstreamClient.stream` est
`nil` → le relais garde son comportement v1 exact (zéro sérialisation, zéro `await`).

**(b) Gate au head — quand le status est connu.** Pour les plugins pré-qualifiés, la closure
évalue `HookMatch.status` (posé par `onComplete`, `PluginManifest.swift:159`) contre le status
réel du head ; seuls les matchants reçoivent l'IPC. Un plugin `"status": [500,502,503]` ne
voit que les erreurs serveur.

Parité avec `onRequest`/`onComplete` : **gating avant tout IPC**, une réponse sans hook
applicable ne paie rien.

---

## 6. Protocole IPC

Méthode **`on_response`** (request/response, daemon → plugin → daemon), **bloquant** :

```json
// daemon → plugin
{ "jsonrpc": "2.0", "id": 42, "method": "on_response",
  "params": { "method": "POST", "uri": "/v1/messages", "host": "api.anthropic.com",
              "status": 200,
              "headers": [["content-type","text/event-stream"], ["x-ratelimit-remaining","12"]] } }

// plugin → daemon  (action = pass | modify ; headers superposés par nom)
{ "jsonrpc": "2.0", "id": 42,
  "result": { "action": "modify", "headers": [["x-iris-tagged","1"]] } }
```

- **Request/response** (R2) : `id` présent, réponse attendue. Le relais retient le head
  jusqu'à la réponse (ou `timeoutMs`).
- `OnResponseParams` : `method`, `uri` (placeholder-form), `host`, `status: Int`,
  `headers: [[String,String]]` (paires ordonnées, casse préservée).
- `OnResponseResult` : `action ∈ {pass, modify}`. `pass` → head inchangé. `modify` → les headers
  renvoyés sont **superposés par nom** (`replaceOrAdd` : les headers non cités sont préservés, pas
  de suppression en v1) — **cohérent avec l'overlay éprouvé d'`onRequest`** (`HookDispatcher.swift`
  §applyModify), plus sûr qu'un remplacement (un tagger n'a pas à ré-émettre les autres headers).
  Status jamais modifiable (R3).
- `PluginRPC.Method.onResponse = "on_response"`. Forme **plate** pilotée par `action`, comme
  `on_request` (plugins-design §9.1).

---

## 7. Architecture & pièces touchées

Toutes des **extensions** de patterns posés par `onRequest` (P1→P3) et `onComplete` (#86).

| Fichier | Changement |
|---|---|
| `Sources/IrisKit/Plugins/PluginManifest.swift` | `HookEvent.onResponse = "on_response"` ; validation : `onFailure: block` rejeté pour hooks réponse (R4). `HookMatch.status` déjà présent. |
| `Sources/IrisKit/Plugins/PluginRPC.swift` | `OnResponseParams`, `OnResponseResult` (`action` + `headers`) ; `Method.onResponse`. |
| `Sources/IrisKit/Plugins/PluginHost.swift` | `func onResponse(_ params:, timeout:) async throws -> OnResponseResult` — encode la requête, `pending` par `id`, attend la réponse (parité `onRequest`) ; conformance `PluginInvoking`. |
| `Sources/IrisKit/Plugins/HookDispatcher.swift` | `responseChainBox` + `updateResponseChain(_:)` ; `func onResponse(head:host:method:path:contentType:) async -> HTTPHeaders` — gate (R6.b) + fold ordonné des plugins applicables (R7). Erreur/timeout d'un plugin → on garde les headers courants (skip, R4). Ajout `onResponse` à `PluginInvoking`. |
| `Sources/IrisKit/Plugins/PluginHostManager.swift` | `republishChain` publie **aussi** la chaîne `onResponse` (filtre `event == .onResponse`, même tri `order`), mise à jour atomique des trois chaînes. |
| `Sources/IrisKit/Proxy/UpstreamClient.swift` | `stream(...)` gagne `responseHeadHook: (@Sendable (HTTPResponseHead) -> EventLoopFuture<HTTPResponseHead>)?` ; transmis au relais. |
| `Sources/IrisKit/Proxy/UpstreamResponseRelay.swift` | `case .head` : si `responseHeadHook == nil` → write immédiat (v1) ; sinon → retient le head, appelle le hook (bridge async↔EL **EL-confiné**), écrit le head résolu, puis reprend. Reads gatés sur writability → **pas d'accumulation de body** pendant l'attente. |
| `Sources/IrisKit/Proxy/MITMHandler.swift` | construit `responseHeadHook` (nil si pré-gate R6.a vide) à partir de `host`/`originalMethod`/`originalURI`/`originalContentType` + `hookDispatcher.onResponse(...)`. |

### 7.1 Bridge async↔EventLoop (contrainte de design)

Le relais est **pur NIO synchrone, EL-confiné** (`UpstreamResponseRelay.swift:31`,
`UpstreamClient.swift:33-34` « no `async` on this hot path »). Le hook est `async` (IPC). La
contrainte de design — forme exacte tranchée au plan — est :

1. L'écriture du head résolu se fait **sur l'EventLoop** du relais (parité du relais
   inter-canaux : pas de hop d'EL pour écrire entre canaux).
2. **Aucun body part n'est bufferisé** : on s'appuie sur le read-gating existant
   (`read(context:)`, ligne 105) — on n'émet pas de nouveau read upstream tant que le head
   n'est pas écrit, donc au plus le(s) part(s) déjà en vol côté TCP attendent dans le socket,
   pas dans un buffer applicatif.
3. Le hook renvoie un `EventLoopFuture<HTTPResponseHead>` (l'`await dispatcher.onResponse`
   enveloppé via `eventLoop.makeFutureWithTask` ou équivalent), résolu sur l'EL.
4. Timeout/échec → le future résout sur le head **original** (R4).

### 7.2 `PluginInvoking` & chaîne

`PluginInvoking` gagne `func onResponse(_ params:, timeout:) async throws -> OnResponseResult`.
`republishChain` construit désormais **trois** listes homogènes (filtrées par `event` :
`onRequest`/`onResponse`/`onComplete`) et les pousse **atomiquement** (pas de fenêtre où l'une
est neuve et l'autre périmée). Un plugin déclarant plusieurs hooks produit une entrée par
chaîne.

---

## 8. Plugin d'exemple (`header-tagger`)

`header-tagger` gagne **aussi** un hook `onResponse` : sur les réponses matchées, il ajoute un
header `x-iris-tagged: 1`. Double bénéfice :

- **Doc vivante** des trois hooks (`onRequest`/`onResponse`/`onComplete`) dans un exemple
  cohérent.
- **Véhicule de test d'intégration** : le test lit le header injecté côté client pour prouver
  la livraison `on_response` **et** que le body a streamé inchangé.

Le montage des cibles sources (`Package.swift` principal + package exemple) suit P5/#86.

---

## 9. Tests & critères de succès (cf. `CLAUDE.md §7`, plugins-design §12)

| Niveau | Ce qui est prouvé |
|---|---|
| **Unit (mock `PluginInvoking`)** | Gating pré-gate (host/method/path/contentType) **et** status-gate (R6) ; fold ordonné de la chaîne (plugin 2 voit les headers du plugin 1, R7) ; `skip` sur timeout **et** sur crash → head original (R4) ; `pass` laisse le head intact ; `modify` remplace bien le set de headers ; status jamais modifié (R3). |
| **Intégration (daemon éphémère + `header-tagger`)** | Vraie requête proxifiée vers un mock upstream **streaming (SSE)** → le client voit `x-iris-tagged` **et** le body arrive **part-par-part inchangé** (preuve : timing/ordre des chunks préservé) ; un plugin `onResponse` **lent/mort ne casse pas** la réponse (relai du head original, mutation-vérifié : rouge si l'échec propageait au lieu de skip — Rule 9). |
| **Régression streaming** | Requête **non-matchée** → réponse **byte-for-byte** celle de v1 (chemin NIO pur, `responseHeadHook == nil`) ; suite proxy (`ProxyEndToEndTests`, streaming) verte. |
| **Sécurité** | Un dump de `OnResponseParams`/events ne contient **jamais** de valeur de secret (`uri` placeholder-form) ; les events loggent les **noms** de headers touchés, jamais les valeurs (R8/§6.1). |

**Definition of done :**
1. `swift build -c release` **0 warning** ; `swift test` vert ; `swift-format lint --strict`
   clean.
2. Test de non-blocage / skip-sur-échec **vert et rouge sur un échec propagé** (mutation-vérifié).
3. Test de régression streaming **vert et rouge si un `await` était inséré sur le chemin
   non-matché** (prouve le zéro-coût du pré-gate).
4. CI macos-15 verte (juge final).
5. Checklist de smoke testing de la PR cochée (daemon éphémère isolé : header injecté sur
   requête matchée, réponse SSE intacte ; requête non-matchée inchangée).

---

## 10. Risques & suivis

- **Latence sur chemin critique** : contrairement à `onComplete`, `onResponse` **retient le
  head** jusqu'à la réponse du plugin. Surcoût = un aller-retour IPC, **uniquement sur les
  requêtes matchées**, plafonné par `timeoutMs`. Pour une réponse SSE, c'est un délai au
  **premier** byte ; les bytes suivants streament normalement. Borné, gaté, documenté.
- **Modes `buffered`/`streaming` de body** : PR ultérieures, gatées sur un plugin concret.
  **Là** seulement le relâchement §7.2 (body) + le collecteur bufferisé (régression streaming).
- **Modification du status code** : exclue ce PR (R3). À rouvrir si un cas concret l'exige.
- **Doc plugin (manuel ch. 23)** : décrire le 3ᵉ hook lors d'un passage doc ultérieur.

---

## 11. Références

- `docs/plugins-design.md` (§1, §3, §4.2-4.3, D5, §8, §9.1-9.2, §13) — design v1 + D5
  (modes de livraison réponse).
- `docs/plugins-oncomplete-design.md` — PR prédécesseure (pose `HookMatch.status`,
  forward-référence cette PR).
- `docs/superpowers/specs/2026-06-02-response-streaming-design.md` — chemin réponse Phase 2.x
  (motivation du non-conflit §7.2 body et du relais part-par-part).
- Code : `Sources/IrisKit/Plugins/{PluginManifest,PluginRPC,PluginHost,HookDispatcher,PluginHostManager}.swift`,
  `Sources/IrisKit/Proxy/{MITMHandler,UpstreamClient,UpstreamResponseRelay}.swift`.
- SPECS : §7.2 (bodies jamais modifiés), §7.3 (streaming non bufferisé), §8.2 (host matching).
