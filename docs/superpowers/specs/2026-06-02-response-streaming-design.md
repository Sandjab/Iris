# Phase 2.x — Streaming de la réponse upstream→client

> Faire **converger le chemin réponse du proxy MITM vers la spec** : relayer la réponse
> upstream→client **au fil de l'eau, sans bufferisation** (SPECS §7.3, §10 étape 12),
> au lieu de l'agréger entièrement avant réémission. Approche : un relais part-level
> inter-canal façon `GlueHandler`, en **backpressure propre** (la *writability* du canal
> client gate la lecture de l'upstream). HTTP/1.1 uniquement, réponse jamais
> scannée ni modifiée. **Écart de conformité, pas nouvelle feature** : le code Phase 2
> a pris un raccourci explicitement étiqueté « Phase 2.x » (`MITMHandler.swift:7-13`,
> `UpstreamClient.swift:8`, `ProxyServer.swift:26`) jamais comblé.

## 1. Objectif et portée

### Motivation

`SPECS.md` spécifie le streaming **dès l'origine** :

- **§7.3** : « *For Server-Sent Events and chunked responses going upstream→client, the
  broker forwards bytes **without buffering or modification***. »
- **§10, étape 12** : « *Daemon proxies bytes **verbatim** back to the agent over the
  agent-facing TLS, **no buffering***. »
- **§7.2** : « *Response bodies are **never** scanned or modified*. »

Le code actuel **viole §7.3 / §10.12** : `UpstreamClient.UpstreamResponseCollector`
(`UpstreamClient.swift:87-130`) attend `.end` avant de résoudre son promise, puis
`MITMHandler.writeResponse` (`MITMHandler.swift:484`) recrache la réponse d'un bloc.

**Impact UX réel et mesurable :** pointer `claude` (réponses **SSE streaming** ; les
tokens arrivent en events `message_start`/`message_delta`) sur Iris produit un
**silence** pendant toute la génération puis le texte **d'un seul bloc** —
time-to-first-byte = durée de génération complète. C'est la lacune qui motive ce lot.

La moitié **requête** de §7.3 (« buffer ≤ limite, scan, substitute, re-emit ») est
déjà conforme (`MITMHandler` Phase 2 + cap 4 MiB + scan/substitute Phase 4). Seule la
moitié **réponse** manque.

### Dans le périmètre

- Refonte du chemin réponse : relais **part-level** (`HTTPClientResponsePart` →
  `HTTPServerResponsePart`) upstream→client, au fil de l'eau.
- **Backpressure propre** : la *writability* du canal client gate le `read()` upstream.
- Co-localisation du canal upstream sur l'`EventLoop` du canal client.
- Gestion d'erreur des trois moments (avant head / mid-stream / client-drop).
- Émission d'`Event` adaptée (à `.end`, statut capturé au head).
- Extension du harnais `MockUpstream` pour streamer une réponse chunkée synchronisée.

### Hors périmètre (justifié)

- **HTTP/2** côté MITM (§7.6 / §11.5 : ALPN force `http/1.1`, downgrade transparent —
  reste roadmap ; l'approche A s'en passe).
- **Streaming de la requête** : la requête reste bufferisée/scannée/substituée — c'est
  ce que §7.3 mandate côté requête. Inchangé.
- **Scan/substitution de la réponse** (§7.2 : jamais).
- **Keep-alive** (réutilisation de la connexion client↔proxy pour plusieurs requêtes) :
  écart séparé, connexion-par-requête conservée.
- **Timeout idle applicatif** : aucun aujourd'hui ; un SSE long (heartbeats) doit rester
  ouvert ; on s'appuie sur les timeouts TCP/TLS système.
- **Point d'inspection/tap de réponse** (préalable du futur compteur de tokens,
  extensions approche C) : on ne le construit pas (YAGNI) ; le design ne fait que **ne
  pas se fermer la porte**.
- **Backpressure du `GlueHandler` de passthrough** : même manque, mais non requis ici
  (voir §8).
- **Métrique time-to-first-byte** : nouveau champ d'`Event`, différé (voir §6).

## 2. Décisions tranchées

1. **Backpressure propre, pas relais naïf** (posture (a)). La mémoire est plafonnée par
   le watermark NIO, jamais par une réponse entière en RAM.
