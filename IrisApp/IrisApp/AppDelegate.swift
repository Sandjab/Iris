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
            button.image = NSImage(named: "StatusIcon")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

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
            showQuitMenu(from: sender)
        } else {
            panelController?.toggle()
        }
    }

    private func showQuitMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Iris", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        // NSMenu.popUp(positioning:at:in:) is the modern (non-deprecated) replacement for
        // statusItem.popUpMenu(_:). Anchored to the button so the menu drops down from the
        // status item. Avoids the recursion risk of synthesising a click via performClick
        // (which would re-enter handleClick and could re-trigger showQuitMenu).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
