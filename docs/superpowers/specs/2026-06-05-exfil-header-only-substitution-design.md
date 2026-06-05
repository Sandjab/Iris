# Exfil — substitution réservée aux headers d'auth ; body/query/path = signaux d'exfil

**Statut**: design validé, prêt pour planning d'implémentation
**Date**: 2026-06-05
**Branche cible**: `feat/exfil-r3-diag-logs` (commit diag `15ed55c` déjà poussé ; fix à empiler dessus)
**Couverture SPECS**: §6 (Goals G2), §9 (Exfiltration detection, R2–R4), threat model A2
**Origine**: handoff `project-exfil-r3-overblock` — `claude` via IRIS renvoyait « invalid api key » depuis le repo `iris`.

---

## 1. Objectif et scope

Resserrer le modèle d'exfiltration pour qu'**un secret ne soit jamais substitué dans un corps de requête**. La substitution n'a lieu que dans un **header d'auth canonique** (`authorization`, `x-api-key`, `api-key`, `x-auth-token`). Tout placeholder de secret **connu** trouvé en query string, path ou body est traité comme un **signal d'exfiltration** : la requête est bloquée (forwardée littérale) et une alerte est émise — jamais substitué. Les placeholders de noms **inconnus** sont inertes partout (ni substitués, ni comptés par une règle).

### Pourquoi

Deux problèmes, une racine commune.

1. **Faux positif rapporté.** Lancé depuis le repo `iris`, `claude` injecte `CLAUDE.md` (auto-chargé) dans le corps de `/v1/messages`. Or `CLAUDE.md` documente la syntaxe `{{kc:NAME}}` en toutes lettres. Le scanner voit donc `anthropic_api_key@header(x-api-key):known` **+** `NAME@body:unknown` → R3 (`multipleSecrets`) compte les inconnus (design §7.1) → `distinctNames=2` → **block** → la requête part avec `x-api-key` littéral → 401 « invalid api key ». Le bug est **auto-référentiel** : la doc d'IRIS déclenche l'exfil d'IRIS. Diagnostic capturé par l'instrumentation `Exfil hit inventory` (commit `15ed55c`).

2. **Trou d'exfil sur secret connu en body.** Un agent prompt-injecté qui POST un PAT GitHub en corps de commentaire (`POST api.github.com/.../comments`, `Content-Type: application/json`, body `{"body":"{{kc:github_pat}}"}`) n'est **pas** bloqué aujourd'hui : R1 passe (host = host autorisé du secret), R2 passe (`.body` non-canonique seulement si `GET`), R4 passe (filtre content-type exclut `json`). Le PAT est substitué et publié. C'est exactement le threat model A2, non couvert.

### Dans le scope

- Deux changements dans `ExfilRuleEngine.evaluate` (cf §3).
- Mise à jour des tests d'`ExfilRuleEngine` (un changement de comportement assumé : secret connu en body POST passe de *allow* à *block*).
- Révision de SPECS (G2, R2/R3/R4) et du design §7.1.

### Hors scope (différés)

- **Allowlist body-credential (OAuth `client_secret` en form body)** : l'Option 2 de la phase de brainstorm. Non requis par claude_code (auth = header `x-api-key`). YAGNI ; ré-ouvrable plus tard via un opt-in explicite `(secret, host/path)`.
- **Suppression du code de substitution body de `PlaceholderEngine`** : devient inatteignable depuis le proxy (R2 bloque avant), mais reste couvert par ses tests unitaires directs. Laissé en place (Rule 3, chirurgical) ; nettoyage = follow-up séparé si souhaité.
- **Arrêt du scan body** : on **garde** le scan — c'est lui qui alimente la détection (R2/R4 alertent sur un secret connu en body). Seule la *substitution* body disparaît.

---

## 2. Constat de cohérence préalable

