//
//  PluginObjectSourceError.swift
//  TableProPluginKit
//
//  Why a driver could not produce an object's source.
//

import Foundation

/// The three answers are genuinely different to a reader and must not collapse into one message.
/// MySQL returns a NULL body rather than an error when the account lacks SHOW_ROUTINE, and Oracle
/// returns nothing rather than raising when the account lacks SELECT_CATALOG_ROLE, so a driver
/// that reports either as "not found" tells the user their routine is gone when it is not.
public enum PluginObjectSourceError: Error, LocalizedError, Sendable {
    case unsupported(String)
    case notFound(String)
    case insufficientPrivilege(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let object):
            return String(format: String(localized: "This database cannot show the source of %@"), object)
        case .notFound(let object):
            return String(format: String(localized: "%@ no longer exists"), object)
        case .insufficientPrivilege(let object):
            return String(
                format: String(localized: "Your account is not allowed to read the source of %@"),
                object
            )
        }
    }
}
