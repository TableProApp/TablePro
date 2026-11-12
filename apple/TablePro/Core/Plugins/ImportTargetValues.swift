//
//  ImportTargetValues.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// How a format's export writes bytes as text, so its import can read them back.
enum ImportBinaryText: Sendable, Equatable {
    case prefixedHex
    case base64

    init?(formatId: String) {
        switch formatId {
        case "csv", "xlsx": self = .prefixedHex
        case "json": self = .base64
        default: return nil
        }
    }
}

// A file holds text; the target column's type decides the value it stands for.
struct ImportTargetValues: Sendable {
    let typeNames: [String: String]
    // A row of defaults on Oracle names one column, and a virtual column refuses even DEFAULT.
    let firstWritableColumn: String?
    private let binaryColumns: Set<String>
    private let numericBooleanColumns: Set<String>
    private let binaryText: ImportBinaryText?

    init(
        columns: [(name: String, typeName: String, isGenerated: Bool)],
        databaseType: DatabaseType,
        binaryText: ImportBinaryText?
    ) {
        var typeNames: [String: String] = [:]
        for column in columns where typeNames[column.name] == nil {
            typeNames[column.name] = column.typeName
        }
        let classifier = ColumnTypeClassifier(family: SQLTypeFamily.of(databaseType))
        let types = typeNames.mapValues { classifier.classify(rawTypeName: $0) }
        // MySQL strict mode refuses `true` for an integer flag, SQL Server refuses `yes` for a bit, and SQLite keeps either as text.
        let writesNumericBooleans = (try? resolveSQLDialect(for: databaseType))?.booleanLiteralStyle == .numeric
        self.typeNames = typeNames
        self.firstWritableColumn = columns.first { !$0.isGenerated }?.name
        self.binaryColumns = Set(types.filter { $0.value.isBlobType }.keys)
        self.numericBooleanColumns = writesNumericBooleans ? Set(types.filter { $0.value.isBooleanType }.keys) : []
        self.binaryText = binaryText
    }

    func values(_ values: [PluginCellValue], columns: [String]) throws -> [PluginCellValue] {
        try zip(columns, values).map { column, value in
            guard case .text(let text) = value else { return value }
            if binaryColumns.contains(column) {
                return try binaryValue(text, column: column)
            }
            if numericBooleanColumns.contains(column), let digit = Self.booleanDigit(text) {
                return .text(digit)
            }
            return value
        }
    }

    // Text not in the form the export writes is bound as text, as it always was: PostgreSQL's own JSON writes bytea as
    // `\x...`, which the server reads from text.
    private func binaryValue(_ text: String, column: String) throws -> PluginCellValue {
        switch binaryText {
        case .prefixedHex:
            guard BlobFormattingService.hasHexPrefix(text) else { return .text(text) }
            guard let bytes = BlobFormattingService.shared.bytes(fromPrefixedHex: text) else {
                throw PluginImportError.importFailed(String(
                    format: String(localized: "%@ is a binary column, and this value is not 0x followed by hex digits."),
                    column
                ))
            }
            return .bytes(bytes)
        case .base64:
            return Data(base64Encoded: text).map { .bytes($0) } ?? .text(text)
        case nil:
            return .text(text)
        }
    }

    // CSV reads t, f, y and n as booleans too.
    static func booleanDigit(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespaces)
        switch PluginSQLLiteral.booleanSynonym(for: word) {
        case .isTrue: return "1"
        case .isFalse: return "0"
        case nil: break
        @unknown default: break
        }
        switch word.lowercased() {
        case "t", "y": return "1"
        case "f", "n": return "0"
        default: return nil
        }
    }
}
