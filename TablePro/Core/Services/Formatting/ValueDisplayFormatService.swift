//
//  ValueDisplayFormatService.swift
//  TablePro
//
//  Applies display format transformations to raw cell values
//  and manages the effective format per column (auto-detected vs. user override).
//

import Foundation
import os

@MainActor
final class ValueDisplayFormatService {
    static let shared = ValueDisplayFormatService()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ValueDisplayFormat")

    /// Auto-detected formats keyed by "connectionId.tableName.columnName" for per-connection isolation.
    private var autoDetectedFormats: [String: ValueDisplayFormat] = [:]

    private(set) var overridesVersion: Int = 0

    private init() {}

    // MARK: - Format Application

    static func applyFormat(_ rawValue: String, format: ValueDisplayFormat) -> String {
        switch format {
        case .raw:
            return rawValue
        case .uuid:
            return formatAsUuid(rawValue)
        case .unixTimestamp:
            return formatAsTimestamp(rawValue, divideBy: 1)
        case .unixTimestampMillis:
            return formatAsTimestamp(rawValue, divideBy: 1_000)
        }
    }

    // MARK: - Effective Format Resolution

    func effectiveFormat(columnName: String, connectionId: UUID?, tableName: String?) -> ValueDisplayFormat {
        // Stored overrides take priority
        if let connId = connectionId, let table = tableName {
            if let overrides = ValueDisplayFormatStorage.shared.load(for: table, connectionId: connId),
               let format = overrides[columnName] {
                return format
            }
        }

        // Then auto-detected (scoped by connection + table)
        let key = scopedKey(columnName: columnName, connectionId: connectionId, tableName: tableName)
        if let format = autoDetectedFormats[key] {
            return format
        }

        return .raw
    }

    func setAutoDetectedFormats(_ formats: [String: ValueDisplayFormat], connectionId: UUID?, tableName: String?) {
        // Clear previous entries for this scope
        let prefix = scopePrefix(connectionId: connectionId, tableName: tableName)
        autoDetectedFormats = autoDetectedFormats.filter { !$0.key.hasPrefix(prefix) }

        for (columnName, format) in formats {
            let key = scopedKey(columnName: columnName, connectionId: connectionId, tableName: tableName)
            autoDetectedFormats[key] = format
        }
    }

    func clearAutoDetectedFormats(connectionId: UUID?, tableName: String?) {
        let prefix = scopePrefix(connectionId: connectionId, tableName: tableName)
        autoDetectedFormats = autoDetectedFormats.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Scoping

    private func scopePrefix(connectionId: UUID?, tableName: String?) -> String {
        "\(connectionId?.uuidString ?? "_").\(tableName ?? "_")."
    }

    private func scopedKey(columnName: String, connectionId: UUID?, tableName: String?) -> String {
        "\(connectionId?.uuidString ?? "_").\(tableName ?? "_").\(columnName)"
    }

    // MARK: - Override Management

    func setOverride(
        _ format: ValueDisplayFormat?,
        columnName: String,
        connectionId: UUID,
        tableName: String
    ) {
        var overrides = ValueDisplayFormatStorage.shared.load(for: tableName, connectionId: connectionId) ?? [:]

        if let format, format != .raw {
            overrides[columnName] = format
        } else {
            overrides.removeValue(forKey: columnName)
        }

        if overrides.isEmpty {
            ValueDisplayFormatStorage.shared.clear(for: tableName, connectionId: connectionId)
        } else {
            ValueDisplayFormatStorage.shared.save(overrides, for: tableName, connectionId: connectionId)
        }

        overridesVersion &+= 1
    }

    // MARK: - Private Formatting

    private static func formatAsUuid(_ rawValue: String) -> String {
        // Try raw binary bytes (isoLatin1 encoding from MySQL)
        if let data = rawValue.data(using: .isoLatin1), data.count == 16 {
            let bytes = [UInt8](data)
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            return insertUuidHyphens(hex)
        }

        // Try hex string (with or without 0x prefix)
        var hex = rawValue
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        hex = hex.replacingOccurrences(of: "-", with: "")

        guard (hex as NSString).length == 32, hex.allSatisfy({ $0.isHexDigit }) else {
            return rawValue
        }

        return insertUuidHyphens(hex.lowercased())
    }

    private static func insertUuidHyphens(_ hex: String) -> String {
        let ns = hex as NSString
        let p1 = ns.substring(with: NSRange(location: 0, length: 8))
        let p2 = ns.substring(with: NSRange(location: 8, length: 4))
        let p3 = ns.substring(with: NSRange(location: 12, length: 4))
        let p4 = ns.substring(with: NSRange(location: 16, length: 4))
        let p5 = ns.substring(with: NSRange(location: 20, length: 12))
        return "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
    }

    private static func formatAsTimestamp(_ rawValue: String, divideBy divisor: Double) -> String {
        guard let numericValue = Double(rawValue) else { return rawValue }
        let seconds = numericValue / divisor
        let date = Date(timeIntervalSince1970: seconds)
        return DateFormattingService.shared.format(date)
    }
}
