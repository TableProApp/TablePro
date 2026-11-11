//
//  PluginExportUtilities.swift
//  TableProPluginKit
//

import Foundation

public enum PluginExportUtilities {
    public static func escapeJSONString(_ string: String) -> String {
        var utf8Result = [UInt8]()
        utf8Result.reserveCapacity(string.utf8.count)
        let wasContiguous = string.utf8.withContiguousStorageIfAvailable {
            appendJSONEscaped($0, to: &utf8Result)
        } != nil
        if !wasContiguous {
            Array(string.utf8).withUnsafeBufferPointer { appendJSONEscaped($0, to: &utf8Result) }
        }
        return String(bytes: utf8Result, encoding: .utf8) ?? string
    }

    private static func appendJSONEscaped(_ bytes: UnsafeBufferPointer<UInt8>, to utf8Result: inout [UInt8]) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x22: // "
                utf8Result.append(0x5C)
                utf8Result.append(0x22)
            case 0x5C: // backslash
                utf8Result.append(0x5C)
                utf8Result.append(0x5C)
            case 0x0A: // \n
                utf8Result.append(0x5C)
                utf8Result.append(0x6E)
            case 0x0D: // \r
                utf8Result.append(0x5C)
                utf8Result.append(0x72)
            case 0x09: // \t
                utf8Result.append(0x5C)
                utf8Result.append(0x74)
            case 0x08: // backspace
                utf8Result.append(0x5C)
                utf8Result.append(0x62)
            case 0x0C: // form feed
                utf8Result.append(0x5C)
                utf8Result.append(0x66)
            case 0x00...0x1F:
                let hex = String(format: "\\u%04X", byte)
                utf8Result.append(contentsOf: hex.utf8)
            case 0xC2 where index < bytes.count && bytes[index] == 0x85:
                utf8Result.append(contentsOf: "\\u0085".utf8)
                index += 1
            case 0xE2 where index + 1 < bytes.count && bytes[index] == 0x80
                && (bytes[index + 1] == 0xA8 || bytes[index + 1] == 0xA9):
                utf8Result.append(contentsOf: (bytes[index + 1] == 0xA8 ? "\\u2028" : "\\u2029").utf8)
                index += 2
            default:
                utf8Result.append(byte)
            }
        }
    }

    @available(*, deprecated, message: "Use beginAtomicWrite(for:) for crash-safe writes")
    public static func createFileHandle(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw PluginExportError.fileWriteFailed(url.path(percentEncoded: false))
        }
        return try FileHandle(forWritingTo: url)
    }

    public static func beginAtomicWrite(for destination: URL) throws -> (FileHandle, URL) {
        let tempURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil) else {
            throw PluginExportError.fileWriteFailed(destination.path(percentEncoded: false))
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        return (handle, tempURL)
    }

    public static func commitAtomicWrite(from tempURL: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
    }

    public static func rollbackAtomicWrite(at tempURL: URL) {
        try? FileManager.default.removeItem(at: tempURL)
    }

    public static func sanitizeForSQLComment(_ name: String) -> String {
        PluginSQLQuoting.lineCommentText(name)
            .replacingOccurrences(of: "/*", with: "", options: .literal)
            .replacingOccurrences(of: "*/", with: "", options: .literal)
            .replacingOccurrences(of: "--", with: "", options: .literal)
    }

    public static func isNumericColumnType(_ typeName: String) -> Bool {
        let numericPrefixes = [
            "int", "bigint", "decimal", "float", "double", "numeric",
            "real", "smallint", "tinyint", "mediumint", "integer", "number"
        ]
        let lower = typeName.lowercased()
        return numericPrefixes.contains { lower.hasPrefix($0) }
    }
}

// Shared so XLSX number cells and the CSV decimal comma read a column's declared type the same way.
public enum PluginColumnNumbers: Equatable, Sendable {
    case text
    case exact
    case approximate
    case untyped

    public init(typeName: String, bitsAreStrings: Bool = false) {
        let base = Self.baseName(typeName)
        if base.isEmpty {
            self = .untyped
        } else if Self.bitTypes.contains(base) {
            self = bitsAreStrings ? .text : .exact
        } else if Self.approximateTypes.contains(base) {
            self = .approximate
        } else if Self.exactTypes.contains(base) {
            self = .exact
        } else if Self.textTypes.contains(base) || Self.textMarkers.contains(where: { base.contains($0) }) {
            self = .text
        } else {
            self = .untyped
        }
    }

    public var isNumeric: Bool {
        self == .exact || self == .approximate
    }

    // `Nullable(UInt64)` and `LowCardinality(Nullable(Int32))` name the type inside. The base is the
    // first word without its width: `int4`, `Int64` and `INT UNSIGNED` are all `int`.
    private static func baseName(_ typeName: String) -> String {
        var name = typeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(")"), let open = name.firstIndex(of: "("),
              ["nullable", "lowcardinality"].contains(String(name[..<open])) {
            name = String(name[name.index(after: open)...].dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        return String(name.prefix { $0.isLetter || $0 == "_" })
    }

    private static let exactTypes: Set<String> = [
        "int", "uint", "integer", "bigint", "smallint", "tinyint", "mediumint", "hugeint",
        "uinteger", "ubigint", "usmallint", "utinyint", "uhugeint", "decimal", "dec", "numeric",
        "number", "bignumeric", "serial", "bigserial", "smallserial", "money", "smallmoney", "year", "oid"
    ]

    private static let approximateTypes: Set<String> = [
        "float", "double", "real", "binary_float", "binary_double"
    ]

    private static let textTypes: Set<String> = ["enum", "set", "json", "jsonb", "name"]

    private static let bitTypes: Set<String> = ["bit", "varbit"]

    // PostgreSQL's `bit(n)` is a string of 0 and 1. SQL Server's is a flag and MySQL's reads as a number.
    public static func bitsAreStrings(databaseTypeId: String) -> Bool {
        enginesWithBitStrings.contains(databaseTypeId)
    }

    private static let enginesWithBitStrings: Set<String> = [
        "PostgreSQL", "Redshift", "CockroachDB", "PGlite", "AlloyDB", "Citus", "Greenplum", "KingbaseES"
    ]

    private static let textMarkers = ["char", "text", "string", "clob"]
}

public extension String {
    func toUTF8Data() throws -> Data {
        guard let data = self.data(using: .utf8) else {
            throw PluginExportError.encodingFailed
        }
        return data
    }
}
