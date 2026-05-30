import IrisAppCore
import IrisKit
import SwiftUI

struct SecretsTab: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling

    enum Route: Equatable {
        case list
        case form(SecretFormState.Mode)
    }

    @State private var route: Route = .list
    @State private var errorText: String?
    @State private var pendingDelete: Secret?

    var body: some View {
        switch route {
        case .list:
            listView
        case .form(let mode):
            SecretFormView(mode: mode, admin: admin) {
                route = .list
            }
        }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    route = .form(.add)
                } label: {
                    Label("Add", systemImage: "plus")
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

            if model.secrets.isEmpty {
                Spacer()
                Text("No secrets.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.secrets, id: \.name) { secret in
                    SecretRow(
                        secret: secret,
                        onEdit: { route = .form(.edit(existing: secret)) },
                        onRotate: { route = .form(.rotate(existing: secret)) },
                        onDelete: { pendingDelete = secret }
                    )
                }
                .listStyle(.plain)
            }
        }
        .task { await refresh() }
        .confirmationDialog(
            "Delete secret?",
            isPresented: deleteBinding,
            presenting: pendingDelete
        ) { secret in
            Button("Delete \(secret.name)", role: .destructive) {
                Task { await deleteSecret(secret) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { secret in
            Text("This removes the Keychain item for \(secret.name). It cannot be undone.")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func refresh() async {
        do {
            try await model.refreshSecrets(via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }

    private func deleteSecret(_ secret: IrisKit.Secret) async {
        errorText = nil
        do {
            try await model.deleteSecret(name: secret.name, via: admin)
        } catch {
            errorText = userMessage(error)
        }
    }
}

private struct SecretRow: View {
    let secret: IrisKit.Secret
    let onEdit: () -> Void
    let onRotate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(secret.name).font(.callout.bold())
                Spacer()
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit allowed hosts")
                Button(action: onRotate) { Image(systemName: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderless)
                    .help("Rotate value")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 4) {
                ForEach(secret.allowedHosts, id: \.self) { host in
                    Text(host)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            Text(metadataLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var metadataLine: String {
        let created = secret.createdAt.formatted(date: .abbreviated, time: .omitted)
        let used = secret.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never"
        return "created \(created) · last used \(used) · \(secret.usageCount) uses"
    }
}
