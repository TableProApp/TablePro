//
//  MSSQLCapabilities.swift
//  MSSQLDriverPlugin
//

import Foundation

struct MSSQLCapabilities: Sendable, Equatable {
    let major: Int

    static let unknown = MSSQLCapabilities(major: 0)

    var hasCreateOrAlterView: Bool { major >= 13 }

    static func parse(_ versionString: String?) -> MSSQLCapabilities {
        guard let versionString else { return .unknown }
        let pattern = #"(\d+)\.\d+\.\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: versionString,
                range: NSRange(versionString.startIndex..., in: versionString)
              ),
              let range = Range(match.range(at: 1), in: versionString),
              let major = Int(versionString[range]) else {
            return .unknown
        }
        return MSSQLCapabilities(major: major)
    }
}
