import SwiftUI

@main
struct IrisAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Accessory (LSUIElement) app: no main window. The Settings scene keeps
        // SwiftUI happy without showing a window; all UI lives in the status-item popover.
        Settings {
            EmptyView()
        }
    }
}
