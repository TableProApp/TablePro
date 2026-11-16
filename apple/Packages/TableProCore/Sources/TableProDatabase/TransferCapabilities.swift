import Foundation
import TableProPluginKit

public enum DatabaseDriverCapabilityError: Error, Equatable, Sendable, LocalizedError {
    public enum Capability: Sendable, Equatable {
        case parameterizedStatements
        case catalogQueries
        case exportRows
    }

    case unsupported(Capability)

    public var errorDescription: String? {
        switch self {
        case .unsupported(.parameterizedStatements):
            return String(localized: "This connection cannot send statements with bound values.")
        case .unsupported(.catalogQueries):
            return String(localized: "This connection cannot read its catalog for an export.")
        case .unsupported(.exportRows):
            return String(localized: "This connection cannot stream rows to a file.")
        }
    }
}

// Raw catalog reads for the shared export catalogs: every row, bytes kept, no display truncation.
public protocol CatalogQuerying: DatabaseDriver {
    func catalogQuery(_ sql: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult
}

public extension CatalogQuerying {
    func catalogQuery(_ sql: String) async throws -> PluginQueryResult {
        try await catalogQuery(sql, parameters: [])
    }
}

// Rows for a file export: pulled one batch at a time, bytes kept, no row cap, and a cancel ends the server read.
public protocol ExportRowStreaming: DatabaseDriver {
    func exportRows(query: String, readOnly: Bool) -> AsyncThrowingStream<PluginStreamElement, Error>
}
