# Phase 9b — Notarisation & stapling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Soumettre `build/Iris.pkg` à la notarisation Apple, agrafer le ticket, et prouver que Gatekeeper l'accepte (`spctl --assess` → « accepted source=Notarized Developer ID »).

**Architecture:** Un seul fichier change — `packaging/notarize.sh` passe du squelette à un flux robuste (soumission `--output-format json`, capture de l'`id`/`status` via `plutil` natif, récupération systématique du log, garde-fou sur statut, staple + validate + spctl). La frontière 9a est conservée : `build-pkg.sh` (build/signature hors-ligne) reste intouché ; `notarize.sh` prend le relais réseau. Puis exécution réelle de la chaîne pour produire la preuve.

**Tech Stack:** bash, `xcrun notarytool` (submit/log), `xcrun stapler` (staple/validate), `spctl`, `plutil` (parsing JSON natif — pas de `jq`).

**Référence design :** `docs/superpowers/specs/2026-06-02-phase-9b-notarization-design.md`.

**Pré-requis vérifiés :** profil keychain `iris-notary` valide (`notarytool history` OK) ; certs Developer ID en place ; `build-pkg.sh` produit un pkg signé hardened-runtime + timestamp (Phase 9a).

**Note infra (pas de tests unitaires) :** 9b est de l'infra de distribution, sans logique Swift métier nouvelle → pas de tests XCTest (Rule 9, cohérent avec le design 9a). La vérification passe par `bash -n`, l'exécution réelle, et des assertions reproductibles sur les sorties (statut Apple, `stapler validate`, `spctl`).

---

## Task 1 : Enrichir `notarize.sh`

**Files:**
- Modify: `packaging/notarize.sh` (remplacement intégral du squelette)

- [ ] **Step 1 : Remplacer le contenu de `packaging/notarize.sh`**

Écrire exactement :

```bash
#!/bin/bash
# IRIS notarize — Phase 9b : soumet build/Iris.pkg à la notarisation Apple,
# récupère le log, agrafe le ticket, et vérifie l'acceptation Gatekeeper.
# Pré-requis : profil keychain notarytool "iris-notary" (cf docs/phase-9-notarization-prep.md),
# et un build/Iris.pkg signé produit par build-pkg.sh.
set -euo pipefail

PKG="${1:-build/Iris.pkg}"
PROFILE="${IRIS_NOTARY_PROFILE:-iris-notary}"
SUBMIT_JSON="build/notarization-submit.json"
LOG_JSON="build/notarization-log.json"

[ -f "$PKG" ] || { echo "error: pkg introuvable: $PKG" >&2; exit 1; }

# 1. Soumettre et attendre le verdict (JSON pour parsing robuste).
echo "→ soumission notarisation: $PKG (profil: $PROFILE)"
xcrun notarytool submit "$PKG" \
  --keychain-profile "$PROFILE" \
  --wait \
  --output-format json > "$SUBMIT_JSON"

# 2. Extraire id + status (plutil natif, pas de jq).
id="$(plutil -extract id raw -o - "$SUBMIT_JSON")"
status="$(plutil -extract status raw -o - "$SUBMIT_JSON")"
echo "→ submission id: $id — status: $status"

# 3. Récupérer le log dans TOUS les cas (peut contenir des warnings même en succès).
xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$LOG_JSON"

# 4. Garde-fou : ne jamais agrafer un pkg non accepté.
if [ "$status" != "Accepted" ]; then
  echo "error: notarisation non acceptée (status=$status). Log:" >&2
  cat "$LOG_JSON" >&2
  exit 1
fi

# 5. Agrafer le ticket pour usage offline.
xcrun stapler staple "$PKG"

# 6. Valider l'agrafage.
xcrun stapler validate "$PKG"

# 7. Vérification finale Gatekeeper (échoue si rejeté — pas de '|| true').
spctl --assess --type install -vv "$PKG"   # attendu : "accepted source=Notarized Developer ID"

echo "OK → $PKG notarisé + stapled + accepté par Gatekeeper"
```

- [ ] **Step 2 : Vérifier la syntaxe bash**

Run: `bash -n packaging/notarize.sh && echo "syntaxe OK"`
Expected: `syntaxe OK`

- [ ] **Step 3 : Vérifier que le fichier reste exécutable**

Run: `test -x packaging/notarize.sh && echo "executable"`
Expected: `executable`
(Si non exécutable : `chmod +x packaging/notarize.sh`.)

- [ ] **Step 4 : Commit**

```bash
git add packaging/notarize.sh
git commit -m "feat(phase-9b): notarize.sh robuste (submit json + log + garde-fou + staple/validate/spctl)"
```

---

## Task 2 : Exécution réelle — produire le pkg signé

**Files:** aucun fichier modifié (artefacts dans `build/`, gitignoré).

**Pré-requis d'exécution :** le Team ID Apple est fourni via la variable d'environnement `IRIS_TEAM_ID` au moment de l'exécution — **jamais commité ni écrit dans un fichier suivi**.

- [ ] **Step 1 : Exporter le Team ID (saisie interactive de l'utilisateur)**

```bash
export IRIS_TEAM_ID=<TON_TEAM_ID>
```
(Si l'agent exécute : demander la valeur à l'utilisateur ou lui faire lancer cette ligne via `! export …` ; ne pas la consigner.)

- [ ] **Step 2 : Construire le pkg signé**

Run: `./packaging/build-pkg.sh`
Expected: se termine par `OK → build/Iris.pkg (signé, NON notarisé ; voir notarize.sh pour la Phase 9b)`

- [ ] **Step 3 : Vérifier la présence et la signature du pkg**

Run: `test -f build/Iris.pkg && pkgutil --check-signature build/Iris.pkg`
Expected: `build/Iris.pkg` existe ; sortie `Status: signed by a developer certificate issued by Apple for distribution` avec la chaîne Developer ID Installer.

- [ ] **Step 4 : Confirmer l'état pré-notarisation (delta de référence)**

Run: `spctl --assess --type install -vv build/Iris.pkg || true`
Expected: **rejeté** (`rejected source=… Unnotarized Developer ID` ou équivalent). C'est l'état attendu AVANT 9b — sert de point de comparaison pour la Task 3.

---

## Task 3 : Exécution réelle — notariser, agrafer, vérifier

**Files:** aucun (artefacts `build/notarization-*.json` + pkg stapled, gitignorés).

- [ ] **Step 1 : Lancer la notarisation**

Run: `./packaging/notarize.sh`
Expected (succès) : affiche `submission id: <UUID> — status: Accepted`, puis `The staple and validate action worked!` (staple), `The validate action worked!` (validate), puis la ligne spctl, et enfin `OK → build/Iris.pkg notarisé + stapled + accepté par Gatekeeper`.

Si `status` ≠ `Accepted` : le script affiche `build/notarization-log.json` et sort en erreur. Inspecter le tableau `issues` (chaque entrée a `severity`/`message`/`path`), corriger la cause (signature, hardened runtime…), puis relancer Task 2 puis Task 3. Ce débogage est un sous-flux normal, pas un échec du plan.

- [ ] **Step 2 : Vérifier le statut capturé**

Run: `plutil -extract status raw -o - build/notarization-submit.json`
Expected: `Accepted`

- [ ] **Step 3 : Inspecter le log (warnings tolérés, erreurs non)**

Run: `plutil -extract status raw -o - build/notarization-log.json ; echo "--- issues ---" ; plutil -extract issues json -o - build/notarization-log.json 2>/dev/null || echo "null (aucune issue)"`
Expected: `status` = `Accepted` ; `issues` = `null` ou un tableau ne contenant aucune entrée `"severity":"error"`.

- [ ] **Step 4 : Valider l'agrafage**

Run: `xcrun stapler validate build/Iris.pkg`
Expected: `The validate action worked!`

- [ ] **Step 5 : Confirmer l'acceptation Gatekeeper (le résultat clé de 9b)**

Run: `spctl --assess --type install -vv build/Iris.pkg`
Expected: `source=Notarized Developer ID` et `accepted` (exit 0). C'est le delta vs Task 2 Step 4.

- [ ] **Step 6 : Capturer les sorties pour la PR**

Conserver les sorties des steps 1-5 (copier dans la description de PR). Aucun commit — les artefacts sont gitignorés.

---

## Task 4 : Pull Request

**Files:** aucun changement de code (la PR porte le commit de Task 1 + le commit design déjà présent sur la branche).

- [ ] **Step 1 : Pousser la branche**

Run: `git push -u origin feat/phase-9b-notarization`

- [ ] **Step 2 : Créer la PR avec checklist smoke**

```bash
gh pr create --base main --head feat/phase-9b-notarization \
  --title "feat(phase-9b): notarisation & stapling du .pkg" \
  --body "<voir checklist ci-dessous, remplie avec les sorties capturées en Task 3>"
```

Checklist smoke à inclure dans le corps (cocher d'après les sorties réelles) :
```
- [ ] `bash -n packaging/notarize.sh` passe sans erreur
- [ ] `build-pkg.sh` produit `build/Iris.pkg` signé Developer ID Installer
- [ ] `notarytool submit --wait` → statut `Accepted`
- [ ] `notarization-log.json` sans `issues` de sévérité `error` (warnings tolérés)
- [ ] `stapler validate build/Iris.pkg` → `The validate action worked!`
- [ ] `spctl --assess --type install -vv` → `accepted source=Notarized Developer ID` (delta vs 9a)
```

- [ ] **Step 3 : Suivi de la revue Gemini (CLAUDE.md §8)**

Poller les commentaires/reviews Gemini, traiter chacun (fix+commit+reply, ou refus factuel). Note : Gemini Code Assist consumer est en fin de vie (arrêt des reviews 17 juillet 2026) ; tant qu'il répond, appliquer la procédure §8.

- [ ] **Step 4 : Merge (après confirmation explicite de l'utilisateur)**

Conditions : commentaires Gemini traités + checklist cochée + `bash -n` vert. Puis, sur feu vert utilisateur :
```bash
gh pr merge <num> --squash --delete-branch
```

---

## Self-Review (rempli)

**1. Spec coverage :**
- §1 portée / §2.1 deux scripts → Task 1 (notarize.sh seul, build-pkg.sh intouché). ✅
- §2.2 plutil pas de jq → Task 1 Step 1 (plutil -extract). ✅
- §2.3 log systématique → Task 1 Step 1 (étape 3 hors du garde-fou). ✅
- §2.4 garde-fou + fail loud → Task 1 Step 1 (étape 4). ✅
- §3.2 flux complet → Task 1 Step 1. ✅
- §4 edge cases (réseau, idempotence, Team ID non commité, pas de secret) → Task 1 (set -euo pipefail) + Task 2 (IRIS_TEAM_ID en env). ✅
- §5 exécution réelle + portée honnête → Tasks 2-3. ✅
- §5.3 smoke checklist → Task 4 Step 2. ✅
- §7 « quoi stapler » → tranché (pkg seul, build-pkg.sh intouché) via doc Apple. ✅
- §8 limitations (machine tierce, Phase 8) → documentées, hors-scope assumé. ✅

**2. Placeholder scan :** `<TON_TEAM_ID>` (Task 2) et `<num>` (Task 4) sont des valeurs runtime fournies par l'utilisateur, pas des TODO de plan. Le script de Task 1 est complet et littéral. Aucun « TBD/implement later ».

**3. Type/commande consistency :** noms de fichiers cohérents (`build/notarization-submit.json`, `build/notarization-log.json`) entre Task 1 et Task 3 ; profil `iris-notary` cohérent partout ; `plutil -extract … raw -o -` identique en Task 1 et Task 3.
