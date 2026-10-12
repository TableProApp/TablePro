import Foundation
import TableProPluginKit

enum HanaResultMapping {
    static func pluginResult(from envelope: HanaResultEnvelope) -> PluginQueryResult {
        PluginQueryResult(
            columns: envelope.columns,
            columnTypeNames: envelope.columnTypeNames,
            rows: envelope.rows.map { row in row.map(\.pluginValue) },
            rowsAffected: Int(clamping: envelope.rowsAffected),
            timing: PluginQueryTiming(total: envelope.executionTime),
            isTruncated: envelope.isTruncated,
            statusMessage: statusMessage(truncatedLobCount: envelope.truncatedLobCount),
            columnMeta: columnMeta(for: envelope)
        )
    }

    static func statusMessage(truncatedLobCount: Int) -> String? {
        guard truncatedLobCount > 0 else { return nil }
        return String(
            format: String(localized: "%lld large object values were longer than 64 MiB and were cut short."),
            Int64(truncatedLobCount)
        )
    }

    static func columnMeta(for envelope: HanaResultEnvelope) -> [PluginColumnInfo]? {
        let hints = envelope.columnClassifications
        guard hints.contains(where: { $0 != nil }),
              hints.count == envelope.columns.count,
              envelope.columnTypeNames.count == envelope.columns.count else {
            return nil
        }
        return envelope.columns.indices.map { index in
            PluginColumnInfo(
                name: envelope.columns[index],
                dataType: envelope.columnTypeNames[index],
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
