//
//  EditorTabPayload.swift
//  TablePro
//
//  Payload for identifying the content of a native window tab.
//  Used with WindowGroup(for:) to create native macOS window tabs.
//

import Foundation

/// Payload passed to each native window tab to identify what content it should display.
/// Each window-tab receives this at creation time via `openWindow(id:value:)`.
internal struct EditorTabPayload: Codable, Hashable {
    /// Unique identifier for this window-tab (ensures openWindow always creates a new window)
    internal let id: UUID
    /// The connection this tab belongs to
    internal let connectionId: UUID
    /// What type of content to display
    internal let tabType: TabType
    /// Table name (for .table tabs)
    internal let tableName: String?
    /// Database context (for multi-database connections)
    internal let databaseName: String?
    /// Initial SQL query (for .query tabs opened from files)
    internal let initialQuery: String?
    /// Whether this tab displays a database view (read-only)
    internal let isView: Bool
    /// Whether to show the structure view instead of data (for "Show Structure" context menu)
    internal let showStructure: Bool
    /// Whether to skip automatic query execution (used for restored tabs that should lazy-load)
    internal let skipAutoExecute: Bool
    /// Whether this tab is a preview (temporary) tab
    internal let isPreview: Bool
    /// Initial filter state (for FK navigation — pre-applies a WHERE filter)
    internal let initialFilterState: TabFilterState?
    /// Source file URL for .sql files opened from disk (used for deduplication)
    internal let sourceFileURL: URL?
    /// Whether this is a Cmd+T new tab (creates default tab eagerly, skips disk restoration)
    internal let isNewTab: Bool

    internal init(
        id: UUID = UUID(),
        connectionId: UUID,
        tabType: TabType = .query,
        tableName: String? = nil,
        databaseName: String? = nil,
        initialQuery: String? = nil,
        isView: Bool = false,
        showStructure: Bool = false,
        skipAutoExecute: Bool = false,
        isPreview: Bool = false,
        initialFilterState: TabFilterState? = nil,
        sourceFileURL: URL? = nil,
        isNewTab: Bool = false
    ) {
        self.id = id
        self.connectionId = connectionId
        self.tabType = tabType
        self.tableName = tableName
        self.databaseName = databaseName
        self.initialQuery = initialQuery
        self.isView = isView
        self.showStructure = showStructure
        self.skipAutoExecute = skipAutoExecute
        self.isPreview = isPreview
        self.initialFilterState = initialFilterState
        self.sourceFileURL = sourceFileURL
        self.isNewTab = isNewTab
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        connectionId = try container.decode(UUID.self, forKey: .connectionId)
        tabType = try container.decode(TabType.self, forKey: .tabType)
        tableName = try container.decodeIfPresent(String.self, forKey: .tableName)
        databaseName = try container.decodeIfPresent(String.self, forKey: .databaseName)
        initialQuery = try container.decodeIfPresent(String.self, forKey: .initialQuery)
        isView = try container.decodeIfPresent(Bool.self, forKey: .isView) ?? false
        showStructure = try container.decodeIfPresent(Bool.self, forKey: .showStructure) ?? false
        skipAutoExecute = try container.decodeIfPresent(Bool.self, forKey: .skipAutoExecute) ?? false
        isPreview = try container.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false
        initialFilterState = try container.decodeIfPresent(TabFilterState.self, forKey: .initialFilterState)
        sourceFileURL = try container.decodeIfPresent(URL.self, forKey: .sourceFileURL)
        isNewTab = try container.decodeIfPresent(Bool.self, forKey: .isNewTab) ?? false
    }

    /// Whether this payload is a "connection-only" payload — just a connectionId
    /// with no specific tab content. Used by MainContentView to decide whether
    /// to create a default tab or restore tabs from storage.
    internal var isConnectionOnly: Bool {
        tabType == .query && tableName == nil && initialQuery == nil
    }

    /// Create a payload from a persisted QueryTab for restoration
    internal init(from tab: QueryTab, connectionId: UUID, skipAutoExecute: Bool = false) {
        self.id = UUID()
        self.connectionId = connectionId
        self.tabType = tab.tabType
        self.tableName = tab.tableName
        self.databaseName = tab.databaseName
        self.initialQuery = tab.query
        self.isView = tab.isView
        self.showStructure = tab.showStructure
        self.skipAutoExecute = skipAutoExecute
        self.isPreview = false
        self.initialFilterState = nil
        self.sourceFileURL = tab.sourceFileURL
        self.isNewTab = false
    }
}
