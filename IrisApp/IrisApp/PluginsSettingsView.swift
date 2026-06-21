import AppKit
import IrisAppCore
import IrisKit
import SwiftUI

struct PluginsSettingsView: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    @State private var errorText: String?
    @State private var pendingDelete: Plugin?
    @State private var pendingEnable: PendingEnable?

    private struct PendingEnable: Identifiable {
        let id: String
        let plugin: Plugin
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    pickAndInstall()
                } label: {
                    Label("Install…", systemImage: "plus")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            if model.plugins.isEmpty {
                GuidedEmptyState(
                    symbol: "puzzlepiece.extension",
                    title: "No plugins yet",
                    message:
                        "Install a plugin to add request/response hooks."
                        + " Plugins run sandboxed and never see your real secret values.",
                    actionTitle: "Install plugin",
                    action: pickAndInstall
                )
            } else {
                List(model.plugins, id: \.manifest.id) { plugin in
                    let index = model.plugins.firstIndex(of: plugin) ?? 0
                    PluginRow(
                        plugin: plugin,
                        canMoveUp: index > 0,
                        canMoveDown: index < model.plugins.count - 1,
                        onEnable: {
                            pendingEnable = PendingEnable(
                                id: plugin.manifest.id,
                                plugin: plugin
                            )
                        },
                        onDisable: { Task { await disable(id: plugin.manifest.id) } },
                        onRemove: { pendingDelete = plugin },
                        onMoveUp: {
                            Task { await reorder(id: plugin.manifest.id, index: index - 1) }
                        },
                        onMoveDown: {
                            Task { await reorder(id: plugin.manifest.id, index: index + 1) }
                        }
                    )
                }
                .listStyle(.plain)
            }
        }
        .task { await refresh() }
        .confirmationDialog(
            "Remove plugin?",
            isPresented: deleteBinding,
            presenting: pendingDelete
        ) { plugin in
            Button("Remove \(plugin.manifest.id)", role: .destructive) {
                Task { await remove(id: plugin.manifest.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This deletes the installed plugin directory. It cannot be undone.")
        }
        .sheet(item: $pendingEnable) { pending in
            PluginConsentSheet(
                plugin: pending.plugin,
                onCancel: { pendingEnable = nil },
                onApprove: {
                    pendingEnable = nil
                    Task { await enable(id: pending.id) }
                }
            )
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func pickAndInstall() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Choose a plugin directory (containing plugin.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await install(path: url.path) }
    }

    private func install(path: String) async {
        errorText = nil
        do {
            try await model.installPlugin(path: path, via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }

    private func refresh() async {
        do {
            try await model.refreshPlugins(via: admin)
            errorText = nil
        } catch {
            errorText = userMessage(error)
        }
    }

    private func enable(id: String) async {
        errorText = nil
        do {
            try await model.enablePlugin(id: id, via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }

    private func disable(id: String) async {
        errorText = nil
        do {
            try await model.disablePlugin(id: id, via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }

    private func remove(id: String) async {
        errorText = nil
        do {
            try await model.removePlugin(id: id, via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }

    private func reorder(id: String, index: Int) async {
        errorText = nil
        do {
            try await model.reorderPlugin(id: id, index: index, via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }
}

// MARK: - PluginRow

private struct PluginRow: View {
    let plugin: Plugin
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEnable: () -> Void
    let onDisable: () -> Void
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(plugin.manifest.name)
                    .font(.callout.bold())
                Text("v\(plugin.manifest.version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                stateBadge
                hashChip
                Spacer()
                Button(action: onMoveUp) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move up in dispatch order")
                Button(action: onMoveDown) {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move down in dispatch order")
                if plugin.displayState == .enabled {
                    Button(action: onDisable) {
                        Image(systemName: "pause.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Disable plugin")
                } else {
                    Button(action: onEnable) {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(plugin.displayState == .needsReapproval)
                    .help(
                        plugin.displayState == .needsReapproval
                            ? "Content changed — remove and reinstall to re-approve"
                            : "Enable plugin"
                    )
                }
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove plugin")
            }
            capabilityChips
        }
        .padding(.vertical, 3)
    }

    private var stateBadge: some View {
        Group {
            switch plugin.displayState {
            case .enabled:
                Text("ENABLED")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            case .disabled:
                Text("DISABLED")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            case .needsReapproval:
                Text("CHANGED — remove & reinstall to re-approve")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            }
        }
    }

    private var hashChip: some View {
        // Show the TOFU provenance indicator only in the healthy state (design §10.2).
        // When the content changed, `stateBadge` already shows the red
        // "CHANGED — remove & reinstall to re-approve"; a second red label here is redundant.
        Group {
            if plugin.hashMatches {
                Text("hash ok")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var capabilityChips: some View {
        let caps = plugin.manifest.capabilities
        return Group {
            if caps.network.isEmpty && caps.filesystem.isEmpty {
                Text("no capabilities (deny-all sandbox)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(caps.network, id: \.self) { entry in
                        Text("net: \(entry)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    ForEach(caps.filesystem, id: \.self) { entry in
                        Text("fs: \(entry)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - PluginConsentSheet

private struct PluginConsentSheet: View {
    let plugin: Plugin
    let onCancel: () -> Void
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enable \(plugin.manifest.name)?")
                .font(.headline)

            Text("This plugin runs in a sandbox and never sees your real secret values.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Requested capabilities:")
                    .font(.subheadline.bold())

                let caps = plugin.manifest.capabilities
                if caps.network.isEmpty && caps.filesystem.isEmpty {
                    Text("No capabilities requested — strict deny-all sandbox.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(caps.network, id: \.self) { entry in
                            Label("Network egress: \(entry)", systemImage: "network")
                                .font(.callout)
                        }
                        ForEach(caps.filesystem, id: \.self) { entry in
                            Label("Filesystem: \(entry)", systemImage: "folder")
                                .font(.callout)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Approve & Enable", action: onApprove)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
