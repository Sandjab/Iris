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