2. **Approche A — relais part-level inter-canal façon `GlueHandler`.** Écartées :
   - **B (`AsyncThrowingStream`)** : la backpressure propre y est contre-nature
     (`bufferingNewest` *drop* — inacceptable pour un proxy ; une vraie backpressure
     impose de réimplémenter à la main le gating que NIO fait nativement). Leçon mémoire
     « SSE backpressure inatteignable via AsyncStream » (refonte `EventsClient` 6.1b).
   - **C (refonte `NIOAsyncChannel`)** : la solution propre **le jour où HTTP/2 forcera
     la refonte** (décision Phase 2.2 : garder le pattern `ChannelHandler` raw tant que
     h2 ne force pas). Le streaming réponse ne *force* pas NIOAsyncChannel → sur-
     dimensionné et contraire à une décision actée aujourd'hui.
3. **Co-localisation EL** : le canal upstream est ouvert sur l'`EventLoop` du canal
   client, comme `performPassthrough` (`ConnectHandler.swift:178`). C'est la condition
   de sûreté du relais inter-canal (`GlueHandler.swift:14-18` documente le même
   invariant : « both channels share the same EventLoop »).
4. **HTTP/1.1**, réponse jamais modifiée, connexion-par-requête conservée.

⚠️ **Correction d'un modèle mental** : le `GlueHandler` **du repo** ne fait **pas** de
backpressure propre — il forward `channelRead → partner.write` /
`channelReadComplete → partner.flush` (`GlueHandler.swift:41-47`) sans gater les
`read()`, s'appuyant sur `autoRead` + le buffer sortant NIO. C'est le forward **naïf**
(posture (b)). Le `GlueHandler` **canonique** de swift-nio override `read(context:)` et
le conditionne à la writability du partenaire. Notre `UpstreamResponseRelay` doit
inclure ce gating — c'est ce qui distingue A (propre) de (b).

## 3. Architecture et flux

```
   Canal CLIENT (EventLoop e)                         Canal UPSTREAM (MÊME EventLoop e)
   ┌──────────────────────────┐                       ┌──────────────────────────┐
   │ NIOSSLServerHandler       │                       │ NIOSSLClientHandler       │
   │ HTTPRequestDecoder        │                       │ HTTP client handlers      │
   │ HTTPResponseEncoder  ◄────┼──── parts réponse ────┤ UpstreamResponseRelay     │
   │ MITMHandler  ─────────────┼──── requête substituée┼───► (envoyée à l'ouverture)│
   └──────────┬───────────────┘                       └─────────────┬────────────┘
              │   writability(client) ──── gate read() ────────────►│
```

### Trois unités, frontières nettes

1. **`MITMHandler` (canal client) — moitié requête INCHANGÉE.** `channelRead` bufferise,
   `processRequest` scan/substitue (cap 4 MiB, §7.3 requête déjà conforme). Seul
   `forwardRequest` change : au lieu de `upstreamClient.send() -> UpstreamResponse`
   bufferisé puis `writeResponse`, il demande à `UpstreamClient` d'ouvrir l'upstream
   **sur `context.eventLoop`**, d'envoyer la requête substituée, et de **câbler le
   relais** vers `context.channel`. La méthode statique `writeResponse`
   (`MITMHandler.swift:484`) est supprimée. Le ping `/__iris_ping`
   (`MITMHandler.swift:96-112`) reste inchangé. Substitution = côté requête uniquement,
   donc rien ne change pour la résolution des secrets ni `recordSubstitution`
   (`MITMHandler.swift:394`).

2. **`UpstreamResponseRelay` (canal upstream) — REMPLACE `UpstreamResponseCollector`.**
   `ChannelInboundHandler`, `InboundIn = HTTPClientResponsePart`. Traduit chaque part en
   `HTTPServerResponsePart` et l'écrit sur le canal client : `.head` (capture le
   `statusCode`, relaie le head), `.body(chunk)` → **write + flush** (le cœur du temps
   réel : chaque chunk poussé immédiatement), `.end` → flush + résolution du handle de
   complétion. Inclut le `read()`-gating (§4). Unité testable isolément.

