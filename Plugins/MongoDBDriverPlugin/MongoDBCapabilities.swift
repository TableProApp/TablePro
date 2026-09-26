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

    var supportsAuthorizedDatabases: Bool {
        major >= 4
    }

    /// `$setField` and `$unsetField` arrived in 5.0. Nil when the version is not known, so the
    /// server answers for itself.
    var supportsFieldExpressions: Bool? {
        guard self != .unknown else { return nil }
        return major >= 5
    }

    static func parse(_ version: String?) -> MongoDBCapabilities {
        guard let version else { return .unknown }
        let parts = version.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return .unknown }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return MongoDBCapabilities(major: major, minor: minor)
    }
}
