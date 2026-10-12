//
//  MSSQLCapabilities.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProMSSQLCore

struct MSSQLCapabilities: Sendable, Equatable {
    let major: Int

    static let unknown = MSSQLCapabilities(major: 0)

    var hasCreateOrAlterView: Bool { major >= 13 }

    static func parse(_ versionString: String?) -> MSSQLCapabilities {
        guard let major = MSSQLServerBanner.majorVersion(from: versionString) else { return .unknown }
        return MSSQLCapabilities(major: major)
    }
}
