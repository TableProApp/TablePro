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

    let themeChanged = PassthroughSubject<Void, Never>()

    let accessibilityTextSizeChanged = PassthroughSubject<Void, Never>()

    // MARK: - Settings

    let editorSettingsChanged = PassthroughSubject<Void, Never>()

    let dataGridSettingsChanged = PassthroughSubject<Void, Never>()

    /// The menu bar re-syncs itself through `MainMenuBuilder`, but a window's toolbar advertises
    /// the same shortcuts in its tooltips and overflow menu and AppKit never revisits either.
    let keyboardSettingsChanged = PassthroughSubject<Void, Never>()

    let currentSchemaChanged = PassthroughSubject<UUID, Never>()

    let aiSettingsChanged = PassthroughSubject<Void, Never>()

    // MARK: - Connections

    let connectionStatusChanged = PassthroughSubject<ConnectionStatusChange, Never>()

    /// The step a connection attempt is currently on. Presentational detail inside the
    /// connecting phase, never a second source of truth for which pane a window shows.
    let connectionStageChanged = PassthroughSubject<ConnectionStageChange, Never>()

    /// Connection metadata changed (name, color, group, type, etc.).
    /// Payload is the affected connection's id, or `nil` for bulk updates
    /// (sync pull, multi-import) where the sender doesn't track individual ids.
    /// Subscribers scoped to a single connection should filter `payload == id`;
    /// list-level subscribers refresh on every event regardless.
    let connectionUpdated = PassthroughSubject<UUID?, Never>()

    let databaseDidConnect = PassthroughSubject<DatabaseDidConnect, Never>()


    // MARK: - Window

    let mainWindowWillClose = PassthroughSubject<Void, Never>()

    /// A connection window was registered, closed, or became key.
    /// Subscribers that present the set of open connections, or which window
    /// stands for each one, refresh on every event.
    let connectionWindowsChanged = PassthroughSubject<Void, Never>()

    /// The user reordered the workspace rail. Every open rail shares one
    /// arrangement, so all of them reload.
    let workspaceRailOrderChanged = PassthroughSubject<Void, Never>()

    /// The workspace rail was shown or hidden. Every window carries its own
    /// rail, so all of them follow the one setting.
    let workspaceRailVisibilityChanged = PassthroughSubject<Void, Never>()

    /// A window's tabs changed in a way that changes which containers they hold
    /// open. Fired only when the set of held containers can differ, not on every
    /// keystroke, so the rail reloads when a workspace appears or goes away.
    let workspaceTabsChanged = PassthroughSubject<Void, Never>()

    /// A connection's browse cursor moved to another database or schema.
    /// Payload is the connection's id.
    let browseContainerChanged = PassthroughSubject<UUID, Never>()

    // MARK: - Data Sources

    /// Query history changed (entry added, deleted, or cleared).
    /// Payload is the affected connection's id, or `nil` for cross-connection
    /// operations (delete-by-id without connection lookup, clear-all).
    /// Per-connection subscribers should refresh on `payload == nil || payload == self.connectionId`.
    let queryHistoryDidUpdate = PassthroughSubject<UUID?, Never>()

    /// SQL favorites or favorite folders changed.
    /// Payload is the affected connection's id, or `nil` for cross-connection
    /// favorites (`favorite.connectionId == nil`) and bulk operations
    /// (multi-favorite delete) where the sender doesn't track a single id.
    /// Per-connection subscribers should refresh on `payload == nil || payload == self.connectionId`.
    let sqlFavoritesDidUpdate = PassthroughSubject<UUID?, Never>()

    let linkedFoldersDidUpdate = PassthroughSubject<Void, Never>()

    let teamLibraryDidUpdate = PassthroughSubject<Void, Never>()

    /// Linked SQL folder rescan completed; cached file index changed.
    /// Senders are bulk rescans across all enabled folders, so payload is always `nil`.
    /// The shape is kept consistent with `sqlFavoritesDidUpdate` so subscribers can
    /// uniformly handle "this update may affect me" via `payload == nil || payload == self.connectionId`.
    let linkedSQLFoldersDidUpdate = PassthroughSubject<UUID?, Never>()

    // MARK: - License & Sync

    let licenseStatusDidChange = PassthroughSubject<Void, Never>()

    let syncChangeTracked = PassthroughSubject<Void, Never>()

    // MARK: - MCP

    let mcpAuditLogChanged = PassthroughSubject<Void, Never>()

    // MARK: - Plugins

    let pluginsRejected = PassthroughSubject<[RejectedPlugin], Never>()

    /// Not private so a test can hand an isolated bus to the object under test. App code uses
    /// `shared`, which is the only instance anything observes.
    init() {}
}

struct ConnectionStatusChange: Sendable {
    let connectionId: UUID
    let status: ConnectionStatus
}

struct ConnectionStageChange: Sendable {
    let connectionId: UUID
    let stage: ConnectionStage
}

struct DatabaseDidConnect: Sendable {
    let connectionId: UUID
}
