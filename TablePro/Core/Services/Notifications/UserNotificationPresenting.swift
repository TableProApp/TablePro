//
//  UserNotificationPresenting.swift
//  TablePro
//

import Foundation
import os
import UserNotifications

/// The seam every notification goes through, so the rules above it can be tested. The real
/// notification centre has no authorization on CI and silently drops everything, which makes a
/// test written against it pass whether or not the code works.
@MainActor
internal protocol UserNotificationPresenting: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool
    func setCategories(_ categories: Set<UNNotificationCategory>)
    func post(_ request: UNNotificationRequest) async throws
    func removeDelivered(identifiers: [String])
}

@MainActor
internal final class SystemNotificationPresenter: UserNotificationPresenting {
    internal static let shared = SystemNotificationPresenter()

    private static let logger = Logger(subsystem: "com.TablePro", category: "Notifications")

    private init() {}

    internal func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    internal func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        } catch {
            Self.logger.error("Notification permission request failed: \(error.localizedDescription)")
            return false
        }
    }

    internal func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    internal func post(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    internal func removeDelivered(identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
