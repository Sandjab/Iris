# Smoke testing Phase 2 — proxy MITM single-host

> Checklist opérationnelle pour valider manuellement le daemon `irisd` tel qu'il existe à la fin de la Phase 2 (proxy MITM monothread, 1 host whitelisté hardcodé `api.anthropic.com`, substitution naïve sans scoping, pas d'IPC).

## Prérequis

- [ ] `swift build -c release` passe sans warning bloquant
- [ ] `swift test` : 59/59 ✅
- [ ] Clé Anthropic réelle disponible pour l'export `IRIS_SECRET_ANTHROPIC_KEY` (sinon, voir variante mock plus bas)
- [ ] Aucun `irisd` en cours sur le port 8888 (`lsof -i :8888` vide)
- [ ] `~/Library/Application Support/iris/ca.pem` absent OU prêt à être écrasé

## 1. Boot du daemon

```bash
export IRIS_SECRET_ANTHROPIC_KEY="sk-ant-..."   # vraie clé
.build/release/irisd --foreground --in-memory-secrets --log-level debug
```

- [ ] Log `Using in-memory secret store (debug)` apparaît
- [ ] Log `Loaded in-memory secrets count=1 names=["anthropic_key"]`
- [ ] Log `CA ready fingerprint=... pem_path=~/Library/Application Support/iris/ca.pem`
- [ ] Log `Proxy bound address=127.0.0.1:8888 allowed_hosts=["api.anthropic.com"]`
- [ ] Le fichier `~/Library/Application Support/iris/ca.pem` existe et est un PEM valide (`openssl x509 -in ca.pem -noout -subject` lisible)
- [ ] La clé privée CA est dans le Keychain login (`security find-generic-password -s io.iris.ca.key -a $(id -un)` retourne un item, **sans afficher la valeur**)

## 2. CA trust

```bash
# Option A — trust temporaire pour curl uniquement
export CURL_CA_BUNDLE=~/Library/Application\ Support/iris/ca.pem

# Option B — trust système (interactif, demande mot de passe admin)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ~/Library/Application\ Support/iris/ca.pem
```

- [ ] Option choisie : ____ (A ou B)
- [ ] Si B : trust visible dans Keychain Access > System > Certificates

## 3. Happy path — substitution

```bash
curl -v -x http://127.0.0.1:8888 \
  -H "x-api-key: {{kc:anthropic_key}}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-opus-4-7","max_tokens":10,"messages":[{"role":"user","content":"ping"}]}' \
  https://api.anthropic.com/v1/messages
```

- [ ] Connexion TLS établie via CA Iris (logs curl : `subject: CN=api.anthropic.com`, issuer = CA Iris)
- [ ] Daemon log : `Substituted secrets host=api.anthropic.com path=/v1/messages secrets=["anthropic_key"]`
- [ ] Daemon log : `Event kind=substituted durationMs=<N>` (vérif via `--log-level debug`)
- [ ] Réponse upstream reçue (HTTP 200 ou erreur applicative Anthropic — pas erreur réseau)
- [ ] `{{kc:anthropic_key}}` n'apparaît jamais dans la requête finale (vérifiable côté Anthropic seulement par succès auth ; côté daemon par l'absence de la chaîne dans les logs)
- [ ] **La valeur réelle de la clé n'apparaît JAMAIS dans les logs daemon**, même en `--log-level debug` (grep `sk-ant-` sur la sortie → 0 hit)

## 4. No-match — substitution non requise

```bash
curl -v -x http://127.0.0.1:8888 -H "x-api-key: real-key-no-placeholder" \
  https://api.anthropic.com/v1/messages -d '{}'
```

- [ ] Daemon log : `Event kind=noMatch`
- [ ] Requête forwardée telle quelle

## 5. Non-whitelisted host

```bash
curl -v -x http://127.0.0.1:8888 https://example.com/
```

- [ ] Daemon log : `Refusing non-whitelisted host host=example.com` OU CONNECT tunnel passthrough sans MITM (selon impl actuelle — vérifier comportement)
- [ ] Connexion soit refusée, soit établie sans interception (cert serveur = vrai cert example.com, pas CA Iris)

## 6. Body cap 4 MiB

