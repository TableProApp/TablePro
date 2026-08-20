//
//  NotificationRouter.swift
//  TablePro
//

import Foundation
import UserNotifications

@MainActor
internal protocol NotificationHandling: AnyObject {
    func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions
    func handle(_ response: UNNotificationResponse)
}

/// Dispatches the two `UNUserNotificationCenterDelegate` callbacks by category.
///
/// This replaces a `hasPrefix` test against one service's identifier prefix. That test was not a
/// filter, it was an allow-list of exactly one: `willPresent` returned no presentation options
/// and `didReceive` returned without acting for every identifier that did not match, so a second
/// kind of notification was dropped when the app was frontmost and did nothing at all when
/// clicked, with no error anywhere to say why.
@MainActor
internal final class NotificationRouter {
    internal static let shared = NotificationRouter()

    private var handlers: [String: any NotificationHandling] = [:]

    internal init() {}

    internal func register(_ handler: any NotificationHandling, forCategory categoryId: String) {
        handlers[categoryId] = handler
    }

    internal func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        guard let handler = handler(for: notification.request) else { return [] }
        return handler.presentationOptions(for: notification)
    }

    internal func handle(_ response: UNNotificationResponse) {
        handler(for: response.notification.request)?.handle(response)
    }

    private func handler(for request: UNNotificationRequest) -> (any NotificationHandling)? {
        handlers[request.content.categoryIdentifier]
    }
}
