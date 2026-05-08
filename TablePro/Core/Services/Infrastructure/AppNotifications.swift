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
    // MARK: - Connections

    static let exportConnections = Notification.Name("exportConnections")
    static let importConnections = Notification.Name("importConnections")
    static let importConnectionsFromApp = Notification.Name("importConnectionsFromApp")
    static let focusConnectionFormWindowRequested = Notification.Name("focusConnectionFormWindowRequested")
    static let openSampleDatabaseRequested = Notification.Name("openSampleDatabaseRequested")
    static let resetSampleDatabaseRequested = Notification.Name("resetSampleDatabaseRequested")

    // MARK: - Export

    static let exportQueryResults = Notification.Name("exportQueryResults")

    // MARK: - SQL Favorites

    static let saveAsFavoriteRequested = Notification.Name("saveAsFavoriteRequested")

    // MARK: - Feedback

    static let showFeedbackWindow = Notification.Name("com.TablePro.showFeedbackWindow")
}
