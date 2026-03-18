//
//  AppNotifications.swift
//  TablePro
//
//  Centralized notification names used across the app.
//  Domain-specific collections remain in TableProApp.swift
//  and SettingsNotifications.swift.
//

import Foundation

extension Notification.Name {
    // MARK: - Query History

    static let queryHistoryDidUpdate = Notification.Name("queryHistoryDidUpdate")

    // MARK: - Connections

    static let connectionUpdated = Notification.Name("connectionUpdated")
    static let databaseDidConnect = Notification.Name("databaseDidConnect")

    // MARK: - SQL Favorites

    static let sqlFavoritesDidUpdate = Notification.Name("sqlFavoritesDidUpdate")
}
