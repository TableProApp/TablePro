//
//  JSONExportPlugin.swift
//  JSONExportPlugin
//

import Combine
import Foundation
import TableProPluginKit

nonisolated final class JSONExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "JSON Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to JSON format"
    static let formatId = "json"
    static let formatDisplayName = "JSON"
    static let defaultFileExtension = "json"
    static let iconName = "curlybraces"

    typealias Settings = JSONExportOptions
    static let settingsStorageId = "json"

    // A nonisolated class cannot hold an @Published property, so the change is announced by hand.
    var settings = JSONExportOptions() {
        willSet { objectWillChange.send() }
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    var currentFileExtension: String {
        settings.layout.fileExtension
    }

    func resetSettingsToDefaults() {
        settings = JSONExportOptions()
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        let (fileHandle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var committed = false
        defer {
            if !committed {
                PluginExportUtilities.rollbackAtomicWrite(at: tempURL)
            }
        }

        // One plugin instance serves every window, so a dialog in another window can change `settings` mid-export.
        let options = settings
        // NDJSON is one row per line by definition, so pretty-printing and the wrapping object do not apply.
        let isNewlineDelimited = options.layout == .newlineDelimited
        let prettyPrint = options.prettyPrint && !isNewlineDelimited
        let indent = prettyPrint ? "  " : ""
        let newline = prettyPrint ? "\n" : ""
        let rowPrefix = prettyPrint ? "\(indent)\(indent)" : ""
        let rowSeparator = isNewlineDelimited ? "\n" : ",\(newline)"
        var output = PluginExportOutputBuffer(fileHandle: fileHandle)
        var rowText = ""

        if !isNewlineDelimited {
            try output.append("{\(newline)")
        }

        var hasWrittenAnyRow = false
        for (tableIndex, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: tableIndex + 1)

            let escapedTableName = PluginExportUtilities.escapeJSONString(table.qualifiedName)
            if !isNewlineDelimited {
                try output.append("\(indent)\"\(escapedTableName)\": [\(newline)")
            }

            var hasWrittenRow = isNewlineDelimited ? hasWrittenAnyRow : false
            var columns: [JSONColumn]?

            let stream = dataSource.streamRows(for: table)
            for try await element in stream {
                try progress.checkCancellation()

                switch element {
                case .header(let header):
                    columns = header.columns.enumerated().map { index, name in
                        let typeName = index < header.columnTypeNames.count ? header.columnTypeNames[index] : ""
                        return JSONColumn(name: name, typeName: typeName)
                    }
                case .rows(let rows):
                    for row in rows {
                        rowText.removeAll(keepingCapacity: true)

                        if hasWrittenRow {
                            rowText += rowSeparator
                        }

                        rowText += rowPrefix
                        rowText += "{"

                        if let columns {
                            var isFirstField = true
                            for (colIndex, column) in columns.enumerated() where colIndex < row.count {
                                let value = row[colIndex]
                                guard options.includeNullValues || !value.isNull else { continue }
                                if !isFirstField {
                                    rowText += ", "
                                }
                                isFirstField = false
                                rowText += column.key
                                Self.appendJSONValue(
                                    value,
                                    type: column.type,
                                    preserveAsString: options.preserveAllAsStrings,
                                    to: &rowText
                                )
                            }
                        }

                        rowText += "}"

                        try output.append(rowText)
                        hasWrittenRow = true
                        hasWrittenAnyRow = true
                        progress.incrementRow()
                    }
                }
            }

            if isNewlineDelimited {
                continue
            }
            if hasWrittenRow {
                try output.append(newline)
            }
            let tableSuffix = tableIndex < tables.count - 1 ? ",\(newline)" : newline
            try output.append("\(indent)]\(tableSuffix)")
        }

        if isNewlineDelimited {
            if hasWrittenAnyRow {
                try output.append("\n")
            }
        } else {
            try output.append("}")
        }

        try progress.checkCancellation()
        try output.flush()
        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult()
    }

    static func formatJSONValue(_ value: PluginCellValue, columnTypeName: String, preserveAsString: Bool) -> String {
        var text = ""
        appendJSONValue(value, type: JSONColumnType(typeName: columnTypeName), preserveAsString: preserveAsString, to: &text)
        return text
    }

    fileprivate static func appendJSONValue(
        _ value: PluginCellValue,
        type: JSONColumnType,
        preserveAsString: Bool,
        to text: inout String
    ) {
        switch value {
        case .null:
            text += "null"
        case .bytes(let data):
            text += "\""
            text += data.base64EncodedString()
            text += "\""
        case .text(let val):
            appendJSONText(val, type: type, preserveAsString: preserveAsString, to: &text)
        }
    }

    private static func appendJSONText(
        _ val: String,
        type: JSONColumnType,
        preserveAsString: Bool,
        to text: inout String
    ) {
        if !preserveAsString {
            if type.isBoolean {
                let folded = val.lowercased()
                if folded == "true" || folded == "false" {
                    text += folded
                    return
                }
            }

            if type.isNumeric {
                if val.utf8.withContiguousStorageIfAvailable(isCanonicalJSONNumber) == true {
                    text += val
                    return
                }
                if let literal = JsonNumberNormalizer.numberLiteral(from: val) {
                    text += literal
                    return
                }
            }
        }

        text += "\""
        text += escapedJSONText(val)
        text += "\""
    }

    fileprivate static func escapedJSONText(_ val: String) -> String {
        let isClean = val.utf8.withContiguousStorageIfAvailable(hasNoJSONEscapes) ?? false
        return isClean ? val : PluginExportUtilities.escapeJSONString(val)
    }

    // True only for text `numberLiteral(from:)` returns as it is: no `+`, padding zero, exponent or bare point.
    private static func isCanonicalJSONNumber(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

        let integerStart = bytes.first == UInt8(ascii: "-") ? 1 : 0
        var index = integerStart
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        let integerDigits = index - integerStart
        guard integerDigits > 0, integerDigits == 1 || bytes[integerStart] != UInt8(ascii: "0") else { return false }
        guard index < bytes.count else { return true }
        guard bytes[index] == UInt8(ascii: ".") else { return false }

        index += 1
        let fractionStart = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        return index == bytes.count && index > fractionStart
    }

    // True only for text `escapeJSONString` returns unchanged. It drops a leading byte order mark, 0xC2 0x85 is U+0085
    // and 0xE2 0x80 opens U+2028 and U+2029.
    private static func hasNoJSONEscapes(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return false
        }
        for index in bytes.indices {
            let byte = bytes[index]
            if byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") {
                return false
            }
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if (byte == 0xC2 && next == 0x85) || (byte == 0xE2 && next == 0x80) {
                return false
            }
        }
        return true
    }

    // Text that reads "TRUE" in a text column stays that string, as a numeric-looking one does.
    // ClickHouse wraps the type, as in `Nullable(Bool)`.
    fileprivate static func isBooleanColumnType(_ typeName: String) -> Bool {
        var base = typeName.lowercased().trimmingCharacters(in: .whitespaces)
        while base.hasSuffix(")"), let open = base.firstIndex(of: "("),
              ["nullable", "lowcardinality"].contains(String(base[..<open])) {
            base = String(base[base.index(after: open) ..< base.index(before: base.endIndex)])
        }
        return base == "bool" || base == "boolean"
    }
}

// Read from the type name once per column, since a table repeats the same answer for every row.
private nonisolated struct JSONColumnType {
    let isBoolean: Bool
    let isNumeric: Bool

    init(typeName: String) {
        isBoolean = JSONExportPlugin.isBooleanColumnType(typeName)
        isNumeric = PluginExportUtilities.isNumericColumnType(typeName)
    }
}

private nonisolated struct JSONColumn {
    let key: String
    let type: JSONColumnType

    init(name: String, typeName: String) {
        key = "\"\(JSONExportPlugin.escapedJSONText(name))\": "
        type = JSONColumnType(typeName: typeName)
    }
}