```bash
# Générer un body > 4 MiB contenant le placeholder
python3 -c "print('x' * 5_000_000 + '{{kc:anthropic_key}}')" > /tmp/big.txt
curl -v -x http://127.0.0.1:8888 \
  -H "x-api-key: dummy" \
  --data-binary @/tmp/big.txt \
  https://api.anthropic.com/v1/messages
```

- [ ] Daemon log : event avec `bodyTooLarge` OU substitution skippée (placeholder reste dans le body forwardé)
- [ ] Pas de crash, pas d'OOM

## 7. Accept-Encoding strippé

```bash
curl -v -x http://127.0.0.1:8888 \
  -H "Accept-Encoding: gzip, deflate, br" \
  -H "x-api-key: {{kc:anthropic_key}}" \
  https://api.anthropic.com/v1/messages -d '{}'
```

- [ ] Réponse non-compressée (curl log : `Content-Encoding:` absent ou `identity`)
- [ ] Si daemon log inclut headers upstream : `Accept-Encoding` retiré avant transmission

## 8. LRU cache des valeurs (TTL 5 min)

Lancer 2 requêtes substituées en < 5 min sur le même secret :

- [ ] 1ère requête : daemon log montre 1 hit Keychain/InMemory store
- [ ] 2ème requête (dans la fenêtre 5 min) : pas de nouvel accès store (vérif via log `debug` ou par instrumentation manuelle)
- [ ] Après 5 min, 3ème requête : nouveau hit store (TTL expiré)

> Note : sans IPC ni endpoint debug, ce point est difficilement observable de l'extérieur. **À considérer comme couvert par tests unitaires** (`PlaceholderEngineTests`). Pour vérif manuelle : breakpoint LLDB ou ré-instrumentation temporaire.

## 9. Body non-UTF8

```bash
# Upload binaire (image PNG par ex.)
curl -v -x http://127.0.0.1:8888 \
  -H "x-api-key: {{kc:anthropic_key}}" \
  --data-binary @/path/to/image.png \
  https://api.anthropic.com/v1/messages
```

- [ ] Daemon log : `Event kind=noMatch nonUtf8=true`
- [ ] Body forwardé intact (pas de corruption binaire)

## 10. EventRing (10 000 entrées)

> **Non observable en Phase 2** (pas d'IPC, pas de dump CLI). Couvert :
> - Capacité ring : test unitaire `EventRingTests` si présent (sinon, à ajouter Phase 3)
> - Émission par requête : implicitement validé par §3, §4, §5, §9 si les logs `Event kind=...` apparaissent

- [ ] Tests unitaires `EventRing` présents et verts : `swift test --filter EventRing`

## 11. Shutdown propre

- [ ] Ctrl-C (SIGINT) sur le daemon : log `Proxy stopping`, le processus rend la main < 2s
- [ ] Aucune socket leak (`lsof -i :8888` vide après stop)
- [ ] Aucun thread NIO en limbo (le process disparaît de `ps`)

## 12. Sécurité — invariance redaction

```bash
# Capturer toute la sortie daemon pendant la session smoke
.build/release/irisd --foreground --in-memory-secrets --log-level trace 2>&1 | tee /tmp/iris-smoke.log
# Après les 11 étapes :
grep -F "$IRIS_SECRET_ANTHROPIC_KEY" /tmp/iris-smoke.log
```

- [ ] **Le grep ne retourne RIEN.** Si la valeur de la clé apparaît même une fois → BLOQUANT, ne pas merger.

---

## Variante sans clé Anthropic réelle

Si tu ne veux pas exposer une vraie clé : remplacer `api.anthropic.com` par un mock local (httpbin auto-hébergé), mais ça implique de patcher le hardcode dans `Sources/irisd/App.swift:52`. À faire dans une branche jetable, ne pas commit.

## Notes

- Les points 6, 8, 10 sont **partiellement opaques** sans IPC. Phase 3 (admin socket + SSE) les rendra triviaux à smoke tester. Pour l'instant, ils reposent sur les tests unitaires (`EventRingTests`, `PlaceholderEngineTests`).
- Le point 5 (non-whitelisted host) doit être confirmé sur le comportement actuel : SPECS §8.3 dit "CONNECT-tunnel passthrough", mais l'impl actuelle pourrait simplement refuser. À observer.