R2 (`isNonCanonicalLocation`) traite **déjà** `.queryString` et `.urlPath` comme non-canoniques → un secret connu y est déjà bloqué, jamais substitué. Le **body-POST est la seule exception** taillée par R2 (`.body` n'est non-canonique que si `method == "GET"`). La localisation canonique d'un secret connu est donc *déjà* « header d'auth », à cette exception près. Ce design **retire l'exception** et aligne le body sur query/path.

Effet de bord positif : SPECS G2 prétend aujourd'hui substituer « in headers, query strings, and request bodies », alors que R2 bloque déjà les secrets connus en query. Le design **résorbe cette incohérence** documentaire.

---

## 3. Changements

Tous dans `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`.

### 3.1 R2 — `.body` toujours non-canonique

```swift
// AVANT
case .body:
    return method.uppercased() == "GET"
// APRÈS
case .body:
    return true
```

`method` devient inutilisé dans `isNonCanonicalLocation` → retirer le paramètre (ou le `_`). Effet : un secret **connu** où que ce soit dans un body → R2 fire (`.nonCanonicalLocation`, high) → `.block` → requête forwardée littérale + `Event(.exfilBlocked)`. Ferme A2-body **par construction**, inconditionnellement (donc non contournable, *fail-closed*).

### 3.2 L1 — R3 et R4 ne considèrent que `knownHits`

R3 et R4 parcourent aujourd'hui `effectiveHits` (inconnus inclus). Les passer sur `knownHits` :

- **R3** : `let distinctNames = Set(knownHits.map(\.name))` (au lieu de `effectiveHits`). Le triggering hit/snippet se dérive de `knownHits`.
- **R4** : `suspiciousContentTypeFires(hits: knownHits, …)` (au lieu de `effectiveHits`).

Aligne R3/R4 sur R1/R2/R5 (déjà `knownHits`). Effet : un nom **inconnu** (la doc `{{kc:NAME}}`) ne déclenche plus aucune règle → FP tué. Principe unifié : *les règles exfil protègent les vrais secrets ; un nom inconnu ne résout jamais → ne fuit jamais → ne doit pas bloquer.*

> Note : l'inventaire diagnostic `Exfil hit inventory` (commit `15ed55c`) continue de loguer `effectiveHits` (connus **et** inconnus) — utile pour voir ce qu'un outil émet réellement. Seules les *décisions* de blocage passent en known-only.

### 3.3 Conséquence : R4 subsumée par R2 (mais conservée)

L'ordre d'évaluation est R1 > R2 > R3 > R4 > R5, première règle qui fire l'emporte. Une fois `.body` toujours non-canonique, **R2 fire sur tout secret connu en body** — avant que R4 ne soit atteinte. Donc R4 (`.suspiciousContentType`) **ne fire plus jamais** sur le chemin actuel : R2 (`.nonCanonicalLocation`, high) la préempte sur tout hit body connu, et L1 l'empêche de fire sur les inconnus. La capacité de détection de R4 (« secret connu faufilé dans un body ») est **conservée**, simplement portée par R2, avec une sévérité *plus haute* — ce qui est plus correct.

On **garde** néanmoins R4 (passée en known-only) :
- défense en profondeur, coût nul (Rule 3 : ne pas supprimer ce qui marche) ;
- elle **redevient vivante** si l'allowlist body-credential (Option 2, hors scope) est ajoutée un jour : R2 ne bloquerait plus les body-secrets allowlistés, et R4 reprendrait son rôle de second filtre sur ceux-là (content-type + path suspects).

R3 n'est **pas** subsumée : deux secrets connus distincts dans des **headers** canoniques (vrai env-dump) ne déclenchent pas R2 → R3 garde son office.

---

## 4. Matrice de comportement

| Localisation | Secret connu | Nom inconnu |
|---|---|---|
| Header d'auth canonique | **substitué** (inchangé) | inerte littéral |
| Header non-canonique | bloqué R2 (inchangé) | inerte |
| Query string / path | bloqué R2 (inchangé) | inerte |
| **Body (tout method)** | **bloqué R2 + alerte (nouveau)** | **inerte (nouveau via L1)** |

**Sémantique de `.block` (rappel) :** « bloquer » ne **droppe pas** la requête — elle est **forwardée upstream telle quelle, avec le placeholder littéral** (jamais substitué), conforme à SPECS §R3 « forwarded unchanged ». S'y ajoutent un `Event(.exfilBlocked)` + alerte (détection A2), et, **seulement** sous le mode `block_notify_pause` (pas le défaut `block_and_notify`), une pause du daemon. Donc un secret connu en body = « laissé passer sans substitution + alerté », pas « rejeté ».

Cas où header connu **et** body connu coexistent (PAT en `Authorization` + PAT en body) : R2 fire sur le hit body → **toute** la requête est bloquée → header **aussi** forwardé littéral → 401 upstream → aucun commentaire créé → aucune fuite + alerte. Refuser la requête entière est le comportement sûr (pas de substitution partielle sous suspicion d'exfil), cohérent avec la sémantique R1/R2 existante.

---

## 5. Tests

`Tests/IrisKitTests/ExfilRuleEngineTests.swift` (+ regression existante) :

- **FP rapporté** : inconnu en body + connu en header canonique, host autorisé → `.allow(resolvable: [connu])`. Header substitué, body littéral.
- **Exfil A2-json** : connu en body, `Content-Type: application/json`, host = host autorisé du secret → `.block`, `rule == .nonCanonicalLocation`. (Le gap PAT→comment.)
- **Secret connu en body POST** : passe de *allow* à `.block` → mettre à jour tout test existant qui assertait l'allow (changement de comportement assumé).
- **R3 known-only** : deux inconnus distincts en body, aucun connu → `.allow` (plus de block sur inconnus).
- **Subsomption R4** : connu en body `text/plain` + path `/comments`, aucun header → `.block` avec `rule == .nonCanonicalLocation` (**R2** préempte, pas R4). Un test qui assertait `.suspiciousContentType` ici doit basculer sur `.nonCanonicalLocation`.
- **R4 plus de FP inconnu** : inconnu en body `text/plain` + `/comments`, aucun connu → `.allow` (R4 known-only ne fire plus sur l'inconnu).
- **§6.1** : les tests redaction/diag existants restent verts (aucune valeur en log).

Critère de réussite : `swift build` + `swift test` verts, `swift-format` clean, et **smoke** `claude` depuis le repo `iris` ne renvoie plus « invalid api key » (substitution header OK, body `{{kc:NAME}}` resté littéral), confirmé via l'inventaire diagnostic.

---

## 6. Impact SPECS / doc

- **G2** : « Substitute placeholders found in HTTP headers, query strings, and request bodies » → « Substitute placeholders **only in canonical auth headers**. Placeholders of known secrets found in query strings, paths, or request bodies are treated as exfiltration signals: the request is blocked (placeholder forwarded literally) and an alert is emitted — never substituted. »
- **R2** (§9) : préciser que `.body` est non-canonique pour tout method (plus seulement GET).
- **R3** (§9) + **design §7.1** : R3 compte les noms **connus** uniquement (plus « known + typo »). Documenter le rejet du comptage des inconnus : un inconnu ne résout jamais (0 leak) et la grammaire `{{kc:…}}` apparaît dans du texte ordinaire (la doc d'IRIS elle-même) → comptage des inconnus = faux positif structurel sans gain de sécurité.
- **R4** (§9) : opère sur les hits de secrets connus, et noter qu'elle est **subsumée par R2** sur le chemin actuel (R2 bloque tout secret connu en body avant R4) ; conservée pour la défense en profondeur et pour le cas futur d'une allowlist body-credential.
- `docs/user-guide.md` : si un endroit promet la substitution en body, le corriger.

---

## 7. Alternatives écartées

Issues du brainstorm (handoff R3). Conservées ici pour ne pas les relitiger.

- **L1 seul (ignorer les inconnus, garder la substitution body)** — *fail-open*. Corrige le FP mais laisse l'exfil PAT→comment (secret connu en body json vers host autorisé) grande ouverte. Ne tient pas la barre de sécurité.
- **Levier 2 « ne plus scanner le body »** — supprimerait R4 (entièrement body) et contredirait A2 → érode la revendication « 5 règles » qui est l'arête documentée vs Agent Vault. Le design retenu **garde** le scan (détection) et ne retire que la substitution.
- **Levier 3 « body inerte si un secret connu est dans un header »** — *fail-open*, **éliminé**. Sa protection est conditionnée à « un secret connu résout dans un header d'auth », précondition absente (donc body substituable → exfil) dans trois cas vérifiés : (1) l'user oublie le secret de header ; (2) le secret de header est non déclaré (inconnu) → l'auth primaire échoue mais le secret du body **part quand même à l'extérieur** ; (3) appel d'une API sans auth sur un host autorisé. Un attaquant peut volontairement faire absenter la précondition (ne pas mettre de secret connu en header). N'établit aucune frontière de sécurité.

Le design retenu (Option 1) est le seul *fail-closed* : la substitution body est interdite **inconditionnellement**, donc non contournable.

---

## 8. Références

- Handoff : mémoire `project-exfil-r3-overblock`.
- Instrumentation diagnostic : commit `15ed55c` (`Exfil hit inventory`, debug-gated, §6.1-safe).
- SPECS §9 (règles R1–R5), threat model A2, G2/G4.
- Design Phase 4 : `docs/superpowers/specs/2026-05-25-phase-4-scoping-exfil-design.md` (§7.1 à réviser).
