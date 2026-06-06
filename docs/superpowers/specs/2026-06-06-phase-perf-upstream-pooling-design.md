# Phase perf — Pool de connexions upstream — Design

> Date : 2026-06-06
> Branche : `feat/phase-perf-upstream-pooling`
> Statut : design validé, en attente du plan d'implémentation.

## 1. Objectif

Supprimer le surcoût de latence dominant du proxy : le **re-handshake TLS vers l'upstream à chaque requête**. Aujourd'hui `irisd` ouvre une connexion TCP+TLS neuve vers l'upstream par requête, puis la ferme. On introduit un **pool de connexions keep-alive upstream**, par-EventLoop, keyed par host.

Cette phase ne couvre **que l'upstream**. Le keep-alive côté client (gain ~3 ms) et HTTP/2 upstream (multiplexing) sont hors-scope, éventuelles phases ultérieures.

## 2. État de départ (mesuré et vérifié, 2026-06-06)

Aucun benchmark dans le repo ; mesure manuelle `curl -w` (direct vs `--proxy 127.0.0.1:8888 --cacert ca.pem`), 6 requêtes keep-alive, `--http1.1` des deux côtés.

| Scénario | TTFB moyen |
| --- | --- |
| Direct, connexion fraîche | ~29 ms |
| Direct, keep-alive (req 2+) | **~9 ms** (1 RTT, 0 handshake) |
| Via Iris (toutes les req) | **~38 ms** |

- **Surcoût net ≈ +29 ms/req** face à un client keep-alive (cas `claude`/undici), sur ce réseau (RTT ≈ 9 ms). Scale avec le RTT : sur RTT 40 ms → ≈ +120 ms/req.
- **Cause confirmée par le code** : Iris ne garde **aucune connexion ouverte**.
  - Client : `MITMHandler.swift:14` (« One request per connection ») + l.199 `channel.close()` à chaque `.end`.
  - Upstream : `UpstreamClient.stream()` ouvre une connexion neuve (`ClientBootstrap.connect`, l.55-77) et la ferme à `.end` (`completion.futureResult.whenComplete { upstream.close }`, l.106).
- **Décomposition du ~38 ms** : leaf agent→irisd (loopback) ~3 ms + handshake upstream TCP+TLS ~18 ms (≈ 2×RTT) + aller-retour upstream ~9 ms (1 RTT) + overhead ~8 ms.
- **Le coût decrypt/re-encrypt MITM symétrique est négligeable** (AES-NI ~5-10 GB/s → <0,5 ms/MB) ; le coût crypto qui compte est le **handshake asymétrique**, précisément ce que le pool amortit.
- Caches déjà en place (hors hot-path latence) : leaf cert (`LeafCertCache.swift:32`, one-time/host), valeur secret (`PlaceholderEngine.swift:53`, TTL 5 min).

## 3. Décisions de scope (tranchées)

| Décision | Choix retenu |
| --- | --- |
| Périmètre | **Pool upstream seul.** Keep-alive client et HTTP/2 hors-scope. |
| Paramètres du pool | **Constantes internes** (pas dans `config.json`) : cap = 4 idle/host/EventLoop, idle-timeout = 30 s. Documentées ici, injectables pour les tests. |
| Approche | **A — pool par-EventLoop, lazy, keyed par host.** Pas de pool global cross-EL (B, casse la co-localisation EL), pas de dépendance tierce (C, `async-http-client` non listé CLAUDE.md §1 + reprendrait le relais maison). |
| Client | **Inchangé** : reste 1-req/conn (`MITMHandler` non touché). |
| Livraison | Spec + plan cette session ; implémentation ultérieure. |

## 4. Faits techniques vérifiés

