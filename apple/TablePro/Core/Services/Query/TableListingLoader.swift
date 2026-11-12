//
//  TableListingLoader.swift
//  TablePro
//

import Foundation
import os

/// Reads one container's table listing over a metadata connection, the way the sidebar reads the
/// tables themselves.
///
/// The statement is built here, from the plugin, every time. A listing tab saves no SQL, so a restored
/// tab never runs text read back from disk, and a plugin that changes its listing is picked up at once.
internal struct TableListingLoader: Sendable {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TableListing")

    let databaseType: DatabaseType
    let slot: EngineNamespaceSlot

    func fetch(
        scope: DatabaseScope,
        from provider: any ScopedMetadataProviding
    ) async -> MetadataFetchOutcome<TableListing> {
        let databaseType = databaseType
        let slot = slot
        do {
            let result = try await provider.withMetadataDriver(scope: scope) { driver in
                let adapter = driver as? PluginDriverAdapter
                let container = AllTablesListing.container(slot: slot, scope: scope) { value in
                    adapter?.escapeStringLiteral(value) ?? value
                }
                guard let statement = AllTablesListing.statement(
                    databaseType: databaseType,
                    pluginListing: adapter?.allTablesMetadataSQL(schema: container)
                ) else {
                    throw TableListingError.unavailable
                }
                return try await driver.executeCatalogRead(query: statement)
            }
            let listingColumns = ObjectListingColumns(columns: result.columns)
            let rows = TableRows.from(
                queryRows: listingColumns?.tableRows(of: result.rows) ?? result.rows,
                columns: listingColumns == nil ? result.columns : result.columns.map(ObjectListingColumns.displayTitle(for:)),
                columnTypes: result.columnTypes
            )
            let items = listingColumns?.items(
                in: rows,
                containerSchema: scope.schema,
                readsSchemaColumn: slot == .schema
            ) ?? [:]
            return .fetched(TableListing(
                rows: rows,
                isIncomplete: result.isTruncated,
                statusMessage: result.statusMessage,
                items: items,
                columnKeys: listingColumns == nil ? [] : result.columns.map { $0.lowercased() }
            ))
        } catch {
            if DatabaseCancellationDiagnosis.isCancellation(error) { return .cancelled }
            Self.logger.error("Failed to list tables: \(error.publicLogShape, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}

/// What a listing came back with. A driver that answers in pages, the way Redis answers `SCAN`, says so,
/// and the listing has to say it too rather than pass one page off as every table there is.
internal struct TableListing: Sendable {
    let rows: TableRows
    let isIncomplete: Bool
    /// The driver's own words about the result, such as the cursor of the next page, else a plain
    /// statement that the listing is partial.
    let notice: String?
    /// The object each row lists, which the name filter and the row commands read. Empty for a
    /// listing with no name column, whose rows stay plain values.
    let items: [RowID: ObjectListingItem]
    /// Each column's source name, the plugin's alias or the built column's key, lowercased. The list
    /// formats, orders and remembers columns by it, since the titles are localized. Empty for a
    /// listing whose rows name no objects.
    let columnKeys: [String]

    init(
        rows: TableRows,
        isIncomplete: Bool,
        statusMessage: String?,
        items: [RowID: ObjectListingItem] = [:],
        columnKeys: [String] = []
    ) {
        self.rows = rows
        self.isIncomplete = isIncomplete
        self.items = items
        self.columnKeys = columnKeys
        if let statusMessage, !statusMessage.isEmpty {
            notice = statusMessage
        } else {
            notice = isIncomplete ? String(localized: "The driver returned part of the listing.") : nil
        }
    }
}

internal enum TableListingError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "This connection's driver does not list its tables.")
        }
    }
}
