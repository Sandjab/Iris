#!/bin/bash
# IRIS dev-uninstall.sh — nettoyage COMPLET des traces d'installation IRIS sur un poste.
#
# ⚠️  DEV ONLY. Outil de poste de développement, NON distribué dans le .pkg.
#     Ce n'est PAS le désinstalleur produit (= « temps 2 » : bouton in-app + script
#     de secours). Il efface aussi des résidus propres au dev (anciens bundle ids,
#     CA régénérées, builds Xcode) qu'un utilisateur final n'aurait jamais.
#
# Chaque opération destructive AFFICHE d'abord ce qu'elle va supprimer, puis demande
# une confirmation explicite. Rien n'est supprimé sans « y ». Lance-le autant de fois
# que nécessaire (idempotent) — la dernière passe doit tout afficher en « rien à faire ».
#
# Usage :  bash packaging/dev-uninstall.sh
set -u

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

confirm() { printf '%s' "${YEL}» $1 [y/N] ${RST}"; read -r a; [ "$a" = y ] || [ "$a" = Y ] || [ "$a" = yes ]; }
section() { printf '\n%s\n' "${BOLD}=== $1 ===${RST}"; }
ok()      { printf '%s\n' "${GRN}  $1${RST}"; }

# ---------------------------------------------------------------------------
section "1. Daemon en cours + services de démarrage (SMAppService)"
running="$(pgrep -fl -i iris 2>/dev/null | grep -ivE 'siri|dev-uninstall' || true)"
svcs="$(launchctl list 2>/dev/null | grep -i iris || true)"
if [ -n "$running$svcs" ]; then
    [ -n "$running" ] && printf 'Process:\n%s\n' "$running"
    [ -n "$svcs" ]    && printf 'Services launchd:\n%s\n' "$svcs"
    if confirm "Arrêter le daemon (launchctl bootout io.iris.daemon + pkill irisd/Iris) ?"; then
        launchctl bootout "gui/$(id -u)/io.iris.daemon" 2>/dev/null || true
        pkill -f 'MacOS/irisd' 2>/dev/null || true
        pkill -f 'Iris.app/Contents/MacOS/Iris' 2>/dev/null || true
        ok "arrêté."
    fi
    printf '%s\n' "${DIM}  Non scriptable : retire aussi les entrées dans Réglages Système → Général →"
    printf '%s\n' "  Ouverture au démarrage (section « Autoriser en arrière-plan »).${RST}"
else
    ok "rien à arrêter."
fi

# ---------------------------------------------------------------------------
section "2. Bundles Iris.app (installé + builds Xcode indexés par Spotlight)"
apps="$( { ls -d /Applications/Iris*.app 2>/dev/null; mdfind "kMDItemFSName == 'Iris.app'" 2>/dev/null; } | sort -u || true)"
if [ -n "$apps" ]; then
    printf '%s\n' "$apps"
    if confirm "Supprimer TOUS ces bundles (sudo demandé si nécessaire) ?"; then
        while IFS= read -r app; do
            [ -n "$app" ] || continue
            # Un .pkg dont l'install a été relocalisée laisse des fichiers owned by root
            # (installd) DANS le bundle → rm user échoue ; on retombe sur sudo.
            rm -rf "$app" 2>/dev/null || sudo rm -rf "$app"
            [ -e "$app" ] && printf '%s\n' "${RED}  ÉCHEC: $app${RST}" || printf '  supprimé: %s\n' "$app"
        done <<< "$apps"
    fi
    if confirm "Supprimer aussi les caches DerivedData IrisApp-* (Xcode) ?"; then
        rm -rf ~/Library/Developer/Xcode/DerivedData/IrisApp-* 2>/dev/null || true
        ok "DerivedData IrisApp-* supprimé."
    fi
else
    ok "aucune Iris.app."
fi

# ---------------------------------------------------------------------------
section "3. CLI /usr/local/bin/iris"
if [ -e /usr/local/bin/iris ]; then
    ls -l /usr/local/bin/iris
    confirm "Supprimer /usr/local/bin/iris (sudo) ?" && { sudo rm -f /usr/local/bin/iris; ok "supprimé."; }
else
    ok "absent."
fi

# ---------------------------------------------------------------------------
section "4. Reçus d'installation pkg (pkgutil)"
pkgs="$(pkgutil --pkgs 2>/dev/null | grep -i iris || true)"
if [ -n "$pkgs" ]; then
    printf '%s\n' "$pkgs"
    if confirm "Oublier ces reçus (sudo pkgutil --forget) ?"; then
        while IFS= read -r p; do [ -n "$p" ] && sudo pkgutil --forget "$p"; done <<< "$pkgs"
    fi
else
    ok "aucun reçu io.iris.*."
fi

