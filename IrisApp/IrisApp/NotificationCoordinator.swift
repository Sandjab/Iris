import AppKit
import IrisAppCore
import UserNotifications

@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: AppModel?
    private let onOpenPopover: @MainActor () -> Void

    init(model: AppModel, onOpenPopover: @escaping @MainActor () -> Void) {
        self.model = model
        self.onOpenPopover = onOpenPopover
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            model?.notificationsEnabled = granted
        } catch {
            model?.notificationsEnabled = false
        }
    }

    func emit(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let uid = response.notification.request.content.userInfo["event_id"] as? String
        let eventID = uid.flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            self.model?.selectedTab = .security
            if let id = eventID { self.model?.focusedAlertID = id }
            self.onOpenPopover()
            completionHandler()
        }
    }
}
