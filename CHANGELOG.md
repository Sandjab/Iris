# Changelog

All notable changes to IRIS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-06-14

### Added
- **About window** — a dedicated "About Iris" window now shows the version and
  these release notes in a scrollable view, instead of the standard macOS panel.
- **"Bust" menu-bar icon set** — a winged-head glyph as an alternative to the key,
  selectable in Settings › Appearance (bust is the new default).
- **Dedicated Settings window** with a sidebar (General / Certificate / Integration
  / Advanced), replacing the cramped inline tab.
- **Menu-bar icon menu** (About / Settings… / Quit) and a **Freeze** control.
- The **menu-bar icon shape reflects the daemon state** (active / paused / stopped
  / connecting), legible on light and dark menu bars.
- The daemon's **paused state now propagates to the UI** (`iris pause` from the CLI
  updates the icon and panel).

### Changed
- Compact redesign of the monitoring panel content.
- Internal simplification (deduplicated proxy / IPC / CLI code paths).
- Documentation and the user manual updated and published on GitHub Pages.

### Fixed
- `daemon.status` is now decoded even when the `paused` field is absent
  (backward compatibility with older daemons).

## [1.0.0] - 2026-06-10

### Added
- First stable release. The 1.0 API, configuration formats, and behavior are stable.
- Local credential broker for macOS: a MITM proxy substitutes `{{kc:NAME}}`
  placeholders with real values from the Keychain before forwarding requests.
- `irisd` daemon (LaunchAgent via SMAppService), `iris` CLI, and the `Iris.app`
  menu-bar app.
- Host-scoped secrets, exfiltration rules, signed `.pkg` installer, and a guided
  uninstall flow.
