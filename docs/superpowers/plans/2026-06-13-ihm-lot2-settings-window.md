# Lot 2 — Fenêtre Réglages dédiée — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extraire la configuration du panneau menu-bar dans une fenêtre Réglages dédiée à sidebar (`NavigationSplitView`), le panneau ne gardant que le monitoring.

**Architecture:** 3 nouveaux fichiers SwiftUI/AppKit dans la cible `IrisApp` (vues de section migrées de `SettingsTab`, racine `NavigationSplitView`, contrôleur `NSWindow`), recâblage de `openSettings`, retrait de l'onglet Settings, suppression de `SettingsTab.swift`. Aucune logique daemon/IPC/modèle nouvelle. Spec : `docs/superpowers/specs/2026-06-13-ihm-lot2-settings-window-design.md`.

**Tech Stack:** Swift, SwiftUI (`NavigationSplitView`, `GroupBox`, `Form`), AppKit (`NSWindow`, `NSHostingController`, `NSWindowController`). Build via `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp`.

> **Note vérification (écart assumé au TDD, identique au Lot 1)** : la cible Xcode `IrisApp` n'a **aucun harnais de tests UI** (les tests SPM couvrent `IrisKit`/`IrisAppCore`). Tester la structure d'une sidebar SwiftUI serait tautologique (anti Rule 9). La vérification est **compilation (`xcodebuild`) + `swift test` SPM inchangé + smoke visuel** (Task 5), conformément au spec §7. Les tâches ne suivent donc pas le cycle TDD test-d'abord ; chaque tâche = écrire le code, builder, lint, committer.

---

## File structure

| Fichier | Rôle | Changement |
|---|---|---|
| `IrisApp/IrisApp/SettingsSections.swift` | 5 vues de section + helpers `SettingSection`/`SettingsPane` | **créé** (migré de `SettingsTab`) |
| `IrisApp/IrisApp/SettingsWindow.swift` | racine `NavigationSplitView` + enum de section + sidebar | **créé** |
| `IrisApp/IrisApp/SettingsWindowController.swift` | hôte `NSWindow` normale activante | **créé** |
| `IrisApp/IrisApp/AppDelegate.swift` | `settingsWindowController` + `openSettings()` | modifié |
| `IrisApp/IrisApp/BrokerPanelView.swift` | retrait onglet `.settings` (→ 5 onglets) | modifié |
| `Sources/IrisAppCore/AppModel.swift` | retrait `.settings` de l'enum `Tab` | modifié |
| `IrisApp/IrisApp/SettingsTab.swift` | onglet Settings | **supprimé** (contenu migré) |

> **Gotcha cible Xcode** : ajouter/supprimer un `.swift` dans `IrisApp/IrisApp/` n'exige **aucune** édition du `.xcodeproj` (groupe `PBXFileSystemSynchronizedRootGroup`).

---

## Task 1 : `SettingsSections.swift` — vues de section migrées

**Files:**
- Create: `IrisApp/IrisApp/SettingsSections.swift`

Migration *design-for-isolation* du `SettingsTab` monolithique : chaque section devient une vue autonome. Le code des corps de `GroupBox` est repris **à l'identique** de `SettingsTab.swift` (logique inchangée) ; seuls l'enrobage (struct + état local + actions) change.

- [ ] **Step 1 : Créer le fichier avec helpers + 5 vues**

Créer `IrisApp/IrisApp/SettingsSections.swift` :

