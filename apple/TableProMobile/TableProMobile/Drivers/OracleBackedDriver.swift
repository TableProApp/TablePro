import Foundation
import TableProDatabase
import TableProModels
import TableProOracleCore
import TableProPluginKit
import TableProQuery

// The Mac's Oracle plugin driver. Its plugin writes rows of its own, but edits here stay on SQLBuilder's Oracle SQL, as
// they were before the plugin ran on this device.
nonisolated final class OracleBackedDriver: PluginBackedDriver, @unchecked Sendable {
    private let oracle: OraclePluginDriver

    init(oracle: OraclePluginDriver, dialedHosts: [String], queryTimeoutSeconds: Int? = nil) {
        self.oracle = oracle
        super.init(
            plugin: oracle,
            dialedHosts: dialedHosts,
            queryTimeoutSeconds: queryTimeoutSeconds,
            readsOnly: { !SQLWriteClassifier.isWriteQuery($0, databaseType: .oracle) }
        )
    }

    // This device keeps no CA file for Oracle, so Verify CA is pointed at Verify Identity, which needs none.
    override func connect() async throws {
        do {
            try await super.connect()
        } catch let error as OraclePluginError where error.core == .certificateAuthorityRequired {
            throw DatabaseError(message: DriverSSLConfiguration.oracleVerifyCaUnavailableMessage)
        }
    }

    // OracleNIO has no out-of-band cancel, so Stop closes the channel and the next statement dials again.
    override func cancelCurrentQuery() async throws {
        oracle.core?.cancelCurrentQuery()
    }

    // A read takes each row as the plugin reads it and cuts its values for display at once, so no row past the one in
    // hand is held whole. A write runs whole and reports the rows it changed.
    override func stream(
        query: String,
        options: StreamOptions,
        bindsToSession: Bool
    ) -> AsyncThrowingStream<StreamElement, Error> {
        guard !SQLWriteClassifier.isWriteQuery(query, databaseType: .oracle) else {
            return super.stream(query: query, options: options, bindsToSession: bindsToSession)
        }
        // One row past the cap, so the read says it stopped there.
        let rowBudget = options.maxRows == .max ? nil : options.maxRows + 1
        let oracle = oracle
        return Self.gridRows(options: options) { oracle.streamEachRow(query: query, rowBudget: rowBudget) }
    }

    // The rows are opened inside the read's task and let go when it returns, which ends the plugin's read at the cap.
    static func gridRows(
        options: StreamOptions,
        reading open: @escaping @Sendable () -> AsyncThrowingStream<PluginStreamElement, Error>
    ) -> AsyncThrowingStream<StreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await emitRows(open(), options: options, into: continuation)
                    if Task.isCancelled {
                        continuation.yield(.truncated(reason: .cancelled))
                    }
                    continuation.finish()
                } catch {
                    // Stop closes the channel, so the read's error is the Stop itself.
                    if error is CancellationError || Task.isCancelled {
                        continuation.yield(.truncated(reason: .cancelled))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // Returns when the rows end or one past the cap arrived.
    private static func emitRows(
        _ rows: AsyncThrowingStream<PluginStreamElement, Error>,
        options: StreamOptions,
        into continuation: AsyncThrowingStream<StreamElement, Error>.Continuation
    ) async throws {
        var emitter = PluginRowEmitter(options: options)
        for try await element in rows {
            switch element {
            case .header(let header):
                emitter.begin(columns: header.columns, typeNames: header.columnTypeNames, into: continuation)
            case .rows(let batch):
                for row in batch {
                    guard emitter.emit(row, locator: nil, into: continuation) else { return }
                }
            }
        }
    }

    // MARK: - Transfer

    // The plugin's own export catalog, which lists each object under its owner (D14).
    override func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        OracleMobileExportCatalog(
            catalog: try oracle.exportCatalog,
            script: ExportCatalogScript(databaseTypeId: DatabaseType.oracle.rawValue, session: settledLexicalFacts)
        )
    }

    // An unknown release writes the identity, as on the Mac.
    override func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        OracleMobileWriteDialect(
            databaseTypeId: DatabaseType.oracle.rawValue,
            createTableSchema: oracle.effectiveSchema(nil),
            supportsIdentity: (try? oracle.serverRelease())?.hasIdentityColumns ?? true
        )
    }
}
