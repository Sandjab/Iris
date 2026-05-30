import IrisAppCore
import IrisKit
import SwiftUI

struct RulesTab: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    @State private var newHost = ""
    @State private var errorText: String?
    @State private var pendingDelete: MITMRule?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("host.example.com", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    Task { await addRule() }
                }
                .disabled(!IrisKit.Secret.isValidHost(newHost.trimmingCharacters(in: .whitespaces)))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }

            Text(
                "Adding a host means traffic to it can have placeholders substituted into it. "
                    + "Make sure no secret allows hosts you don't trust."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if model.rules.isEmpty {
                Spacer()
                Text("No rules.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.rules, id: \.host) { rule in
                    RuleRow(rule: rule, onDelete: rule.source == .runtime ? { pendingDelete = rule } : nil)
                }
                .listStyle(.plain)
            }
        }
        .task { await refresh() }
        .confirmationDialog(
            "Delete rule?",
            isPresented: deleteBinding,
            presenting: pendingDelete
        ) { rule in
            Button("Delete \(rule.host)", role: .destructive) {
                Task { await deleteRule(rule) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func refresh() async {
        do {
            try await model.refreshRules(via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }

    private func addRule() async {
        errorText = nil
        do {
            try await model.addRule(host: newHost.trimmingCharacters(in: .whitespaces), via: admin)
            newHost = ""
        } catch {
            errorText = userMessage(error)
        }
    }

    private func deleteRule(_ rule: MITMRule) async {
        errorText = nil
        do {
            try await model.deleteRule(host: rule.host, via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }
}

private struct RuleRow: View {
    let rule: MITMRule
    let onDelete: (() -> Void)?

    var body: some View {
        HStack {
            Text(rule.host).font(.callout)
            Text(rule.source.rawValue)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            Spacer()
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            } else {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .help("Defined in config.toml")
            }
        }
        .padding(.vertical, 2)
    }
}
