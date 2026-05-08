//
//  AppEvents.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class AppEvents {
    static let shared = AppEvents()

    // MARK: - Theme & Accessibility

    let themeChanged = PassthroughSubject<Void, Never>()

    let accessibilityTextSizeChanged = PassthroughSubject<Void, Never>()

    // MARK: - Settings

    let editorSettingsChanged = PassthroughSubject<Void, Never>()

    let dataGridSettingsChanged = PassthroughSubject<Void, Never>()

    let aiSettingsChanged = PassthroughSubject<Void, Never>()

    let terminalSettingsChanged = PassthroughSubject<Void, Never>()

    // MARK: - Connections

    let connectionStatusChanged = PassthroughSubject<ConnectionStatusChange, Never>()

    let connectionUpdated = PassthroughSubject<Void, Never>()

    let databaseDidConnect = PassthroughSubject<DatabaseDidConnect, Never>()

    let mainCoordinatorTeardown = PassthroughSubject<MainCoordinatorTeardown, Never>()

    // MARK: - Window

    let mainWindowWillClose = PassthroughSubject<Void, Never>()

    // MARK: - Data Sources

    let queryHistoryDidUpdate = PassthroughSubject<Void, Never>()

    let sqlFavoritesDidUpdate = PassthroughSubject<Void, Never>()

    let linkedFoldersDidUpdate = PassthroughSubject<Void, Never>()

    let linkedSQLFoldersDidUpdate = PassthroughSubject<Void, Never>()

    // MARK: - License & Sync

    let licenseStatusDidChange = PassthroughSubject<Void, Never>()

    let syncChangeTracked = PassthroughSubject<Void, Never>()

    // MARK: - MCP

    let mcpAuditLogChanged = PassthroughSubject<Void, Never>()

    // MARK: - Plugins

    let pluginsRejected = PassthroughSubject<[RejectedPlugin], Never>()

    private init() {}
}

struct ConnectionStatusChange: Sendable {
    let connectionId: UUID
    let status: ConnectionStatus
}

struct DatabaseDidConnect: Sendable {
    let connectionId: UUID
}

struct MainCoordinatorTeardown: Sendable {
    let connectionId: UUID
}
