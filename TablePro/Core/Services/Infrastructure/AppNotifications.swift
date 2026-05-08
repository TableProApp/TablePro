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

    static let focusConnectionFormWindowRequested = Notification.Name("focusConnectionFormWindowRequested")
    static let openSampleDatabaseRequested = Notification.Name("openSampleDatabaseRequested")
    static let resetSampleDatabaseRequested = Notification.Name("resetSampleDatabaseRequested")
}