# ---------------------------------------------------------------------------
section "5. Certificats « IRIS local CA » dans le trust store (TOUS — CA régénérées incluses)"
shas="$(security find-certificate -a -c "IRIS local CA" -Z "$LOGIN_KC" 2>/dev/null | awk '/SHA-1 hash:/{print $3}' || true)"
if [ -n "$shas" ]; then
    printf 'SHA-1 trouvés:\n%s\n' "$shas"
    if confirm "Supprimer TOUS ces certificats (delete-certificate -Z, sans panneau, purge le trust setting) ?"; then
        while IFS= read -r sha; do
            [ -n "$sha" ] || continue
            security delete-certificate -Z "$sha" "$LOGIN_KC" 2>/dev/null && printf '  supprimé: %s\n' "$sha"
        done <<< "$shas"
        rest="$(security find-certificate -a -c "IRIS local CA" -Z "$LOGIN_KC" 2>/dev/null | awk '/SHA-1 hash:/{print $3}' || true)"
        [ -z "$rest" ] && ok "trust store propre." || printf '%s\n' "${RED}  reste: $rest${RST}"
    fi
else
    ok "aucun cert IRIS local CA."
fi

# ---------------------------------------------------------------------------
section "6. Trousseau — clé privée de la CA (io.iris.ca / privatekey)"
if security find-generic-password -s io.iris.ca -a privatekey >/dev/null 2>&1; then
    printf '%s\n' "  présente."
    confirm "Supprimer la clé privée CA (peut demander une autorisation trousseau) ?" && \
        { security delete-generic-password -s io.iris.ca -a privatekey >/dev/null 2>&1 && ok "supprimée."; }
else
    ok "absente."
fi

# ---------------------------------------------------------------------------
section "7. Trousseau — SECRETS utilisateur (io.iris.secret)  ⚠️ TES vraies clés API"
first="$(security find-generic-password -s io.iris.secret 2>/dev/null | awk -F'"' '/"acct"<blob>=/{print $4}' | head -1)"
if [ -n "$first" ]; then
    printf '%s\n' "  Au moins un secret présent (p.ex. « $first »)."
    printf '%s\n' "${RED}  ⚠️ Ce sont TES vraies clés API — suppression irréversible.${RST}"
    if confirm "Supprimer TOUS les secrets io.iris.secret ?"; then
        n=0; while security delete-generic-password -s io.iris.secret >/dev/null 2>&1; do n=$((n+1)); done
        ok "$n secret(s) supprimé(s)."
    fi
else
    ok "aucun secret."
fi

# ---------------------------------------------------------------------------
section "8. Fichiers de support ~/Library/Application Support/iris"
SUP="$HOME/Library/Application Support/iris"
if [ -d "$SUP" ]; then
    /bin/ls -la "$SUP" | sed 's/^/    /'
    confirm "Supprimer $SUP ?" && { rm -rf "$SUP" && ok "supprimé."; }
else
    ok "absent."
fi

# ---------------------------------------------------------------------------
section "9. Containers sandbox (~/Library/Containers/*iris* — tous les bundle ids)"
conts="$(ls -d "$HOME"/Library/Containers/*[Ii]ris* 2>/dev/null || true)"
if [ -n "$conts" ]; then
    printf '%s\n' "$conts"
    if confirm "Supprimer ces containers ?"; then
        fail=0
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            if rm -rf "$c" 2>/dev/null; then printf '  supprimé: %s\n' "$c"; else fail=1; printf '%s\n' "${RED}  bloqué (TCC): $c${RST}"; fi
        done <<< "$conts"
        [ "$fail" = 1 ] && printf '%s\n' "${YEL}  → Containers protégés par TCC. Supprime-les via le Finder (⇧⌘G → ~/Library/Containers/ → corbeille),
    ou donne l'« Accès complet au disque » au Terminal (Réglages Système → Confidentialité
    et sécurité), relance le Terminal, puis relance ce script.${RST}"
    fi
else
    ok "aucun container iris."
fi

# ---------------------------------------------------------------------------
section "10. Bloc IRIS dans ~/.zshrc"
if grep -q '# >>> iris >>>' "$HOME/.zshrc" 2>/dev/null; then
    printf '%s\n' "  Bloc présent :"
    sed -n '/# >>> iris >>>/,/# <<< iris <<</p' "$HOME/.zshrc" | sed 's/^/    /'
    if confirm "Retirer ce bloc de ~/.zshrc (un backup horodaté est créé) ?"; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.iris-bak.$(date +%s)"
        sed -i '' '/# >>> iris >>>/,/# <<< iris <<</d' "$HOME/.zshrc"
        ok "retiré (backup ~/.zshrc.iris-bak.*)."
    fi
else
    ok "aucun bloc iris."
fi

printf '\n%s\n' "${BOLD}Nettoyage terminé.${RST} Relance le script pour confirmer l'état zéro (tout en vert)."
