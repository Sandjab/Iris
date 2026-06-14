import AppKit
import SwiftUI

/// Hôte AppKit de la fenêtre « About Iris » (`AboutWindow`) dans une `NSWindow`
/// **normale activante** — même choix que `SettingsWindowController` : consulter
/// l'« À propos » est une action délibérée, la fenêtre prend donc le focus et
/// apparaît en ⌘-Tab (à l'inverse du panneau monitoring, flottant non-activant).
/// Remplace le panneau standard `orderFrontStandardAboutPanel` pour pouvoir
/// afficher la version + les notes de version dans une zone scrollable.
/// Créée paresseusement, retenue pour la durée du process.
@MainActor
final class AboutWindowController {
    private var window: NSWindow?

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

        let hosting = NSHostingController(rootView: AboutWindow())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Iris"
        window.contentViewController = hosting
        // Le bouton fermer masque la fenêtre (instance retenue, réaffichée via « About Iris »).
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 380, height: 360)

        // Persiste position + taille ; centrage géométrique au premier lancement
        // (cf. SettingsWindowController : NSWindow.center() place trop haut).
        window.setFrameAutosaveName("IrisAboutWindow")
        if !window.setFrameUsingName("IrisAboutWindow") {
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
