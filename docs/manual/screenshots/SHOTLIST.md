# SHOTLIST — captures du manuel IRIS

Les 9 captures attendues par `docs/manual/manuel.html`. Les **noms de fichiers sont imposés**
(déjà référencés dans le HTML) — dépose chaque PNG ici, sous `docs/manual/screenshots/`, avec
exactement le nom indiqué.

Une fois les PNG en place, je remplace les placeholders `<div class="screenshot-frame">…</div>`
par des `<img>` et j'ajoute la règle CSS responsive (`.screenshot img { display:block; width:100%; height:auto; }`).
Tu n'as donc qu'à produire les images.

## Conventions communes

- **Format** : PNG. Pas besoin de respecter le 16:9 du placeholder — je gère le cadrage en CSS.
  Vise des captures nettes et lisibles (~1000–1400 px de large).
- **Thème** : capture tout en **apparence claire** (Terminal clair + macOS clair) pour rester
  cohérent avec le thème par défaut du manuel. Le manuel a un mode sombre, mais une image unique
  s'affiche dans les deux ; si tu veux le polish maximal plus tard, on peut faire des variantes
  `-dark.png` avec le même mécanisme `.light/.dark` que les icônes menu-bar.
- **Sécurité (CLAUDE.md §6)** : aucune vraie valeur de secret à l'écran. IRIS ne révèle jamais les
  valeurs (invariant I2), donc les **noms** (`anthropic_api_key`) et **hosts** sont OK à montrer.
  Vérifie juste qu'aucun `--value sk-…` en clair ne traîne dans le scrollback du terminal.
- **Outil de capture** :
  - Fenêtre propre (installeur, Keychain, prompt, app) → `screencapture -w sortie.png` (clic sur la
    fenêtre, ombre portée incluse).
  - Zone précise (terminal) → `screencapture -x -R x,y,w,h sortie.png`, ou `-w` sur la fenêtre Terminal.
- **Permissions** : capture d'app live = *Enregistrement de l'écran* (+ *Accessibilité* si pilotage
  via osascript) à accorder à ton outil de capture.

---

## A. Terminal (CLI `iris`)

- [ ] **`07-iris-doctor-ok.png`** — ch. 17 (Pause/Resume/Doctor)
  - Contenu : sortie de `iris doctor` **tout vert** (7 lignes `[ok]`).
  - Commande : `iris doctor`
  - Pré-requis : daemon up, CA dans le trust store, bloc shell installé (sinon `shell-env-vars`
    ou `ca-trusted-system` passent en warn).

- [ ] **`09-iris-secret-list.png`** — ch. 13 (Gérer les secrets)
  - Contenu : `iris secret list` avec **~4 secrets** (colonnes NAME / STATUS / CREATED / LAST_USED / USES / HOSTS).
  - Commande : `iris secret list`
  - Pré-requis : avoir 3–4 secrets enregistrés (p. ex. `anthropic_api_key`, `github_token`,
    `openai_api_key`) pour que la table soit représentative.

- [ ] **`12-iris-logs-follow.png`** — ch. 15 (Monitoring & logs)
  - Contenu : `iris logs --follow` en cours avec **quelques events colorés** (idéalement un mix
    `substituted` + `exfilBlocked`).
  - Commande : `iris logs --follow`, puis générer du trafic dans un autre terminal (un appel agent
    réel, ou `curl` via le proxy) pour peupler le flux avant la capture.

## B. Application menu-bar (Iris.app)

> Rappel (leçon connue) : le panneau est un **NSPanel non-activant** → le 1er clic sur l'icône/onglet
> est parfois absorbé. Vérifie visuellement chaque PNG avant de le garder.

- [ ] **`13-app-popover.png`** — ch. 18 (App menu-bar)
  - Contenu : panneau ouvert sur l'onglet **Overview** (compteurs Requests/Substituted/Blocked/Errors
    + les 5 derniers events + la pastille d'état en en-tête).

- [ ] **`10-app-secrets-tab.png`** — ch. 18 (App menu-bar)
  - Contenu : onglet **Secrets** — liste des secrets avec hosts en puces, métadonnées
    (créé · dernière utilisation · N usages) et les actions par secret.

## C. Système macOS

- [ ] **`02-pkg-installer-welcome.png`** — ch. 8 (Installation)
  - Contenu : **écran d'accueil** de l'assistant `Iris.pkg` (double-clic sur le `.pkg`, 1er écran
    welcome — bilingue en/fr, fond Mercure).

- [ ] **`03-pkg-installer-success.png`** — ch. 8 (Installation)
  - Contenu : **écran de confirmation** de fin d'installation (liste des composants installés).

- [ ] **`08-keychain-prompt-first.png`** — ch. 13 (Gérer les secrets)
  - Contenu : prompt macOS **« irisd wants to access the keychain »** avec le bouton **Always Allow**.
  - Déclenchement : se produit au **1er accès** à un secret par un `irisd` dont l'ACL n'est pas encore
    liée (p. ex. premier `iris secret add` après une (ré)installation).

- [ ] **`14-keychain-ca-entry.png`** — ch. 11 (CA & trust store)
  - Contenu : **Trousseau d'accès (Keychain Access)** ouvert sur l'entrée de la **CA IRIS**
    (`io.iris.ca` / « IRIS local CA »), montrant les détails **ECDSA P-256**.

---

## Étape finale (à ma charge)

Quand les 9 PNG sont déposés ici, je :
1. remplace chaque placeholder `screenshot-frame` par `<img src="screenshots/NN-….png" alt="…">` ;
2. ajoute la règle CSS responsive pour les images ;
3. re-rends le manuel (clair + sombre) pour vérifier le cadrage, et on enchaîne sur commit/PR.
