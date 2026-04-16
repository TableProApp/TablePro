//
//  EditorTabPayload.swift
//  TablePro
//
//  Payload for identifying the content of a connection window.
//  Used with WindowGroup(for:) to create connection windows.
//

import Foundation

/// Declares the intent behind creating a new window tab.
internal enum TabIntent: String, Codable, Hashable {
    /// Open a specific tab with content (table, query with SQL, create-table, etc.)
    case openContent
    /// Create a new empty query tab (Cmd+T, native "+" button, toolbar "+")
    case newEmptyTab
    /// First window for a connection — restore tabs from disk or create default
    case restoreOrDefault
}

/// Payload passed to each connection window to identify what content it should display.
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
    /// Schema context (for multi-schema connections, e.g. PostgreSQL)
    internal let schemaName: String?
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
    /// Schema key for ER diagram tabs
    internal let erDiagramSchemaKey: String?
    /// Tab title (for restoring persisted tabs with their original names)
    internal let tabTitle: String?
    /// The intent behind creating this tab
    internal let intent: TabIntent

    private enum CodingKeys: String, CodingKey {
        case id, connectionId, tabType, tableName, databaseName, schemaName
        case initialQuery, isView, showStructure, skipAutoExecute, isPreview
        case tabTitle
        case initialFilterState, sourceFileURL, erDiagramSchemaKey, intent
        // Legacy key for backward decoding only
        case isNewTab
    }

    internal init(
        id: UUID = UUID(),
        connectionId: UUID,
        tabType: TabType = .query,
        tableName: String? = nil,
        databaseName: String? = nil,
        schemaName: String? = nil,
        initialQuery: String? = nil,
        isView: Bool = false,
        showStructure: Bool = false,
        skipAutoExecute: Bool = false,
        isPreview: Bool = false,
        initialFilterState: TabFilterState? = nil,
        sourceFileURL: URL? = nil,
        erDiagramSchemaKey: String? = nil,
        tabTitle: String? = nil,
        intent: TabIntent = .openContent
    ) {
        self.id = id
        self.connectionId = connectionId
        self.tabType = tabType
        self.tableName = tableName
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.initialQuery = initialQuery
        self.isView = isView
        self.showStructure = showStructure
        self.skipAutoExecute = skipAutoExecute
        self.isPreview = isPreview
        self.initialFilterState = initialFilterState
        self.sourceFileURL = sourceFileURL
        self.erDiagramSchemaKey = erDiagramSchemaKey
        self.tabTitle = tabTitle
        self.intent = intent
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        connectionId = try container.decode(UUID.self, forKey: .connectionId)
        tabType = try container.decode(TabType.self, forKey: .tabType)
        tableName = try container.decodeIfPresent(String.self, forKey: .tableName)
        databaseName = try container.decodeIfPresent(String.self, forKey: .databaseName)
        schemaName = try container.decodeIfPresent(String.self, forKey: .schemaName)
        initialQuery = try container.decodeIfPresent(String.self, forKey: .initialQuery)
        isView = try container.decodeIfPresent(Bool.self, forKey: .isView) ?? false
        showStructure = try container.decodeIfPresent(Bool.self, forKey: .showStructure) ?? false
        skipAutoExecute = try container.decodeIfPresent(Bool.self, forKey: .skipAutoExecute) ?? false
        isPreview = try container.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false
        initialFilterState = try container.decodeIfPresent(TabFilterState.self, forKey: .initialFilterState)
        sourceFileURL = try container.decodeIfPresent(URL.self, forKey: .sourceFileURL)
        erDiagramSchemaKey = try container.decodeIfPresent(String.self, forKey: .erDiagramSchemaKey)
        tabTitle = try container.decodeIfPresent(String.self, forKey: .tabTitle)
        if let decodedIntent = try container.decodeIfPresent(TabIntent.self, forKey: .intent) {
            intent = decodedIntent
        } else {
            let legacyNewTab = try container.decodeIfPresent(Bool.self, forKey: .isNewTab) ?? false
            intent = legacyNewTab ? .newEmptyTab : .openContent
        }
    }

    internal func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(connectionId, forKey: .connectionId)
        try container.encode(tabType, forKey: .tabType)
        try container.encodeIfPresent(tableName, forKey: .tableName)
        try container.encodeIfPresent(databaseName, forKey: .databaseName)
        try container.encodeIfPresent(schemaName, forKey: .schemaName)
        try container.encodeIfPresent(initialQuery, forKey: .initialQuery)
        try container.encode(isView, forKey: .isView)
        try container.encode(showStructure, forKey: .showStructure)
        try container.encode(skipAutoExecute, forKey: .skipAutoExecute)
        try container.encode(isPreview, forKey: .isPreview)
        try container.encodeIfPresent(initialFilterState, forKey: .initialFilterState)
        try container.encodeIfPresent(sourceFileURL, forKey: .sourceFileURL)
        try container.encodeIfPresent(erDiagramSchemaKey, forKey: .erDiagramSchemaKey)
        try container.encodeIfPresent(tabTitle, forKey: .tabTitle)
        try container.encode(intent, forKey: .intent)
    }

    /// Create a payload from a persisted QueryTab for restoration
    internal init(from tab: QueryTab, connectionId: UUID, skipAutoExecute: Bool = false) {
        self.id = UUID()
        self.connectionId = connectionId
        self.tabType = tab.tabType
        self.tableName = tab.tableName
        self.databaseName = tab.databaseName
        self.schemaName = tab.schemaName
        self.initialQuery = tab.query
        self.isView = tab.isView
        self.showStructure = tab.showStructure
        self.skipAutoExecute = skipAutoExecute
        self.isPreview = false
        self.initialFilterState = nil
        self.sourceFileURL = tab.sourceFileURL
        self.erDiagramSchemaKey = tab.erDiagramSchemaKey
        self.tabTitle = tab.title
        self.intent = .openContent
    }
}
