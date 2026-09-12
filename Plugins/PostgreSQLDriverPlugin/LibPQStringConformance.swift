//
//  LibPQStringConformance.swift
//  PostgreSQLDriverPlugin
//

import Foundation

enum LibPQStringConformance {
    static let parameterName = "standard_conforming_strings"

    static let enableStatement = "SET standard_conforming_strings TO on"

    static let showQuery = "SHOW standard_conforming_strings"

    static func isOn(_ reportedValue: String?) -> Bool? {
        guard let reportedValue else { return nil }
        let normalized = reportedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "on", "true", "yes", "1":
            return true
        case "off", "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    static func escape(_ value: String, standardConformingStrings: Bool) -> String {
        let quoted = value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "'", with: "''")
        guard !standardConformingStrings else { return quoted }
        return quoted.replacingOccurrences(of: "\\", with: "\\\\")
    }
}
