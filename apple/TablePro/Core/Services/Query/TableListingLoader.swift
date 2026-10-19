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
                return try await driver.execute(query: statement)
            }
            return .fetched(TableListing(
                rows: TableRows.from(queryRows: result.rows, columns: result.columns, columnTypes: result.columnTypes),
                isIncomplete: result.isTruncated,
                statusMessage: result.statusMessage
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

    init(rows: TableRows, isIncomplete: Bool, statusMessage: String?) {
        self.rows = rows
        self.isIncomplete = isIncomplete
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