3. **`UpstreamClient` — API streaming.** De « renvoie un `UpstreamResponse` bufferisé »
   à « ouvre l'upstream **sur l'EL fourni**, envoie la requête, câble le relais vers le
   canal client, et renvoie une `EventLoopFuture<StreamOutcome>` qui se résout **à la
   fin du stream** en portant `{ statusCode }` » (pattern future natif NIO, tout sur
   l'EL — pas d'`async` dans ce chemin). Le bootstrap passe de
   `ClientBootstrap(group: self.group)` (`UpstreamClient.swift:38`, EL arbitraire via
   `group.next()`) à `ClientBootstrap(group: clientEventLoop)`. ALPN `http/1.1`
   inchangé (`UpstreamClient.swift:33`).

### Invariants conservés

- Réponse **ni scannée ni modifiée** (§7.2) — pur relais.
- `Event` porte l'URI/méthode **originales** (§6.1, `MITMHandler.swift:127-128`).
- Connexion-par-requête : client + upstream fermés après `.end`.

## 4. Backpressure

Objectif : ne jamais lire l'upstream plus vite que le client ne draine ; mémoire
**bornée**. Sur primitives NIO documentées (et déjà utilisées : `autoRead` est manipulé
dans `ConnectHandler.swift:103,140,171,234`).

1. **`autoRead = false` sur le canal upstream** → lecture explicite par `read()`. Le
   canal client garde son `autoRead` normal pour la phase requête.
2. **La *writability* du canal client est le signal de frein.** `Channel.isWritable`
   bascule `false` au-delà du **high-watermark** (défaut 64 KiB), `true` sous le
   **low-watermark** (32 KiB) — c'est la borne mémoire.
3. **Gating croisé (paire appariée, co-localisée même EL) :**
   - le relais reçoit une part → `write`+`flush` vers le client ;
   - après le flush, il ne ré-arme `read()` sur l'upstream **que si le client est
     `isWritable`** ; sinon il marque un read en attente ;
   - sur `channelWritabilityChanged` du client (redevenu writable) → on déclenche le
     `read()` upstream en attente.
4. **Résultat :** client lent → buffer sortant client plein → `isWritable=false` → on
   cesse de lire l'upstream → la backpressure TCP remonte jusqu'au serveur réel. Mémoire
   plafonnée par le watermark.

Le câblage exact (un handler côté upstream + un côté client, ou un duplex apparié) sera
calé sur le `GlueHandler` canonique de swift-nio au plan d'implémentation.

## 5. Gestion d'erreur

Pivot : **« le head de réponse a-t-il déjà été relayé au client ? »**

| Cas | Moment | Comportement |
|---|---|---|
| **1. Upstream injoignable** | avant le head | Renvoyer **`502 Bad Gateway`** au client + `Event(.error)`. Aligne le MITM sur le passthrough (`ConnectHandler.swift:190-197`). Amélioration vs l'actuel (ferme sans statut). |
| **2. Upstream drop / erreur mid-stream** | après le head | Statut déjà parti → **fermer le canal client** (réponse tronquée, standard HTTP). `Event` avec outcome d'origine + `statusCode` du head + `durationMs` + **log warning « stream interrompu »** (on ne corrompt pas le `kind`). |
| **3. Client drop mid-stream** | pendant | `channelInactive` du client → **fermer le canal upstream** (libère la connexion). `Event` avec ce qu'on a + log. Symétrique à `GlueHandler.swift:49-51`. |
| **4. Erreur requête/substitution** | avant forward | **Inchangé** (géré dans `processRequest`). |

