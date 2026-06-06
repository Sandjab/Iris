import AppKit
import IrisAppCore
import SwiftUI

/// Hôte AppKit de l'IHM du broker (`BrokerPanelView`) dans un `NSPanel` déplaçable,
/// redimensionnable, flottant et **non-activant**. Remplace l'ancien `NSPopover` ancré au
/// status item : le panneau se déplace n'importe où, se redimensionne, et reste ouvert pendant
/// que l'utilisateur travaille dans une autre app (il ne vole pas le focus clavier). Créé
/// paresseusement au premier affichage, puis retenu pour la durée du process.
@MainActor
final class MainPanelController {
    private let admin: AdminCalling
    private let appModel: AppModel
    private var panel: NSPanel?

    init(admin: AdminCalling, appModel: AppModel) {
        self.admin = admin
        self.appModel = appModel
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Affiche le panneau et l'amène devant SANS le rendre key : un panneau non-activant ne
    /// vole pas le focus clavier (l'utilisateur continue à taper dans son terminal). Les champs
    /// texte prennent le focus seulement au clic (`becomesKeyOnlyIfNeeded`).
    func show() {
        makePanelIfNeeded().orderFront(nil)
    }

    /// Bascule la visibilité : masque si visible, affiche sinon.
    func toggle() {
        if isVisible {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingController(
            rootView: BrokerPanelView(admin: admin).environmentObject(appModel)
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Iris"
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        // NSPanel masque par défaut à la désactivation de l'app ; on le garde visible au-dessus
        // du terminal/éditeur.
        panel.hidesOnDeactivate = false
        // Panneau non-activant : ne devient key (focus clavier) que quand un champ texte
        // (hit view `needsPanelToBecomeKey == true`) est cliqué.
        panel.becomesKeyOnlyIfNeeded = true
        // Le bouton fermer masque la fenêtre (instance retenue, réaffichée au clic icône).
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 420, height: 480)

        // Persiste position + taille entre ouvertures et redémarrages. Au tout premier
        // lancement (aucune frame sauvée), on centre sur la zone utile de l'écran. On calcule
        // le centre géométrique plutôt que `NSWindow.center()` : ce dernier place la fenêtre
        // horizontalement centrée mais « somewhat above center vertically » (doc Apple).
        panel.setFrameAutosaveName("IrisBrokerPanel")
        if !panel.setFrameUsingName("IrisBrokerPanel") {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let visible = screen.visibleFrame
                let size = panel.frame.size
                panel.setFrameOrigin(
                    NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
                )
            } else {
                panel.center()
            }
        }

        self.panel = panel
        return panel
    }
}
