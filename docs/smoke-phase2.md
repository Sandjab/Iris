# Smoke testing Phase 2 — proxy MITM single-host

> Checklist opérationnelle pour valider manuellement le daemon `irisd` tel qu'il existe à la fin de la Phase 2 (proxy MITM monothread, 1 host whitelisté hardcodé `api.anthropic.com`, substitution naïve sans scoping, CONNECT-tunnel passthrough pour les autres hosts, pas d'IPC).

## Prérequis

- [ ] `swift build -c release` passe sans warning bloquant
- [ ] `swift test` : 71/71 ✅
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
- [ ] La clé privée CA est dans le Keychain login (`security find-generic-password -s io.iris.ca -a privatekey` retourne un item, **sans afficher la valeur**)

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
- [ ] Réponse upstream reçue (HTTP 200 si la clé est valide, HTTP 401 `invalid x-api-key` si dummy — dans les deux cas, pas d'erreur réseau)
- [ ] `{{kc:anthropic_key}}` n'apparaît jamais dans la requête finale (vérifiable côté Anthropic seulement par succès auth ; côté daemon par l'absence de la chaîne dans les logs)
- [ ] **La valeur réelle de la clé n'apparaît JAMAIS dans les logs daemon**, même en `--log-level debug` (grep `sk-ant-` sur la sortie → 0 hit)

## 4. No-match — substitution non requise

```bash
curl -v -x http://127.0.0.1:8888 -H "x-api-key: real-key-no-placeholder" \
  https://api.anthropic.com/v1/messages -d '{}'
```

- [ ] **Pas** de log `Substituted secrets` pour cette requête (no-match → aucune substitution emit)
- [ ] Requête forwardée telle quelle (la réponse upstream confirme — code HTTP attendu selon validité du header `x-api-key`)

## 5. Non-whitelisted host — CONNECT passthrough (SPECS §8.3)

```bash
curl -v -x http://127.0.0.1:8888 https://example.com/
```

- [ ] Daemon log : `Passthrough tunnel established host=example.com port=443`
- [ ] Connexion HTTPS établie **sans interception** : `curl -v` montre `subject: CN=example.com` et un `issuer` *publique* (Let's Encrypt, DigiCert…), **pas** la CA Iris
- [ ] Réponse HTTP 200 reçue (curl affiche le HTML d'`example.com`)
- [ ] Pas de log `Substituted secrets` pour cet host (le proxy ne déchiffre rien)

## 6. Body cap 4 MiB

```bash
# Générer un body > 4 MiB contenant le placeholder
python3 -c "print('x' * 5_000_000 + '{{kc:anthropic_key}}')" > /tmp/big.txt
curl -v -x http://127.0.0.1:8888 \
  -H "x-api-key: dummy" \
  --data-binary @/tmp/big.txt \
  https://api.anthropic.com/v1/messages
```

- [ ] Daemon log : `warning Body too large, skipping substitution scan size=<N>` (avec `<N>` > 4 194 304)
- [ ] Placeholder reste dans le body forwardé (upstream retourne 401 sur la valeur litterale `{{kc:anthropic_key}}`)
- [ ] Pas de crash, pas d'OOM

## 7. Accept-Encoding strippé

```bash
curl -v -x http://127.0.0.1:8888 \
  -H "Accept-Encoding: gzip, deflate, br" \
  -H "x-api-key: {{kc:anthropic_key}}" \
  https://api.anthropic.com/v1/messages -d '{}'
```

- [ ] Réponse non-compressée (curl log : `Content-Encoding:` absent ou `identity`)
- [ ] Strip `Accept-Encoding` côté daemon : **non observable en boîte noire** (pas de log des headers upstream). Couvert par `ProxyEndToEndTests.testSubstitutedValueReachesUpstream` et inspection visuelle de `MITMHandler.swift:170`.

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

- [ ] Daemon log (debug) : `Body is non-UTF-8, skipping substitution scan`
- [ ] Substitution sur les headers continue (si placeholder dans header : log `Substituted secrets` émis)
- [ ] Body forwardé intact (pas de corruption binaire)

## 10. EventRing (10 000 entrées)

> **Non observable directement en Phase 2** (pas d'IPC, pas de dump CLI). `EventRing.append` est silencieux par design — aucun log `Event kind=...` n'est émis sur stdout. Couvert :
> - Capacité ring + ordering + concurrence : `EventRingTests` (9 tests, PR #6 `2f9f0c1`)
> - Émission `.substituted` / `.noMatch` / `.error` par requête MITM : `ProxyEndToEndTests.testSubstitutedValueReachesUpstream`
> - Émission `.passThrough` par CONNECT non-whitelisté : `ProxyEndToEndTests.testNonWhitelistedHostTunnelsTLSAndPreservesUpstreamCertificate`

- [ ] `swift test --filter EventRing` : 9/9 verts

## 11. Shutdown propre

> Phase 2 : pas de graceful shutdown. SIGINT/SIGTERM coupent le processus via la disposition POSIX par défaut. NIO + Keychain sont libérés implicitement par l'OS. Un teardown propre (log `Proxy stopping`, flush des events SQLite) arrive avec Phase 3+ (IPC).

- [ ] `kill -INT <pid>` (Ctrl-C équivalent) : le processus disparaît < 2s
- [ ] `kill -TERM <pid>` : le processus disparaît < 2s
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
- Le point 5 (passthrough) est désormais conforme à SPECS §8.3 — voir `Sources/IrisKit/Proxy/ConnectHandler.swift::performPassthrough` et `Sources/IrisKit/Proxy/GlueHandler.swift`.
