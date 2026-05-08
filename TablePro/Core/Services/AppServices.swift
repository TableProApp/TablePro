//
//  AppServices.swift
//  TablePro
//

import SwiftUI

@MainActor
struct AppServices {
    let appEvents: AppEvents
    let appSettings: AppSettingsManager
    let connectionStorage: ConnectionStorage
    let databaseManager: DatabaseManager
    let pluginManager: PluginManager
    let schemaService: SchemaService
    let queryHistoryStorage: QueryHistoryStorage
    let sqlFavoriteManager: SQLFavoriteManager
    let aiChatStorage: AIChatStorage
    let syncTracker: SyncChangeTracker
    let themeEngine: ThemeEngine
    let feedbackAPIClient: FeedbackAPIClient

    static let live = AppServices(
        appEvents: .shared,
        appSettings: .shared,
        connectionStorage: .shared,
        databaseManager: .shared,
        pluginManager: .shared,
        schemaService: .shared,
        queryHistoryStorage: .shared,
        sqlFavoriteManager: .shared,
        aiChatStorage: .shared,
        syncTracker: .shared,
        themeEngine: .shared,
        feedbackAPIClient: .shared
    )
}

private struct AppServicesEnvironmentKey: EnvironmentKey {
    @MainActor static var defaultValue: AppServices { .live }
}

extension EnvironmentValues {
    var appServices: AppServices {
        get { self[AppServicesEnvironmentKey.self] }
        set { self[AppServicesEnvironmentKey.self] = newValue }
    }
}
