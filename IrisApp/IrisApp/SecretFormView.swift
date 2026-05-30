import IrisAppCore
import IrisKit
import SwiftUI

/// Inline secret form (add / edit / rotate) rendered in place of the Secrets list.
/// Owns a `SecretFormState` for live validation. On success, calls `onDone()`.
struct SecretFormView: View {
    @EnvironmentObject var model: AppModel
    let admin: AdminCalling
    let onDone: () -> Void

    @StateObject private var form: SecretFormState
    @State private var errorText: String?
    @State private var submitting = false

    init(mode: SecretFormState.Mode, admin: AdminCalling, onDone: @escaping () -> Void) {
        self.admin = admin
        self.onDone = onDone
        _form = StateObject(wrappedValue: SecretFormState(mode: mode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onDone) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            Text(title).font(.headline)

            if showName {
                TextField("name", text: $form.name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isAdd)
            }

            if showValue {
                SecureField("value", text: $form.value)
                    .textFieldStyle(.roundedBorder)
            }

            if showHosts {
                TextField("allowed hosts (comma-separated)", text: $form.hostsInput)
                    .textFieldStyle(.roundedBorder)
                if !hostSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(hostSuggestions, id: \.self) { host in
                                Button(host) { appendHost(host) }
                                    .buttonStyle(.borderless)
                                    .font(.caption2)
                            }
                        }
                    }
                }
                Text("Hosts must also be MITM rules for substitution to occur.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let msg = form.validationError {
                Text(msg).font(.caption).foregroundStyle(.orange)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            Button(submitTitle) {
                Task { await submit() }
            }
            .disabled(!form.canSubmit || submitting)
            .keyboardShortcut(.defaultAction)

            Spacer()
        }
        .padding(12)
    }

    private var isAdd: Bool {
        if case .add = form.mode { return true }
        return false
    }

    private var title: String {
        switch form.mode {
        case .add: return "Add secret"
        case .edit(let s): return "Edit \(s.name)"
        case .rotate(let s): return "Rotate \(s.name)"
        }
    }

    private var submitTitle: String {
        switch form.mode {
        case .add: return "Add"
        case .edit: return "Save"
        case .rotate: return "Rotate"
        }
    }

    private var showName: Bool {
        switch form.mode {
        case .add, .edit, .rotate: return true
        }
    }

    private var showValue: Bool {
        switch form.mode {
        case .add, .rotate: return true
        case .edit: return false
        }
    }

    private var showHosts: Bool {
        switch form.mode {
        case .add, .edit: return true
        case .rotate: return false
        }
    }

    /// MITM rule hosts not already entered — clickable autocompletion (SPECS §15.2.4).
    private var hostSuggestions: [String] {
        let current = Set(form.hosts)
        return model.rules.map(\.host).filter { !current.contains($0) }
    }

    private func appendHost(_ host: String) {
        let trimmed = form.hostsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            form.hostsInput = host
        } else if trimmed.hasSuffix(",") {
            form.hostsInput = trimmed + " " + host
        } else {
            form.hostsInput = trimmed + ", " + host
        }
    }

    private func submit() async {
        errorText = nil
        submitting = true
        defer { submitting = false }
        do {
            switch form.mode {
            case .add:
                try await model.addSecret(
                    name: form.name,
                    allowedHosts: form.hosts,
                    value: form.valueData,
                    via: admin
                )
            case .edit(let s):
                try await model.updateSecret(
                    name: s.name,
                    allowedHosts: form.hosts,
                    via: admin
                )
            case .rotate(let s):
                try await model.rotateSecret(
                    name: s.name,
                    value: form.valueData,
                    via: admin
                )
            }
            onDone()
        } catch {
            errorText = userMessage(error)
        }
    }
}