**Garantie transverse — pas de canal orphelin.** Comme `GlueHandler`, toute
erreur/inactivité d'un côté ferme **les deux** canaux (`errorCaught`/`channelInactive →
partner.close`, `GlueHandler.swift:49-56`). Critique pour ne pas fuiter de connexions
upstream.

⚠️ **Piège réutilisé (leçon CONNECT-502)** : si le `502` du cas 1 est écrit depuis un
contexte hors-EL (`makeFutureWithTask`), il **doit** passer par `channel.write`
(thread-safe), **jamais** `context.write` (qui trap `inEventLoop`).

## 6. Événements et métriques

Le modèle d'`Event` est préservé presque tel quel.

- **Émission à `.end`, un seul `Event` par requête** (jamais par chunk → ni ring ni SSE
  spammés). `durationMs = startTime → fin`, sémantiquement **identique** à l'actuel
  (SPECS §10.13 émet l'Event « *on request completion* »).
- **`statusCode` capturé au `.head`**, remonté via `StreamOutcome { statusCode }` (§3).
  `MITMHandler` détient déjà l'**outcome** (pré-forward) → assemble l'`Event` comme
  `makeEvent` aujourd'hui, sans réponse bufferisée.
- **Inchangé :** `EventRing.append` + diffusion `EventsBus` SSE ; totaux par kind de
  `daemon.stats` ; `recordSubstitution` (R5) côté requête.
- **§6.1 préservé trivialement** : `Event` porte l'URI originale ; la réponse n'étant ni
  scannée ni loggée ni stockée, aucune valeur ne fuit par ce chemin.

**Différé (YAGNI) :** le streaming rend mesurable un **time-to-first-byte** (le vrai
bénéfice UX) — nouveau champ d'`Event`, hors scope tant que non demandé (naturel avec
l'observabilité / le compteur de tokens des extensions).

## 7. Tests et critères de succès

Tout reste **headless** (`MockUpstream`, pas de vrai trousseau ni vraie clé, conforme
§7 CLAUDE.md). **Extension ciblée du harnais :** `MockUpstream` doit pouvoir streamer
une réponse en N chunks avec **barrières de synchronisation**.

| Test | Ce qu'il prouve |
|---|---|
| **Streaming temps réel (pivot)** | Mock : head + chunk1, **attend confirmation client**, puis chunk2 + end. Le client reçoit chunk1 **avant** que chunk2 parte. **Mutation-vérifié** : sur l'ancien code bufferisé, le client ne reçoit rien avant `.end` → confirmation jamais émise → timeout → **le test échoue** (Rule 9). Calqué sur `testEventsClientReceivesSingleIsolatedEvent` (6.1b). |
| **Backpressure** | Client qui ne draine pas + upstream volumineux → lecture upstream **suspendue** au-delà du watermark, mémoire bornée. ⚠️ Déterminisme délicat (handler de comptage de `read()` ou watermark abaissé en test) — affiné au plan. |
| **Réponse intacte (§7.2)** | Byte-for-byte : ce que reçoit le client = ce que le mock a envoyé (headers + corps). |
| **Cas d'erreur (§5)** | (1) upstream injoignable → client reçoit **502** ; (2) drop mid-stream → réponse tronquée + fermeture + Event ; (3) client drop → **upstream fermé** (zéro fuite). |
| **Régression** | `ProxyEndToEndTests`, `ProxyExfilBlockTests`, `testHostMismatchEmitsExfilBlockedEventAndForwardsPlaceholder` restent verts. |
| **Event** | Un seul Event/requête, bon `statusCode`, `durationMs` cohérent, URI originale (§6.1). |

**Definition of done :**
1. Test pivot streaming **vert**, **et rouge sur l'ancien code** (mutation-vérifié).
2. Suite d'intégration verte + invariants §7.2/§6.1 lockés + cas d'erreur couverts.
3. `swift build -c release` **0 warning**, `swift test` vert, `swift-format lint
   --strict` clean.
4. **Smoke réel au poste : `claude` à travers Iris affiche le texte token-par-token**
   (fin du « silence puis bloc »). Juge de paix UX.

## 8. Suivis / écarts adjacents (hors scope, signalés)

- **Backpressure du `GlueHandler` de passthrough** (`GlueHandler.swift:41-47`) : même
  manque de `read()`-gating. Fix identique possible ; à décider séparément.
- **Timeout idle upstream** : absent ; raffinement futur (ne pas casser les longs SSE).
- **Time-to-first-byte** dans `Event` : avec l'observabilité / le compteur de tokens.
- **HTTP/2 MITM** (§7.6/§11.5) + **keep-alive** : roadmap, indépendants.

## 9. Références

- Code : `Sources/IrisKit/Proxy/{MITMHandler,UpstreamClient,ConnectHandler,GlueHandler,ProxyServer}.swift`.
- SPECS : §7.2, §7.3, §7.6, §10 (étapes 12-13), §11.5.
- Leçons mémoire : refonte `EventsClient` 6.1b (raw `ChannelHandler` + continuation, pas
  AsyncStream pour backpressure) ; décision Phase 2.2 (pas de `NIOAsyncChannel` hors h2) ;
  CONNECT-502 (`channel.write` ≠ `context.write` hors-EL) ; fuites d'ELG/connexions.