```swift
import AppKit
import IrisAppCore
import IrisKit
import SwiftUI

// MARK: - Shared layout

/// GroupBox avec le layout partagé (gauche, pleine largeur) de chaque section de
/// réglages. Migré depuis l'ex-`SettingsTab.SettingSection`.
struct SettingSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox(title) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
    }
}

/// Conteneur scrollable partagé par chaque pane de détail : padding + ligne
/// d'erreur/statut locale en bas.
struct SettingsPane<Content: View>: View {
    let error: String?
    let status: String?
    let content: Content

    init(error: String?, status: String?, @ViewBuilder content: () -> Content) {
        self.error = error
        self.status = status
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
                if let status {
                    Text(status).foregroundStyle(.secondary).font(.caption)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - General (Security policy + Backups)

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    @State private var maxSubsText = ""
    @State private var maxBackupsText = ""
    @State private var errorText: String?
    @State private var statusText: String?

    var body: some View {
        SettingsPane(error: errorText, status: statusText) {
            if let cfg = model.config {
                SettingSection("Security") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("On exfil attempt")
                            Spacer()
                            Picker(
                                "",
                                selection: Binding(
                                    get: { cfg.security.onExfilAttempt },
                                    set: { apply(key: "security.on_exfil_attempt", value: $0.rawValue) }
                                )
                            ) {
                                ForEach(ExfilAttemptPolicy.allCases, id: \.self) { policy in
                                    Text(policy.rawValue).tag(policy)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }
                        HStack {
                            Text("Max substitutions / min")
                            Spacer()
                            TextField("", text: $maxSubsText)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .onSubmit {
                                    apply(key: "security.max_substitutions_per_minute", value: maxSubsText)
                                }
                        }
                    }
                }
                SettingSection("Backups") {
                    HStack {
                        Text("Keep backups")
                        Spacer()
                        TextField("", text: $maxBackupsText)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { apply(key: "backups.max_count", value: maxBackupsText) }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        // `.task(id:)` (macOS 13+, non déprécié) re-synchronise les champs dès que la
        // config change — y compris quand elle se charge APRÈS l'apparition de la vue.
        // (On évite `.onChange(of:) { _ in }`, déprécié en macOS 14 — cf. finding Gemini Lot 1.)
        .task(id: configKey) { syncFields() }
    }

    /// Empreinte des valeurs éditables : change quand la config (sub-max / backups) change.
    private var configKey: String {
        let s = model.config?.security.maxSubstitutionsPerMinute ?? -1
        let b = model.config?.backups.maxCount ?? -1
        return "\(s)-\(b)"
    }

    private func apply(key: String, value: String) {
        Task {
            errorText = nil
            statusText = nil
            do {
                _ = try await model.setConfig(
                    [ConfigSetParams.Update(key: key, value: value)], via: admin)
                statusText = "Applied."
                syncFields()
            } catch {
                errorText = userMessage(error)
                syncFields()
            }
        }
    }

    private func syncFields() {
        guard let cfg = model.config else { return }
        maxSubsText = "\(cfg.security.maxSubstitutionsPerMinute)"
        maxBackupsText = "\(cfg.backups.maxCount)"
    }
}

// MARK: - Certificate (CA trust)

struct CertificateSettingsView: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    @State private var errorText: String?

    var body: some View {
        SettingsPane(error: errorText, status: nil) {
            SettingSection("Certificate Authority") {
                HStack {
                    switch model.caTrusted {
                    case .some(true):
                        Label("Trusted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    case .some(false):
                        Label("Not trusted", systemImage: "xmark.seal").foregroundStyle(.orange)
                    case nil:
                        Text("Unknown").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.caTrusted == true {
                        Button("Uninstall…") { caAction(install: false) }
                    } else {
                        Button("Install…") { caAction(install: true) }
                    }
                }
            }
        }
    }

    private func caAction(install: Bool) {
        Task {
            errorText = nil
            do {
                if install {
                    try await model.installCA(via: admin)
                } else {
                    try await model.uninstallCA(via: admin)
                }
            } catch {
                errorText = userMessage(error)
            }
        }
    }
}

// MARK: - Integration (Terminal + Launch at login)

struct IntegrationSettingsView: View {
    @EnvironmentObject var model: AppModel

    @State private var errorText: String?

    var body: some View {
        SettingsPane(error: errorText, status: nil) {
            SettingSection("Terminal") {
                HStack {
                    switch model.shellConfigured {
                    case .some(true):
                        Label("Configured", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false):
                        Label("Not configured", systemImage: "circle").foregroundStyle(.orange)
                    case nil:
                        Text("Unknown").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.shellConfigured == true {
                        Button("Remove…") { shellAction(install: false) }
                    } else {
                        Button("Configure…") { shellAction(install: true) }
                    }
                }
            }
            SettingSection("Launch at login") {
                VStack(alignment: .leading, spacing: 8) {
                    autoStartRow("Background service (irisd)", status: model.daemonAutoStart, target: .daemon)
                    Divider()
                    autoStartRow("Menu bar app (Iris)", status: model.appAutoStart, target: .app)
                }
            }
        }
    }

    @ViewBuilder private func autoStartRow(
        _ label: String, status: AutoStartStatus?, target: AutoStartTarget
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            switch status {
            case .requiresApproval?:
                Label("Needs approval", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Open Login Items…") { model.openLoginItemsSettings() }
            case .notFound?, .unknown?:
                Text("Unavailable").foregroundStyle(.secondary)
            default:
                Toggle(
                    "",
                    isOn: Binding(
                        get: { status == .enabled },
                        set: { newValue in toggleAutoStart(target, enabled: newValue) }
                    )
                )
                .labelsHidden()
                .disabled(status == nil)
            }
        }
    }

    private func shellAction(install: Bool) {
        Task {
            errorText = nil
            do {
                if install {
                    try await model.configureShell()
                } else {
                    try await model.unconfigureShell()
                }
            } catch {
                errorText = userMessage(error)
            }
        }
    }

    private func toggleAutoStart(_ target: AutoStartTarget, enabled: Bool) {
        Task {
            errorText = nil
            do {
                try await model.setAutoStart(target, enabled: enabled)
            } catch {
                errorText = userMessage(error)
            }
        }
    }
}

// MARK: - Advanced (Connection read-only + Reveal/Reload)

struct AdvancedSettingsView: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    @State private var errorText: String?

    var body: some View {
        SettingsPane(error: errorText, status: nil) {
            if let cfg = model.config {
                SettingSection("Connection (read-only)") {
                    VStack(alignment: .leading, spacing: 4) {
                        roRow("Proxy", cfg.broker.listen)
                        roRow("Events", cfg.broker.eventsListen)
                        roRow("Admin socket", cfg.broker.adminSocket)
                        roRow("Log level", cfg.broker.logLevel.rawValue)
                        roRow("Event retention", "\(cfg.broker.eventRetentionDays) days")
                        roRow("Event ring size", "\(cfg.broker.eventRingSize)")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                Button("Reveal config.json") { reveal() }
                Button("Reload") {
                    Task {
                        errorText = nil
                        do {
                            try await model.reloadConfig(via: admin)
                        } catch {
                            errorText = userMessage(error)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private func roRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func reveal() {
        Task {
            do {
                let path = try await model.configFilePath(via: admin)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } catch {
                errorText = userMessage(error)
            }
        }
    }
}

// MARK: - Uninstall

struct UninstallSettingsView: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    @State private var showUninstallConfirm = false
    @State private var deleteSecretsOnUninstall = false
    @State private var uninstallSummary: String?
    @State private var showUninstallDone = false

    var body: some View {
        SettingsPane(error: nil, status: nil) {
            SettingSection("Uninstall") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stops irisd, removes auto-start, the CA certificate and the terminal configuration.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Quit & Uninstall…", role: .destructive) { showUninstallConfirm = true }
                    }
                }
            }
        }
        .confirmationDialog(
            "Uninstall IRIS?", isPresented: $showUninstallConfirm, titleVisibility: .visible
        ) {
            Button("Uninstall (keep my secrets)", role: .destructive) {
                deleteSecretsOnUninstall = false
                runUninstall()
            }
            Button("Uninstall and delete my secrets", role: .destructive) {
                deleteSecretsOnUninstall = true
                runUninstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your secrets stay in the Keychain unless you choose to delete them.")
        }
        .alert("Almost done", isPresented: $showUninstallDone) {
            Button("Reveal uninstall.sh") {
                revealUninstallScript()
                quitApp()
            }
            Button("Quit", role: .cancel) { quitApp() }
        } message: {
            Text(uninstallSummary ?? "")
        }
    }

    private func runUninstall() {
        Task {
            let report = await model.uninstall(deleteSecrets: deleteSecretsOnUninstall, via: admin)
            uninstallSummary = Self.summarize(report)
            showUninstallDone = true
        }
    }

    private static func summarize(_ r: UninstallReport) -> String {
        var lines = [String]()
        lines.append("CA key removed: \(r.caKeyDeleted ? "yes" : "no")")
        lines.append("Secrets deleted: \(r.secretsDeleted)")
        if !r.mcpRestored.isEmpty { lines.append("MCP configs restored: \(r.mcpRestored.count)") }
        if !r.failures.isEmpty {
            lines.append("Could not complete: " + r.failures.map { "\($0.step)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append(
            "To finish: the CLI and the app need your password. Run uninstall.sh (in the Finder), or drag Iris to the Trash."
        )
        return lines.joined(separator: "\n")
    }

    private func revealUninstallScript() {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let script = support?
            .appendingPathComponent("iris", isDirectory: true)
            .appendingPathComponent("uninstall.sh")
        if let script, FileManager.default.fileExists(atPath: script.path) {
            NSWorkspace.shared.activateFileViewerSelecting([script])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
```

