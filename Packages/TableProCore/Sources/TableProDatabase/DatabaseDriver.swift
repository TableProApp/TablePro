import Foundation
import TableProModels

public protocol DatabaseDriver: AnyObject, Sendable {
    func connect() async throws
    func disconnect() async throws
    func ping() async throws -> Bool

    func execute(query: String) async throws -> QueryResult
    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error>
    func cancelCurrentQuery() async throws

    func fetchTables(schema: String?) async throws -> [TableInfo]
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo]
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo]
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo]
    func fetchDatabases() async throws -> [String]

    func switchDatabase(to name: String) async throws
    var supportsSchemas: Bool { get }
    func switchSchema(to name: String) async throws
    func fetchSchemas() async throws -> [String]
    var currentSchema: String? { get }

    var supportsTransactions: Bool { get }
    func beginTransaction() async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws

    var serverVersion: String? { get }
}

public extension DatabaseDriver {
    func executeStreaming(query: String, options: StreamOptions = .default) -> AsyncThrowingStream<StreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.execute(query: query)
                    continuation.yield(.columns(result.columns))

                    var emitted = 0
                    for legacyRow in result.rows {
                        if Task.isCancelled {
                            continuation.yield(.truncated(reason: .cancelled))
                            break
                        }
                        if emitted >= options.maxRows {
                            continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                            break
                        }
                        let cells = legacyRow.enumerated().map { index, value -> Cell in
                            let typeName = index < result.columns.count ? result.columns[index].typeName : nil
                            return Cell.from(legacyValue: value, columnTypeName: typeName, options: options)
                        }
                        continuation.yield(.row(Row(cells: cells)))
                        emitted += 1
                    }

                    if let message = result.statusMessage {
                        continuation.yield(.statusMessage(message))
                    }
                    if result.rowsAffected != 0 {
                        continuation.yield(.rowsAffected(result.rowsAffected))
                    }
                    if result.isTruncated && emitted < options.maxRows {
                        continuation.yield(.truncated(reason: .driverLimit("driver returned isTruncated=true")))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
