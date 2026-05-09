//
//  AppServices.swift
//  TablePro
//

import SwiftUI

@MainActor
struct AppServices {
    let appEvents: AppEvents
    let appSettings: AppSettingsManager
    let appSettingsStorage: AppSettingsStorage
    let connectionStorage: ConnectionStorage
    let databaseManager: DatabaseManager
    let pluginManager: PluginManager
    let schemaService: SchemaService
    let schemaProviderRegistry: SchemaProviderRegistry
    let queryHistoryStorage: QueryHistoryStorage
    let sqlFavoriteManager: SQLFavoriteManager
    let aiChatStorage: AIChatStorage
    let aiKeyStorage: AIKeyStorage
    let groupStorage: GroupStorage
    let tagStorage: TagStorage
    let sshProfileStorage: SSHProfileStorage
    let licenseManager: LicenseManager
    let conflictResolver: ConflictResolver
    let syncMetadataStorage: SyncMetadataStorage
    let favoritesExpansionState: FavoritesExpansionState
    let linkedFolderWatcher: LinkedFolderWatcher
    let queryHistoryManager: QueryHistoryManager
    let dateFormattingService: DateFormattingService
    let copilotService: CopilotService
    let mcpServerManager: MCPServerManager
    let syncTracker: SyncChangeTracker
    let themeEngine: ThemeEngine
    let feedbackAPIClient: FeedbackAPIClient

    static let live = AppServices(
        appEvents: .shared,
        appSettings: .shared,
        appSettingsStorage: .shared,
        connectionStorage: .shared,
        databaseManager: .shared,
        pluginManager: .shared,
        schemaService: .shared,
        schemaProviderRegistry: .shared,
        queryHistoryStorage: .shared,
        sqlFavoriteManager: .shared,
        aiChatStorage: .shared,
        aiKeyStorage: .shared,
        groupStorage: .shared,
        tagStorage: .shared,
        sshProfileStorage: .shared,
        licenseManager: .shared,
        conflictResolver: .shared,
        syncMetadataStorage: .shared,
        favoritesExpansionState: .shared,
        linkedFolderWatcher: .shared,
        queryHistoryManager: .shared,
        dateFormattingService: .shared,
        copilotService: .shared,
        mcpServerManager: .shared,
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
