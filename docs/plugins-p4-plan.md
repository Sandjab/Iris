# Plugins P4 — UI « Plugins » Section — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Plugins" section to the Settings window (sidebar `NavigationSplitView`, next to General/Certificate/Integration/Advanced) so a user can, without the CLI: see installed plugins and their state, install from a directory, enable (with explicit capability consent), disable, remove (confirmed), inspect declared capabilities + TOFU provenance/hash, and reorder the hook chain.

**No new backend.** All seven `plugin.*` RPCs already exist and are proven end-to-end (CLI smoke 10/10, PR #81). P4 is **100% client-side**: extend the `AdminCalling` seam, implement it on `AdminClient`, add `AppModel` plugin state + actions, build the SwiftUI section, wire one sidebar `Pane`. The UI calls the exact same RPCs as `Sources/iris/Commands/PluginCommands.swift`.

**Architecture:** Mirror the existing Secrets/Rules pattern. `AppModel` (a `@MainActor` `ObservableObject` in `IrisAppCore`, `-strict-concurrency=complete`) gains `@Published var plugins: [Plugin]` plus `refreshPlugins` + one method per mutation (each re-fetches the list — no optimistic update, SPECS §15.4). The view layer lives in the `IrisApp` Xcode target (NOT strict-concurrency, NOT `@MainActor`) and is verified by `xcodebuild` + visual smoke, since the `.app` target has no unit tests. The testable surface (protocol conformance shape, `AppModel` logic) is driven by TDD against `FakeAdminCalling`.

**Tech Stack:** Swift 5.9+, SwiftPM (IrisAppCore), Xcode project (IrisApp), SwiftUI + AppKit (`NSOpenPanel` for the directory picker), XCTest.

---

## Key backend facts (verified against live source, do not re-derive)

- `Plugin` (IrisKit, public): `manifest`, `enabled`, `order`, `approvedCapabilities: PluginCapabilities?`, `pinnedHash`, `hashMatches`. Wire keys are snake_case. **`displayState` is computed client-side** (not on the wire) — reuse it.
- `Plugin.DisplayState` has exactly **three** cases: `.disabled`, `.enabled`, `.needsReapproval` (hash changed since pin). **There is no `.failed` runtime state** exposed via RPC — the handoff memo's "échec" wording is stale; live source wins. An auto-disabled crash-looping plugin (P2b) surfaces as `enabled=false` → `.disabled`.
- `PluginCapabilities`: `network: [String]` (host:port egress), `filesystem: [String]` (e.g. `["scratch"]`).
- The **declared** caps to show in the consent sheet are `plugin.manifest.capabilities` (what the plugin asks for). `approvedCapabilities` is what was granted at the last enable. `list` already returns the full `Plugin` incl. manifest, so **no `pluginInfo` RPC is needed** in the UI.
- `enable` (PluginRegistry.swift:238): re-pins hash + re-approves `manifest.capabilities`, but **rejects a changed hash** with `pluginHashMismatch` (-32032). ⟹ a `.needsReapproval` plugin **cannot** be enabled; the only path back is reinstalling from source (which re-pins). v1 UI: show the state + disable the Enable button; resolution is the normal Install flow.
- RPC mapping (from `PluginCommands.swift`, the reference impl):
  - `pluginList` → `[Plugin]`
  - `pluginInstall` + `PluginInstallParams(path:)` → `Plugin` (installed **disabled**, no approved caps)
  - `pluginEnable` + `PluginIdParams(id:)` → `Plugin`
  - `pluginDisable` + `PluginIdParams(id:)` → `Plugin`
  - `pluginRemove` + `PluginIdParams(id:)` → `PluginRemovedResult` (daemon throws `unknownPlugin` rather than `removed:false`)
  - `pluginReorder` + `PluginReorderParams(id:index:)` → `[Plugin]`
- Error codes: `JSONRPCError.pluginUnknown` (-32030 region), `.pluginHashMismatch` (-32032), `.unsafeSource` (-32035). The UI surfaces these as inline error text.

---

## Decisions (locked with user 2026-06-21)

- **Capability consent at enable:** clicking *Enable* opens a **consent sheet** listing the plugin's declared `manifest.capabilities` (network endpoints, filesystem scopes), with an **Approve & Enable** button. If the plugin declares **no** capabilities, the sheet states "No capabilities requested — strict deny-all sandbox" and the same button enables it (uniform, explicit consent — faithful to deny-by-default §7.2).
- **Reorder mechanism:** per-row **up/down buttons** calling `plugin.reorder(id, index)`. Deterministic, robust, smoke-testable; the chain is short. (Not drag-and-drop.)
- **`needsReapproval`:** **display only** in v1 (badge "Content changed — reinstall to re-approve", Enable disabled). No in-UI re-pin flow.
- **After install:** plugin stays **disabled** (CLI parity); the user then explicitly enables (and consents to caps).

---

## Scope

**In scope (P4):**
- `AdminCalling` protocol: 6 plugin methods (`listPlugins`, `installPlugin(path:)`, `enablePlugin(id:)`, `disablePlugin(id:)`, `removePlugin(id:)`, `reorderPlugin(id:index:)`).
- `AdminClient` conformance in `IrisKitConformances.swift`.
- `FakeAdminCalling` extension (stubbed plugin store + call recording).
- `AppModel`: `@Published var plugins` + `refreshPlugins` + 5 mutating actions (each re-fetches).
- `AppModelPluginsTests` (TDD): refresh sorts by `order`; each mutation hits the right RPC then re-fetches; errors propagate; value-free (no secret/payload surface — N/A here but assert no leak channel introduced).
- `PluginsSettingsView` (+ row + consent sheet) in IrisApp; `Pane.plugins` wired into `SettingsWindow`.
- Visual smoke checklist in the PR.

**Out of scope (deferred):**
- Schema-driven config forms (D6, later phase).
- `onResponse`/`onComplete` UI.
- In-UI re-approval of a changed plugin (reinstall covers it).
- Any backend change — if a backend gap appears, STOP and surface it (no silent scope widening).

---

## File Structure

**New files:**
- `IrisApp/IrisApp/PluginsSettingsView.swift` — section view, `PluginRow`, consent sheet.
- `Tests/IrisAppCoreTests/AppModelPluginsTests.swift` — TDD for AppModel plugin logic.

**Modified files:**
- `Sources/IrisAppCore/Protocols/AdminCalling.swift` — +6 method signatures.
- `Sources/IrisAppCore/Protocols/IrisKitConformances.swift` — +6 `AdminClient` impls.
- `Sources/IrisAppCore/AppModel.swift` — `@Published var plugins` + refresh/actions.
- `Tests/IrisAppCoreTests/Mocks/FakeAdminCalling.swift` — +6 stubs.
- `IrisApp/IrisApp/SettingsWindow.swift` — `Pane.plugins` (title "Plugins", symbol `puzzlepiece.extension`) + `detail(for:)` case.

The IrisApp target is a `PBXFileSystemSynchronizedRootGroup` — adding `PluginsSettingsView.swift` needs **no** pbxproj edit.

---

## Tasks

### Task 1 — `AdminCalling` seam + `AdminClient` conformance + mock (IrisAppCore)

- [ ] Add 6 method signatures to `AdminCalling` (doc-commented, mirroring secret/rule entries):
      `listPlugins() async throws -> [Plugin]`, `installPlugin(path: String) async throws -> Plugin`,
      `enablePlugin(id: String) async throws -> Plugin`, `disablePlugin(id: String) async throws -> Plugin`,
      `removePlugin(id: String) async throws`, `reorderPlugin(id: String, index: Int) async throws -> [Plugin]`.
- [ ] Implement each on `extension AdminClient: AdminCalling` using the params/return types above
      (copy the call shapes from `PluginCommands.swift`).
- [ ] Extend `FakeAdminCalling`: `var stubPlugins: [Plugin] = []`, record calls (`"listPlugins"`,
      `"installPlugin(\(path))"`, `"enablePlugin(\(id))"`, …), mutate `stubPlugins` so re-fetch reflects the action
      (install appends a disabled plugin; enable flips `enabled`/sets approvedCapabilities; disable flips off;
      remove drops it; reorder renumbers). Honour `shouldThrow`.
- [ ] **Verify:** `swift build` + `swift test` (existing suite green; conformance compiles).

### Task 2 — `AppModel` plugin state + actions (IrisAppCore, TDD)

- [ ] **RED:** write `AppModelPluginsTests` first:
      - `refreshPlugins` sorts by `order` ascending.
      - `installPlugin(path:)` calls `installPlugin` then `refreshPlugins` (calls == `["installPlugin(...)","listPlugins"]`).
      - `enablePlugin`/`disablePlugin`/`removePlugin`/`reorderPlugin` each call their RPC then `listPlugins`.
      - a thrown error propagates and leaves `plugins` unchanged.
- [ ] **GREEN:** add to `AppModel`: `@Published public var plugins: [Plugin] = []`,
      `refreshPlugins(via:)` (sorted by `order`), and `installPlugin(path:via:)` / `enablePlugin(id:via:)` /
      `disablePlugin(id:via:)` / `removePlugin(id:via:)` / `reorderPlugin(id:index:via:)` — each `_ = try await admin.…`
      then `try await refreshPlugins(via: admin)` (mirror `deleteSecret`).
- [ ] **Verify:** `swift test` green (new tests pass, zero regressions); `swift-format lint --strict … ` exit 0.

### Task 3 — `PluginsSettingsView` + sidebar wiring (IrisApp)

- [ ] `Pane.plugins` in `SettingsWindow` (between `.advanced` and the `.uninstall` Section; title "Plugins",
      symbol `puzzlepiece.extension`); add the `detail(for:)` case → `PluginsSettingsView(admin: admin)`.
- [ ] `PluginsSettingsView`: header with an **Install…** button (`NSOpenPanel`, `canChooseDirectories=true`,
      `canChooseFiles=false`, single selection → `model.installPlugin(path: url.path, via: admin)`); inline error text;
      `GuidedEmptyState` (symbol `puzzlepiece.extension`, "No plugins yet") when empty; else a `List` of `PluginRow`
      sorted by `order`; `.task { await refresh() }`.
- [ ] `PluginRow`: name + version; **state badge** (enabled=green, disabled=secondary, needsReapproval=red
      "Content changed — reinstall to re-approve"); hash chip (`ok` / `CHANGED`); declared capability chips
      (network/filesystem, "none" if empty); buttons — **↑/↓** (reorder; disabled at ends), **Enable** (opens consent
      sheet; hidden when enabled; disabled when `.needsReapproval`), **Disable** (when enabled), **Remove** (destructive
      → `confirmationDialog`).
- [ ] Consent sheet (`.sheet`): title "Enable \(id)?", lists declared `manifest.capabilities` (or the deny-all line),
      a short note that the plugin runs sandboxed and never sees real secret values (§3), **Cancel** / **Approve & Enable**
      (→ `model.enablePlugin(id:via:)`). Surface `pluginHashMismatch` as an inline error if it races.
- [ ] **Verify:** `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp build` succeeds (CI macos-15 is the
      final judge). Each `NSMenuItem`/multi-arg call obeys `.swift-format` (1 arg/line where required).

### Task 4 — Holistic review + full verification + PR

- [ ] Holistic subagent review (feature-dev:code-reviewer) over the whole diff — focus on the IrisAppCore↔IrisApp seam,
      consent-sheet correctness (caps shown == caps approved), error surfacing, and that no secret/payload channel is added.
- [ ] `swift build` + `swift test` + `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp` (exit 0)
      + `xcodebuild … IrisApp build`.
- [ ] Open PR with the smoke checklist below; wait for Gemini (one round, CLAUDE.md §8); apply/refuse factually; merge on
      explicit user confirmation (squash).

---

## Smoke checklist (PR body)

Against a daemon with a test plugin installed (CLI to set up, UI to drive — or fully via the Settings window):

- [ ] Settings → **Plugins** appears in the sidebar; empty state shows when no plugins.
- [ ] **Install…** picks a directory; the plugin appears as **disabled** with its version, hash `ok`, and declared caps.
- [ ] **Enable** opens the consent sheet listing the declared capabilities (or the deny-all line); **Approve & Enable**
      flips it to **enabled**; **Cancel** leaves it disabled.
- [ ] **Disable** returns it to disabled.
- [ ] **↑/↓** reorders the chain; order persists after a Reload / reopen.
- [ ] **Remove** asks for confirmation; after confirm the plugin is gone from the list and its directory is deleted.
- [ ] Tampering with an installed plugin's files (then reopening) shows **CHANGED / needs re-approval**, with Enable disabled.
- [ ] Light + dark mode both render correctly.

---

## Verification gates (Goal-Driven Execution)

- `swift build` clean.
- `swift test` — full suite green, new `AppModelPluginsTests` included, zero regressions.
- `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp` — exit 0.
- `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp build` — succeeds locally; **CI macos-15 build-test + xcode-build both green** is the binding gate.
- Holistic review: 0 blockers (or all fixed).
- Visual smoke 8/8 (above).
