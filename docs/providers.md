# Providers courants — presets de secrets IRIS

Référence des fournisseurs d'API fréquemment utilisés, à pré-définir dans IRIS :
le **nom de secret** (`{{kc:NAME}}`) et ses **`allowed_hosts`** (scoping).

> Liste non exhaustive. En cas de doute sur un host, voir [Confirmer le host exact](#confirmer-le-host-exact).

## Règle de compatibilité

Un provider n'est substituable par IRIS que si **la clé voyage dans un header HTTP**
vers un host **MITM-able** :

- ✅ clé en header (`Authorization: Bearer …`, `x-api-key`, etc.) ;
- ✅ host en HTTP/1.1 (pas de gRPC / h2 obligatoire), sans cert-pinning ;
- ❌ clé en **query string** (`?key=`, `?api_key=`) ou en **body JSON** → bloquée + alertée (substitution *headers-only*, fail-closed) ;
- ❌ signature dérivée de la clé (AWS **SigV4**, JWT GCP service-account…) → hors modèle.

## Utilisation

Le nom de secret est libre ; par convention = la variable d'env en minuscules.

```sh
# 1. enregistrer la valeur réelle (jamais en clair dans un fichier/historique)
printf %s "$KEY" | iris secret add openai_api_key --value-from-stdin --allowed-hosts api.openai.com

# 2. câbler le placeholder dans l'environnement (ou un fichier de config)
export OPENAI_API_KEY={{kc:openai_api_key}}
```

---

## LLM / inférence

| Provider | Variable d'env | Secret IRIS | `allowed_hosts` | Clé dans |
|---|---|---|---|---|
| OpenAI | `OPENAI_API_KEY` | `openai_api_key` | `api.openai.com` | header `Authorization` |
| Anthropic | `ANTHROPIC_API_KEY` | `anthropic_api_key` | `api.anthropic.com` | header `x-api-key` |
| OpenRouter | `OPENROUTER_API_KEY` | `openrouter_api_key` | `openrouter.ai` | header `Authorization` |
| Google Gemini (AI Studio) | `GEMINI_API_KEY` (ou `GOOGLE_API_KEY`) | `gemini_api_key` | `generativelanguage.googleapis.com` | header `x-goog-api-key` ⚠️ **pas** `?key=` |
| Groq | `GROQ_API_KEY` | `groq_api_key` | `api.groq.com` | header `Authorization` |
| Mistral | `MISTRAL_API_KEY` | `mistral_api_key` | `api.mistral.ai` | header `Authorization` |
| DeepSeek | `DEEPSEEK_API_KEY` | `deepseek_api_key` | `api.deepseek.com` | header `Authorization` |
| xAI (Grok) | `XAI_API_KEY` | `xai_api_key` | `api.x.ai` | header `Authorization` |
| Perplexity | `PERPLEXITY_API_KEY` | `perplexity_api_key` | `api.perplexity.ai` | header `Authorization` |
| Together | `TOGETHER_API_KEY` | `together_api_key` | `api.together.xyz` (alias `.ai`) | header `Authorization` |
| Fireworks | `FIREWORKS_API_KEY` | `fireworks_api_key` | `api.fireworks.ai` | header `Authorization` |
| Cohere | `COHERE_API_KEY` | `cohere_api_key` | `api.cohere.com` | header `Authorization` |
| Replicate | `REPLICATE_API_TOKEN` | `replicate_api_token` | `api.replicate.com` | header `Authorization` |
| Hugging Face | `HF_TOKEN` | `hf_token` | `huggingface.co`, `api-inference.huggingface.co` | header `Authorization` |
| Azure OpenAI | `AZURE_OPENAI_API_KEY` | `azure_openai_api_key` | `<ta-ressource>.openai.azure.com` | header `api-key` |

## Embeddings / recherche / voix (souvent via MCP)

| Provider | Variable d'env | Secret IRIS | `allowed_hosts` | Clé dans |
|---|---|---|---|---|
| Voyage AI | `VOYAGE_API_KEY` | `voyage_api_key` | `api.voyageai.com` | header `Authorization` |
| Brave Search | `BRAVE_API_KEY` | `brave_api_key` | `api.search.brave.com` | header `X-Subscription-Token` |
| ElevenLabs | `ELEVENLABS_API_KEY` | `elevenlabs_api_key` | `api.elevenlabs.io` | header `xi-api-key` |
| Tavily | `TAVILY_API_KEY` | `tavily_api_key` | `api.tavily.com` | ⚠️ historiquement dans le **body** — OK seulement si l'outil envoie le header `Authorization` |

## Code hosting & registries

| Provider | Variable d'env | Secret IRIS | `allowed_hosts` | Clé dans |
|---|---|---|---|---|
| GitHub (API / `gh`) | `GITHUB_TOKEN` / `GH_TOKEN` | `github_token` | `api.github.com` (+ `github.com` pour git push HTTPS) | header `Authorization` |
| GitLab | `GITLAB_TOKEN` | `gitlab_token` | `gitlab.com` | header `PRIVATE-TOKEN` / `Authorization` |
| npm | `NPM_TOKEN` | `npm_token` | `registry.npmjs.org` | header `Authorization` |
| PyPI (twine) | `TWINE_PASSWORD` | `pypi_token` | `upload.pypi.org` | header `Authorization` |

## ⛔ Incompatibles (à ne pas pré-définir)

- **AWS** (Bedrock, S3…) : signature **SigV4** dérivée de la clé → hors modèle (facteur F3).
- **GCP Vertex AI via SDK gRPC** : **h2 obligatoire** → hors modèle (facteur F2). *(Gemini AI Studio REST ci-dessus = OK.)*
- Tout provider qui transmet la clé en **query string** ou en **body JSON** → bloqué + alerté (`nonCanonicalLocation`).

## Confirmer le host exact

Pour fixer un `allowed_hosts` sans deviner : ajoute le secret, lance l'outil **une fois**,
puis regarde le host réellement contacté.

```sh
iris logs --follow
# le host apparaît à chaque requête ; un exfilBlocked signale une clé
# partant vers un host non scopé ou ailleurs que dans un header.
```

C'est la source de vérité, en particulier pour les hosts à variantes
(Cohere `.com`/`.ai`, Together `.xyz`/`.ai`) ou les endpoints par-ressource (Azure).
