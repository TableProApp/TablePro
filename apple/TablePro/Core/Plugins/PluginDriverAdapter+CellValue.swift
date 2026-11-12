import Foundation
import os
import TableProNumberFormatting
import TableProPluginKit
import TableProUtilities

extension PluginDriverAdapter {
    private static let iso8601Formatter = OSAllocatedUnfairLock(
        uncheckedState: {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    )

    static func cellValue(for parameter: Any?) -> PluginCellValue {
        guard let parameter else { return .null }
        if let typed = parameter as? TypedParameterValue { return .text(typed.text) }
        if let data = parameter as? Data { return .bytes(data) }
        if let f = parameter as? Float {
            guard f.isFinite else { return .null }
            return .text(NumberText.text(for: f))
        }
        if let f = parameter as? any BinaryFloatingPoint {
            let d = Double(f)
            guard d.isFinite else { return .null }
            return .text(NumberText.text(for: d))
        }
        return .text(stringValue(for: parameter))
    }

    private static func stringValue(for parameter: Any) -> String {
        switch parameter {
        case let s as String:
            return s
        case let b as Bool:
            return b ? "1" : "0"
        case let i as any BinaryInteger:
            return String(i)
        case let f as any BinaryFloatingPoint:
            return NumberText.text(for: Double(f))
        case let d as Date:
            return Self.iso8601Formatter.withLockUnchecked { $0.string(from: d) }
        case let data as Data:
            return data.hexEncoded
        case let uuid as UUID:
            return uuid.uuidString
        default:
            return String(describing: parameter)
        }
    }
}
