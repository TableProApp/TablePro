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

    // Carries both because a Light/Dark switch keeps the theme and a theme switch keeps the appearance; it also reaches views detached from every window.
    let themeChanged = PassthroughSubject<ThemeChange, Never>()

    let accessibilityTextSizeChanged = PassthroughSubject<Void, Never>()

    // MARK: - System Environment

    // A grid keeps strings formatted in the old time zone until a re-fetch, and nothing else re-derives them.
    let systemTimeZoneChanged = PassthroughSubject<Void, Never>()

    // MARK: - Settings

    let editorSettingsChanged = PassthroughSubject<Void, Never>()

    // A session's health monitor starts once at connect, so an open session sees a new interval only through this.
    let connectionHealthCheckChanged = PassthroughSubject<Void, Never>()

    let dataGridSettingsChanged = PassthroughSubject<Void, Never>()

    let valueColorSettingsChanged = PassthroughSubject<Void, Never>()

    // The menu bar re-syncs itself, but AppKit never revisits the shortcuts in a toolbar's tooltips or overflow menu.
    let keyboardSettingsChanged = PassthroughSubject<Void, Never>()

    let currentSchemaChanged = PassthroughSubject<UUID, Never>()

    let aiSettingsChanged = PassthroughSubject<Void, Never>()

    // MARK: - Connections

    let connectionStatusChanged = PassthroughSubject<ConnectionStatusChange, Never>()
    // The phase lives on the workspace, so the payload is only the connection id.
    let connectionPhaseChanged = PassthroughSubject<UUID, Never>()

    // A driver's Vault lease can no longer be renewed, so the driver has to sign in again.
    let credentialLeaseEnding = PassthroughSubject<CredentialLeaseEnding, Never>()

    // Presentational only: which pane a window shows comes from the phase, never from the stage.
    let connectionStageChanged = PassthroughSubject<ConnectionStageChange, Never>()

    // nil for a bulk update (sync pull, multi-import) whose sender does not track ids.
    let connectionUpdated = PassthroughSubject<UUID?, Never>()

    let databaseDidConnect = PassthroughSubject<DatabaseDidConnect, Never>()

    let connectionListStateChanged = PassthroughSubject<Void, Never>()

    // MARK: - Window

    let mainWindowWillClose = PassthroughSubject<Void, Never>()

    // Also fires when a connection window becomes key, since that can change which window stands for a connection.
    let connectionWindowsChanged = PassthroughSubject<Void, Never>()

    // Every open rail shares one arrangement, so all of them reload.
    let workspaceRailOrderChanged = PassthroughSubject<Void, Never>()

    // Every window carries its own rail, and all of them follow the one setting.
    let workspaceRailVisibilityChanged = PassthroughSubject<Void, Never>()

    // Fired only when the set of held containers can differ, not on every keystroke.
    let workspaceTabsChanged = PassthroughSubject<Void, Never>()

    let browseContainerChanged = PassthroughSubject<UUID, Never>()

    // The connections strip moves its highlight on this.
    let visibleContainerChanged = PassthroughSubject<Void, Never>()

    let sessionTransactionsChanged = PassthroughSubject<UUID, Never>()

    // MARK: - Data Sources

    // nil when the sender cannot name one connection (delete by id, clear all), so a per-connection subscriber refreshes on nil too.
    let queryHistoryDidUpdate = PassthroughSubject<UUID?, Never>()

    // SQLFavoriteManager.scopeToAnnounce picks the payload, since a subscriber never sees the scope a record moved from.
    let sqlFavoritesDidUpdate = PassthroughSubject<UUID?, Never>()

    let linkedFoldersDidUpdate = PassthroughSubject<Void, Never>()

    let teamLibraryDidUpdate = PassthroughSubject<Void, Never>()

    // Always nil, since every rescan is bulk; typed like sqlFavoritesDidUpdate so subscribers share one filter.
    let linkedSQLFoldersDidUpdate = PassthroughSubject<UUID?, Never>()

    // Refresh on a tab that loads its own content rather than through the coordinator, by tab id.
    let tabRefreshRequested = PassthroughSubject<UUID, Never>()

    // MARK: - License & Sync

    let licenseStatusDidChange = PassthroughSubject<Void, Never>()

    let syncChangeTracked = PassthroughSubject<Void, Never>()

    // MARK: - MCP

    let mcpAuditLogChanged = PassthroughSubject<Void, Never>()

    // MARK: - Plugins

    let pluginsRejected = PassthroughSubject<[RejectedPlugin], Never>()

    // Not private so a test can hand an isolated bus to the object under test; app code uses only shared.
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
