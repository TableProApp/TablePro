//
//  MongoDBJsonNumber.swift
//  MongoDBDriverPlugin
//

import Foundation

enum MongoDBJsonNumber {
    private static let regex = try? NSRegularExpression(
        pattern: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#
    )

    static func isValid(_ value: String) -> Bool {
        guard let regex else { return false }
        let nsValue = value as NSString
        let range = NSRange(location: 0, length: nsValue.length)
        guard let match = regex.firstMatch(in: value, range: range), match.range == range else {
            return false
        }
        if isPlainInteger(value) {
            return Int64(value) != nil
        }
        return Double(value)?.isFinite ?? false
    }

    private static func isPlainInteger(_ value: String) -> Bool {
        !value.contains(".") && !value.contains("e") && !value.contains("E")
    }
}
