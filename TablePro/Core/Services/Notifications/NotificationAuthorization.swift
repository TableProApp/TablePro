//
//  NotificationAuthorization.swift
//  TablePro
//

import Foundation
import os
import UserNotifications

/// Asks for notification permission the first time a notification would actually be shown, which
/// is what Apple's own guidance asks for: "Sending the request in context provides a better
/// experience than automatically requesting authorization on first launch."
///
/// One requester for the whole app, because the options are frozen by the first grant. Apple:
/// "Subsequent authorization requests don't prompt the person." Two services asking separately
/// would mean whichever asked first decided what the other could ever do.
@MainActor
internal final class NotificationAuthorization {
    internal static let shared = NotificationAuthorization()

    internal static let options: UNAuthorizationOptions = [.alert, .sound]

    private static let logger = Logger(subsystem: "com.TablePro", category: "Notifications")

    private let presenter: any UserNotificationPresenting
    private var didRequest = false
    private(set) var status: UNAuthorizationStatus = .notDetermined

    internal init(presenter: any UserNotificationPresenting = SystemNotificationPresenter.shared) {
        self.presenter = presenter
    }

    @discardableResult
    internal func refresh() async -> UNAuthorizationStatus {
        status = await presenter.authorizationStatus()
        return status
    }

    /// Returns whether a notification may be posted right now. Callers must re-read anything
    /// time-sensitive after awaiting this: the permission dialog is modal and the user can take
    /// as long as they like over it, so state sampled before the call is stale after it.
    internal func ensureAuthorized() async -> Bool {
        await refresh()

        if status == .notDetermined, !didRequest {
            didRequest = true
            let granted = await presenter.requestAuthorization(options: Self.options)
            Self.logger.info("Notification permission \(granted ? "granted" : "denied")")
            await refresh()
        }

        return status == .authorized
    }
}
