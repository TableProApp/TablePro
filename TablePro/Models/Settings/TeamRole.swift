//
//  TeamRole.swift
//  TablePro
//
//  Role a member holds on a Team license, as signed into the license payload
//

import Foundation

/// A member's role on a Team license. String-based rather than a plain enum for the same reason
/// `LicenseTier` is: the server owns the vocabulary and may add to it, so a role this build does
/// not recognise round-trips instead of failing to decode.
internal enum TeamRole: Equatable {
    case owner
    case admin
    case member
    case unknown(String)

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "owner":
            self = .owner
        case "admin":
            self = .admin
        case "member":
            self = .member
        default:
            self = .unknown(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .owner:
            return String(localized: "Owner")
        case .admin:
            return String(localized: "Admin")
        case .member:
            return String(localized: "Member")
        case .unknown(let raw):
            return raw.capitalized
        }
    }
}
