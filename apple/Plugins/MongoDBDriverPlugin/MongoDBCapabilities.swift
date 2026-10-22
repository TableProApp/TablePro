//
//  MongoDBCapabilities.swift
//  MongoDBDriverPlugin
//

import Foundation

nonisolated struct MongoDBCapabilities: Sendable, Equatable {
    let major: Int
    let minor: Int

    static let unknown = MongoDBCapabilities(major: 0, minor: 0)

    var supportsListDatabasesNameOnly: Bool {
        major > 3 || (major == 3 && minor >= 4)
    }

    var supportsAuthorizedDatabases: Bool {
        major >= 4
    }

    /// The guard an edit is saved under uses `$convert`, which MongoDB 4.0 added. A server whose
    /// version is not known is let through, so its own error reaches the user.
    var supportsDocumentReplaceGuard: Bool {
        self == .unknown || major >= 4
    }

    /// `$setField` and `$unsetField` arrived in 5.0. Nil when the version is not known, so the
    /// server answers for itself.
    var supportsFieldExpressions: Bool? {
        guard self != .unknown else { return nil }
        return major >= 5
    }

    // `$regexMatch` arrived in 4.2. A server whose version is not known is not sent it.
    var supportsRegexMatch: Bool {
        major > 4 || (major == 4 && minor >= 2)
    }

    static func parse(_ version: String?) -> MongoDBCapabilities {
        guard let version else { return .unknown }
        let parts = version.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return .unknown }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return MongoDBCapabilities(major: major, minor: minor)
    }
}
