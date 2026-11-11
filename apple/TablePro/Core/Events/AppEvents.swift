//
//  AppEvents.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

@MainActor
final class AppEvents {
    static let shared = AppEvents()

    // MARK: - Theme & Accessibility

    // Both the revision and the appearance: a forced Light/Dark switch never changes the theme, and the reverse.
    let themeChanged = PassthroughSubject<ThemeChange, Never>()

    let accessibilityTextSizeChanged = PassthroughSubject<Void, Never>()

    // MARK: - System Environment

    // A grid keeps text formatted in the old zone until its result is fetched again.
    let systemTimeZoneChanged = PassthroughSubject<Void, Never>()

    // MARK: - Settings

    let editorSettingsChanged = PassthroughSubject<Void, Never>()

    // A session's health monitor starts once, at connect.
    let connectionHealthCheckChanged = PassthroughSubject<Void, Never>()

    let dataGridSettingsChanged = PassthroughSubject<Void, Never>()

    // The toolbar's tooltips and overflow menu show shortcuts too, and AppKit never revisits them.
    let keyboardSettingsChanged = PassthroughSubject<Void, Never>()

    let currentSchemaChanged = PassthroughSubject<UUID, Never>()

    let aiSettingsChanged = PassthroughSubject<Void, Never>()

    // MARK: - Connections

    let connectionStatusChanged = PassthroughSubject<ConnectionStatusChange, Never>()
    // Carries the connection id; the phase lives on the workspace.
    let connectionPhaseChanged = PassthroughSubject<UUID, Never>()

    // A driver's Vault lease can no longer be renewed, so the driver has to sign in again.
    let credentialLeaseEnding = PassthroughSubject<CredentialLeaseEnding, Never>()

    // Detail inside the connecting phase, never what decides which pane a window shows.
    let connectionStageChanged = PassthroughSubject<ConnectionStageChange, Never>()

    // The connection's id, or nil for a sync pull or a multi-import.
    let connectionUpdated = PassthroughSubject<UUID?, Never>()

    let databaseDidConnect = PassthroughSubject<DatabaseDidConnect, Never>()

    let connectionListStateChanged = PassthroughSubject<Void, Never>()

    // MARK: - Window

    let mainWindowWillClose = PassthroughSubject<Void, Never>()

    // A connection window was registered, closed, or became key.
    let connectionWindowsChanged = PassthroughSubject<Void, Never>()

    // Every open rail shares one arrangement.
    let workspaceRailOrderChanged = PassthroughSubject<Void, Never>()

    // Every window's rail follows the one setting.
    let workspaceRailVisibilityChanged = PassthroughSubject<Void, Never>()

    // Only when the set of containers the tabs hold open can differ, never per keystroke.
    let workspaceTabsChanged = PassthroughSubject<Void, Never>()

    // The connection's id.
    let browseContainerChanged = PassthroughSubject<UUID, Never>()

    let visibleContainerChanged = PassthroughSubject<Void, Never>()

    // The connection's id.
    let sessionTransactionsChanged = PassthroughSubject<UUID, Never>()

    // MARK: - Data Sources

    // The connection's id, or nil for a change across connections, such as Clear History.
    let queryHistoryDidUpdate = PassthroughSubject<UUID?, Never>()

    // Nil when every connection's list changed, which only the sender knows: `SQLFavoriteManager.scopeToAnnounce`.
    let sqlFavoritesDidUpdate = PassthroughSubject<UUID?, Never>()

    let linkedFoldersDidUpdate = PassthroughSubject<Void, Never>()

    let teamLibraryDidUpdate = PassthroughSubject<Void, Never>()

    // Always nil: a rescan covers every folder. Shaped like `sqlFavoritesDidUpdate` for shared subscribers.
    let linkedSQLFoldersDidUpdate = PassthroughSubject<UUID?, Never>()

    // Refresh on a tab that loads its own content rather than through the coordinator, by tab id.
    let tabRefreshRequested = PassthroughSubject<UUID, Never>()

    // A query tab's edit history was written. The tab's id, or nil after a purge or Clear History.
    let queryTabVersionsDidUpdate = PassthroughSubject<UUID?, Never>()

    // MARK: - License & Sync

    let licenseStatusDidChange = PassthroughSubject<Void, Never>()

    let syncChangeTracked = PassthroughSubject<Void, Never>()

    // MARK: - MCP

    let mcpAuditLogChanged = PassthroughSubject<Void, Never>()

    // MARK: - Plugins

    let pluginsRejected = PassthroughSubject<[RejectedPlugin], Never>()

    // Not private, so a test can hand an isolated bus to the object under test.
    init() {}
}

struct ConnectionStatusChange: Sendable {
    let connectionId: UUID
    let status: ConnectionStatus
}

struct CredentialLeaseEnding: Sendable, Equatable {
    let connectionId: UUID
    let driver: ObjectIdentifier
    // How long the database user has left.
    let remaining: Duration
}

struct ConnectionStageChange: Sendable {
    let connectionId: UUID
    let stage: ConnectionStage
}

struct DatabaseDidConnect: Sendable {
    let connectionId: UUID
}
