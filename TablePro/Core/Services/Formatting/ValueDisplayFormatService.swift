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
        case .json, .phpSerialized:
            return rawValue
        }
    }

    // MARK: - Effective Format Resolution

    func effectiveFormat(columnName: String, scope: TableScope?) -> ValueDisplayFormat {
        if let scope,
           let overrides = ValueDisplayFormatStorage.shared.load(for: scope),
           let format = overrides[columnName] {
            return format
        }

        if let format = autoDetectedFormats[scopedKey(columnName: columnName, scope: scope)] {
            return format
        }

        return .raw
    }

    func setAutoDetectedFormats(_ formats: [String: ValueDisplayFormat], scope: TableScope?) {
        let prefix = scopePrefix(scope: scope)
        autoDetectedFormats = autoDetectedFormats.filter { !$0.key.hasPrefix(prefix) }

        for (columnName, format) in formats {
            autoDetectedFormats[scopedKey(columnName: columnName, scope: scope)] = format
        }
    }

    func clearAutoDetectedFormats(scope: TableScope?) {
        let prefix = scopePrefix(scope: scope)
        autoDetectedFormats = autoDetectedFormats.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Scoping

    private func scopePrefix(scope: TableScope?) -> String {
        "\(scope?.storageComponent ?? "_")."
    }

    private func scopedKey(columnName: String, scope: TableScope?) -> String {
        "\(scope?.storageComponent ?? "_").\(columnName)"
    }

    // MARK: - Override Management

    func setOverride(
        _ format: ValueDisplayFormat?,
        columnName: String,
        scope: TableScope
    ) {
        var overrides = ValueDisplayFormatStorage.shared.load(for: scope) ?? [:]

        if let format, format != .raw {
            overrides[columnName] = format
        } else {
            overrides.removeValue(forKey: columnName)
        }

        if overrides.isEmpty {
            ValueDisplayFormatStorage.shared.clear(for: scope)
        } else {
            ValueDisplayFormatStorage.shared.save(overrides, for: scope)
        }

        overridesVersion &+= 1
    }

    // MARK: - Private Formatting

    private static func formatAsUuid(_ rawValue: String) -> String {
        // Try raw binary bytes (isoLatin1 encoding from MySQL)
        if let data = rawValue.data(using: .isoLatin1), data.count == 16 {
            let bytes = [UInt8](data)
            let hex = bytes.hexEncoded
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
