import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Multi-instance protection (SPECS §3.3 + §4 edge cases): a second launch exits
        // immediately so we never end up with two status items fighting over one daemon.
        let bundleID = Bundle.main.bundleIdentifier ?? "io.iris.app"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Template icon: monochrome SF Symbol. Replaced by xcassets in Task 19.
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Iris")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 480, height: 600)
        popover.contentViewController = NSHostingController(rootView: PopoverView())
        self.popover = popover
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showQuitMenu(from: sender)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
