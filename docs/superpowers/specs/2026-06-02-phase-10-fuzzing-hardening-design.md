# Phase 10 — Hardening : fuzzing du parser de placeholder

> Durcir la surface de substitution de secrets par un **fuzzer maison déterministe**
> (XCTest, zéro dépendance tierce) qui attaque le pipeline réel
> `PlaceholderScanner → ExfilRuleEngine → PlaceholderEngine` avec un corpus adverse,
> et vérifie trois invariants sous tous les inputs : robustesse (I1), non-fuite (I2),
> non-bypass du scoping (I3). Comble aussi le trou de couverture redaction du **flux
> SSE**. Source SPECS : phasage CLAUDE.md §12 (« Phase 10 — Hardening : tests
> d'intégration, fuzzing du parser de placeholder ») + invariants sécurité §6.
> Contexte vérifié : le code visé est déjà couvert (parser 11 tests, exfil R1–R5
> 35 tests, redaction 5 tests, ~3440 LOC d'intégration) — ce lot **comble des trous
> étroits**, il ne re-teste pas l'existant.

## 1. Objectif et portée

IRIS substitue des placeholders `{{kc:NAME}}` par de vrais secrets dans le trafic
sortant. Sa valeur repose sur deux promesses : **aucune valeur de secret ne fuit**
hors du canal upstream autorisé, et **aucune substitution n'a lieu sans match de
scope explicite**. Ces promesses sont vérifiées aujourd'hui par des tests à cas
nommés. Phase 10 les soumet à un fuzzer : un générateur d'inputs adverses
déterministe qui cherche à les violer.

Le fuzzer n'introduit aucun code de production et aucune dépendance : tout vit sous
`Tests/`. La cible de test n'est pas liée dans `irisd` / `Iris.app` / le `.pkg`
notarisé — impact nul sur le binaire distribué.

**Dans le périmètre :**
- Un PRNG déterministe seedé (SplitMix64) sous `Tests/IrisKitTests/Fuzzing/`.
- Un générateur de corpus adverse ciblant la grammaire `{{kc:NAME}}` et ses abords.
- Un harnais de fuzz exécutant le **vrai** pipeline scan → evaluate → substitute et
  asseyant I1/I2/I3 sur chaque input (corpus nommé + N itérations seedées).
- Combler le trou redaction **encodage SSE** : un Event/Alert sérialisé pour le flux
  ne contient jamais la valeur brute du secret.
- **Un** test d'intégration ciblé : secret hors-scope poussé via le proxy → rien ne
  fuit upstream (bloqué) + l'event SSE ne porte pas la valeur. Réutilise le harnais
  d'intégration existant (`CLIDaemonHarness`, `MockUpstream`).

**Hors périmètre (frontières explicites) :**
- ❌ Dépendance de fuzzing tierce (SwiftCheck, swift-property-based…) → interdit par
  CLAUDE.md (liste fermée) **et** sous-optimal ici : SwiftCheck est figé en 2019, non
  `Sendable`, incompatible avec `-strict-concurrency=complete` ; son seul atout (le
  *shrinking*) a peu de valeur sur des invariants binaires. Décision tranchée en
  brainstorming.
- ❌ Load / stress / perf-test (débit, épuisement de cache sous charge) → c'est de la
  performance, pas du hardening de correction. Autre lot si un besoin réel émerge.
- ❌ Refonte du harnais d'intégration existant → on le réutilise tel quel.
- ❌ Fuzzing des autres parsers (TOML de config, JSON-RPC IPC) → autre surface, autre
  lot. Ce lot cible le parser de placeholder.

## 2. Décisions de design

### 2.1 — Fuzzer hybride : corpus nommé + génération seedée (approche C)

Le harnais combine deux sources d'inputs :
- un **corpus nommé** de cas-régression lisibles, chacun encodant une intention
  explicite (« NAME de 65 caractères », « accolades déséquilibrées », « body
  non-UTF8 »…) — satisfait Rule 9 (le test dit *pourquoi* il existe et resterait
  pertinent si la logique métier changeait) ;
- une **passe générative seedée** sur N itérations pour la largeur de couverture.

Rejeté :
- **Corpus statique pur (A)** : couverture figée à ce qu'on a imaginé ; n'explore
  rien au-delà.
- **Génératif pur (B)** : large mais sans cas-régression nommés documentant
  l'intention ; échecs moins parlants. L'hybride garde la documentation de A et la
  largeur de B pour un coût marginal.

### 2.2 — Déterminisme par construction (PRNG seedé, pas d'aléa système)

Un PRNG **SplitMix64** (~15 lignes) conforme à `RandomNumberGenerator`, **seed
constant en dur** et **nombre d'itérations fixe** (valeur initiale **2000**, ajustable
si le CI rame). Conséquence : le corpus généré est identique à chaque run → CI stable,
**zéro flaky**. Reproduire un échec = le couple (seed, index d'itération) rejoue
l'input exact. On évite ainsi le piège du property-based à seed aléatoire (échecs
intermittents non reproductibles).

Pourquoi un PRNG maison : `SystemRandomNumberGenerator` n'est pas seedable.
SplitMix64 est un algorithme standard, court et sans dépendance.

### 2.3 — Secrets à valeur sentinelle reconnaissable

L'`InMemorySecretStore` de test est peuplé de secrets dont la **valeur** est une
sentinelle unique et improbable (ex. `SENTINEL-<random-hex-seedé>`). Les assertions
de non-fuite (I2) cherchent cette sentinelle dans les artefacts d'observation : sa
présence = fuite prouvée. Une sentinelle distincte par secret permet d'attribuer une
fuite éventuelle à un secret précis.

### 2.4 — Périmètre exact de l'invariant I2 (non-fuite)

Subtilité encodée explicitement pour ne pas écrire un test faux (Rule 9) : lors d'une
substitution **autorisée**, la valeur réelle du secret est **légitimement** présente
dans le body forwardé upstream — c'est le canal voulu, le but même du produit. I2 ne
porte donc **pas** sur l'output de `substituteResolvable` (canal upstream), mais
uniquement sur les **artefacts d'observation** : `event.path`, `alert.snippet`, les
logs, et le **flux SSE**. La sentinelle ne doit jamais y apparaître, quel que soit
l'input.

## 3. Composants et fichiers

Tout sous `Tests/` (aucun impact binaire) :

| Fichier | Rôle |
|---|---|
| `Tests/IrisKitTests/Fuzzing/SeededGenerator.swift` | PRNG SplitMix64 déterministe (`RandomNumberGenerator`) + helpers de tirage (longueurs, sélection pondérée, octets aléatoires). Seed constant. |
| `Tests/IrisKitTests/Fuzzing/AdversarialInputGenerator.swift` | Produit des triplets (headers, uri, body) adverses : NAME hors-grammaire et aux limites (0 / 64 / 65 chars), milliers d'occurrences, unicode / homoglyphes / combining marks, accolades déséquilibrées et imbrication `{{kc:{{kc:x}}}}`, séquences d'échappement, caractères de contrôle / null, body non-UTF8, casse mixte des noms de header, placement en path / query / body. Expose le corpus nommé **et** le générateur seedé. |
| `Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift` | Harnais XCTest : pour chaque input (corpus + 2000 itérations seedées), exécute scan → evaluate → substitute avec `InMemorySecretStore` à sentinelles, asseoit I1/I2/I3. |
| `Tests/IrisKitTests/RedactionTests.swift` (extension) | Comble le trou **encodage SSE** : un Event/Alert sérialisé pour le flux ne contient jamais la sentinelle. |
| `Tests/IntegrationTests/<nouveau ou extension>` | **Un** test E2E : secret hors-`allowed_hosts` poussé via le proxy → requête bloquée, rien ne fuit upstream, et l'event diffusé sur SSE ne porte pas la sentinelle. Réutilise `CLIDaemonHarness` + `MockUpstream`. |

## 4. Les trois invariants asséyés

Pipeline réel testé : `PlaceholderScanner.scan(headers:uri:body:)` →
`ExfilRuleEngine.evaluate(hits:context:)` → `PlaceholderEngine.substituteResolvable(…)`.

- **I1 — Robustesse.** Quel que soit l'input, aucun appel ne panique ni ne boucle ;
  le scan termine et borne son travail. Un input qui fait crasher/hang = bug.
- **I2 — Non-fuite.** La sentinelle n'apparaît dans **aucun** artefact d'observation
  (`event.path`, `alert.snippet`, logs, flux SSE), quel que soit l'input. Périmètre
  précisé en §2.4 (l'output upstream est le canal autorisé, exclu d'I2).
- **I3 — Non-bypass.** Si le secret est hors `allowed_hosts` (R1) ou hors header
  canonique (R2), alors `substituted` est vide et `decision == .block`. Aucune
  résolution sans match de scope explicite.

## 5. Critères de réussite (vérifiables en remote)

- `swift build` et `swift test` passent localement (preuve = sortie de commande).
- Les nouveaux tests de fuzz s'exécutent dans un temps raisonnable (objectif < ~quelques
  secondes pour 2000 itérations ; sinon réduire N et le documenter — pas de cap
  silencieux).
- Le CI (xcodebuild macos-15) passe — oracle réel pour ce projet.
- Aucune régression sur la suite existante.
- Couverture nouvelle effective : un I2/I3 délibérément cassé (mutation locale de test)
  doit faire échouer le harnais (le fuzzer *peut* échouer quand la logique régresse —
  Rule 9). À démontrer pendant l'implémentation, pas à laisser en commentaire.

## 6. Points d'incertitude (à lever à l'implémentation)

- **Signature exacte de l'encodage SSE.** Le code de sérialisation de l'event pour le
  flux SSE n'a pas encore été lu en détail ; la forme précise du test SSE (quel type
  encode, quelle fonction) sera confirmée en lisant `EventsSSETests.swift` et la source
  de l'event ring → flux. Le *principe* (la sentinelle ne doit pas y apparaître) est
  fixe ; l'API exacte est à confirmer (Rule 8).
- **Coût CPU de 2000 itérations** sur le pipeline complet (qui inclut un `actor`
  `ExfilRuleEngine`, donc des hops async) : à mesurer ; si trop lent, réduire N et/ou
  séparer un fuzz « scan-only » rapide d'un fuzz « pipeline complet » plus court.
