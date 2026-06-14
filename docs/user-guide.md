<p align="center">
  <img src="../assets/iris-icon-256.png" alt="" aria-hidden="true" width="96" height="96">
</p>

# Guide utilisateur IRIS

> IRIS 1.0 est **entièrement livré** : tout ce que décrit ce guide est disponible.
> Le tableau [§ État d'implémentation](#état-dimplémentation-juin-2026) en tête de
> document récapitule chaque composant et sa phase.

---

## Table des matières

1. [À quoi sert IRIS](#1-à-quoi-sert-iris)
2. [Concepts clés](#2-concepts-clés)
3. [Installation](#3-installation)
4. [Configuration initiale](#4-configuration-initiale)
5. [Créer et gérer ses clés API](#5-créer-et-gérer-ses-clés-api)
6. [Usage quotidien](#6-usage-quotidien)
7. [Configurer un serveur MCP](#7-configurer-un-serveur-mcp)
8. [Vérification et monitoring](#8-vérification-et-monitoring)
9. [Sécurité — ce qu'IRIS garantit (et pas)](#9-sécurité)
10. [Dépannage](#10-dépannage)
11. [FAQ](#11-faq)
12. [Désinstaller](#12-désinstaller)

---

## État d'implémentation (juin 2026)

| Composant | Phase | Statut |
|---|---|---|
| Daemon `irisd` + proxy MITM | Phase 2 ✅ | Disponible |
| Substitution placeholders | Phase 2 ✅ | Disponible |
| Streaming de la réponse (SSE upstream→client, sans bufferisation) | Phase 2.x ✅ | Disponible |
| CONNECT-tunnel passthrough non-whitelist | Phase 2.1 ✅ | Disponible |
| Mode debug `--in-memory-secrets` | Phase 2 ✅ | Disponible |
| IPC admin Unix socket + flux SSE d'events | Phase 3 ✅ | Disponible |
| Scoping `allowed_hosts` + exfil rules (R1-R5) | Phase 4 ✅ | Disponible |
| CLI `iris` (secret / status / logs / doctor / mcp) | Phase 5 ✅ | Disponible |
| Menu bar app `Iris.app` | Phase 6 ✅ | Disponible (6 onglets : Overview / Logs / Security / Secrets / Rules / Settings) |
| Modèle de config unifié (`config.json` app-first, `iris config set`) | Phase 6.3a ✅ | Disponible |
| LaunchAgent + `SMAppService` (auto-start) | Phase 7 ✅ | Disponible |
| Installation complète (CLI distribuée + terminal) & désinstallation | v1.0 ✅ | Disponible |
| ACL Keychain signed-binary | Phase 8 ✅ | Disponible |
| `.pkg` signé + notarisé | Phase 9 ✅ | Disponible |
| Hardening + fuzz tests | Phase 10 ✅ | Disponible |

**Aujourd'hui** : le broker est utilisable de bout en bout — secrets en Keychain via la CLI `iris` ou l'app menu bar, proxy MITM avec substitution scopée par `allowed_hosts`, détection d'exfiltration, streaming des réponses, ACL Keychain liée au binaire signé, config unifiée `config.json` (seedée au 1er boot, éditable via `iris config set`), et `.pkg` signé + notarisé. Le démarrage automatique (LaunchAgent/`SMAppService`) et l'onglet Settings de l'app sont eux aussi livrés — l'installeur configure le tout au premier lancement. Le mode `--in-memory-secrets` (secrets via `IRIS_SECRET_<NAME>`) reste disponible pour le debug.

---

## 1. À quoi sert IRIS

IRIS est un **broker de credentials local** pour macOS. Il s'interpose entre vos outils CLI (Claude Code, `gh`, `curl`, scripts Python, serveurs MCP…) et les API distantes (Anthropic, GitHub, OpenAI…), et **substitue à la volée** des placeholders comme `{{kc:anthropic_api_key}}` par les vraies valeurs tirées du trousseau macOS.

**Le bénéfice principal** : aucun outil n'a jamais accès à votre vraie clé API. Si un agent IA est compromis (prompt injection, MCP malveillant), il ne peut voler qu'un placeholder inutile.

### Avant / après

**Sans IRIS** :
```bash
export ANTHROPIC_API_KEY="sk-ant-api03-XXXXXXXXXXXXXXXXXX"   # en clair, lisible par tout process
```

**Avec IRIS** :
```bash
export ANTHROPIC_API_KEY="{{kc:anthropic_api_key}}"          # placeholder inerte
```

La vraie clé vit dans le trousseau, ACL-protégée pour le seul binaire `irisd` signé.

---

## 2. Concepts clés

- **Placeholder** : chaîne au format `{{kc:NAME}}` (kc = keychain). `NAME` correspond au nom d'un secret enregistré via `iris secret add`.
- **Proxy MITM** : `irisd` écoute sur `127.0.0.1:8888`. Vos outils y sont dirigés via `HTTPS_PROXY`. Pour les hosts dans la whitelist (ex. `api.anthropic.com`), IRIS déchiffre, substitue, re-chiffre. Pour les autres, il fait un *passthrough TCP* sans déchiffrer (et donc sans pouvoir substituer — c'est volontaire).
- **CA local** : pour pouvoir déchiffrer le trafic vers les hosts whitelistés, IRIS génère un certificat racine local stocké dans votre Keychain (clé privée) + sur disque en PEM (cert public). Vous devez l'ajouter au trust store pour que vos outils acceptent les certs forgés par IRIS.
- **`allowed_hosts`** : chaque secret est lié à un ou plusieurs hosts autorisés. Si un agent essaie de fuiter votre clé Anthropic dans un POST vers `api.github.com`, IRIS refuse la substitution et émet un alert.

![Diagramme de flux IRIS](screenshots/01-architecture-flow.png "Architecture / flux du trafic")

---

## 3. Installation

### Prérequis

- macOS 13 Ventura ou plus récent
- Architecture Apple Silicon ou Intel
- Droits administrateur (pour installer le `.pkg` et ajouter le CA au trust store)

### Méthode 1 — Package signé (recommandée, Phase 9)

1. Téléchargez `Iris-<version>.pkg` depuis la page Releases du repo.
2. Double-cliquez sur le `.pkg`. macOS vérifie la signature Apple Developer ID et la notarisation.
3. Suivez l'assistant. Une fois terminé :
   - L'app `Iris.app` est dans `/Applications/`
   - La CLI `iris` est dans `/usr/local/bin/`
   - `irisd` est embarqué dans `Iris.app` (`Contents/MacOS/irisd`), géré par **SMAppService**
4. Le démarrage automatique est géré via **SMAppService** — configurable dans Réglages système → Général → Ouverture de session, ou via les toggles de l'onglet Settings de l'app.

![Installation .pkg étape 1](screenshots/02-pkg-installer-welcome.png "Écran d'accueil de l'installeur")

![Installation .pkg étape finale](screenshots/03-pkg-installer-success.png "Confirmation d'installation")

### Méthode 2 — Build depuis les sources (développeurs)

Cf. README.md du repo. Cette méthode ne signe pas le binaire et **désactive donc la protection ACL Keychain** ; à réserver à du développement.

---

## 4. Configuration initiale

### 4.1 Lancer l'app pour le premier setup

Au premier lancement d'`Iris.app`, un assistant vous accompagne :

1. Création de la CA locale (clé privée → trousseau, cert public → `~/Library/Application Support/iris/ca.pem`)
2. Ajout du CA au trust store de l'utilisateur (authentification requise)
3. Configuration du terminal **avec votre consentement** : lancez `iris shell install` (affiche les lignes, demande confirmation avant d'écrire) ou cliquez sur « Configurer… » dans l'onglet Settings → Terminal de l'app. Variables exportées : `HTTPS_PROXY` (`http://127.0.0.1:8888`), `NODE_EXTRA_CA_CERTS` (`$HOME/Library/Application Support/iris/ca.pem`).

![Assistant setup — étape CA](screenshots/04-app-setup-ca.png "Création de la CA")

![Assistant setup — trust store](screenshots/05-app-setup-trust.png "Ajout au trust store")

![Assistant setup — env shell](screenshots/06-app-setup-shell.png "Patch des variables d'environnement")

### 4.2 Setup manuel (équivalent CLI)

Si vous préférez la CLI :

```bash
# 1. Exporter le CA public (à faire une seule fois)
iris ca export
# → écrit ~/Library/Application Support/iris/ca.pem

# 2. Ajouter le CA au trust store de l'utilisateur (authentification requise)
iris ca install

# 3. Patcher votre shell profile manuellement
cat >> ~/.zshrc <<'EOF'

# IRIS — local credential broker
export HTTPS_PROXY="http://127.0.0.1:8888"
export NODE_EXTRA_CA_CERTS="$HOME/Library/Application Support/iris/ca.pem"
EOF

# 4. Recharger
source ~/.zshrc
```

> ℹ️ **Pourquoi pas de `SSL_CERT_FILE`** : contrairement à `NODE_EXTRA_CA_CERTS` qui *ajoute* le cert IRIS au bundle Node.js, `SSL_CERT_FILE` **remplace** tout le bundle CA pour les outils OpenSSL/LibreSSL (Python, Ruby, curl…). Le pointer sur le seul `ca.pem` d'IRIS casserait la validation TLS pour tous les domaines non whitelistés. Pour couvrir ces outils, faites `iris ca install` à l'étape 2 ci-dessus : le CA est ajouté au trust store de l'utilisateur, respecté par les outils qui consultent le trust store macOS (curl système, Safari, gh, git…).

> ⚠️ `HTTPS_PROXY` ne s'applique qu'aux processus lancés depuis un shell (terminal, scripts). Les apps GUI lancées depuis le Finder/Dock/Spotlight ne sont **pas** interceptées — c'est intentionnel.

### 4.3 Vérification du setup

```bash
iris doctor
```

Sortie attendue :
```
✓ Daemon up (uptime 12s)
✓ CA cert present at ~/Library/Application Support/iris/ca.pem
✓ CA cert trusted by system
✓ Env vars : HTTPS_PROXY, NODE_EXTRA_CA_CERTS
✓ Internal ping 127.0.0.1:8888/__iris_ping → 200 ok
✓ apiKeyHelper not set in ~/.claude/settings.json
```

![iris doctor — sortie propre](screenshots/07-iris-doctor-ok.png "iris doctor — tout vert")

---

## 5. Créer et gérer ses clés API

### 5.1 Ajouter un secret

```bash
iris secret add anthropic_api_key --allowed-hosts api.anthropic.com
# (vous êtes invité à coller la valeur dans le terminal — l'entrée est masquée)
```

Ou via stdin (utile pour scripter) :
```bash
echo "sk-ant-api03-XXXXX" | iris secret add anthropic_api_key \
  --allowed-hosts api.anthropic.com \
  --value-from-stdin
```

**Au premier `secret add`**, macOS affiche un prompt "irisd veut accéder au trousseau" :

![Prompt Keychain — first access](screenshots/08-keychain-prompt-first.png "Prompt macOS lors du premier ajout")

Cliquez sur **Toujours autoriser**. Cela pose l'ACL signed-binary : irisd aura un accès silencieux pour ce secret (et les futurs), tout autre process déclenchera un prompt.

### 5.2 Conventions de nommage

- `name` : `^[a-zA-Z0-9_-]{1,64}$` — minuscules + underscores conseillés (ex. `github_token`, `openai_api_key`)
- `allowed_hosts` : un ou plusieurs noms DNS valides, séparés par virgule. Wildcards non supportés.

Exemples :
```bash
iris secret add github_token       --allowed-hosts api.github.com,uploads.github.com
iris secret add openai_api_key     --allowed-hosts api.openai.com
iris secret add stripe_secret      --allowed-hosts api.stripe.com
```

### 5.3 Lister les secrets

```bash
iris secret list
```

Sortie :
```
NAME                ALLOWED HOSTS                          LAST USED
anthropic_api_key   api.anthropic.com                      2 min ago
github_token        api.github.com,uploads.github.com      1 day ago
openai_api_key      api.openai.com                         never
```

**La valeur n'est jamais affichée.** Aucune commande IRIS ne révèle un secret en clair.

![iris secret list](screenshots/09-iris-secret-list.png "Liste des secrets")

### 5.4 Rotation

```bash
iris secret rotate anthropic_api_key
# (prompt pour la nouvelle valeur)
```

L'ancienne valeur est écrasée dans le trousseau, l'ACL est préservée.

### 5.5 Modifier les `allowed_hosts`

```bash
iris secret edit github_token --allowed-hosts api.github.com,uploads.github.com,raw.githubusercontent.com
```

### 5.6 Suppression

```bash
iris secret rm anthropic_api_key
# Confirmation explicite demandée
```

### 5.7 Via l'app menu bar

L'app `Iris.app` expose un onglet **Secrets** avec les mêmes opérations sous forme graphique. Source de vérité = daemon, l'app est un thin client : aucune valeur ne transite par son process.

![App — onglet Secrets](screenshots/10-app-secrets-tab.png "Onglet Secrets de l'app")

![App — sheet Add Secret](screenshots/11-app-add-secret-sheet.png "Sheet Add Secret")

### 5.8 Whitelist MITM et configuration

La whitelist des hosts interceptés et tous les réglages vivent dans un fichier **unique géré par le daemon** : `~/Library/Application Support/iris/config.json`. Il est **créé automatiquement** (seedé avec des valeurs par défaut) au premier démarrage — rien à éditer à la main. Le daemon en est le seul auteur ; chaque écriture est précédée d'un backup horodaté sous `backups/` (rotation configurable via `backups.max_count`).

Gérer la whitelist :

```bash
iris rule add api.github.com      # autoriser un host (origin: user)
iris rule list                    # HOST / ORIGIN (default|user) / CREATED
iris rule rm api.github.com       # retirer un host user
```

Le host par défaut `api.anthropic.com` est marqué `origin: default` et **protégé** : `iris rule rm api.anthropic.com` est refusé (évite de casser `claude` par mégarde).

Lire et changer les réglages :

```bash
iris config get                                              # dump lisible
iris config set security.on_exfil_attempt block_only         # appliqué à chaud
iris config set security.max_substitutions_per_minute 120    # appliqué à chaud
iris config set backups.max_count 5                          # appliqué à chaud
iris config set broker.event_ring_size 20000                 # → requires_restart
```

Les champs `security.*` et `backups.max_count` prennent effet immédiatement ; les champs `broker.*` (ports, socket, tailles) sont persistés mais nécessitent un redémarrage du daemon — `config set` le signale dans `requires_restart`. Si `config.json` est corrompu au démarrage, le daemon le sauvegarde, repart sur les défauts et émet une alerte `high` (visible dans l'onglet Security et `iris logs`) plutôt que de refuser de démarrer.

---

## 6. Usage quotidien

### 6.1 Variables d'environnement classiques, mais placeholders

Là où vous mettiez la vraie clé :

```bash
# AVANT
export ANTHROPIC_API_KEY="sk-ant-api03-XXXXXXXXX"
export GITHUB_TOKEN="ghp_YYYYYYYYY"
```

Désormais :

```bash
# APRÈS
export ANTHROPIC_API_KEY="{{kc:anthropic_api_key}}"
export GITHUB_TOKEN="{{kc:github_token}}"
```

Vos outils continuent de lire ces variables exactement comme avant. Au moment de la requête HTTP, le proxy IRIS détecte les placeholders dans les headers/body et les substitue par les vraies valeurs.

### 6.2 Pas de friction pour l'outil

```bash
# Cette commande marche identiquement, avec ou sans IRIS
gh api user
```

- Sans IRIS : `GITHUB_TOKEN=ghp_YYY` → header `Authorization: Bearer ghp_YYY` → upstream OK
- Avec IRIS : `GITHUB_TOKEN={{kc:github_token}}` → header `Authorization: Bearer {{kc:github_token}}` → IRIS substitue → upstream reçoit `ghp_YYY`

### 6.3 Fichiers `.env` projet

Même principe :
```dotenv
# .env
ANTHROPIC_API_KEY={{kc:anthropic_api_key}}
GITHUB_TOKEN={{kc:github_token}}
```

Ce fichier peut être **commité** dans votre repo (privé ou public) : il ne contient aucun secret réel. Fin du `.env.example` à dupliquer manuellement.

### 6.4 Si vous oubliez `HTTPS_PROXY`

C'est un *fail-safe* explicite : la requête sortira avec `{{kc:...}}` littéral, l'API renverra `401 invalid api key`. Votre vraie clé ne fuit pas. Vous savez immédiatement que vous avez oublié de configurer le proxy.

---

## 7. Configurer un serveur MCP

Les serveurs MCP (Model Context Protocol) consomment leurs credentials via un fichier de config JSON (`.mcp.json` ou `claude.json`), pas via env shell. IRIS fournit une commande pour les patcher automatiquement :

### 7.1 Wrap (substitution automatique)

```bash
iris mcp wrap ~/.config/claude/claude.json
```

Avant :
```json
{
  "mcpServers": {
    "github": {
      "command": "github-mcp",
      "env": { "GITHUB_TOKEN": "ghp_RAW_TOKEN_HERE" }
    }
  }
}
```

Après (file original sauvegardé en `.bak`) :
```json
{
  "mcpServers": {
    "github": {
      "command": "github-mcp",
      "env": { "GITHUB_TOKEN": "{{kc:github_token}}" }
    }
  }
}
```

IRIS détecte les valeurs qui ressemblent à des secrets (patterns `sk-*`, `ghp_*`, `xoxb-*`, etc.), propose le mapping vers un secret existant ou en crée un nouveau, et patche le fichier.

### 7.2 Mode `--dry-run`

Affiche le diff sans modifier :
```bash
iris mcp wrap ~/.config/claude/claude.json --dry-run
```

### 7.3 Mode `--watch`

Surveille le fichier et re-wrap automatiquement si vous (ou un outil) y ajoute un nouveau secret en clair :
```bash
iris mcp wrap ~/.config/claude/claude.json --watch
```

### 7.4 Unwrap (rollback)

```bash
iris mcp unwrap ~/.config/claude/claude.json
# Restaure le .bak
```

---

## 8. Vérification et monitoring

### 8.1 État du daemon

```bash
iris status
```

```
irisd up (pid 1234, uptime 4h12m)
Proxy:   127.0.0.1:8888  → 3 active connections
Secrets: 5 registered
Events:  142 today (138 substituted, 3 noMatch, 1 exfilBlocked)
```

### 8.2 Logs en direct

```bash
iris logs --follow
```

Avec filtre :
```bash
iris logs --follow --filter "host=api.anthropic.com"
```

![iris logs --follow](screenshots/12-iris-logs-follow.png "Stream de logs en temps réel")

### 8.3 Menu bar app

L'icône d'IRIS dans la barre de menus indique l'état d'un coup d'œil. C'est la **forme** qui porte l'information — l'icône est monochrome (règle macOS pour les *menu bar extras* : noir + transparent, teinté automatiquement selon le thème clair/sombre).

IRIS propose **deux jeux d'icônes** interchangeables dans *Settings › Appearance* : la **tête ailée** (*Winged head*, par défaut) et la **clé** (*Key*). Le tableau ci-dessous montre la tête ailée ; la clé équivalente figure entre parenthèses.

| Icône | État | Signification |
|:---:|---|---|
| <picture><source media="(prefers-color-scheme: dark)" srcset="../assets/menubar-bust-active-dark.png"><img src="../assets/menubar-bust-active.png" alt="tête ailée pleine" width="22" height="22"></picture> (<picture><source media="(prefers-color-scheme: dark)" srcset="../assets/menubar-active-dark.png"><img src="../assets/menubar-active.png" alt="clé pleine" width="18" height="18"></picture>) | **active** | Daemon actif, substitution en cours |
| <picture><source media="(prefers-color-scheme: dark)" srcset="../assets/menubar-bust-paused-dark.png"><img src="../assets/menubar-bust-paused.png" alt="tête ailée en contour" width="22" height="22"></picture> (<picture><source media="(prefers-color-scheme: dark)" srcset="../assets/menubar-paused-dark.png"><img src="../assets/menubar-paused.png" alt="clé creuse" width="18" height="18"></picture>) | **en pause** | Substitution suspendue (`iris pause`) |
| <picture><source media="(prefers-color-scheme: dark)" srcset="../assets/menubar-bust-stopped-dark.png"><img src="../assets/menubar-bust-stopped.png" alt="tête ailée barrée" width="22" height="22"></picture> (<picture><source media="(prefers-color-scheme: dark)" srcset="../assets/menubar-stopped-dark.png"><img src="../assets/menubar-stopped.png" alt="clé barrée" width="18" height="18"></picture>) | **arrêté** | Daemon arrêté ou en erreur |
| <picture><source media="(prefers-color-scheme: dark)" srcset="../assets/menubar-bust-connecting-dark.png"><img src="../assets/menubar-bust-connecting.png" alt="tête ailée atténuée" width="22" height="22"></picture> (<picture><source media="(prefers-color-scheme: dark)" srcset="../assets/menubar-connecting-dark.png"><img src="../assets/menubar-connecting.png" alt="clé atténuée" width="18" height="18"></picture>) | **connexion** | Connexion au daemon en cours (icône atténuée) |

Un **badge** (compteur) apparaît à côté de l'icône lorsqu'une ou plusieurs alertes de sécurité non lues attendent dans l'onglet **Security**.

Cliquez sur l'icône pour ouvrir le panneau (déplaçable et redimensionnable). Son en-tête porte une **pastille d'état colorée** (verte = actif, orange = en pause, rouge = arrêté, grise = connexion) — c'est là que vit la couleur, pas sur l'icône de la barre de menus :

![Panneau menu-bar](screenshots/13-app-popover.png "Panneau de l'app menu-bar")

Les six onglets :
- **Overview** : compteurs depuis le démarrage (requests / substituted / blocked / errors) et derniers events
- **Logs** : flux d'events en direct, avec recherche, filtre par host/type et mise en pause
- **Security** : alertes d'exfiltration et alertes système, triées par sévérité, avec action quarantaine
- **Secrets** : CRUD secrets, rotation, quarantaine (cf §5.7)
- **Rules** : whitelist MITM
- **Settings** : config, CA, terminal, démarrage automatique, désinstallation

### 8.4 Pause temporaire

```bash
iris pause
# Le daemon arrête de substituer ; les requêtes passent telles quelles.
# Utile pour tester un outil hors IRIS sans modifier l'env shell.

iris resume
```

L'app expose la même bascule via le bouton Pause/Resume en haut du panneau.

---

## 9. Sécurité

### Ce qu'IRIS garantit

1. **Aucun outil hôte n'a accès à la vraie clé** — il ne voit que `{{kc:...}}` et la requête sortante est substituée à la dernière seconde par le proxy.
2. **Scoping** : un secret destiné à `api.anthropic.com` ne sera **jamais** substitué dans une requête vers un autre host. Tentative bloquée → event `exfilBlocked` + alert.
3. **CA privée ACL-restreinte** : seul le binaire `irisd` signé peut signer des certificats avec la CA. Aucun autre process ne peut l'extraire.
4. **Aucun secret sur disque non chiffré** : les valeurs vivent uniquement dans le trousseau. Les events SQLite (Phase 3) ne stockent que les noms et métadonnées.
5. **Aucun phone-home** : IRIS ne contacte que les hosts présents dans la whitelist MITM, point final. Pas de télémétrie, pas de check de version.
6. **Redaction des logs** : aucune commande, log, event ou export ne révèle une valeur de secret. Si une valeur apparaît même partiellement → BLOQUANT côté tests.

### Ce qu'IRIS ne couvre pas

- **Accès root local** : si un attaquant a root sur votre machine, il peut lire `irisd` en mémoire et extraire les valeurs déchiffrées en transit. IRIS ne défend pas contre une compromission de la machine.
- **Kernel exploits / SIP bypass / Mach injection** : hors scope. Le trust model d'IRIS est celui de macOS user-mode.
- **Réseau hostile sur Wi-Fi public** : le proxy n'écoute que sur `127.0.0.1`. Aucun risque réseau externe.
- **Apps GUI lancées depuis Finder/Dock** : non interceptées (G8 SPECS). Si Safari a votre clé en cookie, c'est en dehors du périmètre d'IRIS.

### Modèle de menace couvert

| Adversaire | Couvert ? |
|---|---|
| A1 — Agent prompt-injecté qui dump son env et POST vers un attaquant | ✅ (l'env ne contient que des placeholders) |
| A2 — Agent qui POST un placeholder vers un host non-whitelisté | ✅ (scoping refuse la substitution + alert) |
| A3 — MCP malveillant qui lit l'env via stdio inheritance | ✅ (idem A1) |
| A4 — Process non-root local qui essaie de lire la CA privée | ✅ (ACL Keychain signed-binary) |

---

## 10. Dépannage

### `iris doctor` rapporte `Daemon down`

```bash
launchctl list | grep io.iris.daemon
```

Si absent, relancez `Iris.app` — le démarrage automatique est géré par **SMAppService**. Pour le réactiver : basculez le toggle dans l'onglet **Settings** de l'app, ou activez l'entrée dans **Réglages système → Général → Ouverture de session**.

Si présent mais en erreur, consultez les logs :
```bash
tail -f /tmp/irisd.err.log
```

### `curl: (60) SSL certificate problem`

Le CA d'IRIS n'est pas dans le trust store. Corrigez :
```bash
iris ca install
```

### `401 invalid api key` malgré le placeholder

1. Vérifier que `HTTPS_PROXY` est bien exporté dans la session courante :
   ```bash
   echo $HTTPS_PROXY
   ```
   Doit afficher `http://127.0.0.1:8888`.
2. Vérifier que le placeholder correspond bien à un secret existant :
   ```bash
   iris secret list
   ```
3. Vérifier que l'host de destination est dans les `allowed_hosts` du secret.
4. Vérifier les events :
   ```bash
   iris logs --follow --filter "kind=exfilBlocked"
   ```
   Si vous voyez un event → le scoping a refusé. Ajustez `allowed_hosts` :
   ```bash
   iris secret edit <name> --allowed-hosts <correct_host>
   ```

### Prompt Keychain "irisd wants to access"

Normal au premier accès à un secret nouvellement créé. Cliquez **Toujours autoriser**. Si vous voyez ce prompt à chaque requête, l'ACL signed-binary n'a pas été posée correctement — essayez :
```bash
iris doctor
```
et vérifiez `Keychain ACL : ok`. Si KO, contactez le support / réinstallez le `.pkg`.

### MCP server qui ne respecte pas `HTTPS_PROXY`

Certains serveurs MCP utilisent des clients HTTP qui ignorent les variables d'environnement (par exemple si un binaire Go utilise un `http.Transport` personnalisé sans configuration de proxy — le transport par défaut `net/http`, lui, honore bien `HTTPS_PROXY` via `http.ProxyFromEnvironment`). Vérifiez la doc du serveur ou utilisez `iris mcp wrap` qui patche directement le fichier de config (`HTTPS_PROXY` ajouté en `env` du serveur MCP).

---

## 11. FAQ

**Q : Puis-je commiter mes `.env` avec des `{{kc:...}}` sur GitHub ?**
R : Oui. Ces fichiers ne contiennent aucun secret. C'est même un des bénéfices principaux d'IRIS : fin du `.env.example` à dupliquer.

**Q : Que se passe-t-il si je désinstalle IRIS ?**
R : Vos placeholders deviennent inertes (les requêtes sortantes contiendront `{{kc:...}}` littéral → 401). **L'uninstall ne supprime PAS vos secrets du trousseau** sans demande explicite. Voir [§ 12. Désinstaller](#12-désinstaller) pour la procédure complète.

**Q : IRIS supporte-t-il HTTP/2 ?**
R : **Pas pour les hosts déchiffrés.** Le proxy MITM fonctionne en **HTTP/1.1 uniquement** : pour les hosts de la whitelist, IRIS annonce `http/1.1` en ALPN, donc le client négocie HTTP/1.1 (downgrade transparent). Le support HTTP/2 côté MITM reste en roadmap. En revanche, le **passthrough TCP** (hosts non whitelistés) fonctionne avec n'importe quelle version de protocole — HTTP/2, HTTP/3 — car IRIS ne déchiffre rien.

**Q : Que faire si Claude Code définit un `apiKeyHelper` ?**
R : `apiKeyHelper` est incompatible avec IRIS (il court-circuite l'env var). `iris doctor` vous alerte si configuré. Supprimez-le de `~/.claude/settings.json` et utilisez l'env var classique avec placeholder.

**Q : IRIS peut-il intercepter le trafic d'apps GUI (Safari, Slack…) ?**
R : Non, **par design** (cf G8 SPECS). Les apps GUI lancées depuis Finder/Dock/Spotlight n'héritent pas de `HTTPS_PROXY`. Le cas d'usage cible est l'outillage CLI agentique.

**Q : Multi-machine / synchro iCloud des secrets ?**
R : Hors scope (G1 — single-user). Le trousseau iCloud peut techniquement synchroniser les items `kSecClassGenericPassword` que IRIS crée, mais l'ACL signed-binary ne traverse pas la synchro. À utiliser à vos risques.

**Q : Comment exporter un secret pour le donner à un collègue ?**
R : Délibérément non supporté. IRIS n'exporte aucune valeur. Si vous devez partager une clé, passez par votre gestionnaire de secrets habituel (1Password, etc.) puis chaque utilisateur l'ajoute à son propre IRIS.

**Q : IRIS marche-t-il avec `direnv` ?**
R : Oui. `direnv` exporte des env vars comme n'importe quel mécanisme shell. Mettez `{{kc:...}}` dans vos `.envrc` et c'est bon.

---

## 12. Désinstaller

Deux chemins, selon que l'app est encore disponible ou non.

### Depuis l'app (recommandé)

Menu bar → onglet **Settings** → **Quit & Uninstall**. Une boîte de dialogue
propose de conserver ou de supprimer vos secrets (conservés par défaut). L'app :

- nettoie le trousseau (clé CA, et vos secrets si vous l'avez demandé) — sans
  aucune invite ;
- retire le certificat CA du trust store (une invite mot de passe) ;
- restaure les fichiers de configuration MCP que `iris mcp wrap` avait modifiés ;
- retire le bloc IRIS de votre `~/.zshrc` ;
- désenregistre le démarrage automatique ;
- ouvre le Finder et révèle `uninstall.sh`.

Le **CLI** (`/usr/local/bin/iris`) et l'**application** (`/Applications/Iris.app`)
appartiennent au système : ils exigent votre mot de passe. Pour les retirer,
lancez le script révélé dans le Finder.

### Avec le script (app déjà supprimée, ou pour finir)

```bash
bash "$HOME/Library/Application Support/iris/uninstall.sh"
```

Le script confirme chaque opération. Options : `--yes` (non-interactif, sauf les
secrets), `--delete-secrets` (supprime aussi vos secrets). Vos secrets ne sont
**jamais** supprimés sans demande explicite.

> ⚠️ Pensez à retirer Iris dans **Réglages Système → Général → Ouverture au
> démarrage** (ce réglage ne peut pas être retiré sans l'application).

---

## Ressources

- [SPECS.md](../SPECS.md) — spécification technique complète
- [README.md](../README.md) — vue d'ensemble produit
- [Issues GitHub](https://github.com/Sandjab/Iris/issues) — bugs et feature requests
