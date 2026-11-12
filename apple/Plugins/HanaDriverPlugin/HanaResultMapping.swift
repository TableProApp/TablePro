import Foundation
import os
import TableProPluginKit

enum HanaResultMapping {
    static func pluginResult(from envelope: HanaResultEnvelope) -> PluginQueryResult {
        PluginQueryResult(
            columns: envelope.columns,
            columnTypeNames: envelope.columnTypeNames,
            rows: pluginRows(envelope.rows),
            rowsAffected: Int(clamping: envelope.rowsAffected),
            timing: PluginQueryTiming(total: envelope.executionTime),
            isTruncated: envelope.isTruncated,
            statusMessage: statusMessage(truncatedLobCount: envelope.truncatedLobCount),
            columnMeta: columnMeta(
                columns: envelope.columns,
                columnTypeNames: envelope.columnTypeNames,
                classifications: envelope.columnClassifications
            )
        )
    }

    static func pluginRows(_ rows: [[HanaBridgeCell]]) -> [PluginRow] {
        rows.map { row in row.map(\.pluginValue) }
    }

    static func statusMessage(truncatedLobCount: Int) -> String? {
        guard truncatedLobCount > 0 else { return nil }
        return String(
            format: String(localized: "%lld large object values were longer than 64 MiB and were cut short."),
            Int64(truncatedLobCount)
        )
    }

    static func columnMeta(
        columns: [String],
        columnTypeNames: [String],
        classifications hints: [String?]
    ) -> [PluginColumnInfo]? {
        guard hints.contains(where: { $0 != nil }),
              hints.count == columns.count,
              columnTypeNames.count == columns.count else {
            return nil
        }
        return columns.indices.map { index in
            PluginColumnInfo(
                name: columns[index],
                dataType: columnTypeNames[index],
                isNullable: true,
                isPrimaryKey: false,
                defaultValue: nil,
                extra: nil,
                charset: nil,
                collation: nil,
                comment: nil,
                identityKind: nil,
                isGenerated: false,
                allowedValues: nil,
                generationExpression: nil,
                generationKind: nil,
                ddlSpelling: nil,
                ddlDefault: nil,
                ddlGenerationExpression: nil,
                ddlCollation: nil,
                classificationTypeName: hints[index]
            )
        }
    }
}

final class HanaStreamReport: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "HanaPluginDriver")

    private let lock = NSLock()
    private var header: HanaCursorHeader?
    private var truncatedLargeObjects = 0

    func record(_ header: HanaCursorHeader) {
        lock.withLock { self.header = header }
    }

    func record(truncatedLargeObjects count: Int) {
        guard count > 0 else { return }
        lock.withLock { truncatedLargeObjects += count }
    }

    // A stream header has no field for the warning a result carries in statusMessage, so an export only logs it.
    func logTruncatedLargeObjects() {
        let count = lock.withLock { truncatedLargeObjects }
        guard count > 0 else { return }
        Self.logger.warning("SAP HANA cut \(count) large object values in a streamed result at 64 MiB")
    }

    func completing(_ collected: PluginQueryResult) -> PluginQueryResult {
        let (header, count) = lock.withLock { (self.header, self.truncatedLargeObjects) }
        var result = PluginQueryResult(
            columns: collected.columns,
            columnTypeNames: collected.columnTypeNames,
            rows: collected.rows,
            rowsAffected: collected.rowsAffected,
            timing: collected.timing,
            isTruncated: collected.isTruncated,
            statusMessage: HanaResultMapping.statusMessage(truncatedLobCount: count),
            columnMeta: header.flatMap {
                HanaResultMapping.columnMeta(
                    columns: $0.columns,
                    columnTypeNames: $0.columnTypeNames,
                    classifications: $0.columnClassifications
                )
            }
        )
        result.columnOrigins = collected.columnOrigins
        return result
    }
}