- [ ] **Step 2 : Compiler**

Run :
```bash
xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build 2>&1 | tail -5
```
Expected : `** BUILD SUCCEEDED **`. (Les nouvelles vues sont autonomes et inutilisées ; `SettingsTab.swift` coexiste encore.)

- [ ] **Step 3 : Lint + commit**

```bash
swift-format lint --strict IrisApp/IrisApp/SettingsSections.swift || swift-format format -i IrisApp/IrisApp/SettingsSections.swift
git add IrisApp/IrisApp/SettingsSections.swift
git commit -m "feat(ihm): vues de section Réglages (migrées de SettingsTab)"
```

---

## Task 2 : `SettingsWindow.swift` — racine NavigationSplitView + sidebar

**Files:**
- Create: `IrisApp/IrisApp/SettingsWindow.swift`

- [ ] **Step 1 : Créer le fichier**

Créer `IrisApp/IrisApp/SettingsWindow.swift` :

```swift
import IrisAppCore
import SwiftUI

/// Racine de la fenêtre Réglages : sidebar (`NavigationSplitView`) + pane de détail.
/// Charge l'état de config/CA/auto-start/shell une fois à l'apparition, puis chaque
/// section lit le `model` partagé.
struct SettingsWindow: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    /// Nommé `Pane` (pas `Section`) pour ne pas ombrer `SwiftUI.Section`, utilisé plus bas.
    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case general, certificate, integration, advanced, uninstall
        var id: Self { self }
        var title: String {
            switch self {
            case .general: return "General"
            case .certificate: return "Certificate"
            case .integration: return "Integration"
            case .advanced: return "Advanced"
            case .uninstall: return "Uninstall"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .certificate: return "lock.shield"
            case .integration: return "terminal"
            case .advanced: return "slider.horizontal.3"
            case .uninstall: return "trash"
            }
        }
    }

    @State private var selection: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach([Pane.general, .certificate, .integration, .advanced]) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
                // Action destructive isolée en bas de la sidebar (Section visuelle SwiftUI).
                Section {
                    Label(Pane.uninstall.title, systemImage: Pane.uninstall.symbol)
                        .tag(Pane.uninstall)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            detail(for: selection)
                .navigationTitle(selection.title)
        }
        .task {
            // Best-effort : peuple model.config / caTrusted / autoStart / shellConfigured.
            try? await model.loadConfig(via: admin)
            try? await model.refreshCATrust(via: admin)
            model.refreshAutoStart()
            await model.refreshShellConfigured()
        }
    }

    @ViewBuilder private func detail(for pane: Pane) -> some View {
        switch pane {
        case .general: GeneralSettingsView(admin: admin)
        case .certificate: CertificateSettingsView(admin: admin)
        case .integration: IntegrationSettingsView()
        case .advanced: AdvancedSettingsView(admin: admin)
        case .uninstall: UninstallSettingsView(admin: admin)
        }
    }
}
```

