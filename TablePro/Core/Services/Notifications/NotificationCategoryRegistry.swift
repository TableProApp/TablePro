//
//  NotificationCategoryRegistry.swift
//  TablePro
//

import Foundation
import UserNotifications

/// The single owner of `setNotificationCategories`, which replaces the entire category set on
/// every call rather than adding to it. With one registrant that was invisible; with two, whoever
/// registered last silently deleted the other one's actions, so a notification would arrive with
/// no buttons on it and nothing would explain why.
@MainActor
internal final class NotificationCategoryRegistry {
    internal static let shared = NotificationCategoryRegistry()

    private let presenter: any UserNotificationPresenting
    private var categoriesByOwner: [String: Set<UNNotificationCategory>] = [:]

    internal init(presenter: any UserNotificationPresenting = SystemNotificationPresenter.shared) {
        self.presenter = presenter
    }

    internal func register(_ categories: Set<UNNotificationCategory>, owner: String) {
        categoriesByOwner[owner] = categories
        presenter.setCategories(allCategories)
    }

    internal var allCategories: Set<UNNotificationCategory> {
        categoriesByOwner.values.reduce(into: Set<UNNotificationCategory>()) { $0.formUnion($1) }
    }
}
