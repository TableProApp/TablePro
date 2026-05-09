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

    /// Connection metadata changed (name, color, group, type, etc.).
    /// Payload is the affected connection's id, or `nil` for bulk updates
    /// (sync pull, multi-import) where the sender doesn't track individual ids.
    /// Subscribers scoped to a single connection should filter `payload == id`;
    /// list-level subscribers refresh on every event regardless.
    let connectionUpdated = PassthroughSubject<UUID?, Never>()

    let databaseDidConnect = PassthroughSubject<DatabaseDidConnect, Never>()


    // MARK: - Window

    let mainWindowWillClose = PassthroughSubject<Void, Never>()

    // MARK: - Data Sources

    let queryHistoryDidUpdate = PassthroughSubject<Void, Never>()

    /// SQL favorites or favorite folders changed.
    /// Payload is the affected connection's id, or `nil` for cross-connection
    /// favorites (`favorite.connectionId == nil`) and bulk operations
    /// (multi-favorite delete) where the sender doesn't track a single id.
    /// Per-connection subscribers should refresh on `payload == nil || payload == self.connectionId`.
    let sqlFavoritesDidUpdate = PassthroughSubject<UUID?, Never>()

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
