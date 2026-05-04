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
    static let connectionStatusDidChange = Notification.Name("connectionStatusDidChange")
    static let databaseDidConnect = Notification.Name("databaseDidConnect")
    static let successfulConnectionRecorded = Notification.Name("successfulConnectionRecorded")
    static let exportConnections = Notification.Name("exportConnections")
    static let importConnections = Notification.Name("importConnections")
    static let importConnectionsFromApp = Notification.Name("importConnectionsFromApp")
    static let linkedFoldersDidUpdate = Notification.Name("linkedFoldersDidUpdate")
    static let focusConnectionFormWindowRequested = Notification.Name("focusConnectionFormWindowRequested")
    static let openSampleDatabaseRequested = Notification.Name("openSampleDatabaseRequested")
    static let resetSampleDatabaseRequested = Notification.Name("resetSampleDatabaseRequested")

    // MARK: - License

    static let licenseStatusDidChange = Notification.Name("licenseStatusDidChange")

    // MARK: - Export

    static let exportQueryResults = Notification.Name("exportQueryResults")

    // MARK: - SQL Favorites

    static let sqlFavoritesDidUpdate = Notification.Name("sqlFavoritesDidUpdate")
    static let saveAsFavoriteRequested = Notification.Name("saveAsFavoriteRequested")

    // MARK: - Plugins

    static let pluginsRejected = Notification.Name("pluginsRejected")

    // MARK: - Settings Window

    static let openSettingsWindow = Notification.Name("com.TablePro.openSettingsWindow")

    // MARK: - Feedback

    static let showFeedbackWindow = Notification.Name("com.TablePro.showFeedbackWindow")
}
