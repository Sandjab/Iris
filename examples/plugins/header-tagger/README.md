# header-tagger — IRIS example plugin

A minimal, complete IRIS plugin. It adds an `X-Iris-Plugin: header-tagger` header
to every request IRIS routes to it. Use it as a starting point for your own plugin.

## What it does

The plugin is an `onRequest` mutator. IRIS decides which requests it sees via the
`hooks[].match` block in `plugin.json` (here: `POST` requests to `api.anthropic.com`
under `/v1/`). For each matched request the plugin returns a `modify` action that
overlays the tag header; every other header — including the `{{kc:...}}` credential
placeholder IRIS substitutes afterwards — is preserved.

It requests **no capabilities** (no network, no filesystem) and never sees a
resolved secret: IRIS substitutes credentials only *after* plugins run (security
invariant). The full IPC protocol (NDJSON / JSON-RPC 2.0 over stdio) is documented
in `docs/plugins-design.md §8`; the `Sources/header-tagger/main.swift` here is the
smallest faithful implementation of it — read it as living documentation.

## Build

```bash
swift build -c release
```

This produces `.build/release/header-tagger`, the path referenced by `plugin.json`'s
`executable`.

## Install (requires a running irisd)

```bash
iris plugin install examples/plugins/header-tagger
iris plugin enable org.iris.example.header-tagger
```

The content hash is pinned at install time (TOFU). If you rebuild the binary after
installing, the directory content changes and IRIS marks the plugin
`needs-reapproval`. Re-pinning is **remove then reinstall** (install rejects an
already-installed id — there is no in-place re-pin):

```bash
iris plugin rm org.iris.example.header-tagger
iris plugin install examples/plugins/header-tagger
iris plugin enable org.iris.example.header-tagger
```
