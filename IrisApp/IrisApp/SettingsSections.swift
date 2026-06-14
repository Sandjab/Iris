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
                                    Text(displayName(for: policy)).tag(policy)
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
        // (On évite `.onChange(of:) { _ in }`, déprécié en macOS 14.)
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
                    [ConfigSetParams.Update(key: key, value: value)],
                    via: admin
                )
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
                        // Désactivé tant que l'état de confiance est inconnu (nil = en cours
                        // de chargement) : évite une invite d'auth admin avant de savoir.
                        Button("Install…") { caAction(install: true) }
                            .disabled(model.caTrusted == nil)
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
                        // Désactivé tant que l'état est inconnu (nil) : évite une écriture
                        // redondante dans le profil shell avant de connaître l'état réel.
                        Button("Configure…") { shellAction(install: true) }
                            .disabled(model.shellConfigured == nil)
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
        _ label: String,
        status: AutoStartStatus?,
        target: AutoStartTarget
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
            "Uninstall IRIS?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
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
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
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