- Le pool par-EventLoop **pré-alloué à l'init** confine tout l'état mutable à un EL mono-thread → **aucun lock**. Le dictionnaire `[ObjectIdentifier(EventLoop): pool]` est **immuable après init** (lecture seule depuis n'importe quel EL = safe).
- La co-localisation client/upstream sur le même EL est l'**invariance du relais inter-canaux** (Phase 2.x, « relais sans hop ») : un pool par-EL la préserve, un pool global la casserait.
- Réutiliser une connexion HTTP/1.1 exige une réponse à framing délimité (`Content-Length` ou `Transfer-Encoding: chunked`) **et** l'absence de `Connection: close` / HTTP/1.0.
- Clé de pool = **host** ; le `serverHostname` TLS (`NIOSSLClientHandler`, `UpstreamClient.swift:60-63`) est figé à la création → une connexion ne peut jamais servir un autre host. **Pas de bypass de scoping** via mutualisation.

## 5. Architecture

### 5.1 Nouveau type `UpstreamConnectionPool` (`Sources/IrisKit/Proxy/`)

Un par EventLoop (`final class`), tout son état touché **uniquement sur son EL** :

- état : `[host: [PooledConnection]]` — les connexions **idle** disponibles.
- `acquire(host, port, sslContext) -> EventLoopFuture<Channel>` : dépile une connexion idle vivante pour ce host ; sinon en ouvre une neuve (le `ClientBootstrap` actuel, SSL + HTTP client handlers installés à la création).
- `release(host, channel, reusable: Bool)` : si `reusable` et sous le cap → remet en idle + (ré)arme l'idle-timeout ; sinon `close`.
- `shutdown() -> EventLoopFuture<Void>` : ferme toutes les idle (arrêt du daemon).
- init paramétrable : `cap` (déf. 4) et `idleTimeout` (déf. 30 s) injectables pour des tests déterministes — **pas exposés en config**.

`PooledConnection` = `{ channel, host, idleTimeoutTask: Scheduled<Void>? }`. Le `channel` conserve **SSL + HTTP client handlers** (handshake amorti, framing réutilisé) ; seul le relais est jetable (§5.3).

### 5.2 `UpstreamClient` (modifié)

`stream()` ne fait plus `connect` + `close`. À la place :

1. Résout le pool de l'EL courant (`pools[ObjectIdentifier(eventLoop)]`).
2. `pool.acquire(host, port, sslContext)`.
3. Installe un **relais frais** en queue de pipeline, armé pour cette requête.
4. Écrit `head`+`body`+`end` ; le relais streame la réponse (comportement 2.x).
5. À la fin du stream, `pool.release(host, channel, reusable:)`.

`UpstreamClient` détient le dict immuable `[ObjectIdentifier(EventLoop): UpstreamConnectionPool]`, construit à l'init en itérant les EventLoops du `group`.

### 5.3 `UpstreamResponseRelay` (modifié) — découpage persistant / jetable

- **Persistant** (poolé) : `NIOSSLClientHandler` + `HTTPClientHandlers`.
- **Jetable** (par requête) : le `UpstreamResponseRelay`, installé à l'emprunt, qui **se retire lui-même** du pipeline (`removeHandler`) à `.end` ou à l'échec, libère ses refs par-requête, et signale le résultat via `completion` avec un drapeau **`reusable`**.

Choix « retirer/réinstaller un relais frais » plutôt que « ré-armer un relais persistant » : garde chaque relais immuable et sans état résiduel entre requêtes (raisonnement et tests plus simples ; pas de setter externe violant le confinement EL). Le coût add/remove handler est négligeable vs le handshake économisé.

### 5.4 Inchangé

`MITMHandler` (client 1-req/conn), `PlaceholderEngine`, `ExfilRuleEngine`, le modèle de sécurité, `config.json`. Aucune dépendance ajoutée.

## 6. Data flow (une requête)

1. `MITMHandler` traite la requête (scan/substitution/exfil — inchangé) et appelle `UpstreamClient.stream()`.
2. `acquire(host)` → channel idle réutilisé (SSL+HTTP en place) **ou** neuf.
3. Relais frais installé + armé (clientChannel/completion/headWritten de cette requête).
4. Écriture head+body+end ; réponse streamée vers le client au fil de l'eau.
5. À `.end` : le relais se retire, calcule `reusable`, résout `completion`.
6. `release(host, channel, reusable:)` → idle (timer armé) ou close.
7. Côté client : `MITMHandler` ferme le `clientChannel` (inchangé). La connexion upstream survit pour la requête suivante.

## 7. Robustesse / error handling

1. **Staleness** :
   - au `acquire`, on saute les connexions `!channel.isActive` (jetées), sinon on en ouvre une neuve ;
   - **retry-once** : si l'écriture échoue ou si le channel devient inactif **avant** toute réponse (`headWritten == false`), réessai **unique** sur une connexion neuve. Si `headWritten == true`, pas de retry → on propage (502 si rien d'écrit, sinon close tronqué = logique 2.x actuelle). Borné à 1 (anti-boucle).
