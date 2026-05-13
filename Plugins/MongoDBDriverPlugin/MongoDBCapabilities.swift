//
//  MongoDBCapabilities.swift
//  MongoDBDriverPlugin
//

import Foundation

struct MongoDBCapabilities: Sendable, Equatable {
    let major: Int
    let minor: Int

    static let unknown = MongoDBCapabilities(major: 0, minor: 0)

    var supportsListDatabasesNameOnly: Bool {
        major > 3 || (major == 3 && minor >= 4)
    }

    static func parse(_ version: String?) -> MongoDBCapabilities {
        guard let version else { return .unknown }
        let parts = version.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return .unknown }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return MongoDBCapabilities(major: major, minor: minor)
    }
}