- [ ] **Step 2 : Compiler**

Run :
```bash
xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build 2>&1 | tail -5
```
Expected : `** BUILD SUCCEEDED **`. (Si « Cannot find 'GeneralSettingsView' » : Task 1 non compilée — oracle = le compilateur, pas SourceKit.)

- [ ] **Step 3 : Lint + commit**

```bash
swift-format lint --strict IrisApp/IrisApp/SettingsWindow.swift || swift-format format -i IrisApp/IrisApp/SettingsWindow.swift
git add IrisApp/IrisApp/SettingsWindow.swift
git commit -m "feat(ihm): racine NavigationSplitView de la fenêtre Réglages"
```

---

## Task 3 : `SettingsWindowController.swift` — hôte NSWindow

**Files:**
- Create: `IrisApp/IrisApp/SettingsWindowController.swift`

Réplique du pattern `MainPanelController.swift`, mais pour une `NSWindow` **normale activante** (pas un `NSPanel` non-activant).

- [ ] **Step 1 : Créer le fichier**

Créer `IrisApp/IrisApp/SettingsWindowController.swift` :

```swift
import AppKit
import IrisAppCore
import SwiftUI

/// Hôte AppKit de la fenêtre Réglages (`SettingsWindow`) dans une `NSWindow`
/// **normale activante** : configurer est une tâche délibérée, donc la fenêtre
/// prend le focus et apparaît en ⌘-Tab (à l'inverse du panneau monitoring,
/// non-activant et flottant). Créée paresseusement, retenue pour la durée du process.
@MainActor
final class SettingsWindowController {
    private let admin: AdminCalling
    private let appModel: AppModel
    private var window: NSWindow?

    init(admin: AdminCalling, appModel: AppModel) {
        self.admin = admin
        self.appModel = appModel
    }

    /// Affiche la fenêtre, l'amène devant et active l'app (LSUIElement non-activante
    /// par défaut). `activate(ignoringOtherApps:)` est déprécié en macOS 14 → garde
    /// `#available` (même choix qu'au Lot 1 pour `showAbout`).
    func show() {
        let window = makeWindowIfNeeded()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }

        let hosting = NSHostingController(
            rootView: SettingsWindow(admin: admin).environmentObject(appModel)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Iris Settings"
        window.contentViewController = hosting
        // Le bouton fermer masque la fenêtre (instance retenue, réaffichée via « Settings… »).
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 400)

        // Persiste position + taille ; centrage géométrique au premier lancement
        // (cf. MainPanelController : NSWindow.center() place trop haut).
        window.setFrameAutosaveName("IrisSettingsWindow")
        if !window.setFrameUsingName("IrisSettingsWindow") {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let visible = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(
                    NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
                )
            } else {
                window.center()
            }
        }

        self.window = window
        return window
    }
}
```

- [ ] **Step 2 : Compiler**

Run :
```bash
xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build 2>&1 | tail -5
```
Expected : `** BUILD SUCCEEDED **`. (Le contrôleur est encore inutilisé.)

- [ ] **Step 3 : Lint + commit**

```bash
swift-format lint --strict IrisApp/IrisApp/SettingsWindowController.swift || swift-format format -i IrisApp/IrisApp/SettingsWindowController.swift
git add IrisApp/IrisApp/SettingsWindowController.swift
git commit -m "feat(ihm): SettingsWindowController (NSWindow activante)"
```

---

## Task 4 : Recâblage + retraits

**Files:**
- Modify: `IrisApp/IrisApp/AppDelegate.swift` (propriété + `openSettings`)
- Modify: `IrisApp/IrisApp/BrokerPanelView.swift` (TabBar + switch)
- Modify: `Sources/IrisAppCore/AppModel.swift` (enum `Tab`)
- Delete: `IrisApp/IrisApp/SettingsTab.swift`

- [ ] **Step 1 : `AppDelegate` — propriété `settingsWindowController`**

Dans `AppDelegate.swift`, après la ligne `private var panelController: MainPanelController?` (`:19`), ajouter :
```swift
    private var settingsWindowController: SettingsWindowController?
