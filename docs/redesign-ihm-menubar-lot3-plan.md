# IHM Lot 3 — refonte du contenu du panneau — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Densifier et hiérarchiser le contenu du panneau menu-bar `Iris.app` (5 onglets) : Overview rempli (V1=C) avec compteurs pondérés (V6=B) + sparkline, lignes Logs enrichies (V4), symbole d'état à forme (R4), empty states guidés (V5), microcopy harmonisée.

**Architecture:** La **logique pure** (bucketing sparkline, mapping symbole d'état, résumé alertes, libellés de politique) vit dans `IrisAppCore` (cible SPM en `-strict-concurrency=complete`, testée en XCTest). Les **vues** vivent dans la cible app `IrisApp` (SwiftUI, non `@MainActor`, non testée unitairement → vérifiée par `xcodebuild build` + smoke visuel). Cette séparation suit le découpage existant (`IrisAppCore/Models/LogFilters.swift` testé dans `Tests/IrisAppCoreTests/Models/`).

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, XCTest, SwiftPM + Xcode (cible app).

**Conventions rappel :**
- IHM **en anglais** (cf. spec §1). Pas de force-unwrap hors tests (CLAUDE §5). `swift-format` avant chaque commit (1 argument/ligne sur les constructions multi-args).
- Cible Xcode `IrisApp` = `PBXFileSystemSynchronizedRootGroup` → ajouter un `.swift` n'exige **aucune** édition `.pbxproj`.
- Oracle de compilation = `swift build`/`swift test` (SPM) + `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp build` (app). **SourceKit retarde** sur le compilateur → ne pas se fier à l'éditeur, lancer le build.
- Spec de référence : [`redesign-ihm-menubar-lot3.md`](redesign-ihm-menubar-lot3.md).

---

## Task 1: `ActivitySeries` — bucketing de la sparkline (logique pure)

**Files:**
- Create: `Sources/IrisAppCore/Models/ActivitySeries.swift`
- Test: `Tests/IrisAppCoreTests/Models/ActivitySeriesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IrisAppCoreTests/Models/ActivitySeriesTests.swift
import IrisKit
import XCTest

@testable import IrisAppCore

final class ActivitySeriesTests: XCTestCase {
    private func event(at offset: TimeInterval) -> Event {
        Event(timestamp: Date(timeIntervalSince1970: offset), kind: .passThrough, host: "h", method: "GET", path: "/")
    }

    // WHY: no data → the view must hide the sparkline entirely, not draw an empty axis.
    func test_emptyEvents_returnsEmpty() {
        XCTAssertEqual(ActivitySeries.buckets(from: [], count: 12), [])
    }

    // WHY: defensive — a non-positive bucket count is a programming error, never a crash.
    func test_nonPositiveCount_returnsEmpty() {
        XCTAssertEqual(ActivitySeries.buckets(from: [event(at: 0)], count: 0), [])
    }

    // WHY: simultaneous events (zero time span) must not divide by zero; recency lands in the last bin.
    func test_simultaneousEvents_collapseToLastBucket() {
        let evts = [event(at: 5), event(at: 5), event(at: 5)]
        XCTAssertEqual(ActivitySeries.buckets(from: evts, count: 4), [0, 0, 0, 3])
    }

    // WHY: the sparkline must reflect *temporal distribution*, not just a total (its whole purpose).
    func test_eventsDistributeAcrossBucketsByTime() {
        let evts = [event(at: 0), event(at: 1), event(at: 2), event(at: 3)]
        XCTAssertEqual(ActivitySeries.buckets(from: evts, count: 4), [1, 1, 1, 1])
    }

    // WHY: no event may be silently dropped — sum of bins always equals the input count.
    func test_totalCountPreserved() {
        let evts = (0..<10).map { event(at: TimeInterval($0)) }
        XCTAssertEqual(ActivitySeries.buckets(from: evts, count: 5).reduce(0, +), 10)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ActivitySeriesTests`
Expected: FAIL — `cannot find 'ActivitySeries' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/IrisAppCore/Models/ActivitySeries.swift
import Foundation
import IrisKit

/// Buckets recent events into a fixed number of equal-width time bins for the
/// Overview sparkline. Pure, deterministic — covers only the in-memory events
/// window (labelled "recent" in the UI), not the daemon lifetime.
public enum ActivitySeries {
    /// Per-bin event counts over `[minTimestamp, maxTimestamp]` split into `count`
    /// equal time intervals. Empty input or non-positive `count` → `[]`.
    /// Zero span (all simultaneous) → all events in the last bin.
    public static func buckets(from events: [Event], count: Int) -> [Int] {
        let times = events.map { $0.timestamp.timeIntervalSince1970 }
        guard count > 0, let lo = times.min(), let hi = times.max() else { return [] }
        var bins = Array(repeating: 0, count: count)
        let span = hi - lo
        guard span > 0 else {
            bins[count - 1] = events.count
            return bins
        }
        for t in times {
            var idx = Int((t - lo) / span * Double(count))
            if idx >= count { idx = count - 1 }
            if idx < 0 { idx = 0 }
            bins[idx] += 1
        }
        return bins
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ActivitySeriesTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Format & commit**

```bash
swift-format format -i Sources/IrisAppCore/Models/ActivitySeries.swift Tests/IrisAppCoreTests/Models/ActivitySeriesTests.swift
git add Sources/IrisAppCore/Models/ActivitySeries.swift Tests/IrisAppCoreTests/Models/ActivitySeriesTests.swift
git commit -m "feat(ihm): ActivitySeries bucketing for Overview sparkline (V1/V6)"
```

---

## Task 2: `statusGlyph` — symbole d'état à forme (R4, logique pure)

**Files:**
- Create: `Sources/IrisAppCore/Models/StatusPresentation.swift`
- Test: `Tests/IrisAppCoreTests/Models/StatusPresentationTests.swift`

Note : `DaemonStatus` est défini dans `IrisAppCore` (`Sources/IrisAppCore/Models/DaemonStatus.swift`), cas `.up(DaemonStats, TimeInterval, Bool)` / `.down(DownReason)` / `.connecting`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IrisAppCoreTests/Models/StatusPresentationTests.swift
import IrisKit
import XCTest

@testable import IrisAppCore

final class StatusPresentationTests: XCTestCase {
    // WHY: R4's whole point — state must be distinguishable by SHAPE, not colour alone
    // (colour-blind safety). If two states ever share a symbol, this test fails.
    func test_allStatesUseDistinctSymbols() {
        let symbols = [
            statusGlyph(for: .up(.zero, 0, false)).symbolName,
            statusGlyph(for: .up(.zero, 0, true)).symbolName,
            statusGlyph(for: .down(.notRunning)).symbolName,
            statusGlyph(for: .connecting).symbolName,
        ]
        XCTAssertEqual(Set(symbols).count, 4, "each daemon state must have its own glyph shape")
    }

    func test_pausedMapsToPauseGlyph() {
        let g = statusGlyph(for: .up(.zero, 0, true))
        XCTAssertEqual(g.symbolName, "pause.circle.fill")
        XCTAssertEqual(g.tint, .paused)
    }

    func test_runningMapsToUpTint() {
        XCTAssertEqual(statusGlyph(for: .up(.zero, 0, false)).tint, .up)
    }

    func test_downMapsToDownTint() {
        XCTAssertEqual(statusGlyph(for: .down(.notRunning)).tint, .down)
    }
}
```

> Si l'init de `DownReason.notRunning` ou de `DaemonStats.zero` diffère, ajuste l'appel — vérifie `Sources/IrisAppCore/Models/DaemonStatus.swift` et `DaemonStats.zero` (`AdminProtocol.swift:174`).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StatusPresentationTests`
Expected: FAIL — `cannot find 'statusGlyph' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/IrisAppCore/Models/StatusPresentation.swift
import Foundation

/// Semantic tint for the daemon-state glyph. Mapped to a concrete SwiftUI colour
/// in the view layer (keeps SwiftUI out of the testable core).
public enum StatusTint: Sendable, Equatable {
    case up, paused, down, connecting
}

/// An SF Symbol whose SHAPE (not only colour) encodes the daemon state — fixes the
/// colour-only `StatusDot` (R4) and stays legible for colour-blind users.
public struct StatusGlyph: Sendable, Equatable {
    public let symbolName: String
    public let tint: StatusTint
}

public func statusGlyph(for status: DaemonStatus) -> StatusGlyph {
    switch status {
    case .up(_, _, let paused):
        return paused
            ? StatusGlyph(symbolName: "pause.circle.fill", tint: .paused)
            : StatusGlyph(symbolName: "checkmark.circle.fill", tint: .up)
    case .down:
        return StatusGlyph(symbolName: "exclamationmark.triangle.fill", tint: .down)
    case .connecting:
        return StatusGlyph(symbolName: "circle.dotted", tint: .connecting)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StatusPresentationTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Format & commit**

```bash
swift-format format -i Sources/IrisAppCore/Models/StatusPresentation.swift Tests/IrisAppCoreTests/Models/StatusPresentationTests.swift
git add Sources/IrisAppCore/Models/StatusPresentation.swift Tests/IrisAppCoreTests/Models/StatusPresentationTests.swift
git commit -m "feat(ihm): statusGlyph shape-coded daemon state (R4)"
```

---

## Task 3: HeaderBar — remplacer `StatusDot` par le glyph à forme (R4, vue)

**Files:**
- Modify: `IrisApp/IrisApp/BrokerPanelView.swift:81-111` (HeaderBar + StatusDot)

- [ ] **Step 1: Remplacer `StatusDot` dans le HeaderBar**

Dans `HeaderBar.body`, remplacer la ligne `StatusDot(status: model.daemonStatus)` (`:82`) par `StatusIndicator(status: model.daemonStatus)` (la vue redéfinie ci-dessous ; nommée `StatusIndicator` pour ne pas entrer en collision avec le type `StatusGlyph` d'`IrisAppCore`). Puis remplacer **tout** le `private struct StatusDot` (`:97-111`) par :

```swift
private struct StatusIndicator: View {
    let status: IrisAppCore.DaemonStatus

    var body: some View {
        let glyph = statusGlyph(for: status)
        Image(systemName: glyph.symbolName)
            .font(.callout)
            .foregroundStyle(color(for: glyph.tint))
            .accessibilityLabel(Text(label(for: glyph.tint)))
    }

    private func label(for tint: StatusTint) -> String {
        switch tint {
        case .up: return "Daemon up"
        case .paused: return "Daemon paused"
        case .down: return "Daemon down"
        case .connecting: return "Daemon connecting"
        }
    }

    private func color(for tint: StatusTint) -> Color {
        switch tint {
        case .up: return .green
        case .paused: return .orange
        case .down: return .red
        case .connecting: return .secondary
        }
    }
}
```

> `StatusTint` ne conforme pas `CustomStringConvertible` → si `"Daemon \(glyph.tint)"` ne compile pas, remplace par un `switch` qui renvoie un mot ("up"/"paused"/"down"/"connecting"). Garde l'`accessibilityLabel` non vide.

- [ ] **Step 2: Build the app target**

Run: `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (Si `checkmark.circle.fill` / `pause.circle.fill` / `exclamationmark.triangle.fill` / `circle.dotted` ne rendaient pas au smoke, swappe via l'app SF Symbols — tous standard macOS 11-12+.)

- [ ] **Step 3: Commit**

```bash
swift-format format -i IrisApp/IrisApp/BrokerPanelView.swift
git add IrisApp/IrisApp/BrokerPanelView.swift
git commit -m "feat(ihm): header state glyph by shape, drop colour-only dot (R4)"
```

---

## Task 4: OverviewTab — compteurs pondérés (V6=B) + sparkline + plus d'events (V1=C)

**Files:**
- Modify: `IrisApp/IrisApp/OverviewTab.swift`

- [ ] **Step 1: Compteurs pondérés (V6=B)**

Remplacer `countersSection` (`:19-30`) et `counter(label:value:)` (`:37-42`) par une version pondérée — volume atténué, incidents proéminents :

```swift
@ViewBuilder private var countersSection: some View {
    let stats = currentStats()
    VStack(alignment: .leading, spacing: 4) {
        Text("Since daemon start").font(.headline)
        HStack(spacing: 20) {
            counter(label: "Requests", value: stats.reqTotal, style: .volume)
            counter(label: "Substituted", value: stats.subTotal, style: .volume)
            counter(label: "Blocked", value: stats.exfilBlockedTotal, style: .incident(.red))
            counter(label: "Errors", value: stats.errorsTotal, style: .incident(.orange))
        }
    }
}

private enum CounterStyle {
    case volume
    case incident(Color)
}

private func counter(label: String, value: UInt64, style: CounterStyle) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        switch style {
        case .volume:
            Text("\(value)").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        case .incident(let color):
            Text("\(value)").font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption.weight(.medium))
        }
    }
}
```

- [ ] **Step 2: Bloc sparkline (V1=C)**

Insérer, dans `body` entre `countersSection`/`Divider()` et `recentSection` (`:10-14`), un appel `activitySection`, et ajouter la vue. La série vient de `ActivitySeries` (Task 1) ; le bloc se **masque** si vide :

```swift
@ViewBuilder private var activitySection: some View {
    let series = ActivitySeries.buckets(from: model.events, count: 12)
    if !series.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity (recent)").font(.headline)
            Sparkline(values: series)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct Sparkline: View {
    let values: [Int]

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor.opacity(0.45))
                        .frame(height: max(1, geo.size.height * CGFloat(v) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
```

Mettre à jour `body` :

```swift
var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            countersSection
            activitySection
            Divider()
            recentSection
        }
        .padding(12)
    }
}
```

- [ ] **Step 3: Plus d'events récents (V1=C)**

Dans `recentSection` (`:50`), remplacer `model.events.prefix(5)` par `model.events.prefix(8)`.

- [ ] **Step 4: Build the app target**

Run: `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
swift-format format -i IrisApp/IrisApp/OverviewTab.swift
git add IrisApp/IrisApp/OverviewTab.swift
git commit -m "feat(ihm): densify Overview — weighted counters + activity sparkline (V1/V6)"
```

---

## Task 5: LogsTab — ligne enrichie `LogEventRow` (V4)

**Files:**
- Create: `IrisApp/IrisApp/LogEventRow.swift`
- Modify: `IrisApp/IrisApp/LogsTab.swift:63-68` (le `List` utilise `LogEventRow` au lieu de `EventRow`)

> `EventRow` (dans `OverviewTab.swift`) reste **inchangé** : il sert encore l'Overview (ligne compacte). On introduit une ligne dédiée pour le contexte dense des Logs.

- [ ] **Step 1: Créer `LogEventRow`**

```swift
// IrisApp/IrisApp/LogEventRow.swift
import IrisKit
import SwiftUI

/// Dense Logs row (V4): a leading colour accent encodes the event kind by position
/// (not a repeated loud pill), and the row surfaces method / status / duration —
/// fields already on `Event` but never shown. Never renders secret values
/// (`substitutedSecrets` are names; we don't display them here).
struct LogEventRow: View {
    let event: Event

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
            Text(timeString(event.timestamp))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(event.method)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .leading)
            Text(event.host).font(.callout).fontWeight(.medium)
            Text(event.path).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if let code = event.statusCode {
                Text("\(code)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(statusColor(code))
            }
            if let ms = event.durationMs {
                Text("\(ms)ms")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var accent: Color {
        switch event.kind {
        case .substituted: return .green
        case .passThrough, .noMatch: return .gray.opacity(0.4)
        case .exfilBlocked, .systemAlert: return .red
        case .error: return .orange
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<400: return .green
        case 400..<600: return .red
        default: return .secondary
        }
    }

    private func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
```

- [ ] **Step 2: Brancher dans `LogsTab`**

Dans `LogsTab.list` (`:63-68`), remplacer `EventRow(event: event)` par `LogEventRow(event: event)` :

```swift
private var list: some View {
    List(filteredEvents) { event in
        LogEventRow(event: event)
    }
    .listStyle(.plain)
}
```

- [ ] **Step 3: Build the app target**

Run: `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
swift-format format -i IrisApp/IrisApp/LogEventRow.swift IrisApp/IrisApp/LogsTab.swift
git add IrisApp/IrisApp/LogEventRow.swift IrisApp/IrisApp/LogsTab.swift
git commit -m "feat(ihm): enriched Logs rows — kind accent + method/status/duration (V4)"
```

---

## Task 6: `alertsSummary` — résumé d'alertes total+non-lues (V5, logique pure)

**Files:**
- Create: `Sources/IrisAppCore/Models/AlertsSummary.swift`
- Test: `Tests/IrisAppCoreTests/Models/AlertsSummaryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IrisAppCoreTests/Models/AlertsSummaryTests.swift
import XCTest

@testable import IrisAppCore

final class AlertsSummaryTests: XCTestCase {
    // WHY: lifts the "0 unread" vs visible-alerts contradiction — the header always shows the TOTAL
    // alongside the unread count, so a list of read alerts no longer reads as "nothing here".
    func test_showsTotalAlongsideUnread() {
        XCTAssertEqual(alertsSummary(total: 3, unread: 0), "3 alerts · 0 unread")
    }

    // WHY: polish — singular must read naturally, not "1 alerts".
    func test_singularPluralization() {
        XCTAssertEqual(alertsSummary(total: 1, unread: 1), "1 alert · 1 unread")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AlertsSummaryTests`
Expected: FAIL — `cannot find 'alertsSummary' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/IrisAppCore/Models/AlertsSummary.swift
import Foundation

/// Security-tab header text. Always pairs the TOTAL with the unread count so a list
/// of (read) alerts never looks empty behind a bare "0 unread" (V5).
public func alertsSummary(total: Int, unread: Int) -> String {
    let noun = total == 1 ? "alert" : "alerts"
    return "\(total) \(noun) · \(unread) unread"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AlertsSummaryTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Format & commit**

```bash
swift-format format -i Sources/IrisAppCore/Models/AlertsSummary.swift Tests/IrisAppCoreTests/Models/AlertsSummaryTests.swift
git add Sources/IrisAppCore/Models/AlertsSummary.swift Tests/IrisAppCoreTests/Models/AlertsSummaryTests.swift
git commit -m "feat(ihm): alertsSummary header text total+unread (V5)"
```

---

## Task 7: Empty states guidés Secrets / Rules / Security + entête Security (V5, vues)

**Files:**
- Create: `IrisApp/IrisApp/GuidedEmptyState.swift` (composant réutilisable)
- Modify: `IrisApp/IrisApp/SecretsTab.swift:52-55`
- Modify: `IrisApp/IrisApp/RulesTab.swift:54-57`
- Modify: `IrisApp/IrisApp/SecurityTab.swift:13-15` (entête) et `:30-33` (empty)

- [ ] **Step 1: Composant réutilisable**

```swift
// IrisApp/IrisApp/GuidedEmptyState.swift
import SwiftUI

/// Guided empty state (V5): icon + title + one-line intent + optional call-to-action,
/// replacing bare "Nothing here." centred labels.
struct GuidedEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Secrets empty state + CTA**

Dans `SecretsTab.listView`, remplacer le bloc `if model.secrets.isEmpty { Spacer(); Text("No secrets.")…; Spacer() }` (`:52-55`) par :

```swift
if model.secrets.isEmpty {
    GuidedEmptyState(
        symbol: "key",
        title: "No secrets yet",
        message: "Add one to substitute your credentials in allowed traffic.",
        actionTitle: "Add secret",
        action: { route = .form(.add) }
    )
} else {
```

- [ ] **Step 3: Rules empty state**

Dans `RulesTab`, remplacer `if model.rules.isEmpty { Spacer(); Text("No rules.")…; Spacer() }` (`:54-57`) par (pas de CTA — le champ d'ajout est déjà en haut de l'onglet) :

```swift
if model.rules.isEmpty {
    GuidedEmptyState(
        symbol: "network",
        title: "No rules yet",
        message: "Add a host above to allow placeholder substitution in its traffic."
    )
} else {
```

- [ ] **Step 4: Security entête + empty state**

Dans `SecurityTab.body`, remplacer le `Text("\(model.unreadAlertCount) unread")…` (`:13-15`) par l'entête résumé (Task 6) :

```swift
Text(alertsSummary(total: model.alerts.count, unread: model.unreadAlertCount))
    .font(.callout)
    .foregroundStyle(model.unreadAlertCount > 0 ? Color.red : Color.secondary)
```

Et remplacer le bloc empty `if model.alerts.isEmpty { Spacer(); Text("No alerts.")…; Spacer() }` (`:30-33`) par :

```swift
if model.alerts.isEmpty {
    GuidedEmptyState(
        symbol: "checkmark.shield",
        title: "No alerts",
        message: "Exfiltration attempts will appear here."
    )
} else {
```

- [ ] **Step 5: Build the app target**

Run: `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
swift-format format -i IrisApp/IrisApp/GuidedEmptyState.swift IrisApp/IrisApp/SecretsTab.swift IrisApp/IrisApp/RulesTab.swift IrisApp/IrisApp/SecurityTab.swift
git add IrisApp/IrisApp/GuidedEmptyState.swift IrisApp/IrisApp/SecretsTab.swift IrisApp/IrisApp/RulesTab.swift IrisApp/IrisApp/SecurityTab.swift
git commit -m "feat(ihm): guided empty states + Security total/unread header (V5)"
```

---

## Task 8: Microcopy — libellés de politique + vocabulaire d'état

**Files:**
- Create: `Sources/IrisAppCore/Models/ExfilAttemptPolicy+Display.swift`
- Test: `Tests/IrisAppCoreTests/Models/ExfilPolicyDisplayTests.swift`
- Modify: `IrisApp/IrisApp/SettingsSections.swift:84`
- Modify: `IrisApp/IrisApp/AppDelegate.swift:200,204` (vocabulaire tooltip)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IrisAppCoreTests/Models/ExfilPolicyDisplayTests.swift
import IrisKit
import XCTest

@testable import IrisAppCore

final class ExfilPolicyDisplayTests: XCTestCase {
    // WHY: snake_case raw values (block_and_notify) leak the wire format into the UI; the user
    // sees human labels while the daemon still receives the unchanged rawValue.
    func test_humanLabels() {
        XCTAssertEqual(displayName(for: .blockOnly), "Block only")
        XCTAssertEqual(displayName(for: .blockAndNotify), "Block & notify")
        XCTAssertEqual(displayName(for: .blockNotifyPause), "Block, notify & pause")
    }

    // WHY: guard against an un-mapped case silently falling back to snake_case.
    func test_everyCaseHasNonRawLabel() {
        for policy in ExfilAttemptPolicy.allCases {
            XCTAssertFalse(displayName(for: policy).contains("_"), "\(policy) still shows raw value")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ExfilPolicyDisplayTests`
Expected: FAIL — `cannot find 'displayName' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/IrisAppCore/Models/ExfilAttemptPolicy+Display.swift
import IrisKit

/// Human-readable label for the exfil policy Picker (Settings window). UI-only —
/// the daemon and CLI keep using `rawValue` (block_only / block_and_notify / …).
public func displayName(for policy: ExfilAttemptPolicy) -> String {
    switch policy {
    case .blockOnly: return "Block only"
    case .blockAndNotify: return "Block & notify"
    case .blockNotifyPause: return "Block, notify & pause"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ExfilPolicyDisplayTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Brancher le Picker**

Dans `SettingsSections.swift:84`, remplacer `Text(policy.rawValue).tag(policy)` par `Text(displayName(for: policy)).tag(policy)`.

- [ ] **Step 6: Harmoniser le vocabulaire d'état du tooltip**

Dans `AppDelegate.updateStatusIcon` : aligner le `label` sur le lexique du header (Up / Paused / Down / Connecting). Remplacer `label = paused ? "paused" : "active"` (`:200`) par `label = paused ? "paused" : "up"`, et `label = "stopped"` (`:204`) par `label = "down"`. (`connecting` inchangé.)

- [ ] **Step 7: Build (SPM + app)**

Run: `swift test --filter ExfilPolicyDisplayTests && xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp build 2>&1 | tail -5`
Expected: tests PASS + `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Format & commit**

```bash
swift-format format -i Sources/IrisAppCore/Models/ExfilAttemptPolicy+Display.swift Tests/IrisAppCoreTests/Models/ExfilPolicyDisplayTests.swift IrisApp/IrisApp/SettingsSections.swift IrisApp/IrisApp/AppDelegate.swift
git add Sources/IrisAppCore/Models/ExfilAttemptPolicy+Display.swift Tests/IrisAppCoreTests/Models/ExfilPolicyDisplayTests.swift IrisApp/IrisApp/SettingsSections.swift IrisApp/IrisApp/AppDelegate.swift
git commit -m "feat(ihm): humanise policy labels + unify state vocabulary (microcopy)"
```

---

## Task 9: Vérification complète + préparation PR

**Files:** aucun (vérification).

- [ ] **Step 1: Full SPM test suite**

Run: `swift build && swift test 2>&1 | tail -15`
Expected: build OK + tous les tests PASS (les ~493 existants + les nouveaux d'`IrisAppCore`). Aucun test skippé.

- [ ] **Step 2: App build propre**

Run: `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp clean build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Lint**

Run: `swift-format lint -r Sources Tests IrisApp 2>&1 | tail -20`
Expected: aucune sortie (ou diff vide).

- [ ] **Step 4: Smoke visuel (manuel, par l'utilisateur)**

Parcourir la checklist §7 de la spec (`redesign-ihm-menubar-lot3.md`) sur l'app prod, clair **et** sombre. Capturer si besoin (cf. méthode mémoire : Screen Recording + `screencapture -x -R`).

- [ ] **Step 5: Pousser la branche + ouvrir la PR**

```bash
git push -u origin feat/ihm-lot-3-panneau-compact
```

Ouvrir la PR vers `main` avec la **checklist de smoke** (§7 de la spec) recopiée en cases `- [ ]` dans la description (CLAUDE §8 — sans cette checklist la PR n'est pas mergeable). Puis suivre le polling Gemini (CLAUDE §8). **Pas de merge sans confirmation explicite de l'utilisateur.**

---

## Self-review (couverture spec)

| Spec | Tâche |
|---|---|
| V1=C densifier Overview | Task 4 (sparkline + plus d'events, fenêtre inchangée) |
| V6=B compteurs pondérés | Task 4 step 1 |
| R4 symbole à forme | Task 2 (logique) + Task 3 (vue) |
| Sparkline (données « recent ») | Task 1 (logique) + Task 4 step 2 (vue) |
| V4 lignes Logs enrichies | Task 5 |
| V5 empty states Secrets/Rules/Security | Task 7 |
| V5 entête Security total+unread | Task 6 (logique) + Task 7 step 4 |
| Microcopy vocabulaire d'état | Task 8 step 6 |
| Microcopy block_and_notify | Task 8 (logique + Picker) |
| V3 | Retiré (spec §6) — aucune tâche, voulu |
| Tests redaction | Couvert : `LogEventRow` ne rend aucune valeur de secret (Task 5 commentaire) ; `RedactionTests` IrisKit existants inchangés |
