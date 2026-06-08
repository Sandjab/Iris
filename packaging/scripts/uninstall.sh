#!/bin/bash
# IRIS uninstall.sh — désinstallation propre côté utilisateur.
#
# Déposé dans ~/Library/Application Support/iris/ par le postinstall (survit au
# drag-to-trash) et versionné dans packaging/scripts/. Couvre le paquet « root »
# (sudo) et le cas « app déjà jetée ». Le bouton in-app fait le reste sans mot
# de passe ; ce script termine ce qui exige sudo.
#
# Usage : bash uninstall.sh [--yes] [--delete-secrets]
#   --yes             non-interactif (sauf les secrets, toujours opt-in explicite)
#   --delete-secrets  supprime aussi les secrets du trousseau (sinon conservés)
set -u

YES=0; DELETE_SECRETS=0
for arg in "$@"; do
    case "$arg" in
        --yes) YES=1 ;;
        --delete-secrets) DELETE_SECRETS=1 ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; exit 64 ;;
    esac
done

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
SUP="$HOME/Library/Application Support/iris"
MANIFEST="$SUP/wrapped-paths.json"

confirm() {
    [ "$YES" = 1 ] && return 0
    printf '%s' "${YEL}» $1 [y/N] ${RST}"; read -r a
    [ "$a" = y ] || [ "$a" = Y ] || [ "$a" = yes ]
}
section() { printf '\n%s\n' "${BOLD}=== $1 ===${RST}"; }
ok()      { printf '%s\n' "${GRN}  $1${RST}"; }

# 1. Daemon (sinon le bundle reste verrouillé).
section "1. Arrêt du daemon (launchd)"
if launchctl print "gui/$(id -u)/io.iris.daemon" >/dev/null 2>&1; then
    if confirm "Arrêter irisd (launchctl bootout) ?"; then
        launchctl bootout "gui/$(id -u)/io.iris.daemon" 2>/dev/null || true
        ok "arrêté."
    fi
else
    ok "non actif."
fi

# 2. MCP unwrap (avant de retirer App Support + le CLI).
section "2. Restauration des configs MCP wrappées"
if [ -f "$MANIFEST" ]; then
    i=0
    while p="$(plutil -extract "$i" raw -o - "$MANIFEST" 2>/dev/null)"; do
        bak="$p.iris.bak"
        if [ -f "$bak" ]; then
            if confirm "Restaurer $p depuis son backup ?"; then
                cp "$bak" "$p" && rm -f "$bak" && ok "restauré: $p"
            fi
        else
            printf '%s\n' "${DIM}  backup absent (déjà restauré ?): $p${RST}"
        fi
        i=$((i+1))
    done
    [ "$i" = 0 ] && ok "aucune config wrappée listée."
else
    ok "aucun registre MCP."
fi

# 3. Bundle /Applications/Iris.app (root:wheel).
section "3. Application /Applications/Iris.app"
if [ -d /Applications/Iris.app ]; then
    if confirm "Supprimer /Applications/Iris.app (sudo) ?"; then
        sudo rm -rf /Applications/Iris.app && ok "supprimée."
    fi
else
    ok "absente (déjà jetée ?)."
fi

# 4. CLI /usr/local/bin/iris (root:wheel).
section "4. CLI /usr/local/bin/iris"
if [ -e /usr/local/bin/iris ]; then
    if confirm "Supprimer /usr/local/bin/iris (sudo) ?"; then
        sudo rm -f /usr/local/bin/iris && ok "supprimé."
    fi
else
    ok "absent."
fi

# 5. Reçus d'installation.
section "5. Reçus d'installation (pkgutil)"
pkgs="$(pkgutil --pkgs 2>/dev/null | grep -E 'io\.iris\.(app|cli)' || true)"
if [ -n "$pkgs" ]; then
    printf '%s\n' "$pkgs"
    if confirm "Oublier ces reçus (sudo pkgutil --forget) ?"; then
        while IFS= read -r p; do [ -n "$p" ] && sudo pkgutil --forget "$p"; done <<< "$pkgs"
    fi
else
    ok "aucun reçu io.iris.*."
fi

# 6. Certificat(s) CA dans le trust store (sans panneau).
section "6. Certificat(s) « IRIS local CA » (trust store)"
shas="$(security find-certificate -a -c "IRIS local CA" -Z "$LOGIN_KC" 2>/dev/null | awk '/SHA-1 hash:/{print $3}' || true)"
if [ -n "$shas" ]; then
    printf 'SHA-1 trouvés:\n%s\n' "$shas"
    if confirm "Supprimer ces certificats (delete-certificate -Z) ?"; then
        while IFS= read -r sha; do
            [ -n "$sha" ] || continue
            security delete-certificate -Z "$sha" "$LOGIN_KC" 2>/dev/null && printf '  supprimé: %s\n' "$sha"
        done <<< "$shas"
    fi
else
    ok "aucun cert IRIS local CA."
fi

# 7. Clé privée CA (prompt trousseau attendu : plus d'ACL daemon).
section "7. Clé privée CA (io.iris.ca)"
if security find-generic-password -s io.iris.ca -a privatekey >/dev/null 2>&1; then
    printf '%s\n' "${DIM}  Une autorisation trousseau peut s'afficher (le daemon n'est plus là pour l'ACL).${RST}"
    if confirm "Supprimer la clé privée CA ?"; then
        security delete-generic-password -s io.iris.ca -a privatekey >/dev/null 2>&1 && ok "supprimée."
    fi
else
    ok "absente."
fi

# 8. Secrets utilisateur — opt-in STRICT (§10).
section "8. Secrets utilisateur (io.iris.secret)  ⚠️ tes vraies clés API"
if [ "$DELETE_SECRETS" = 1 ] || { [ "$YES" = 0 ] && confirm "Supprimer TOUS les secrets io.iris.secret ?"; }; then
    n=0; while security delete-generic-password -s io.iris.secret >/dev/null 2>&1; do n=$((n+1)); done
    ok "$n secret(s) supprimé(s)."
else
    ok "conservés (utilise --delete-secrets pour les supprimer)."
fi

# 9. Bloc IRIS dans ~/.zshrc.
section "9. Bloc IRIS dans ~/.zshrc"
if grep -q '# >>> iris >>>' "$HOME/.zshrc" 2>/dev/null; then
    if confirm "Retirer le bloc iris de ~/.zshrc (backup créé) ?"; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.iris-bak.$(date +%s)"
        sed -i '' '/# >>> iris >>>/,/# <<< iris <<</d' "$HOME/.zshrc"
        ok "retiré."
    fi
else
    ok "aucun bloc iris."
fi

# 10. Fichiers de support — EN DERNIER (self-suppression, après lecture du registre).
section "10. Fichiers de support ~/Library/Application Support/iris"
if [ -d "$SUP" ]; then
    if confirm "Supprimer $SUP (y compris ce script) ?"; then
        rm -rf "$SUP" && ok "supprimé."
    fi
else
    ok "absent."
fi

printf '\n%s\n' "${BOLD}Désinstallation terminée.${RST}"
printf '%s\n' "${DIM}Pensez à retirer Iris dans Réglages Système → Général → Ouverture au démarrage.${RST}"