2. **Framing non réutilisable** → `reusable: false` (close) si : `Connection: close`, HTTP/1.0, corps délimité-par-fermeture (ni `Content-Length` ni `chunked`), ou erreur/troncature. Drapeau calculé au `.head`, confirmé au `.end`.
3. **Bornes & arrêt** : cap 4 idle/host/EL (au-delà, close au release) ; idle-timeout 30 s (`scheduleTask` par idle, ré-armé au retour idle, annulé à l'emprunt) ; `shutdown()` ferme tout à l'arrêt.

## 8. Sécurité (inchangée, explicite)

- Clé de pool = host ; `serverHostname` TLS figé → jamais de réutilisation cross-host (pas de bypass de scoping).
- Substitution / évaluation exfil restent strictement par requête, sur le contenu ; le pool n'agit que sur le transport.
- Une requête bloquée (exfil) ou bypassée (pause) utilise une connexion poolée normalement (elle forwarde quand même le placeholder littéral, leçon Phase 10).
- Aucune valeur de secret n'entre dans l'état du pool (clé = host, pas de contenu).

## 9. Testing & critères de succès

**Critères de succès (mesurables)** :
1. **Non-régression** : les 462+ tests passent ; streaming réponse 2.x, substitution, scoping, détection exfil inchangés.
2. **Réutilisation prouvée** : mock HTTP upstream local, 2 requêtes séquentielles même host ⇒ **une seule connexion TCP acceptée** (le mock compte les `accept`). Test d'intention central (CLAUDE.md §7 / Rule 9) — échoue si le pool ne réutilise pas.
3. **Gain mesuré** : rejouer le harnais `curl` (baseline TTFB ~38 ms) ⇒ TTFB req 2..N attendu **~20 ms** (économie ≈ handshake upstream ~18 ms), sur ce réseau.

**Tests unitaires `UpstreamConnectionPool`** (EventLoop de test, paramètres injectés) :
- `acquire` ouvre si vide ; `release(reusable:true)` puis `acquire` réutilise le **même** channel.
- cap : au-delà de 4 idle/host, `release` ferme.
- idle-timeout : idle fermée après le délai (délai court injecté).
- staleness : idle inactive sautée au `acquire`.
- `shutdown` ferme toutes les idle.

**Tests d'intégration** (harnais mock HTTP local existant) :
- réutilisation (critère #2) ;
- **retry-once** : le mock ferme après la 1ʳᵉ réponse ⇒ 2ᵉ requête réussit via connexion neuve ;
- **framing non réutilisable** : le mock répond `Connection: close` ⇒ 2 connexions TCP observées.

## 10. Hors-scope (phases ultérieures éventuelles)

- Keep-alive côté client (agent→irisd) — gain ~3 ms.
- HTTP/2 upstream (multiplexing, 1 connexion) — gros chantier `nio-http2`.
- Exposition des paramètres du pool dans `config.json` / UI Settings.
- Métriques de pool (taux de réutilisation) dans `iris doctor` ou les events.
