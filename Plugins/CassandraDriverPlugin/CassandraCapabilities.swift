//
//  CassandraCapabilities.swift
//  CassandraDriverPlugin
//

import Foundation

struct CassandraCapabilities: Sendable, Equatable {
    let releaseVersionMajor: Int

    static let unknown = CassandraCapabilities(releaseVersionMajor: 0)

    var hasSystemSchemaKeyspace: Bool { releaseVersionMajor >= 3 }

    static func parseMajorVersion(_ version: String?) -> Int {
        guard let version, let majorString = version.split(separator: ".").first,
              let major = Int(majorString) else {
            return 0
        }
        return major
    }
}
