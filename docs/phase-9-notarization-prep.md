# Phase 9 — Préparation notarisation & signature

> Document de préparation à la **Phase 9** du phasage IRIS (`.pkg` + codesign + notarize).
> À exécuter dès l'inscription au Apple Developer Program validée, sans attendre l'arrivée en Phase 9.
> Sources : [TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool), [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

---

## 1. Pré-requis

- [ ] Apple Developer Program **payant** validé (compte gratuit insuffisant).
- [ ] Xcode 13+ installé (`xcrun notarytool` requiert Xcode 13 minimum).
- [ ] 2FA actif sur l'Apple ID lié au compte développeur.

Vérification rapide :

```sh
xcrun notarytool --help    # doit afficher l'aide, pas une erreur
xcode-select --print-path  # doit pointer sur une install Xcode 13+
```

---

## 2. Credentials de soumission notarisation

Deux méthodes possibles. La **voie API Key est strictement supérieure** ; l'app-specific password n'est gardé qu'en fallback.

### Voie 1 — App Store Connect API Key (recommandée)

#### 2.1 Créer la clé

1. https://appstoreconnect.apple.com → **Users and Access** → onglet **Integrations** → **App Store Connect API** → **Keys**.
2. Bouton **+** (Generate API Key).
3. Nom : `iris-notarization`.
4. **Access role** : `Developer` (suffisant pour `notarytool` ; éviter `Admin` / `Account Holder`).
5. **Generate**.

#### 2.2 Récupérer les 3 éléments

Sur la page Keys, immédiatement après création :

| Élément | Format | Récupération |
|---|---|---|
| Fichier `.p8` | `AuthKey_<KEYID>.p8` | Bouton "Download API Key" — **TÉLÉCHARGEABLE UNE SEULE FOIS** |
| **Key ID** | 10 caractères (ex. `T9GPZ92M7K`) | Colonne de la liste des keys |
| **Issuer ID** | UUID (ex. `c055ca8c-e5a8-4836-b61d-aa5794eeb3f4`) | En haut de la page Keys, commun à toutes les clés |

⚠️ Le `.p8` est non-récupérable. Si raté → révoquer la clé et en créer une nouvelle.

#### 2.3 Sauvegarder le `.p8`

```sh
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
```

**Backup chiffré obligatoire** (gestionnaire de mots de passe / `.dmg` chiffré / archive AES). Jamais dans le repo, jamais en cloud non chiffré.

#### 2.4 Stocker dans le trousseau

```sh
xcrun notarytool store-credentials "iris-notary" \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> \
  --issuer <ISSUER_UUID>
```

Effet : item `com.apple.gke.notary.tool` créé dans le trousseau data-protection (visible dans *Keychain Access → Local Items* ou *iCloud Keychain*). Profil réutilisable via `--keychain-profile "iris-notary"`.

#### 2.5 Tester

```sh
xcrun notarytool history --keychain-profile "iris-notary"
```

Sortie attendue (premier usage) :

```
Successfully received submission history.
  history: []
```

Si `Error: HTTP status code: 401` → credentials invalides.

### Voie 2 — App-specific password (fallback)

À utiliser uniquement si la voie 1 bloque administrativement.

```sh
# 1. Générer le password : https://account.apple.com
#    → Sign-In and Security → App-Specific Passwords → "iris-notarization"
# 2. Récupérer le Team ID : https://developer.apple.com/account → Membership details

xcrun notarytool store-credentials "iris-notary" \
  --apple-id "<apple-id@…>" \
  --team-id <TEAM_ID>
# Saisir le mdp à l'invite interactive (jamais en arg CLI)
```

⚠️ Ne **jamais** passer l'app-specific password en argument CLI ni en variable d'env tracée par l'historique shell. L'invite interactive de `store-credentials` est faite pour ça.

---

## 3. Certificats Developer ID (signature)

**Séparés des credentials notarisation.** Les credentials API servent à *soumettre* à Apple ; les certificats Developer ID servent à *signer* les binaires et le `.pkg` avant soumission.

### 3.1 Créer les deux certificats

Xcode → **Settings** → **Accounts** → ton compte Apple → bouton **Manage Certificates…** → bouton **+** :

- [ ] `Developer ID Application` — signe `irisd`, `iris` (CLI), `Iris.app`
- [ ] `Developer ID Installer` — signe le `.pkg` produit par `productbuild`

### 3.2 Vérifier la présence dans le trousseau

```sh
# Application identity
security find-identity -v -p codesigning
# Attendu : "Developer ID Application: Jean-Paul Gavini (<TEAM_ID>)"

# Installer identity
security find-identity -v -p basic | grep "Developer ID Installer"
# Attendu : "Developer ID Installer: Jean-Paul Gavini (<TEAM_ID>)"
```

### 3.3 Backup `.p12` (critique)

Sans backup, perdre le Mac = perdre la capacité à re-signer (même Developer ID). Apple ne ré-émet pas la clé privée.

Pour chacun des deux certificats :

1. Keychain Access → catégorie *My Certificates*.
2. Déplier l'entrée pour voir **certificat + clé privée**.
3. Sélectionner les deux, clic droit → **Export 2 items…**.
4. Format `.p12`, mot de passe fort, fichier dans archive chiffrée séparée.

---

## 4. Récapitulatif des artefacts

| Artefact | Emplacement | Sensible | Backup obligatoire |
|---|---|:---:|:---:|
| `AuthKey_<KEYID>.p8` | `~/.appstoreconnect/private_keys/` | 🔒 | ✅ (non-récupérable) |
| Key ID | Doc projet | ❌ | ❌ (lisible dans App Store Connect) |
| Issuer ID | Doc projet | ❌ | ❌ (lisible dans App Store Connect) |
| Profil keychain `iris-notary` | Trousseau macOS | 🔒 | ❌ (recréable depuis le `.p8`) |
| Cert + clé `Developer ID Application` (`.p12`) | Archive chiffrée | 🔒 | ✅ (non-récupérable) |
| Cert + clé `Developer ID Installer` (`.p12`) | Archive chiffrée | 🔒 | ✅ (non-récupérable) |
| Team ID | Doc projet | ❌ | ❌ |
| Bundle Identifiers (`org.gavini.iris.*`) | Doc projet | ❌ | ❌ |

---

## 5. Checklist d'exécution

À cocher en séquence :

- [ ] **2.1** API Key créée dans App Store Connect (rôle `Developer`)
- [ ] **2.2** `.p8` téléchargé + Key ID + Issuer ID notés
- [ ] **2.3** `.p8` placé dans `~/.appstoreconnect/private_keys/` avec `chmod 600`
- [ ] **2.3** Backup chiffré du `.p8` effectué
- [ ] **2.4** `xcrun notarytool store-credentials "iris-notary" …` exécuté avec succès
- [ ] **2.5** `xcrun notarytool history --keychain-profile "iris-notary"` retourne `Successfully received submission history.`
- [ ] **3.1** Certificat `Developer ID Application` créé via Xcode
- [ ] **3.1** Certificat `Developer ID Installer` créé via Xcode
- [ ] **3.2** `security find-identity` liste les deux identités
- [ ] **3.3** Backup `.p12` `Developer ID Application` (cert + clé privée) effectué
- [ ] **3.3** Backup `.p12` `Developer ID Installer` (cert + clé privée) effectué

Une fois ces 11 cases cochées, la Phase 9 peut démarrer sans blocage administratif.

---

## 6. Référence d'usage (Phase 9, pour mémoire)

Le futur script `packaging/build-pkg.sh` orchestre :

```sh
# 1. Signer les binaires (Mach-O + bundle .app)
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Jean-Paul Gavini (<TEAM_ID>)" \
  --entitlements <path>.entitlements \
  <path-to-binary-or-app>

# 2. Construire le .pkg et le signer avec l'identité Installer
productbuild --component Iris.app /Applications \
  --sign "Developer ID Installer: Jean-Paul Gavini (<TEAM_ID>)" \
  Iris.pkg

# 3. Soumettre à la notarisation (bloquant jusqu'à réponse)
xcrun notarytool submit Iris.pkg \
  --keychain-profile "iris-notary" \
  --wait

# 4. Récupérer le log (à faire même en cas de succès, peut contenir des warnings)
xcrun notarytool log <submission-id> \
  --keychain-profile "iris-notary" \
  notarization-log.json

# 5. Agrafer le ticket dans le .pkg pour usage offline
xcrun stapler staple Iris.pkg

# 6. Vérification finale
spctl --assess --type install --verbose Iris.pkg
# Attendu : "Iris.pkg: accepted source=Notarized Developer ID"
```

⚠️ Hardened runtime (`--options runtime`) et timestamp (`--timestamp`) sont **requis** pour passer la notarisation. Tout binaire non signé hardened runtime sera rejeté.

---

## 7. Liens utiles

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Developer ID certificates — Apple Developer help](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
