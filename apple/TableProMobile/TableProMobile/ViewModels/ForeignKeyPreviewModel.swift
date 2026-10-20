import Foundation
import os
import TableProDatabase
import TableProModels

@MainActor
@Observable
final class ForeignKeyPreviewModel {
    enum Phase {
        case loading
        case loaded
        case notFound
        case failed(AppError)
    }

    struct Field: Identifiable {
        let id: Int
        let name: String
        let value: String?
        let reference: ForeignKeyReference?
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ForeignKeyPreviewModel")

    let reference: ForeignKeyReference
    private(set) var phase: Phase = .loading
    private(set) var fields: [Field] = []

    @ObservationIgnored private let session: ConnectionSession?
    @ObservationIgnored private let databaseType: DatabaseType
    @ObservationIgnored private var isRunning = false

    init(reference: ForeignKeyReference, session: ConnectionSession?, databaseType: DatabaseType) {
        self.reference = reference
        self.session = session
        self.databaseType = databaseType
    }

    var isLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    var canOpen: Bool { isLoaded && reference.filters() != nil }

    var notFoundMessage: String { Self.notFoundMessage(for: reference) }

    nonisolated static func notFoundMessage(
        for reference: ForeignKeyReference,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        let pairs = reference.parts.map { "\($0.column) = '\($0.value)'" }
        let condition = formatter.string(from: pairs) ?? pairs.joined(separator: ", ")
        return String(
            format: String(localized: "No row found in %@ where %@.", bundle: bundle, locale: locale),
            reference.table,
            condition
        )
    }

    // The page's task runs again when a pushed page pops back to it, and the row is already here.
    func load() async {
        guard case .loading = phase, !isRunning else { return }
        guard let session else {
            phase = .failed(AppError(
                category: .config,
                title: String(localized: "Not Connected"),
                message: String(localized: "No active database session."),
                recovery: nil,
                underlying: nil
            ))
            return
        }
        isRunning = true
        defer { isRunning = false }

        let driver = session.driver
        // The key columns' types pick each literal, as they do for the filter Open Table runs.
        var keyColumns: [ColumnInfo] = []
        do {
            keyColumns = try await driver.fetchColumns(table: reference.table, schema: reference.schema)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning("Foreign key preview could not read columns: \(error.localizedDescription, privacy: .private)")
        }
        let query = SQLBuilder.buildSingleRowLookup(
            table: reference.table,
            schema: reference.schema,
            key: reference.parts.map { (column: $0.column, value: $0.value) },
            columns: keyColumns,
            type: databaseType,
            driver: driver
        )
        let result: QueryResult
        do {
            result = try await driver.execute(query: query)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning("Foreign key preview failed: \(error.localizedDescription, privacy: .private)")
            phase = .failed(AppError(
                category: .query,
                title: String(localized: "Could Not Load the Referenced Row"),
                message: error.localizedDescription,
                recovery: nil,
                underlying: error
            ))
            return
        }
        guard let row = result.rows.first else {
            phase = .notFound
            return
        }

        var foreignKeys: [ForeignKeyInfo] = []
        do {
            foreignKeys = try await driver.fetchForeignKeys(table: reference.table, schema: reference.schema)
        } catch {
            Self.logger.warning("Foreign key preview could not read keys: \(error.localizedDescription, privacy: .private)")
        }

        fields = Self.fields(columns: result.columns, row: row, foreignKeys: foreignKeys, schema: reference.schema)
        phase = .loaded
    }

    // Typed through `Cell.from`, so a binary column's text form never becomes a key value.
    private static func fields(
        columns: [ColumnInfo],
        row: [String?],
        foreignKeys: [ForeignKeyInfo],
        schema: String?
    ) -> [Field] {
        let options = StreamOptions(textTruncationBytes: .max)
        let cells = row.indices.map { index in
            Cell.from(
                legacyValue: row[index],
                columnTypeName: index < columns.count ? columns[index].typeName : nil,
                options: options
            )
        }
        return zip(columns, row).enumerated().map { index, pair in
            Field(
                id: index,
                name: pair.0.name,
                value: pair.1,
                reference: ForeignKeyReference.make(
                    forColumn: pair.0.name,
                    foreignKeys: foreignKeys,
                    columns: columns,
                    cells: cells,
                    sourceSchema: schema
                )
            )
        }
    }
}
