import AppKit
import IrisAppCore
import IrisKit
import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    @State private var maxSubsText: String = ""
    @State private var maxBackupsText: String = ""
    @State private var errorText: String?
    @State private var statusText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let cfg = model.config {
                    securityBox(cfg)
                    backupsBox()
                    caBox()
                    autoStartBox()
                    connectionBox(cfg)
                    footer()
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.caption)
                }
                if let statusText {
                    Text(statusText).foregroundStyle(.secondary).font(.caption)
                }
            }
            .padding(12)
        }
        .task { await reload() }
    }

    // MARK: - Sections

    @ViewBuilder private func securityBox(_ cfg: Config) -> some View {
        GroupBox("Security") {
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
                        .onSubmit { apply(key: "security.max_substitutions_per_minute", value: maxSubsText) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder private func backupsBox() -> some View {
        GroupBox("Backups") {
            HStack {
                Text("Keep backups")
                Spacer()
                TextField("", text: $maxBackupsText)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { apply(key: "backups.max_count", value: maxBackupsText) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder private func caBox() -> some View {
        GroupBox("Certificate Authority") {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder private func autoStartBox() -> some View {
        GroupBox("Launch at login") {
            VStack(alignment: .leading, spacing: 8) {
                autoStartRow("Background service (irisd)", status: model.daemonAutoStart, target: .daemon)
                Divider()
                autoStartRow("Menu bar app (Iris)", status: model.appAutoStart, target: .app)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
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
            default:  // .enabled / .notRegistered / nil (en cours de chargement)
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

    @ViewBuilder private func connectionBox(_ cfg: Config) -> some View {
        GroupBox("Connection (read-only)") {
            VStack(alignment: .leading, spacing: 4) {
                roRow("Proxy", cfg.broker.listen)
                roRow("Events", cfg.broker.eventsListen)
                roRow("Admin socket", cfg.broker.adminSocket)
                roRow("Log level", cfg.broker.logLevel.rawValue)
                roRow("Event retention", "\(cfg.broker.eventRetentionDays) days")
                roRow("Event ring size", "\(cfg.broker.eventRingSize)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder private func footer() -> some View {
        HStack {
            Button("Reveal config.json") { reveal() }
            Button("Reload") {
                Task {
                    errorText = nil
                    do {
                        try await model.reloadConfig(via: admin)
                        syncFields()
                    } catch { errorText = userMessage(error) }
                }
            }
            Spacer()
        }
    }

    private func roRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    // MARK: - Actions

    private func apply(key: String, value: String) {
        Task {
            errorText = nil
            statusText = nil
            do {
                _ = try await model.setConfig([ConfigSetParams.Update(key: key, value: value)], via: admin)
                statusText = "Applied."
                syncFields()
            } catch {
                errorText = userMessage(error)
                syncFields()  // revert displayed value to the daemon's truth
            }
        }
    }

    private func caAction(install: Bool) {
        Task {
            errorText = nil
            do {
                if install { try await model.installCA(via: admin) } else { try await model.uninstallCA(via: admin) }
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

    private func reload() async {
        errorText = nil
        syncFields()  // sync immediately if config is already loaded (bootstrap) — avoids empty-field flicker
        do {
            try await model.loadConfig(via: admin)
            try await model.refreshCATrust(via: admin)
            model.refreshAutoStart()
            syncFields()
        } catch {
            errorText = userMessage(error)
        }
    }

    private func syncFields() {
        guard let cfg = model.config else { return }
        maxSubsText = "\(cfg.security.maxSubstitutionsPerMinute)"
        maxBackupsText = "\(cfg.backups.maxCount)"
    }
}