```

- [ ] **Step 2 : `AppDelegate` — instancier le contrôleur**

Dans `applicationDidFinishLaunching`, juste après l'instanciation du `panelController` (`panelController = MainPanelController(admin: admin, appModel: appModel)`), ajouter :
```swift
        settingsWindowController = SettingsWindowController(admin: admin, appModel: appModel)
```

- [ ] **Step 3 : `AppDelegate` — recâbler `openSettings`**

Remplacer le corps de `openSettings()` :
```swift
    @objc private func openSettings() {
        appModel.selectedTab = .settings
        panelController?.show()
    }
```
par :
```swift
    @objc private func openSettings() {
        settingsWindowController?.show()
    }
```

- [ ] **Step 4 : `BrokerPanelView` — retirer l'onglet Settings**

Dans le `switch model.selectedTab` (`:21-28`), supprimer la ligne :
```swift
                case .settings: SettingsTab(admin: admin)
```

Dans `TabBar.items` (`:148-155`), supprimer la ligne :
```swift
        Item(tab: .settings, title: "Settings", symbol: "gearshape"),
```

- [ ] **Step 5 : `AppModel` — retirer `.settings` de l'enum**

Dans `Sources/IrisAppCore/AppModel.swift:8`, remplacer :
```swift
        case overview, logs, security, secrets, rules, settings
```
par :
```swift
        case overview, logs, security, secrets, rules
