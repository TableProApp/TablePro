import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar

// A read statement run again for every row it returns, as macOS `StreamingQueryExportDataSource` does for a result
// larger than the grid holds.
nonisolated final class MobileQueryExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    let lexicalFeatures: SQLLexicalFeatures

    private let query: String
    private let driver: any DatabaseDriver
    private let databaseType: DatabaseType
    private let readOnly: Bool
    private let skipsSnapshotStatements: Bool

    init(
        query: String,
        driver: any DatabaseDriver,
        databaseType: DatabaseType,
        readOnly: Bool,
        skipsSnapshotStatements: Bool = false
    ) {
        self.query = query
        self.driver = driver
        self.databaseType = databaseType
        self.readOnly = readOnly
        self.skipsSnapshotStatements = skipsSnapshotStatements
        self.databaseTypeId = databaseType.rawValue
        self.lexicalFeatures = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: driver.settledLexicalFacts
        ).execution.pluginFeatures
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let rows = driver as? any ExportRowStreaming else {
            return MobileExportStreams.failing(DatabaseDriverCapabilityError.unsupported(.exportRows))
        }
        return rows.exportRows(query: query, readOnly: readOnly)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        nil
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        ""
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await MobileExportStreams.execute(
            query, on: driver, readOnly: readOnly, skipsTransactionStatements: skipsSnapshotStatements
        )
    }

    func quoteIdentifier(_ identifier: String) -> String {
        SQLBuilder.quoteIdentifier(identifier, for: databaseType)
    }

    func escapeStringLiteral(_ value: String) -> String {
        ClipboardExporter.literalBody(value, databaseType: databaseType, driver: driver)
    }
}

nonisolated enum MobileExportStreams {
    static func failing<Element>(_ error: any Error) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    // The keywords macOS `ExportDataSourceAdapter.execute` passes over at Read-Only, where each read takes a read-only
    // transaction of its own.
    static let transactionKeywords: Set<String> = ["BEGIN", "START", "COMMIT", "END", "ROLLBACK"]

    static func leadingKeyword(of statement: String) -> String {
        var text = Substring(statement)
        while true {
            text = text.drop { $0.isWhitespace }
            if text.hasPrefix("--") {
                text = text.drop { $0 != "\n" }
            } else if text.hasPrefix("/*"), let end = text.range(of: "*/") {
                text = text[end.upperBound...]
            } else {
                break
            }
        }
        return text.prefix { $0.isLetter }.uppercased()
    }

    // A snapshot statement is dropped where it cannot run: at Read-Only, and on a session that holds the user's own
    // transaction, whose COMMIT would end that transaction.
    static func execute(
        _ query: String,
        on driver: any DatabaseDriver,
        readOnly: Bool,
        skipsTransactionStatements: Bool
    ) async throws -> PluginQueryResult {
        if readOnly || skipsTransactionStatements, transactionKeywords.contains(leadingKeyword(of: query)) {
            return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }
        if let catalog = driver as? any CatalogQuerying, !readOnly {
            return try await catalog.catalogQuery(query)
        }
        if let rows = driver as? any ExportRowStreaming {
            return try await collect(rows.exportRows(query: query, readOnly: readOnly))
        }
        let result = try await driver.execute(query: query)
        return PluginQueryResult(
            columns: result.columns.map(\.name),
            columnTypeNames: result.columns.map(\.typeName),
            rows: result.rows.map { $0.map(PluginCellValue.fromOptional) },
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime
        )
    }

    static func collect(_ stream: AsyncThrowingStream<PluginStreamElement, Error>) async throws -> PluginQueryResult {
        var columns: [String] = []
        var typeNames: [String] = []
        var rows: [[PluginCellValue]] = []
        for try await element in stream {
            switch element {
            case .header(let header):
                columns = header.columns
                typeNames = header.columnTypeNames
            case .rows(let batch):
                rows.append(contentsOf: batch)
            }
        }
        return PluginQueryResult(columns: columns, columnTypeNames: typeNames, rows: rows, rowsAffected: 0, executionTime: 0)
    }

    // The first cell of the first row as a count, from a statement read the way the export reads its rows.
    static func count(_ query: String, on driver: any DatabaseDriver, readOnly: Bool) async throws -> Int? {
        let result: PluginQueryResult
        if let rows = driver as? any ExportRowStreaming {
            result = try await collect(rows.exportRows(query: query, readOnly: readOnly))
        } else {
            result = try await execute(query, on: driver, readOnly: readOnly, skipsTransactionStatements: false)
        }
        guard let cell = result.rows.first?.first?.asText?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(cell) ?? Double(cell).flatMap { Int(exactly: $0.rounded()) }
    }
}
