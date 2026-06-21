# header-tagger — IRIS example plugin (P1 fixture)

A minimal example plugin used as an **install fixture** and living documentation.

**P1 status:** inert. The executable is a stub that only prints a "not yet wired"
line to stderr — IRIS does not execute plugins in P1. The real JSON-RPC-over-stdio
`onRequest` handler (which would add an `X-Iris-Plugin` header to matched requests)
lands in P3.

## Build

```bash
swift build -c release
```

This produces `.build/release/header-tagger`, the path referenced by
`plugin.json`'s `executable`.

## Install (requires a running irisd)

```bash
iris plugin install examples/plugins/header-tagger
iris plugin enable org.iris.example.header-tagger
```

Note: the content hash is pinned at install time (TOFU). If you rebuild the
binary after installing, the directory content changes and IRIS marks the
plugin `needs-reapproval` — re-run `install`/`enable` to re-pin.
