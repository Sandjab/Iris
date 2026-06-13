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