```
*(Pas de migration : `AppModel.swift:67-68` fait déjà `Tab.init(rawValue:)` + `?? .overview` → une valeur persistée « settings » devenue inconnue retombe sur `.overview`.)*

- [ ] **Step 6 : Supprimer `SettingsTab.swift`**

```bash
git rm IrisApp/IrisApp/SettingsTab.swift
```

- [ ] **Step 7 : Compiler (Debug)**

Run :
```bash
xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build 2>&1 | tail -5
```
Expected : `** BUILD SUCCEEDED **`. (Si « type 'AppModel.Tab' has no member 'settings' » subsiste : un `case .settings` résiduel — vérifier `BrokerPanelView`.)

- [ ] **Step 8 : Lint + commit**

```bash
swift-format lint --strict IrisApp/IrisApp/AppDelegate.swift IrisApp/IrisApp/BrokerPanelView.swift Sources/IrisAppCore/AppModel.swift
git add IrisApp/IrisApp/AppDelegate.swift IrisApp/IrisApp/BrokerPanelView.swift Sources/IrisAppCore/AppModel.swift
git commit -m "feat(ihm): « Settings… » ouvre la fenêtre Réglages ; retrait de l'onglet Settings"
```

---

## Task 5 : Vérification — build complet + SPM + smoke visuel

**Files:** aucun.

- [ ] **Step 1 : Build Release**

Run :
```bash
xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Release build 2>&1 | tail -5
```
Expected : `** BUILD SUCCEEDED **`.

- [ ] **Step 2 : SPM build + test (retrait `Tab.settings` ne casse rien)**

Run :
```bash
swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5
```
Expected : build OK ; tests verts (493/0 attendus — aucun test ne référence `.settings` ni `Tab.allCases`).

- [ ] **Step 3 : Smoke visuel** (checklist du spec §7 — devient la checklist de smoke de la PR)

Lancer le `.app` Release (méthode Lot 1 : quitter `/Applications/Iris.app`, lancer le build DerivedData, piloter via osascript/CGEvent ; cf. [[reference-macos-design-skills]]). Vérifier :
- [ ] « Settings… » (clic-droit icône) ouvre la fenêtre **Iris Settings** au premier plan ;
- [ ] sidebar = General · Certificate · Integration · Advanced · ─ · Uninstall ;
- [ ] **General** : changer « On exfil attempt » et « Max substitutions / min » → appliqué (statut « Applied. ») ; « Keep backups » idem ;
- [ ] **Certificate** : statut trust affiché, bouton Install…/Uninstall… présent ;
- [ ] **Integration** : statut Terminal + 2 toggles Launch at login ;
- [ ] **Advanced** : Connection read-only renseigné, « Reveal config.json » + « Reload » ;
- [ ] **Uninstall** : « Quit & Uninstall… » ouvre bien le dialog (ne PAS confirmer la désinstallation) ;
- [ ] le panneau monitoring n'a plus que **5 onglets** (Overview/Logs/Security/Secrets/Rules) ;
- [ ] fermer la fenêtre Réglages la masque ; « Settings… » la ré-ouvre (état conservé) ;
- [ ] aucune régression panneau : clic gauche ouvre/ferme, Pause daemon, Freeze Logs.

Restaurer `/Applications/Iris.app` après le smoke (le daemon `irisd` n'est pas touché).

---

## Self-review (auteur du plan)

- **Couverture spec** : §2 fichiers → Tasks 1-4 ; §3 fenêtre → Task 3 ; §4 sidebar+sections → Tasks 1-2 ; §5 recâblage → Task 4 ; §6 décisions (titre, suppression SettingsTab) → Task 3/Task 4 ; §7 vérif → Task 5. Hors-scope (⌘, global, refonte panneau) : absents — correct.
- **Placeholders** : aucun « TBD » ; code complet à chaque step (corps migrés à l'identique de `SettingsTab`).
- **Cohérence des types** : `SettingsWindow.Pane`/`selection`, `GeneralSettingsView(admin:)` etc., `SettingsWindowController(admin:appModel:)`/`show()`, `settingsWindowController?.show()` cohérents entre Tasks. `IntegrationSettingsView` sans `admin` (shell/auto-start passent par `model`, cf. spec §4). `ConfigSetParams.Update(key:value:)` / `userMessage(_:)` / `AdminCalling` confirmés existants.

## Notes d'exécution

- Toujours sur la branche `feat/ihm-lot2-settings-window`.
- Build IrisApp = `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp` (le scheme n'est PAS dans le workspace SPM `iris`).
- Avant PR : `swift build` + `swift test` + `swift-format` verts, puis PR avec la checklist de smoke (Task 5 Step 3). Oracle final IrisApp = CI macOS-15.
- Committer **ciblé** (jamais `git add -A` : le working tree peut contenir des modifs non liées).
