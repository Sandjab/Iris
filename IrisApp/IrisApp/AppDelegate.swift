import AppKit
import Combine
import IrisAppCore
import IrisKit
import UserNotifications
import os

/// Default admin socket path (SPECS §681). Made configurable via Settings in Phase 6.3.
/// Module-internal so `MainPanelController` reuses it without duplicating the literal.
func defaultAdminSocketPath() -> String {
    ("~/Library/Application Support/iris/admin.sock" as NSString).expandingTildeInPath
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel()
    private var notifications: NotificationCoordinator?
    private var statusItem: NSStatusItem?
    private var panelController: MainPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var pulseWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Multi-instance protection (SPECS §3.3 + §4 edge cases): a second launch exits
        // immediately so we never end up with two status items fighting over one daemon.
        let bundleID = Bundle.main.bundleIdentifier ?? "io.iris.app"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        // Phase 7 : le postinstall relance l'app avec `--first-launch` pour enregistrer
        // les services SMAppService dès l'installation (idempotent, best-effort). Hors
        // main-actor : register() peut bloquer sur l'IPC launchd. Un échec n'est pas
        // bloquant — l'utilisateur garde les toggles de Settings.
        if CommandLine.arguments.contains("--first-launch") {
            Task.detached {
                let service = SystemAutoStartService()
                let log = Logger(subsystem: "io.iris.app", category: "autostart")
                for target in AutoStartTarget.allCases {
                    do {
                        try service.register(target)
                    } catch {
                        log.error(
                            "first-launch register(\(String(describing: target))) failed: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }

        let coordinator = NotificationCoordinator(model: appModel) { [weak self] in
            self?.panelController?.show()
        }
        notifications = coordinator
        Task { await coordinator.requestAuthorization() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        updateStatusIcon(appModel.daemonStatus)

        // Badge: mirror unreadAlertCount onto the status item title.
        appModel.$unreadAlertCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.updateBadge(count) }
            .store(in: &cancellables)

        // SPECS §15.1 — subtle "active" pulse on the icon after each new substituted event.
        // Explicit closure types + an eraseToAnyPublisher keep the chain cheap to type-check.
        appModel.$events
            .compactMap { (events: [Event]) -> Event? in events.first }
            .removeDuplicates { (lhs: Event, rhs: Event) -> Bool in lhs.id == rhs.id }
            .filter { (event: Event) -> Bool in event.kind == .substituted }
            .eraseToAnyPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pulseIcon() }
            .store(in: &cancellables)

        // Menu-bar icon shape mirrors the daemon state. Template SF Symbols keep
        // it legible on light/dark menu bars and when the menu is open — the
        // *shape* carries the state (HIG: menu bar extras use black + clear only).
        appModel.$daemonStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.updateStatusIcon(status) }
            .store(in: &cancellables)

        // One daemon client for the whole app: admin RPC over UDS + loopback SSE.
        // The same `admin` is reused by both the SyncCoordinator and the panel's
        // pause/resume control, so we never spin up (and leak) a per-click EventLoopGroup.
        // It lives for the process lifetime; its owned group is reclaimed at exit.
        let admin = AdminClient(socketPath: defaultAdminSocketPath())
        let eventsClient = EventsClient(port: 8899)

        // L'IHM du broker vit dans un panneau déplaçable, redimensionnable, flottant et
        // non-activant (créé paresseusement au premier clic). Il réutilise le client `admin`
        // commun à toute l'app et l'`appModel` partagé.
        panelController = MainPanelController(admin: admin, appModel: appModel)
        settingsWindowController = SettingsWindowController(admin: admin, appModel: appModel)

        let sync = SyncCoordinator(model: appModel, admin: admin, events: eventsClient)
        let model = appModel
        Task {
            try? await sync.bootstrap()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await sync.runStreamWithReconnect() }
                group.addTask { try? await sync.runStatsPoll() }
                // Notification fan-out: emit a system notification for each new alert event.
                group.addTask { @MainActor in
                    // Seed with alerts already loaded by bootstrap() so historical alerts
                    // don't trigger a notification flood on launch.
                    var seenIDs = Set(model.alerts.map(\.id))
                    for await alertEvents in model.$alerts.values {
                        for event in alertEvents where !seenIDs.contains(event.id) {
                            seenIDs.insert(event.id)
                            if let content = NotificationBuilder.build(from: event) {
                                coordinator.emit(content)
                            }
                        }
                        // Bound the dedupe set to the current (capped) alert window so it
                        // cannot grow unbounded as alerts age out of the ring.
                        seenIDs.formIntersection(alertEvents.map(\.id))
                    }
                }
            }
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            panelController?.toggle()
            return
        }
        // Ctrl+left-click is the standard macOS secondary-click shortcut.
        let isSecondaryClick =
            event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isSecondaryClick {
            showStatusMenu(from: sender)
        } else {
            panelController?.toggle()
        }
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About Iris",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Iris",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // NSMenu.popUp(positioning:at:in:) is the modern (non-deprecated) replacement for
        // statusItem.popUpMenu(_:). Anchored to the button so the menu drops down from the
        // status item. Avoids the recursion risk of synthesising a click via performClick
        // (which would re-enter handleClick and could re-trigger showStatusMenu).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    /// Swaps the status-item image to reflect the daemon state, as a monochrome
    /// template image (macOS handles light/dark + selection tinting). The form
    /// conveys the state, never colour:
    ///   up (active) = `key.fill` · paused = `key` (hollow) ·
    ///   down/error = `key.slash` · connecting = `key`, dimmed.
    private func updateStatusIcon(_ status: IrisAppCore.DaemonStatus) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let dimmed: Bool
        let label: String
        switch status {
        case .up(_, _, let paused):
            symbol = paused ? "key" : "key.fill"
            dimmed = false
            label = paused ? "paused" : "active"
        case .down:
            symbol = "key.slash"
            dimmed = false
            label = "stopped"
        case .connecting:
            symbol = "key"
            dimmed = true
            label = "connecting"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "IRIS daemon \(label)")
        image?.isTemplate = true
        button.image = image
        // Cancel any pending pulse reset so it can't clobber the dimmed
        // connecting state; restore full opacity when leaving connecting.
        pulseWorkItem?.cancel()
        button.alphaValue = dimmed ? 0.45 : 1.0
    }

    private func updateBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        button.title = count == 0 ? "" : " \(count)"
    }

    private func pulseIcon() {
        guard let button = statusItem?.button else { return }
        pulseWorkItem?.cancel()
        button.alphaValue = 0.6
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            button.animator().alphaValue = 1.0
        }
        // Re-arm after 5s so the next pulse feels fresh.
        let work = DispatchWorkItem { [weak button] in button?.alphaValue = 1.0 }
        pulseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    @objc private func openSettings() {
        settingsWindowController?.show()
    }

    @objc private func showAbout() {
        // L'app est LSUIElement non-activante : activer avant pour que le panneau
        // About standard passe au premier plan. `activate(ignoringOtherApps:)` est
        // déprécié en macOS 14 → `activate()` sur 14+, l'ancien sur la cible 13.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
