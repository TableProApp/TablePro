import Foundation

public enum LibPQStringConformance {
    public static let parameterName = "standard_conforming_strings"

    public static let enableStatement = "SET standard_conforming_strings TO on"

    public static let showQuery = "SHOW standard_conforming_strings"

    public static func isOn(_ reportedValue: String?) -> Bool? {
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

    public static func escape(_ value: String, standardConformingStrings: Bool) -> String {
        let quoted = value
            .replacingOccurrences(of: "\0", with: "", options: .literal)
            .replacingOccurrences(of: "'", with: "''", options: .literal)
        guard !standardConformingStrings else { return quoted }
        return quoted.replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
    }
}
